use v6.d;
use experimental :rakuast;
use Raku::LanguageServer::Features::Support;

#| Semantic tokens (full document). Walks the AST and emits typed, delta-encoded
#| tokens for packages, routines, variables, type names, and literals, using the
#| legend advertised in server capabilities.
unit module Raku::LanguageServer::Features::SemanticTokens;

# Token type indices — must match @TOKEN-TYPES order in Server.rakumod.
my constant T-namespace = 0;
my constant T-type      = 1;
my constant T-class     = 2;
my constant T-interface = 4;
my constant T-variable  = 8;
my constant T-function  = 10;
my constant T-method    = 11;
my constant T-string    = 15;
my constant T-number    = 16;
my constant T-regexp    = 17;

my constant MOD-declaration = 1;   # 1 << 0

#| Child Name node origin (from, to), for routine/call identifiers.
sub child-name-span($node) {
    my $span;
    $node.visit-children: -> $c {
        if !$span.defined && $c ~~ RakuAST::Name {
            with (try $c.origin) -> $o { $span = ($o.from, $o.to) if $o.defined }
        }
    }
    $span
}

sub package-type($node) {
    my $n = $node.^name;
    $n.contains('Role')   ?? T-interface
    !! $n.contains('Module') ?? T-namespace
    !!                          T-class
}

#| Collect raw tokens as { from, to, type, mods, prio }. Higher prio wins ties.
sub collect-tokens($ast) {
    my @toks;
    sub emit($from, $to, $type, $mods = 0, $prio = 1) {
        return unless $from.defined && $to.defined && $to > $from;
        @toks.push: %( :$from, :$to, :$type, :$mods, :$prio );
    }
    # $in-regex is true within a regex/token/rule body. Inside it the atoms
    # (subrule calls, captures, char classes, literal matches) are NOT ordinary
    # names/variables/strings, so we don't emit semantic tokens for them and let
    # the editor's regex-aware syntax highlighting handle those spans. Only the
    # enclosing declarations (grammar, token/rule names) get tokens.
    sub visit($node, Bool $in-regex = False) {
        return unless $node ~~ RakuAST::Node;
        my $rx = $in-regex || $node.^name.contains('Regex');
        given $node {
            when RakuAST::Package {
                with (try .name.origin) -> $o {
                    emit($o.from, $o.to, package-type($node), MOD-declaration, 5) if $o.defined;
                }
            }
            when RakuAST::Routine {
                my $t = $node ~~ RakuAST::Method ?? T-method
                     !! $node ~~ RakuAST::Regex  ?? T-regexp
                     !! $node.^name.contains('Regex') ?? T-regexp
                     !!                             T-function;
                with child-name-span($node) -> $s { emit($s[0], $s[1], $t, MOD-declaration, 5) }
            }
            # Regex/grammar constructs — emitted even inside a regex body so they
            # override the editor's (often wrong) built-in regex highlighting.
            when RakuAST::Regex::Assertion::Named {   # <subrule> call
                with (try .origin) -> $o { emit($o.from, $o.to, T-method, 0, 4) if $o.defined }
            }
            when RakuAST::Regex::Quote {              # '...' / "..." literal match
                with (try .origin) -> $o { emit($o.from, $o.to, T-string, 0, 4) if $o.defined }
            }
            when RakuAST::Regex::BackReference {      # $0, $<name> back-references
                with (try .origin) -> $o { emit($o.from, $o.to, T-variable, 0, 4) if $o.defined }
            }
            when RakuAST::Call::Name {
                unless $rx { with child-name-span($node) -> $s { emit($s[0], $s[1], T-function, 0, 4) } }
            }
            when RakuAST::Var {
                unless $rx { with .origin -> $o { emit($o.from, $o.to, T-variable, 0, 3) if $o.defined } }
            }
            when RakuAST::VarDeclaration::Simple {
                unless $rx {
                    with .origin -> $o {
                        emit($o.from, $o.from + (~.name).chars, T-variable, MOD-declaration, 4) if $o.defined;
                    }
                }
            }
            when RakuAST::StrLiteral {
                unless $rx { with .origin -> $o { emit($o.from, $o.to, T-string, 0, 2) if $o.defined } }
            }
            when RakuAST::IntLiteral | RakuAST::NumLiteral | RakuAST::RatLiteral {
                unless $rx { with .origin -> $o { emit($o.from, $o.to, T-number, 0, 2) if $o.defined } }
            }
            when RakuAST::Type::Simple {
                unless $rx { with (try .name.origin) -> $o { emit($o.from, $o.to, T-type, 0, 2) if $o.defined } }
            }
            when RakuAST::Name {
                unless $rx { with .origin -> $o { emit($o.from, $o.to, T-type, 0, 1) if $o.defined } }
            }
        }
        $node.visit-children(-> $c { visit($c, $rx) });
    }
    visit($ast);

    # Dedup by span keeping the highest-priority classification.
    my %best;
    for @toks -> $t {
        my $k = "{$t<from>}..{$t<to>}";
        %best{$k} = $t if !%best{$k} || $t<prio> > %best{$k}<prio>;
    }
    %best.values
}

#| Encode tokens per the LSP semantic-tokens delta format.
sub encode-tokens($doc, @raw) {
    my $pos = $doc.position;
    # Single-line tokens only; sort by position.
    my @tokens = @raw
        .map({
            my %s = $pos.offset-to-position(.<from>);
            my %e = $pos.offset-to-position(.<to>);
            %( line => %s<line>, char => %s<character>,
               len => (%e<line> == %s<line> ?? %e<character> - %s<character> !! 0),
               type => .<type>, mods => .<mods> )
        })
        .grep({ .<len> > 0 })
        .sort({ .<line>, .<char> });

    my @data;
    my ($pl, $pc) = 0, 0;
    for @tokens -> $t {
        my $dl = $t<line> - $pl;
        my $dc = $dl == 0 ?? $t<char> - $pc !! $t<char>;
        @data.append: $dl, $dc, $t<len>, $t<type>, $t<mods>;
        ($pl, $pc) = $t<line>, $t<char>;
    }
    @data
}

sub register-semantic-tokens($server, $analyzer) is export {
    $server.on-request: 'textDocument/semanticTokens/full', -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            with $doc.ast -> $ast {
                %( data => [ encode-tokens($doc, collect-tokens($ast)) ] )
            }
            else { %( data => [] ) }
        }
        else { %( data => [] ) }
    };

    $server.on-request: 'textDocument/semanticTokens/range', -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            with $doc.ast -> $ast {
                my $from = $doc.offset-at(%params<range><start>);
                my $to   = $doc.offset-at(%params<range><end>);
                my @raw  = collect-tokens($ast).grep({ .<from> >= $from && .<to> <= $to });
                %( data => [ encode-tokens($doc, @raw) ] )
            }
            else { %( data => [] ) }
        }
        else { %( data => [] ) }
    };
}

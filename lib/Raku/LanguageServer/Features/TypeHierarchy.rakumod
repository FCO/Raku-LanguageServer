use v6.d;
use experimental :rakuast;
use Raku::LanguageServer::Features::Support;

#| Type hierarchy: from a class/role/grammar, browse its supertypes (what it
#| `is`/`does`) and subtypes (packages that `is`/`does` it). Relationships are
#| read from each package's declaration header; only types declared in the
#| document are linkable (name-based, best-effort).
unit module Raku::LanguageServer::Features::TypeHierarchy;

# LSP SymbolKind
my constant Class     = 5;
my constant Interface = 11;
my constant Module    = 2;

sub package-kind($node --> Int) {
    my $n = $node.^name;
    $n.contains('Role')   ?? Interface
    !! $n.contains('Module') ?? Module
    !!                          Class
}

#| A TypeHierarchyItem from a package declaration occurrence.
sub item($doc, $occ --> Hash) {
    my $o = $occ<node>.origin;
    {
        name           => $occ<text>,
        kind           => package-kind($occ<node>),
        uri            => $doc.uri,
        range          => $doc.range($o.from, $o.to),
        selectionRange => $doc.range($occ<from>, $occ<to>),
        data           => { name => $occ<text> },
    }
}

sub package-decls($analyzer, $doc) {
    $analyzer.occurrences($doc).grep({ .<kind> eq 'decl' && .<node> ~~ RakuAST::Package })
}

#| The declaration header (up to the opening brace) of a package node.
sub header($doc, $node --> Str) {
    my $o    = $node.origin;
    my $src  = $doc.text.substr($o.from, $o.to - $o.from);
    my $brace = $src.index('{');
    $brace.defined ?? $src.substr(0, $brace) !! $src
}

#| Type names named by `is X` / `does X` traits in a header.
sub parent-names(Str $header) {
    ($header ~~ m:g/ << ['is' | 'does'] >> \s+ (<[A..Za..z_]> <[\w:]>*) /)
        .map({ ~.[0] })
}

sub item-doc($srv, $analyzer, %params) {
    my $uri = %params<item><uri> // return Nil;
    my $doc = $srv.workspace.get($uri) // return Nil;
    $analyzer.analyze($doc);
    $doc
}

sub register-type-hierarchy($server, $analyzer) is export {
    $server.on-request: 'textDocument/prepareTypeHierarchy', -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            with $analyzer.identifier-at($doc, param-offset($doc, %params)) -> $id {
                [ package-decls($analyzer, $doc).grep({ .<text> eq $id<text> }).map({ item($doc, $_) }) ]
            }
            else { [] }
        }
        else { [] }
    };

    # Supertypes: the types this one `is`/`does`, if declared in the document.
    $server.on-request: 'typeHierarchy/supertypes', -> %params, $srv {
        with item-doc($srv, $analyzer, %params) -> $doc {
            my $name  = %params<item><data><name> // %params<item><name>;
            my @decls = package-decls($analyzer, $doc);
            with @decls.first({ .<text> eq $name }) -> $self {
                my @parents = parent-names(header($doc, $self<node>));
                [ @parents.map(-> $p { @decls.first({ .<text> eq $p }) }).grep(*.defined).map({ item($doc, $_) }) ]
            }
            else { [] }
        }
        else { [] }
    };

    # Subtypes: packages that `is`/`does` this one.
    $server.on-request: 'typeHierarchy/subtypes', -> %params, $srv {
        with item-doc($srv, $analyzer, %params) -> $doc {
            my $name  = %params<item><data><name> // %params<item><name>;
            [ package-decls($analyzer, $doc)
                .grep({ parent-names(header($doc, .<node>)).grep(* eq $name) })
                .map({ item($doc, $_) }) ]
        }
        else { [] }
    };
}

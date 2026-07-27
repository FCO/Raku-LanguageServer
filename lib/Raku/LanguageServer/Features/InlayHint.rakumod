use v6.d;
use experimental :rakuast;
use Raku::LanguageServer::Features::Support;

#| Inlay hints. Two kinds, both best-effort from RakuAST (no full type inference):
#|
#|  * B<Type hints> — for an untyped `my`/`our`/`state` scalar with a literal or
#|    `.new` initializer, annotate the inferred type after the name: `my $x⟨: Int⟩`.
#|  * B<Parameter hints> — at a call, label positional arguments with the callee's
#|    parameter names: `add(⟨a:⟩ 1, ⟨b:⟩ 2)`.
unit module Raku::LanguageServer::Features::InlayHint;

# LSP InlayHintKind
my constant Type      = 1;
my constant Parameter = 2;

#| Infer a display type for a variable initializer expression, or Nil.
sub infer-type($expr, $doc --> Str) {
    return Str unless $expr.defined;
    my $n = $expr.^name;
    return 'Int'     if $n.contains('IntLiteral');
    return 'Rat'     if $n.contains('RatLiteral');
    return 'Num'     if $n.contains('NumLiteral');
    return 'Complex' if $n.contains('ComplexLiteral');
    return 'Str'     if $n.contains('QuotedString') || $n.contains('StrLiteral');
    # `Type.new` / `Type.bless` construction: read the type name from the source.
    with (try $expr.origin) -> $o {
        my $src = $doc.text.substr($o.from, $o.to - $o.from);
        return ~$0 if $src ~~ / ^ (<[\w]> [<[\w]> | '::']*) '.' ['new' | 'bless'] >> /;
    }
    Str
}

#| Desigilized parameter name (`$a` → `a`), or Nil for parameters not worth
#| labelling: named, slurpy, captures, or anything without a plain `$name`
#| target (e.g. `|c`, whose target has no simple identifier).
sub param-name($p --> Str) {
    return Str if (try $p.named);
    return Str if (try $p.slurpy);
    my $raw = try $p.target.name;
    return Str unless $raw.defined;
    my $s = $raw ~~ Str ?? $raw !! (try ~$raw);
    return Str unless $s.defined;
    # Require a clean sigil + identifier (rejects capture/gist junk like
    # "RakuAST::Name<…>" or "c").
    return Str unless $s ~~ / ^ <[$@%&]> <[_A..Za..z]> \w* $ /;
    return Str if $s eq '%_' || $s eq '$_';
    $s.substr(1)   # drop sigil
}

#| The char offset where an argument visually begins. An argument node's own
#| `origin` is unreliable for placement — a quoted string's origin starts inside
#| the quotes, and a postfix like `$x.key` has the origin of just `.key`. So use
#| the leftmost origin in the argument's subtree, then step back over a leading
#| string delimiter.
sub arg-start($doc, $arg --> Int) {
    my $min;
    sub visit($n) {
        return unless $n ~~ RakuAST::Node;
        with (try $n.origin) -> $o {
            $min = $o.from if $o.defined && (!$min.defined || $o.from < $min);
        }
        $n.visit-children(&visit);
    }
    visit($arg);
    return Nil unless $min.defined;
    my $before = $min > 0 ?? $doc.text.substr($min - 1, 1) !! '';
    $min-- if $before eq q{'} || $before eq q{"} || $before eq '‘'
           || $before eq '“' || $before eq '«';
    $min
}

#| Type name of a method-call invocant when it is written as a type (e.g. the
#| `Foo` in `Foo.bar(...)`), for cross-file method resolution. Nil otherwise.
sub invocant-type-name($operand --> Str) {
    return Str unless $operand.defined;
    return ~(try $operand.name.canonicalize) if $operand ~~ RakuAST::Type::Simple;
    Str
}

sub routine-param-names($routine) {
    my @names;
    with (try $routine.signature) -> $sig {
        for |(try $sig.parameters) // () -> $p {
            @names.push: param-name($p);
        }
    }
    @names
}

sub register-inlay-hint($server, $analyzer) is export {
    $server.on-request: 'textDocument/inlayHint', -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            with $doc.ast -> $ast {
                my $lo = $doc.offset-at(%params<range><start> // { :line(0), :character(0) });
                my $hi = $doc.offset-at(%params<range><end>   // { :line(0), :character(0) });

                # Callee name → declaration, kept separate by kind so a sub call
                # only ever resolves to a sub and a method call to a method.
                my (%subs, %methods);
                for $analyzer.occurrences($doc).grep({ .<kind> eq 'decl' }) -> $o {
                    given $o<node> {
                        when RakuAST::Method { %methods{$o<text>} //= $_ }
                        when RakuAST::Sub    { %subs{$o<text>}    //= $_ }
                    }
                }

                my @hints;
                my sub push-hint($off, Str $label, $kind, :$left, :$right) {
                    return unless $lo <= $off <= $hi;
                    my %h = position => $doc.position.offset-to-position($off), :$label, :$kind;
                    %h<paddingLeft>  = True if $left;
                    %h<paddingRight> = True if $right;
                    @hints.push: %h;
                }

                # Label positional arguments with parameter names (skipping named
                # args). @names is aligned to positional arguments.
                my sub emit-args(@names, @args) {
                    for @args.kv -> $i, $arg {
                        last if $i >= @names.elems;
                        my $pn = @names[$i];
                        next unless $pn.defined;
                        next if $arg.^name.contains('ColonPair') || $arg.^name.contains('FatArrow');
                        with arg-start($doc, $arg) -> $start {
                            push-hint($start, "$pn:", Parameter, :right);
                        }
                    }
                }

                sub visit($node) {
                    return unless $node ~~ RakuAST::Node;

                    # Type hints for untyped scalar declarations with an initializer.
                    if $node ~~ RakuAST::VarDeclaration::Simple {
                        my $name = ~(try $node.name // '');
                        if $name.starts-with('$') && !(try $node.type).defined {
                            with (try $node.initializer) -> $init {
                                my $ty = infer-type((try $init.expression), $doc);
                                with (try $node.origin) -> $o {
                                    push-hint($o.from + $name.chars, ": $ty", Type, :left)
                                        if $ty.defined && $o.defined;
                                }
                            }
                        }
                    }

                    # Sub-call parameter hints (same-file sub declarations).
                    if $node ~~ RakuAST::Call::Name {
                        my $callee = (try $node.name.canonicalize) // (try ~$node.name);
                        with ($callee.defined ?? %subs{~$callee} !! Nil) -> $routine {
                            my @args = |(try $node.args.args) // ();
                            emit-args(routine-param-names($routine), @args);
                        }
                    }

                    # Method-call parameter hints. The invocant lives on the
                    # wrapping ApplyPostfix. Same-file method declarations resolve
                    # by name; otherwise, if the invocant is a type name, that
                    # type's module is loaded and the method signature read via
                    # introspection — so methods from other files are covered too.
                    if $node ~~ RakuAST::ApplyPostfix && (try $node.postfix) ~~ RakuAST::Call::Method {
                        my $call   = $node.postfix;
                        my $method = (try $call.name.canonicalize) // (try ~$call.name);
                        if $method.defined {
                            my @names;
                            with %methods{~$method} -> $routine {
                                @names = routine-param-names($routine);
                            }
                            orwith invocant-type-name($node.operand) -> $tn {
                                @names = $analyzer.type-method-params($doc, $tn, ~$method);
                            }
                            my @args = |(try $call.args.args) // ();
                            emit-args(@names, @args) if @names;
                        }
                    }

                    $node.visit-children(&visit);
                }
                visit($ast);
                [ @hints ]
            }
            else { [] }
        }
        else { [] }
    };
}

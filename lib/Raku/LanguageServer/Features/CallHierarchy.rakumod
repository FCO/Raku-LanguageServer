use v6.d;
use experimental :rakuast;
use Raku::LanguageServer::Features::Support;

#| Call hierarchy: from a routine, browse its callers (incoming) and callees
#| (outgoing). Name-based (best-effort across scopes), reusing the Analyzer's
#| occurrence table and enclosing-routine lookup.
unit module Raku::LanguageServer::Features::CallHierarchy;

# LSP SymbolKind
my constant Method   = 6;
my constant Function = 12;

sub is-routine($node) { $node ~~ RakuAST::Sub || $node ~~ RakuAST::Method }

#| A CallHierarchyItem from a routine declaration occurrence.
sub item($doc, $occ --> Hash) {
    my $o = $occ<node>.origin;
    {
        name           => $occ<text>,
        kind           => ($occ<node> ~~ RakuAST::Method ?? Method !! Function),
        uri            => $doc.uri,
        range          => $doc.range($o.from, $o.to),
        selectionRange => $doc.range($occ<from>, $occ<to>),
        data           => { name => $occ<text> },
    }
}

sub routine-decls($analyzer, $doc) {
    $analyzer.occurrences($doc).grep({ .<kind> eq 'decl' && is-routine(.<node>) })
}

#| Fetch + analyze the document an item lives in.
sub item-doc($srv, $analyzer, %params) {
    my $uri = %params<item><uri> // return Nil;
    my $doc = $srv.workspace.get($uri) // return Nil;
    $analyzer.analyze($doc);
    $doc
}

sub register-call-hierarchy($server, $analyzer) is export {
    $server.on-request: 'textDocument/prepareCallHierarchy', -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            with $analyzer.identifier-at($doc, param-offset($doc, %params)) -> $id {
                [ routine-decls($analyzer, $doc)
                    .grep({ .<text> eq $id<text> })
                    .map({ item($doc, $_) }) ]
            }
            else { [] }
        }
        else { [] }
    };

    # Who calls this routine — grouped by the routine each call sits in.
    $server.on-request: 'callHierarchy/incomingCalls', -> %params, $srv {
        with item-doc($srv, $analyzer, %params) -> $doc {
            my $name  = %params<item><data><name> // %params<item><name>;
            my @decls = routine-decls($analyzer, $doc);
            my %callers;
            for $analyzer.occurrences($doc).grep({ .<kind> eq 'use' && .<text> eq $name }) -> $call {
                with $analyzer.enclosing-routine($doc, $call<from>) -> $r {
                    with @decls.first({ .<node> === $r }) -> $occ {
                        my $key = "{$occ<from>}:{$occ<to>}";
                        %callers{$key} //= { from => item($doc, $occ), fromRanges => [] };
                        %callers{$key}<fromRanges>.push: $doc.range($call<from>, $call<to>);
                    }
                }
            }
            [ %callers.values ]
        }
        else { [] }
    };

    # What this routine calls — grouped by callee.
    $server.on-request: 'callHierarchy/outgoingCalls', -> %params, $srv {
        with item-doc($srv, $analyzer, %params) -> $doc {
            my $name  = %params<item><data><name> // %params<item><name>;
            my @decls = routine-decls($analyzer, $doc);
            my %by-name;
            %by-name{.<text>} //= $_ for @decls;

            with @decls.first({ .<text> eq $name }) -> $self {
                my $span = $self<node>.origin;
                my %callees;
                for $analyzer.occurrences($doc).grep({
                        .<kind> eq 'use' && (%by-name{.<text>}:exists)
                        && $span.from <= .<from> < $span.to
                }) -> $call {
                    my $callee = %by-name{$call<text>};
                    my $key    = "{$callee<from>}:{$callee<to>}";
                    %callees{$key} //= { to => item($doc, $callee), fromRanges => [] };
                    %callees{$key}<fromRanges>.push: $doc.range($call<from>, $call<to>);
                }
                [ %callees.values ]
            }
            else { [] }
        }
        else { [] }
    };
}

use v6.d;
use experimental :rakuast;
use Raku::LanguageServer::Features::Support;

#| Go to implementation. Best-effort (name-based):
#|  * for a routine name — every declaration of a routine with that name;
#|  * for a role/class name — every package that consumes it (`does`/`is`),
#|    across the project rather than only in the open buffer.
#|
#| The name is taken qualified where it is written that way: matching a bare
#| `Transform` against the source text never found `does Cro::Transform`, so
#| asking for implementations of an imported role came back empty even when a
#| consumer sat in the same file.
unit module Raku::LanguageServer::Features::Implementation;

sub register-implementation($server, $analyzer) is export {
    $server.on-request: 'textDocument/implementation', -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            my $offset = param-offset($doc, %params);
            with $analyzer.identifier-at($doc, $offset) -> $id {
                my $name = $analyzer.qualified-name-at($doc, $offset) // $id<text>;

                # Routine implementations sharing the name, from the buffer's AST.
                my @routines = $analyzer.occurrences($doc).grep({
                    .<kind> eq 'decl' && .<text> eq $id<text>
                    && (.<node> ~~ RakuAST::Sub || .<node> ~~ RakuAST::Method)
                }).map({ location($doc, .<from>, .<to>) });

                # Packages consuming a role/class of this name, project-wide.
                # The consumer the cursor is standing in is dropped: asking for
                # implementations from inside `class RouteSet does Cro::Transform`
                # otherwise answers with that same line, which just navigates to
                # where you already are.
                my $cursor-line = $doc.position.offset-to-position($offset)<line>;
                my @consumers = $analyzer.consumers-of($doc, $name).grep({
                    !(.<uri> eq $doc.uri && .<range><start><line> == $cursor-line)
                });

                my %seen;
                [ (|@routines, |@consumers).grep({
                    !%seen{"{.<uri>}:{.<range><start><line>}:{.<range><start><character>}"}++
                }) ]
            }
            else { [] }
        }
        else { [] }
    };
}

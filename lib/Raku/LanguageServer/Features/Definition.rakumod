use v6.d;
use Raku::LanguageServer::Features::Support;

#| Go to definition / declaration. Resolves the identifier under the cursor
#| (name-based) to the declaration(s) with the same name. In Raku declaration
#| and definition coincide, so both requests share this handler.
#|
#| The buffer is searched first; a name declared in another file — a class from
#| a `use`d module, a routine from a sibling file — is then looked up across the
#| project, which is the only way `gd` works on an imported type.
#|
#| When the cursor is already ON the declaration, jumping to it does nothing, so
#| what implements it is offered instead: the packages consuming a role, or the
#| other declarations of a routine's name.
unit module Raku::LanguageServer::Features::Definition;

#| The name under the cursor, preferring the qualified form: the declaring file
#| spells `Cro::Transform`, not the segment the cursor happens to sit on.
sub name-at($analyzer, $doc, Int $offset) {
    my $id = $analyzer.identifier-at($doc, $offset) orelse return Nil;
    my %r  = bare => $id<text>;
    %r<qualified> = $analyzer.qualified-name-at($doc, $offset) // $id<text>;
    %r
}

sub declaration-locations($analyzer, $doc, %name, Int $offset) {
    my @local = $analyzer.occurrences($doc)
        .grep({ .<kind> eq 'decl' && .<text> eq %name<bare> })
        .map({ location($doc, .<from>, .<to>) });
    return @local if @local;

    # The buffer may simply not compile right now, leaving no AST to search.
    # Scan its text before looking at other files, so a local name never
    # resolves to some other file that happens to mention it.
    my @scanned = $analyzer.local-declaration-spans($doc, %name<bare>);
    return @scanned if @scanned;

    if %name<qualified> ne %name<bare> {
        my @q = $analyzer.cross-file-declarations($doc, %name<qualified>);
        return @q if @q;
    }
    $analyzer.cross-file-declarations($doc, %name<bare>).List
}

#| True when every location is the line the cursor is already on — i.e. going
#| there would not move.
sub all-under-cursor(@locs, $doc, Int $line --> Bool) {
    so @locs && !@locs.grep({
        !(.<uri> eq $doc.uri && .<range><start><line> == $line)
    })
}

#| What implements the declaration under the cursor: packages that consume it,
#| plus declarations of the same name elsewhere (a routine's other candidates).
sub implementations-of($analyzer, $doc, %name, Int $line) {
    my @found = |$analyzer.consumers-of($doc, %name<qualified>),
                |$analyzer.cross-file-declarations($doc, %name<qualified>);
    my %seen;
    @found.grep({
        !(.<uri> eq $doc.uri && .<range><start><line> == $line)
        && !%seen{"{.<uri>}:{.<range><start><line>}:{.<range><start><character>}"}++
    })
}

sub register-definition($server, $analyzer) is export {
    my &handler = -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            my $offset = param-offset($doc, %params);
            with name-at($analyzer, $doc, $offset) -> %name {
                my @locs = declaration-locations($analyzer, $doc, %name, $offset);
                my $line = $doc.position.offset-to-position($offset)<line>;

                # Standing on the declaration: offer what implements it, but only
                # if there is something — otherwise the declaration itself is
                # still the honest answer.
                if all-under-cursor(@locs, $doc, $line) {
                    my @impls = implementations-of($analyzer, $doc, %name, $line);
                    @locs = @impls if @impls;
                }
                [ @locs ]
            }
            else { [] }
        }
        else { [] }
    };
    $server.on-request: 'textDocument/definition',  &handler;
    $server.on-request: 'textDocument/declaration', &handler;
}

use v6.d;
use Raku::LanguageServer::Features::Support;
use Raku::LanguageServer::Features::References;

#| Rename symbol. Produces a WorkspaceEdit replacing every occurrence of the
#| identifier under the cursor with the new name. Name-based (best-effort across
#| scopes), matching the resolution used by references.
unit module Raku::LanguageServer::Features::Rename;

sub register-rename($server, $analyzer) is export {
    # prepareRename: confirm there is a renameable identifier and return its range.
    $server.on-request: 'textDocument/prepareRename', -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            with $analyzer.identifier-at($doc, param-offset($doc, %params)) -> $id {
                { range => $doc.range($id<from>, $id<to>), placeholder => $id<text> }
            }
            else { Any }
        }
        else { Any }
    };

    $server.on-request: 'textDocument/rename', -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            my $new  = %params<newName> // '';
            my @occ  = matching-occurrences($analyzer, $doc, param-offset($doc, %params));
            my @edits = @occ.map({ %( range => $doc.range(.<from>, .<to>), newText => $new ) });
            { changes => { $doc.uri => [@edits] } }
        }
        else { Any }
    };
}

use v6.d;
use Raku::LanguageServer::Document;
use Raku::LanguageServer::Features::Support;

#| Workspace-level notifications.
#|
#| `didChangeWatchedFiles` matters here beyond bookkeeping: cross-file lookups
#| read other files from disk and cache them, and while an mtime check catches
#| edits, a file created or deleted behind the server's back would otherwise
#| linger. `didChangeConfiguration` is accepted and ignored — the server has no
#| settings yet, but a client that sends it should not see an error.
unit module Raku::LanguageServer::Features::Workspace;

sub register-workspace-notifications($server, $analyzer) is export {
    $server.on-notification: 'workspace/didChangeWatchedFiles', -> %params, $srv {
        my @paths = (%params<changes> // ()).map({ .<uri> // Str })
                                            .grep(*.defined)
                                            .map({ uri-to-path($_) });
        $analyzer.forget-files(|@paths);
    };
    $server.on-notification: 'workspace/didChangeConfiguration', -> %params, $srv { };
}

use v6.d;
use Raku::LanguageServer::Features::Diagnostics;

#| Text document synchronization: keeps the workspace in step with the editor
#| (full sync) and republishes diagnostics on every open/change. Registers the
#| `textDocument/didOpen`, `didChange`, and `didClose` notifications.
unit module Raku::LanguageServer::Features::TextSync;

sub register-text-sync($server, $analyzer) is export {
    $server.on-notification: 'textDocument/didOpen', -> %params, $srv {
        my %td   = %params<textDocument>;
        my $doc  = $srv.workspace.open(%td<uri>, %td<text> // '', %td<version> // 0);
        publish-diagnostics($srv, $analyzer, $doc);
    };

    $server.on-notification: 'textDocument/didChange', -> %params, $srv {
        my $uri     = %params<textDocument><uri>;
        my $version = %params<textDocument><version> // 0;
        # Full sync: the last content change holds the entire new text.
        my @changes = |(%params<contentChanges> // ());
        my $text    = @changes ?? @changes[*-1]<text> // '' !! '';
        my $doc     = $srv.workspace.change($uri, $text, $version);
        publish-diagnostics($srv, $analyzer, $doc);
    };

    $server.on-notification: 'textDocument/didClose', -> %params, $srv {
        my $uri = %params<textDocument><uri>;
        $srv.workspace.close($uri);
        # Clear diagnostics for the closed file.
        $srv.notify: 'textDocument/publishDiagnostics',
            { :$uri, diagnostics => [] };
    };
}

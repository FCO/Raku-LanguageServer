use v6.d;
use Raku::LanguageServer::Document;

#| Helpers shared across feature handlers.
unit module Raku::LanguageServer::Features::Support;

#| Fetch the open document named by a request's `textDocument.uri` and ensure it
#| is analyzed. Returns Nil if the document is not open.
sub analyzed-doc($server, $analyzer, %params) is export {
    my $uri = %params<textDocument><uri> // return Nil;
    my $doc = $server.workspace.get($uri) // return Nil;
    # Keep the analyzer's view of the workspace in step with the client's. This is
    # what lets a project-wide search work from a buffer whose own directory is not
    # a project — a dependency opened at `~/.raku/sources/<sha>`.
    $analyzer.workspace-roots = $server.workspace-roots;
    $analyzer.peer-uris       = $server.workspace.all.map(*.uri).grep({ $_ ne $uri });
    $analyzer.analyze($doc);
    $doc
}

#| Char offset for the `position` field of a request's params.
sub param-offset(Raku::LanguageServer::Document:D $doc, %params --> Int) is export {
    $doc.offset-at(%params<position> // { :line(0), :character(0) })
}

#| An LSP `Location` for a char-offset span in a document.
sub location(Raku::LanguageServer::Document:D $doc, Int $from, Int $to --> Hash) is export {
    { uri => $doc.uri, range => $doc.range($from, $to) }
}

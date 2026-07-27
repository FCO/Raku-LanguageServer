use v6.d;
use Raku::LanguageServer::Features::Support;

#| Document highlight: highlights every occurrence of the identifier under the
#| cursor within the current file (drives editors' cursor-hold highlighting).
unit module Raku::LanguageServer::Features::DocumentHighlight;

# LSP DocumentHighlightKind
my constant Read  = 2;
my constant Write = 3;

sub register-document-highlight($server, $analyzer) is export {
    $server.on-request: 'textDocument/documentHighlight', -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            with $analyzer.identifier-at($doc, param-offset($doc, %params)) -> $id {
                [ $analyzer.occurrences($doc)
                    .grep({ .<text> eq $id<text> })
                    .map({ %(
                        range => $doc.range(.<from>, .<to>),
                        kind  => .<kind> eq 'decl' ?? Write !! Read,
                    ) }) ]
            }
            else { [] }
        }
        else { [] }
    };
}

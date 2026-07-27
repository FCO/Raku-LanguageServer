use v6.d;
use Raku::LanguageServer::Features::Support;

#| Document links: turns each `use`/`need` of a module that lives in the current
#| project's `lib/` into a clickable link to that module's source file.
unit module Raku::LanguageServer::Features::DocumentLink;

sub register-document-link($server, $analyzer) is export {
    $server.on-request: 'textDocument/documentLink', -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            my @links;
            for $analyzer.use-statements($doc) -> $use {
                with $analyzer.resolve-module-file($doc, $use<module>) -> $path {
                    @links.push: %(
                        range  => $doc.range($use<from>, $use<to>),
                        target => 'file://' ~ $path,
                    );
                }
            }
            [ @links ]
        }
        else { [] }
    };
}

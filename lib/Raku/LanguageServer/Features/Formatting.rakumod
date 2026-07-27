use v6.d;
use experimental :rakuast;
use Raku::LanguageServer::Features::Support;

#| Document formatting via RakuAST deparse. Only formats when the buffer's
#| cached AST matches the current text (i.e. it compiles cleanly); otherwise
#| returns no edits rather than risk reformatting from a stale tree.
#|
#| Note: deparse normalizes source aggressively (whitespace, quoting, optional
#| parentheses), so output can differ stylistically from the input.
unit module Raku::LanguageServer::Features::Formatting;

sub register-formatting($server, $analyzer) is export {
    $server.on-request: 'textDocument/formatting', -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            if $doc.ast-current {
                my $formatted = try $doc.ast.DEPARSE;
                if $formatted.defined && $formatted ne $doc.text {
                    # A single-element edit list; itemize the hash so it is not
                    # flattened into pairs by list context.
                    my $edit = %(
                        range   => $doc.range(0, $doc.text.chars),
                        newText => ~$formatted,
                    );
                    [ $edit ]
                }
                else { [] }
            }
            else { [] }
        }
        else { [] }
    };
}

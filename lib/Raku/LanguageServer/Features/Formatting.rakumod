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

#| Format only the selected lines. Deparse works on the whole tree, so there is
#| no way to format a fragment directly; instead the statements that begin
#| inside the selection are re-deparsed individually and spliced back, leaving
#| everything outside the range untouched.
sub register-range-formatting($server, $analyzer) is export {
    $server.on-request: 'textDocument/rangeFormatting', -> %params, $srv {
        my @edits;
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            if $doc.ast-current {
                my %r   = %params<range> // %();
                my $from = $doc.offset-at(%r<start> // %( line => 0, character => 0 ));
                my $to   = $doc.offset-at(%r<end>   // %( line => 0, character => 0 ));
                for $analyzer.statements-in($doc, $from, $to) -> %stmt {
                    my $new = try %stmt<node>.DEPARSE;
                    next unless $new.defined;
                    $new = ~$new;
                    $new .= chomp;
                    my $old = $doc.text.substr(%stmt<from>, %stmt<to> - %stmt<from>);
                    next if $new eq $old || $new eq '';
                    # Keep the statement's own indentation.
                    my $line   = $doc.position.offset-to-position(%stmt<from>)<line>;
                    my $indent = ($doc.text.lines[$line] // '') ~~ / ^ (\h*) / ?? ~$0 !! '';
                    $new = $new.lines.kv.map(-> $i, $l {
                        $i == 0 ?? $l !! ($l eq '' ?? '' !! $indent ~ $l)
                    }).join("\n");
                    @edits.push: %( range => $doc.range(%stmt<from>, %stmt<to>), newText => $new );
                }
            }
        }
        # Later edits first: applying back-to-front keeps earlier offsets valid.
        [ @edits.sort({ -.<range><start><line> }) ]
    };
}

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

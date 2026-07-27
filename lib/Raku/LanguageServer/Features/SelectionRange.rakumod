use v6.d;
use Raku::LanguageServer::Features::Support;

#| Selection range (smart expand/shrink). For each requested position, returns
#| the innermost enclosing AST range with a `parent` chain widening outward.
unit module Raku::LanguageServer::Features::SelectionRange;

#| Build the nested SelectionRange for one offset from its ancestor spans
#| (ordered innermost-first). Falls back to a zero-width range at the offset.
sub build($doc, @spans, Int $off) {
    my $node;
    # Fold from outermost (largest) inward so each node's parent is the next
    # wider range; the final $node is the innermost.
    for @spans.reverse -> $s {
        my %sr = range => $doc.range($s[0], $s[1]);
        %sr<parent> = $node if $node.defined;
        $node = %sr;
    }
    $node // %( range => $doc.range($off, $off) )
}

sub register-selection-range($server, $analyzer) is export {
    $server.on-request: 'textDocument/selectionRange', -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            [ (%params<positions> // ()).map({
                my $off = $doc.offset-at($_);
                build($doc, $analyzer.ancestors-at($doc, $off), $off)
            }) ]
        }
        else { [] }
    };
}

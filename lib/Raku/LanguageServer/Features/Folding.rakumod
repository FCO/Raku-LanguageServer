use v6.d;
use experimental :rakuast;
use Raku::LanguageServer::Features::Support;

#| Folding ranges. Emits a fold for every multi-line block-bearing construct
#| (packages, routines, and blocks).
unit module Raku::LanguageServer::Features::Folding;

sub register-folding($server, $analyzer) is export {
    $server.on-request: 'textDocument/foldingRange', -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            my $ast = $doc.ast;
            if $ast {
                my $pos = $doc.position;
                my %by-start;      # startLine → widest endLine
                sub visit($node) {
                    return unless $node ~~ RakuAST::Node;
                    if $node ~~ RakuAST::Package
                    || $node ~~ RakuAST::Routine
                    || $node ~~ RakuAST::Block {
                        with $node.origin -> $o {
                            if $o.defined {
                                my $start = $pos.offset-to-position($o.from)<line>;
                                my $end   = $pos.offset-to-position($o.to - 1)<line>;
                                if $end > $start {
                                    %by-start{$start} = ($end max (%by-start{$start} // 0));
                                }
                            }
                        }
                    }
                    $node.visit-children(&visit);
                }
                visit($ast);
                [ %by-start.sort(*.key).map({
                    %( startLine => .key.Int, endLine => .value.Int )
                }) ]
            }
            else { [] }
        }
        else { [] }
    };
}

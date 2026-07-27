use v6.d;
use experimental :rakuast;
use Raku::LanguageServer::Features::Support;

#| Signature help. When the cursor is inside a call's argument list, shows the
#| callee's signature and highlights the active parameter.
unit module Raku::LanguageServer::Features::SignatureHelp;

#| Innermost RakuAST::Call whose origin span contains the offset.
sub enclosing-call($analyzer, $doc, Int $offset) {
    my $ast = $doc.ast orelse return Nil;
    my $best; my $best-span = Inf;
    sub visit($node) {
        return unless $node ~~ RakuAST::Node;
        if $node ~~ RakuAST::Call {
            with $node.origin -> $o {
                if $o.defined && $o.from <= $offset <= $o.to && ($o.to - $o.from) < $best-span {
                    $best = $node; $best-span = $o.to - $o.from;
                }
            }
        }
        $node.visit-children(&visit);
    }
    visit($ast);
    $best
}

#| Parameter label strings from a routine node's signature.
sub param-labels($routine) {
    my @labels;
    with (try $routine.signature) -> $sig {
        for |(try $sig.parameters) // () -> $p {
            my $l = (try $p.DEPARSE) // '';
            @labels.push: $l.trim if $l.trim;
        }
    }
    @labels
}

#| Active parameter index: commas between the call's opening paren and cursor.
sub active-parameter($doc, $call, Int $offset --> Int) {
    my $o = $call.origin orelse return 0;
    my $open = $doc.text.index('(', $o.from);
    return 0 unless $open.defined && $open < $offset;
    $doc.text.substr($open + 1, $offset - $open - 1).comb(',').elems
}

sub register-signature-help($server, $analyzer) is export {
    $server.on-request: 'textDocument/signatureHelp', -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            my $off  = param-offset($doc, %params);
            my $call = enclosing-call($analyzer, $doc, $off);
            if $call {
                my $name = (try $call.name.canonicalize) // '';
                my $decl = $analyzer.occurrences($doc)
                    .first({ .<kind> eq 'decl' && .<text> eq ~$name });
                my @labels = $decl ?? param-labels($decl<node>) !! [];
                my $label  = "$name\({ @labels.join(', ') })";
                my $sig = %(
                    :$label,
                    parameters => [ @labels.map({ %( label => $_ ) }) ],
                );
                %(
                    signatures       => [ $sig ],
                    activeSignature  => 0,
                    activeParameter  => active-parameter($doc, $call, $off),
                )
            }
            else { Any }
        }
        else { Any }
    };
}

use v6.d;
use experimental :rakuast;
use Raku::LanguageServer::Features::Support;

#| Hover. Shows the declaration of the identifier under the cursor (kind, name,
#| and a deparsed signature line) as Markdown; falls back to the AST node kind
#| when nothing resolves.
unit module Raku::LanguageServer::Features::Hover;

#| First non-empty line of a node's deparsed source (the signature-ish line).
sub signature-line($node --> Str) {
    my $src = (try $node.DEPARSE) // '';
    ($src.lines.first(*.trim.chars) // '').trim
}

sub markdown(Str $code, Str $note = '' --> Hash) {
    my $value = "```raku\n$code\n```";
    $value ~= "\n\n$note" if $note;
    { kind => 'markdown', :$value }
}

sub register-hover($server, $analyzer) is export {
    $server.on-request: 'textDocument/hover', -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            my $off = param-offset($doc, %params);
            with $analyzer.identifier-at($doc, $off) -> $id {
                my $decl = $analyzer.occurrences($doc)
                    .first({ .<kind> eq 'decl' && .<text> eq $id<text> });
                if $decl {
                    {
                        contents => markdown(signature-line($decl<node>)),
                        range    => $doc.range($id<from>, $id<to>),
                    }
                }
                else {
                    # Unresolved: describe the AST node kind at the cursor.
                    my $node = $analyzer.node-at($doc, $off);
                    my $kind = $node ?? $node.^name.subst('RakuAST::', '') !! 'term';
                    {
                        contents => markdown($id<text>, "*$kind*"),
                        range    => $doc.range($id<from>, $id<to>),
                    }
                }
            }
            else { Any }
        }
        else { Any }
    };
}

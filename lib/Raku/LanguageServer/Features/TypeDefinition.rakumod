use v6.d;
use experimental :rakuast;
use Raku::LanguageServer::Features::Support;

#| Go to type definition. If the identifier under the cursor is a type name,
#| jumps to that type's declaration; if it is a typed variable, resolves the
#| variable's declared type and jumps there. Best-effort (name-based).
unit module Raku::LanguageServer::Features::TypeDefinition;

sub register-type-definition($server, $analyzer) is export {
    $server.on-request: 'textDocument/typeDefinition', -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            with $analyzer.identifier-at($doc, param-offset($doc, %params)) -> $id {
                my @occ = $analyzer.occurrences($doc);

                # Determine the type name to jump to: the identifier itself, or,
                # if it is a typed variable declaration, its declared type.
                my $type-name = $id<text>;
                with @occ.first({ .<kind> eq 'decl' && .<text> eq $id<text> }) -> $decl {
                    if $decl<node> ~~ RakuAST::VarDeclaration::Simple {
                        with (try $decl<node>.type.name.canonicalize) -> $t {
                            $type-name = ~$t;
                        }
                    }
                }

                [ @occ
                    .grep({ .<kind> eq 'decl' && .<node> ~~ RakuAST::Package
                            && .<text> eq $type-name })
                    .map({ location($doc, .<from>, .<to>) }) ]
            }
            else { [] }
        }
        else { [] }
    };
}

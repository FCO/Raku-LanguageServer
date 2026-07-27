use v6.d;
use experimental :rakuast;
use Raku::LanguageServer::Features::Support;

#| Code lens: a "N references" annotation above each routine and package
#| declaration. The count is the number of use-sites of that name (name-based,
#| like references). The lens carries a `showReferences` command so clients that
#| support it can jump straight to the reference list.
unit module Raku::LanguageServer::Features::CodeLens;

sub is-lensable($node) { $node ~~ RakuAST::Routine || $node ~~ RakuAST::Package }

sub register-code-lens($server, $analyzer) is export {
    $server.on-request: 'textDocument/codeLens', -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            my @occ = $analyzer.occurrences($doc);

            # Use-sites grouped by name, counted once.
            my %uses;
            %uses{.<text>}.push($_) for @occ.grep({ .<kind> eq 'use' });

            my @lenses;
            for @occ.grep({ .<kind> eq 'decl' && is-lensable(.<node>) }) -> $d {
                my @refs  = |(%uses{$d<text>} // []);
                my $count = @refs.elems;
                my $pos   = $doc.position.offset-to-position($d<from>);
                @lenses.push: %(
                    range   => $doc.range($d<from>, $d<to>),
                    command => %(
                        title     => "$count reference{$count == 1 ?? '' !! 's'}",
                        command   => 'editor.action.showReferences',
                        arguments => [
                            $doc.uri,
                            $pos,
                            [ @refs.map({ location($doc, .<from>, .<to>) }) ],
                        ],
                    ),
                );
            }
            [ @lenses ]
        }
        else { [] }
    };
}

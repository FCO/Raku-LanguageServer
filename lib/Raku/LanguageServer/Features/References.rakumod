use v6.d;
use Raku::LanguageServer::Features::Support;

#| Find references. Returns every occurrence (declarations and uses) of the
#| identifier under the cursor, in the buffer and across the project.
#| `context.includeDeclaration` is honored.
#|
#| The buffer's own occurrences come from its AST, so they never fall inside a
#| string or comment. Other files are scanned as text — the server does not
#| compile files the user did not open — so those are best-effort.
unit module Raku::LanguageServer::Features::References;

#| Shared by references and rename: all occurrences matching the identifier at
#| the given offset, within the current document only. Rename depends on this
#| staying buffer-local; it edits only the open document.
sub matching-occurrences($analyzer, $doc, Int $offset) is export {
    with $analyzer.identifier-at($doc, $offset) -> $id {
        $analyzer.occurrences($doc).grep({ .<text> eq $id<text> }).List
    }
    else { () }
}

sub register-references($server, $analyzer) is export {
    $server.on-request: 'textDocument/references', -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            my $offset  = param-offset($doc, %params);
            my $include = %params<context><includeDeclaration> // True;

            my @occ = matching-occurrences($analyzer, $doc, $offset);
            @occ = @occ.grep({ .<kind> ne 'decl' }) unless $include;
            my @locs = @occ.map({ location($doc, .<from>, .<to>) });

            with $analyzer.identifier-at($doc, $offset) -> $id {
                # A qualified reference is spelled in full elsewhere, so search
                # for that form when the cursor sits inside one.
                my $name = $analyzer.qualified-name-at($doc, $offset) // $id<text>;

                # No AST means no occurrences for this file — common for a module
                # whose dependencies do not all resolve. Scan its text instead,
                # or `gr` reports nothing for the very file being read.
                @locs = $analyzer.local-reference-spans(
                    $doc, $id<text>, include-declarations => $include) unless @locs;

                @locs.append: $analyzer.references-across-files(
                    $doc, $name, include-declarations => $include);
            }
            [ @locs ]
        }
        else { [] }
    };
}

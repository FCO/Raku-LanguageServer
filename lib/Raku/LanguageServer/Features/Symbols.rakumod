use v6.d;
use Raku::LanguageServer::Features::Support;

#| Document and workspace symbols. Converts the Analyzer's symbol tree into LSP
#| `DocumentSymbol[]` (hierarchical) and `SymbolInformation[]` (flat, workspace).
unit module Raku::LanguageServer::Features::Symbols;

#| Convert one Analyzer symbol (and its children) into an LSP DocumentSymbol.
sub to-document-symbol($doc, $sym --> Hash) {
    {
        name           => $sym.name,
        detail         => $sym.detail,
        kind           => $sym.kind,
        range          => $doc.range($sym.from, $sym.to),
        selectionRange => $doc.range($sym.sel-from, $sym.sel-to),
        children       => [ $sym.children.map({ to-document-symbol($doc, $_) }) ],
    }
}

#| Flatten the symbol tree into LSP SymbolInformation entries for workspace
#| symbol results (which are not hierarchical).
sub flatten-symbols($doc, @syms, $container = Str, @into = []) {
    for @syms -> $sym {
        @into.push: {
            name          => $sym.name,
            kind          => $sym.kind,
            location      => location($doc, $sym.from, $sym.to),
            containerName => $container,
        };
        flatten-symbols($doc, $sym.children, $sym.name, @into);
    }
    @into
}

sub register-symbols($server, $analyzer) is export {
    $server.on-request: 'textDocument/documentSymbol', -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            [ $doc.symbols.map({ to-document-symbol($doc, $_) }) ]
        }
        else { [] }
    };

    $server.on-request: 'workspace/symbol', -> %params, $srv {
        my $query = (%params<query> // '').lc;
        my @results;
        for $srv.workspace.all -> $doc {
            $analyzer.analyze($doc);
            my @flat = flatten-symbols($doc, $doc.symbols);
            @results.append: @flat.grep({ !$query || .<name>.lc.contains($query) });
        }
        @results
    };
}

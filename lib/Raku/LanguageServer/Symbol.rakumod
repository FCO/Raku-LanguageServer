use v6.d;

#| A declaration discovered in a document: a package, routine, or variable.
#| Carries enough to build an LSP `DocumentSymbol` and to answer hover /
#| definition / reference queries.
#|
#|  * `from`/`to`       — char offsets of the whole declaration
#|  * `sel-from`/`sel-to` — char offsets of just the name (LSP selection range)
unit class Raku::LanguageServer::Symbol;

has Str $.name;
has Int $.kind;            #| LSP SymbolKind
has Str $.detail = '';
has Int $.from;
has Int $.to;
has Int $.sel-from;
has Int $.sel-to;
has $.node;               #| the RakuAST node
has @.children;

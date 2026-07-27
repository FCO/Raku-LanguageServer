use v6.d;
use Raku::LanguageServer::Position;

#| One open text document. Holds the current text and version, a lazily built
#| `Position` index for coordinate conversion, and slots the Analyzer fills in
#| with the parsed AST, extracted symbols, and any compile error.
unit class Raku::LanguageServer::Document;

has Str $.uri      is required;
has Str $.text     is rw = '';
has Int $.version  is rw = 0;
has Str $.encoding is rw = 'utf-16';

# Analysis cache — populated by the Analyzer.
#
# `ast`/`symbols` hold the LAST SUCCESSFUL parse and survive edits that fail to
# compile, so positional features degrade gracefully while the user is mid-edit
# (their offsets may be slightly stale). `compile-error` always reflects the
# latest analysis. `ast-version` records which text version `ast` came from.
has $.ast          is rw;          #| last good RakuAST root, or Nil
has @.symbols      is rw;          #| symbol tree from the last good AST
has Int $.ast-version is rw = -1;
has $.compile-error is rw;         #| the X::Comp exception from the latest analyze, or Nil
has Bool $.analyzed is rw = False;

has Raku::LanguageServer::Position $!position;

#| Replace the whole document text (full sync) and mark analysis stale.
#| The last-good AST and symbols are intentionally retained.
method update(Str $text, Int $version) {
    $!text     = $text;
    $!version  = $version;
    $!position = Nil;              # invalidate coordinate index
    $!analyzed = False;
}

#| True when the cached AST matches the current text.
method ast-current(--> Bool) { $!ast.defined && $!ast-version == $!version }

#| The coordinate index for the current text (built on demand).
method position(--> Raku::LanguageServer::Position) {
    $!position //= Raku::LanguageServer::Position.new(:$!text, :$!encoding);
}

#| Convenience: char offset for an LSP position hash.
method offset-at(%pos --> Int) { self.position.position-to-offset(%pos) }

#| Convenience: LSP range for a char-offset span.
method range(Int $from, Int $to --> Hash) { self.position.range($from, $to) }

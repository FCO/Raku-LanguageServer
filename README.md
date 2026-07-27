class Raku::LanguageServer
--------------------------

A Language Server Protocol implementation for Raku, written in Raku. Construct with a Transport (defaults to stdio) and call `.run` to serve. All features share one Analyzer, which compiles buffers in-process via RakuAST and caches the parsed tree and symbol table per document.

### method register-features

```raku
method register-features() returns Mu
```

Wire every feature's handlers onto the server.

### method run

```raku
method run() returns Mu
```

Run the server loop until the client disconnects or sends `exit`.

NAME
====

Raku::LanguageServer - A Language Server Protocol implementation for Raku, in Raku

SYNOPSIS
========

```raku
# Speaks LSP over stdin/stdout; takes no arguments.
raku-language-server
```

DESCRIPTION
===========

`Raku::LanguageServer` is a [Language Server Protocol](https://microsoft.github.io/language-server-protocol/) server for the Raku programming language, written in Raku and powered by **RakuAST**. It compiles the buffer in-process with `.AST`, with the owning project on the module search path, so `use`d sibling modules resolve and diagnostics come from the real compiler rather than a reimplementation of it. Source positions RakuAST attaches to every node (`.origin.from`/`.to`) drive the position-based features.

A buffer that fails to compile keeps its last good AST, so hover, symbols, folding and the rest keep working while you are mid-edit instead of blinking out on every incomplete keystroke.

Navigation
----------

  * **Go to definition / declaration** — searches the buffer, then the project, then the modules it uses. On a declaration it falls back to implementations, since jumping to where the cursor already is helps nobody.

  * **Go to type definition** — from a typed variable to its type's declaration

  * **Go to implementation** — every package that `does`/`is` a role or class, project-wide

  * **Find references** — occurrences in the buffer (from the AST) and across the project

  * **Document highlight** — occurrences of the symbol under the cursor

  * **Document & workspace symbols** — hierarchical outline of packages, routines and variables

  * **Call hierarchy** — a routine's callers and callees

  * **Type hierarchy** — a class's supertypes and subtypes

  * **Document links** — `use`d modules link to their source file

Reading and editing
-------------------

  * **Diagnostics** — live compile errors, warnings and worries, pushed as you type or pulled on request

  * **Hover** — declaration kind and deparsed signature

  * **Completion** — context-aware; see below

  * **Signature help** — parameters of the call being written

  * **Inlay hints** — parameter names at call sites, including for types declared in other files

  * **Semantic tokens** — typed tokens for highlighting (full document and by range)

  * **Selection range** — smart expand following the syntax tree

  * **Folding ranges** — fold packages, routines and blocks

  * **Formatting** — whole document or a selected range, via RakuAST deparse

  * **Code lens** — a "N references" count above each routine and package

  * **Rename** — rename an identifier across the document

  * **Code actions** — quick fixes and refactorings; see below

Completion
----------

What is offered depends on where the cursor is, rather than being one undifferentiated list:

  * after `.` — real methods of the invocant's type, resolved from `my Foo $x`, `self`, a bare type name, or a typed block topic (`-> Foo $_ { .« } `). A type's own methods rank above what it inherits, and each item says which class it came from.

  * after `.name:` — callables: the block forms first, then every routine in reach, `&`-sigiled

  * after a sigil — declared variables of that sigil only

  * after `use` — module names from the project and from installed distributions

  * after `is`/`does` — traits, including those a used module adds

  * otherwise — keywords, all `CORE::` routines, the buffer's own declarations, and what its modules bring in: exported routines, operators, types, and custom declarators

Custom declarators come from the compile-time `EXPORTHOW::DECLARE` hook, so a module adding `model` or `actor` gets it completed like a keyword.

Refactorings
------------

Offered as code actions at the cursor or over a selection.

  * **Extract to variable** (`refactor.extract`) — a selected single-line expression

  * **Extract to routine** (`refactor.extract`) — selected statements; the new `sub` lands before the enclosing routine

  * **Inline variable** (`refactor.inline`) — a `my $x = …;` that is used and never reassigned

  * **Postfix ⇄ block `if`/`unless`** (`refactor.rewrite`) — a one-statement conditional with no `else`

  * **Convert quotes** `'` ⇄ `"` (`refactor.rewrite`) — only when flipping cannot change meaning

  * **Add `is export`** (`refactor.rewrite`) — on a routine or package declaration

  * **Toggle `has $.x` ⇄ `has $!x`** (`refactor.rewrite`) — give an attribute an accessor, or take it away

  * **Wrap in `try`** (`refactor.rewrite`) — around a selection

  * **Sort `use` statements** (`source.organizeImports`) — when the leading block is out of order

Quick fixes are driven by the compiler's own message: declare an undeclared variable with `my`, apply a "Did you mean" suggestion, stub an undeclared routine, add a `use` for an undeclared type. A **Beautify** source action deparses the whole document.

Cross-file lookup
-----------------

Definition, implementation and references reach past the open buffer. Other files are searched **by scanning their text, never by compiling them**: `.AST` resolves and runs `BEGIN`, so compiling a project's own sources inside the server re-registers their packages in the running process — which once handed the server a second, incompatible copy of its own classes mid-request. Scanning also works on the many files that do not compile standalone.

Candidates are tried in order of likelihood, stopping at the first file that answers: the name read as a module name and its parent namespaces; then a breadth-first walk of the `use` graph, which is what finds a type reached only transitively (a file saying just `use Cro`) or one whose module is named nothing like it; then the rest of the project.

The price of scanning rather than compiling is precision: a declaration-shaped phrase inside a string literal can match. Comments are filtered out.

Caveats
-------

  * **`.AST` runs `BEGIN` blocks and `use` statements** of the buffer. That is what makes the diagnostics real, but opening a file does execute its compile-time code. Every compile is wrapped in `try` and can never crash the server.

  * **Rename is buffer-local.** It will not touch other files; widening it means editing on a text match, which wants `workspaceEdit` support and more confidence than a scan can offer.

  * **Cross-file results are text-derived**, so they can match inside string literals. Results from the open buffer come from the AST and do not.

  * **Roles applied at runtime** (`.^add_role`) or via `also does` in a body are not found by the implementation search, which reads declaration headers.

  * **Extract to routine does not compute parameters** — it leaves an empty signature rather than guessing one wrong.

  * **Formatting normalizes source aggressively**, since deparse rewrites whitespace, quoting and optional parentheses.

Editor setup
------------

The server is the `raku-language-server` executable (installed to your Raku `bin`). During development, run it with `raku -Ilib bin/raku-language-server`.

**Neovim** (0.11+):

```lua
vim.filetype.add {
  extension = { raku = 'raku', rakumod = 'raku', rakutest = 'raku',
                rakudoc = 'raku', rakuconfig = 'raku', pm6 = 'raku' },
  -- Installed dependency sources live at `sources/<sha1>` with no extension.
  -- Without this, jumping into one lands in a buffer with no filetype, and so
  -- no language server.
  pattern = {
    ['.*/%.raku/sources/%x+'] = 'raku',
    ['.*/share/perl6/.*/sources/%x+'] = 'raku',
  },
}

vim.lsp.config['raku_ls'] = {
  cmd = { 'raku-language-server' },
  filetypes = { 'raku' },
  root_markers = { 'META6.json', '.git' },
}
vim.lsp.enable('raku_ls')
```

A dependency opened from `~/.raku/sources` has no `META6.json` above it, so marker-based detection finds no root and project-wide requests have nowhere to search. If you follow definitions into dependencies often, hand such buffers the root of a project you already have open via a `root_dir` function.

**Emacs** (Eglot):

```lisp
(add-to-list 'eglot-server-programs '(raku-mode . ("raku-language-server")))
(add-hook 'raku-mode-hook #'eglot-ensure)
```

**VS Code**: no extension is published; use a generic LSP client extension and point its server command at `raku-language-server` with `raku` as the document selector.

Architecture
------------

    Transport   Content-Length framing over stdio, binary-safe
    Protocol    JSON-RPC envelopes and error codes
    Server      lifecycle, capabilities, request/notification dispatch
    Workspace   open documents, keyed by URI
    Document    text, version, coordinate index, cached AST
    Position    char offset <-> LSP {line, character}, utf-8 or utf-16
    Analyzer    compiles buffers, extracts symbols, answers structural queries
    Features/   one module per LSP capability

Every feature shares one `Analyzer`. Each `Features/*.rakumod` exports `register-E<lt>nameE<gt>($server, $analyzer)`, wired up in `Raku::LanguageServer.register-features`.

Development
-----------

    zef install --deps-only .
    prove6 -I. t

The suite drives the real `Server` over an in-memory transport rather than mocking handlers, so a failing test usually means a client would see the same thing. CI runs on Linux, macOS and Windows.

AUTHOR
======

Fernando Correa de Oliveira <fco@cpan.org>

COPYRIGHT AND LICENSE
=====================

Copyright 2026 Fernando Correa de Oliveira

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.


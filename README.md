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
# Start the server (speaks LSP over stdio):
raku-language-server
```

DESCRIPTION
===========

`Raku::LanguageServer` is a [Language Server Protocol](https://microsoft.github.io/language-server-protocol/) server for the Raku programming language, written in Raku and powered by **RakuAST**. It compiles the buffer in-process with `.AST`, using the source positions RakuAST attaches to every node (`.origin.from`/`.to`) to drive position-based features.

It communicates with any LSP-capable editor over stdin/stdout using JSON-RPC 2.0 with `Content-Length` framing.

Features
--------

  * **Diagnostics** — live syntax/compile errors as you type

  * **Document & workspace symbols** — hierarchical outline of packages, routines, and variables

  * **Hover** — declaration kind and deparsed signature

  * **Completion** — keywords, common built-ins, and in-scope declarations

  * **Go to definition / declaration** — jump to a declaration (name-based resolution)

  * **Go to type definition** — jump from a typed variable to its type's declaration

  * **Go to implementation** — routines of a name, or packages consuming a role/class

  * **Find references** — every use and declaration of an identifier

  * **Call hierarchy** — browse a routine's callers (incoming) and callees (outgoing)

  * **Type hierarchy** — browse a class's supertypes and subtypes

  * **Code lens** — a "N references" count above each routine and package

  * **Code actions** — quick-fixes (declare undeclared variable, apply a "Did you mean" suggestion, stub an undeclared routine, add a `use` for an undeclared type) and a beautify (deparse) source action

  * **Document highlight** — highlight occurrences of the symbol under the cursor

  * **Rename** — rename an identifier across the document

  * **Signature help** — parameters of the call under the cursor

  * **Semantic tokens** — typed tokens for richer highlighting (full and by range)

  * **Selection range** — smart expand/shrink following the syntax tree

  * **Inlay hints** — inferred types for untyped literals and parameter names at calls

  * **Document links** — `use`d project modules link to their source files

  * **Folding ranges** — fold packages, routines, and blocks

  * **Formatting** — whole-document reformat via RakuAST deparse

Caveats
-------

Diagnostics use an in-process `.AST` compile, which **runs** `BEGIN` blocks and `use` statements in the buffer. Every compile is isolated in a `try` so it can never crash the server, but be aware that opening a file executes its compile-time code. Definition/references/rename use name-based resolution (best-effort across scopes). Formatting normalizes source aggressively.

Editor setup
------------

The server is the `raku-language-server` executable (installed to your Raku `bin`). During development, run it with `raku -Ilib bin/raku-language-server`.

**Neovim** (built-in LSP):

```lua
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'raku',
  callback = function(args)
    vim.lsp.start({
      name = 'raku-language-server',
      cmd = { 'raku-language-server' },
      root_dir = vim.fs.dirname(vim.fs.find({ 'META6.json', '.git' }, { upward = true })[1]),
    })
  end,
})
```

**Emacs** (Eglot):

```lisp
(add-to-list 'eglot-server-programs '(raku-mode . ("raku-language-server")))
(add-hook 'raku-mode-hook #'eglot-ensure)
```

**VS Code**: use a generic LSP client extension and point its server command at `raku-language-server` with `raku` as the document selector.

AUTHOR
======

Fernando Correa de Oliveira <fco@cpan.org>

COPYRIGHT AND LICENSE
=====================

Copyright 2026 Fernando Correa de Oliveira

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.


use v6.d;
use Raku::LanguageServer::Transport;
use Raku::LanguageServer::Server;
use Raku::LanguageServer::Analyzer;
use Raku::LanguageServer::Features::TextSync;
use Raku::LanguageServer::Features::Symbols;
use Raku::LanguageServer::Features::Hover;
use Raku::LanguageServer::Features::Completion;
use Raku::LanguageServer::Features::Folding;
use Raku::LanguageServer::Features::Definition;
use Raku::LanguageServer::Features::TypeDefinition;
use Raku::LanguageServer::Features::Implementation;
use Raku::LanguageServer::Features::References;
use Raku::LanguageServer::Features::DocumentHighlight;
use Raku::LanguageServer::Features::Rename;
use Raku::LanguageServer::Features::SignatureHelp;
use Raku::LanguageServer::Features::SemanticTokens;
use Raku::LanguageServer::Features::SelectionRange;
use Raku::LanguageServer::Features::InlayHint;
use Raku::LanguageServer::Features::CallHierarchy;
use Raku::LanguageServer::Features::TypeHierarchy;
use Raku::LanguageServer::Features::CodeLens;
use Raku::LanguageServer::Features::CodeAction;
use Raku::LanguageServer::Features::DocumentLink;
use Raku::LanguageServer::Features::Formatting;

#| A Language Server Protocol implementation for Raku, written in Raku.
#|
#| Construct with a Transport (defaults to stdio) and call `.run` to serve. All
#| features share one Analyzer, which compiles buffers in-process via RakuAST
#| and caches the parsed tree and symbol table per document.
unit class Raku::LanguageServer;

has Raku::LanguageServer::Transport $.transport .= new;
has Raku::LanguageServer::Analyzer  $.analyzer  .= new;
has Raku::LanguageServer::Server    $.server;

submethod TWEAK {
    $!server //= Raku::LanguageServer::Server.new(:$!transport);
    self.register-features;
}

#| Wire every feature's handlers onto the server.
method register-features {
    register-text-sync($!server, $!analyzer);
    register-symbols($!server, $!analyzer);
    register-hover($!server, $!analyzer);
    register-completion($!server, $!analyzer);
    register-folding($!server, $!analyzer);
    register-definition($!server, $!analyzer);
    register-type-definition($!server, $!analyzer);
    register-implementation($!server, $!analyzer);
    register-references($!server, $!analyzer);
    register-document-highlight($!server, $!analyzer);
    register-rename($!server, $!analyzer);
    register-signature-help($!server, $!analyzer);
    register-semantic-tokens($!server, $!analyzer);
    register-selection-range($!server, $!analyzer);
    register-inlay-hint($!server, $!analyzer);
    register-call-hierarchy($!server, $!analyzer);
    register-type-hierarchy($!server, $!analyzer);
    register-code-lens($!server, $!analyzer);
    register-code-action($!server, $!analyzer);
    register-document-link($!server, $!analyzer);
    register-formatting($!server, $!analyzer);
}

#| Run the server loop until the client disconnects or sends `exit`.
method run {
    $!server.run;
}

=begin pod

=head1 NAME

Raku::LanguageServer - A Language Server Protocol implementation for Raku, in Raku

=head1 SYNOPSIS

=begin code :lang<raku>

# Start the server (speaks LSP over stdio):
raku-language-server

=end code

=head1 DESCRIPTION

C<Raku::LanguageServer> is a L<Language Server Protocol|https://microsoft.github.io/language-server-protocol/>
server for the Raku programming language, written in Raku and powered by
B<RakuAST>. It compiles the buffer in-process with C<.AST>, using the source
positions RakuAST attaches to every node (C<.origin.from>/C<.to>) to drive
position-based features.

It communicates with any LSP-capable editor over stdin/stdout using JSON-RPC 2.0
with C<Content-Length> framing.

=head2 Features

=item B<Diagnostics> — live syntax/compile errors as you type
=item B<Document & workspace symbols> — hierarchical outline of packages, routines, and variables
=item B<Hover> — declaration kind and deparsed signature
=item B<Completion> — keywords, common built-ins, and in-scope declarations
=item B<Go to definition / declaration> — jump to a declaration (name-based resolution)
=item B<Go to type definition> — jump from a typed variable to its type's declaration
=item B<Go to implementation> — routines of a name, or packages consuming a role/class
=item B<Find references> — every use and declaration of an identifier
=item B<Call hierarchy> — browse a routine's callers (incoming) and callees (outgoing)
=item B<Type hierarchy> — browse a class's supertypes and subtypes
=item B<Code lens> — a "N references" count above each routine and package
=item B<Code actions> — quick-fixes (declare undeclared variable, apply a "Did you mean" suggestion, stub an undeclared routine, add a C<use> for an undeclared type) and a beautify (deparse) source action
=item B<Document highlight> — highlight occurrences of the symbol under the cursor
=item B<Rename> — rename an identifier across the document
=item B<Signature help> — parameters of the call under the cursor
=item B<Semantic tokens> — typed tokens for richer highlighting (full and by range)
=item B<Selection range> — smart expand/shrink following the syntax tree
=item B<Inlay hints> — inferred types for untyped literals and parameter names at calls
=item B<Document links> — `use`d project modules link to their source files
=item B<Folding ranges> — fold packages, routines, and blocks
=item B<Formatting> — whole-document reformat via RakuAST deparse

=head2 Caveats

Diagnostics use an in-process C<.AST> compile, which B<runs> C<BEGIN> blocks and
C<use> statements in the buffer. Every compile is isolated in a C<try> so it can
never crash the server, but be aware that opening a file executes its
compile-time code. Definition/references/rename use name-based resolution
(best-effort across scopes). Formatting normalizes source aggressively.

=head2 Editor setup

The server is the C<raku-language-server> executable (installed to your Raku
C<bin>). During development, run it with C<raku -Ilib bin/raku-language-server>.

B<Neovim> (built-in LSP):

=begin code :lang<lua>

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

=end code

B<Emacs> (Eglot):

=begin code :lang<lisp>

(add-to-list 'eglot-server-programs '(raku-mode . ("raku-language-server")))
(add-hook 'raku-mode-hook #'eglot-ensure)

=end code

B<VS Code>: use a generic LSP client extension and point its server command at
C<raku-language-server> with C<raku> as the document selector.

=head1 AUTHOR

Fernando Correa de Oliveira <fco@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Fernando Correa de Oliveira

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod

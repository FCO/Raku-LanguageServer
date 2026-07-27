use v6.d;
use Raku::LanguageServer::Transport;
use Raku::LanguageServer::Server;
use Raku::LanguageServer::Analyzer;
use Raku::LanguageServer::Features::TextSync;
use Raku::LanguageServer::Features::Diagnostics;
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
use Raku::LanguageServer::Features::Workspace;

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
    register-range-formatting($!server, $!analyzer);
    register-diagnostic-request($!server, $!analyzer);
    register-workspace-notifications($!server, $!analyzer);
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

# Speaks LSP over stdin/stdout; takes no arguments.
raku-language-server

=end code

=head1 DESCRIPTION

C<Raku::LanguageServer> is a L<Language Server Protocol|https://microsoft.github.io/language-server-protocol/>
server for the Raku programming language, written in Raku and powered by
B<RakuAST>. It compiles the buffer in-process with C<.AST>, with the owning
project on the module search path, so C<use>d sibling modules resolve and
diagnostics come from the real compiler rather than a reimplementation of it.
Source positions RakuAST attaches to every node (C<.origin.from>/C<.to>) drive
the position-based features.

A buffer that fails to compile keeps its last good AST, so hover, symbols,
folding and the rest keep working while you are mid-edit instead of blinking
out on every incomplete keystroke.

=head2 Navigation

=item B<Go to definition / declaration> — searches the buffer, then the project, then the modules it uses. On a declaration it falls back to implementations, since jumping to where the cursor already is helps nobody.
=item B<Go to type definition> — from a typed variable to its type's declaration
=item B<Go to implementation> — every package that C<does>/C<is> a role or class, project-wide
=item B<Find references> — occurrences in the buffer (from the AST) and across the project
=item B<Document highlight> — occurrences of the symbol under the cursor
=item B<Document & workspace symbols> — hierarchical outline of packages, routines and variables
=item B<Call hierarchy> — a routine's callers and callees
=item B<Type hierarchy> — a class's supertypes and subtypes
=item B<Document links> — C<use>d modules link to their source file

=head2 Reading and editing

=item B<Diagnostics> — live compile errors, warnings and worries, pushed as you type or pulled on request
=item B<Hover> — declaration kind and deparsed signature
=item B<Completion> — context-aware; see below
=item B<Signature help> — parameters of the call being written
=item B<Inlay hints> — parameter names at call sites, including for types declared in other files
=item B<Semantic tokens> — typed tokens for highlighting (full document and by range)
=item B<Selection range> — smart expand following the syntax tree
=item B<Folding ranges> — fold packages, routines and blocks
=item B<Formatting> — whole document or a selected range, via RakuAST deparse
=item B<Code lens> — a "N references" count above each routine and package
=item B<Rename> — rename an identifier across the document
=item B<Code actions> — quick fixes and refactorings; see below

=head2 Completion

What is offered depends on where the cursor is, rather than being one
undifferentiated list:

=item after C<.> — real methods of the invocant's type, resolved from C<my Foo $x>, C<self>, a bare type name, or a typed block topic (C<< -> Foo $_ { .« } >>). A type's own methods rank above what it inherits, and each item says which class it came from.
=item after C<.name:> — callables: the block forms first, then every routine in reach, C<&>-sigiled
=item after a sigil — declared variables of that sigil only
=item after C<use> — module names from the project and from installed distributions
=item after C<is>/C<does> — traits, including those a used module adds
=item otherwise — keywords, all C<CORE::> routines, the buffer's own declarations, and what its modules bring in: exported routines, operators, types, and custom declarators

Custom declarators come from the compile-time C<EXPORTHOW::DECLARE> hook, so a
module adding C<model> or C<actor> gets it completed like a keyword.

=head2 Refactorings

Offered as code actions at the cursor or over a selection.

=item B<Extract to variable> (C<refactor.extract>) — a selected single-line expression
=item B<Extract to routine> (C<refactor.extract>) — selected statements; the new C<sub> lands before the enclosing routine
=item B<Inline variable> (C<refactor.inline>) — a C<my $x = …;> that is used and never reassigned
=item B<Postfix ⇄ block C<if>/C<unless>> (C<refactor.rewrite>) — a one-statement conditional with no C<else>
=item B<Convert quotes> C<'> ⇄ C<"> (C<refactor.rewrite>) — only when flipping cannot change meaning
=item B<Add C<is export>> (C<refactor.rewrite>) — on a routine or package declaration
=item B<Toggle C<has $.x> ⇄ C<has $!x>> (C<refactor.rewrite>) — give an attribute an accessor, or take it away
=item B<Wrap in C<try>> (C<refactor.rewrite>) — around a selection
=item B<Sort C<use> statements> (C<source.organizeImports>) — when the leading block is out of order

Quick fixes are driven by the compiler's own message: declare an undeclared
variable with C<my>, apply a "Did you mean" suggestion, stub an undeclared
routine, add a C<use> for an undeclared type. A B<Beautify> source action
deparses the whole document.

=head2 Cross-file lookup

Definition, implementation and references reach past the open buffer. Other
files are searched B<by scanning their text, never by compiling them>: C<.AST>
resolves and runs C<BEGIN>, so compiling a project's own sources inside the
server re-registers their packages in the running process — which once handed
the server a second, incompatible copy of its own classes mid-request. Scanning
also works on the many files that do not compile standalone.

Candidates are tried in order of likelihood, stopping at the first file that
answers: the name read as a module name and its parent namespaces; then a
breadth-first walk of the C<use> graph, which is what finds a type reached only
transitively (a file saying just C<use Cro>) or one whose module is named
nothing like it; then the rest of the project.

The price of scanning rather than compiling is precision: a declaration-shaped
phrase inside a string literal can match. Comments are filtered out.

=head2 Caveats

=item B<C<.AST> runs C<BEGIN> blocks and C<use> statements> of the buffer. That is what makes the diagnostics real, but opening a file does execute its compile-time code. Every compile is wrapped in C<try> and can never crash the server.
=item B<Rename is buffer-local.> It will not touch other files; widening it means editing on a text match, which wants C<workspaceEdit> support and more confidence than a scan can offer.
=item B<Cross-file results are text-derived>, so they can match inside string literals. Results from the open buffer come from the AST and do not.
=item B<Roles applied at runtime> (C<.^add_role>) or via C<also does> in a body are not found by the implementation search, which reads declaration headers.
=item B<Extract to routine does not compute parameters> — it leaves an empty signature rather than guessing one wrong.
=item B<Formatting normalizes source aggressively>, since deparse rewrites whitespace, quoting and optional parentheses.

=head2 Editor setup

The server is the C<raku-language-server> executable (installed to your Raku
C<bin>). During development, run it with C<raku -Ilib bin/raku-language-server>.

B<Neovim> (0.11+):

=begin code :lang<lua>

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

=end code

A dependency opened from C<~/.raku/sources> has no C<META6.json> above it, so
marker-based detection finds no root and project-wide requests have nowhere to
search. If you follow definitions into dependencies often, hand such buffers
the root of a project you already have open via a C<root_dir> function.

B<Emacs> (Eglot):

=begin code :lang<lisp>

(add-to-list 'eglot-server-programs '(raku-mode . ("raku-language-server")))
(add-hook 'raku-mode-hook #'eglot-ensure)

=end code

B<VS Code>: no extension is published; use a generic LSP client extension and
point its server command at C<raku-language-server> with C<raku> as the
document selector.

=head2 Architecture

=begin code

Transport   Content-Length framing over stdio, binary-safe
Protocol    JSON-RPC envelopes and error codes
Server      lifecycle, capabilities, request/notification dispatch
Workspace   open documents, keyed by URI
Document    text, version, coordinate index, cached AST
Position    char offset <-> LSP {line, character}, utf-8 or utf-16
Analyzer    compiles buffers, extracts symbols, answers structural queries
Features/   one module per LSP capability

=end code

Every feature shares one C<Analyzer>. Each C<Features/*.rakumod> exports
C<register-E<lt>nameE<gt>($server, $analyzer)>, wired up in
C<Raku::LanguageServer.register-features>.

=head2 Development

=begin code

zef install --deps-only .
prove6 -I. t

=end code

The suite drives the real C<Server> over an in-memory transport rather than
mocking handlers, so a failing test usually means a client would see the same
thing. CI runs on Linux, macOS and Windows.

=head1 AUTHOR

Fernando Correa de Oliveira <fco@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Fernando Correa de Oliveira

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod

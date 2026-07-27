use v6.d;
use MONKEY-SEE-NO-EVAL;
use experimental :rakuast;
use Raku::LanguageServer::Document;
use Raku::LanguageServer::Symbol;

#| Turns document text into a RakuAST tree and a symbol table, and answers
#| structural queries (`node-at`, `document-symbols`). Compilation happens in
#| process via `.AST` and is fully guarded: a buffer that fails to compile
#| leaves the previous good AST in place and records the error for Diagnostics.
unit class Raku::LanguageServer::Analyzer;

# LSP SymbolKind numeric constants (subset we emit).
my constant SK-Module    = 2;
my constant SK-Package   = 4;
my constant SK-Class     = 5;
my constant SK-Method    = 6;
my constant SK-Field     = 8;
my constant SK-Enum      = 10;
my constant SK-Interface = 11;
my constant SK-Function  = 12;
my constant SK-Variable  = 13;
my constant SK-Constant  = 14;

# `use` targets that are not loadable modules.
my constant PRAGMAS = set <
    v6 v6.c v6.d v6.e lib strict isms experimental fatal worries
    nqp MONKEY MONKEY-SEE-NO-EVAL MONKEY-TYPING MONKEY-GUTS trace variables
    precompilation soft invocant
>;

#| How many files one lookup may read before giving up. The `use` graph of a
#| framework can be large; a bound keeps a miss from walking the ecosystem.
my constant MAX-FILES-SCANNED = 400;

# uri → project root path (or Nil). The repo chain is deliberately NOT cached;
# see `!repo-chain`.
has %!root-cache;

# Cross-file type introspection: module-name → loaded type object (present only
# on success), plus a set of names already attempted (so we EVAL each once).
has %!type-cache;
has %!type-attempted;

# Completion support, all keyed by module name: exported symbol names, trait
# names, and custom `EXPORTHOW::DECLARE` declarators.
has %!export-cache;
has %!trait-cache;
has %!declarator-cache;
has @!known-modules;

# path → { stamp, text } for files that are not open in the editor, so a
# cross-file scan reads each file once per version.
has %!file-text-cache;

#| Directories the editor reports as the workspace, set from `initialize`.
#| A buffer's own path is not always a useful project: opening a dependency
#| lands in `~/.raku/sources/<sha>`, whose directory says nothing about which
#| code the user is actually working on.
has @.workspace-roots is rw;

#| URIs of the other documents currently open. Editors do not always supply a
#| workspace root — Neovim derives one from `META6.json`/`.git` above the file,
#| so a dependency opened under `~/.raku/sources` gets `root=nil` and no root at
#| all. The projects owning the other open buffers are then the best available
#| answer to "which code did the user mean".
has @.peer-uris is rw;

#| Positional, hint-worthy parameter names (desigilized) of a runtime Signature,
#| skipping the invocant, `%_`, named, and slurpy parameters.
sub runtime-param-names($sig) {
    ((try $sig.params) // ()).grep({
        (try .name).defined && !(try .invocant) && !(try .named)
        && !(try .slurpy) && .name ne '%_' && .name.chars > 1
    }).map({ .name.substr(1) })
}

#| Load a module by name into this process (once) so its type becomes available
#| for meta-object introspection. Runs under the document's repo chain. Loading
#| executes the module's compile-time code — the same cost already paid when the
#| buffer that `use`s it is compiled.
method !ensure-type-loaded(Raku::LanguageServer::Document:D $doc, Str $name) {
    return if %!type-attempted{$name}++;
    return unless $name ~~ / ^ <[A..Za..z_]> <[\w:]>* $ /;   # sanitize before EVAL
    my $repo = (try self!repo-chain($doc.uri)) // $*REPO;

    # `use <TypeName>` covers the common case of a type living in a module of the
    # same name. It misses types a module merely *exports* — `RootConfig` out of
    # a `Test1Config` — so fall back to importing each module the buffer uses and
    # asking for the name from there.
    my @sources = $name, |self.used-module-names($doc).map({ "$_; $name" });
    my ($type, $ok);
    {
        my $*REPO = $repo;
        for @sources -> $source {
            $ok = try { $type = EVAL "use $source"; True };
            last if $ok;
        }
    }
    %!type-cache{$name} = $type if $ok;
}

#| Module names a chunk of source pulls in, by scanning its `use`/`need` lines.
#| Text-based so it works on any file without compiling it — which is how the
#| `use` graph gets walked past the buffer itself.
sub used-names-in-text(Str $text) {
    ($text ~~ m:g/ ^^ \h* ['use' | 'need'] \h+
                   ( <[A..Za..z_]> \w* [ '::' \w+ ]* ) /)
        .map({ ~.[0] })
        .grep({ $_ && $_ !(elem) PRAGMAS })
        .unique
}

#| Module names the buffer pulls in, from the AST when it has one and from the
#| text as well — the two disagree exactly while the buffer is being edited.
#| Pragmas and version literals are dropped: they are not loadable modules.
method used-module-names(Raku::LanguageServer::Document:D $doc) {
    my @ast = ((try self.use-statements($doc)) // ()).map({ .<module> });
    my @txt = used-names-in-text($doc.text);
    (|@ast, |@txt).grep({ $_ && $_ !(elem) PRAGMAS && sane-module-name($_) }).unique
}

#| Positional parameter names of a method found on a type declared in another
#| module, by loading that module and introspecting. `[]` if unknown. This is
#| what lets us describe methods from classes in other files.
method type-method-params(Raku::LanguageServer::Document:D $doc, Str $type-name, Str $method-name) {
    self!ensure-type-loaded($doc, $type-name);
    return [] unless %!type-cache{$type-name}:exists;
    my $type = %!type-cache{$type-name};
    my $m    = try $type.^lookup($method-name);
    return [] unless $m.defined;
    my @cands = (try $m.candidates).List || ($m,);
    @cands ?? runtime-param-names(@cands[0].signature).Array !! []
}

#| Decode a `file://` URI to a filesystem path.
method !uri-to-path(Str $uri --> Str) {
    return $uri unless $uri.starts-with('file://');
    my $p = $uri.subst(/^ 'file://' <-[/]>* /, '');   # drop scheme + optional authority
    $p = $p.subst(:g, / '%' (<[0..9A..Fa..f]> ** 2) /, { chr(:16(~$0)) });
    # `file:///C:/x` decodes to `/C:/x`, which is not a path Windows accepts.
    $p .= subst(/^ '/' (<[A..Za..z]> ':')/, { ~$0 });
    norm-path($p)
}

#| One spelling for a path so comparisons hold: Windows reports `.absolute` with
#| backslashes while URIs carry forward slashes, and the two must still compare
#| equal when deciding whether a candidate file is the buffer itself.
sub norm-path(Str $p --> Str) { $p.subst(:g, '\\', '/') }

#| Encode a filesystem path as a `file://` URI. The extra slash matters on
#| Windows: an absolute path there starts with a drive letter rather than `/`,
#| so `file://` + `C:/x` would make `C:` look like the authority.
sub path-to-uri(IO() $path --> Str) {
    my $abs = norm-path($path.absolute);
    $abs.starts-with('/') ?? "file://$abs" !! "file:///$abs"
}

#| The root directory of the project that owns a document — the nearest ancestor
#| with a `META6.json`, found by walking up from the file. Nil for loose files.
#| Cached per URI.
method !project-root(Str $uri) {
    return %!root-cache{$uri} if %!root-cache{$uri}:exists;
    my $root = Str;
    my $dir  = self!uri-to-path($uri).IO.parent;
    while $dir.defined && $dir.Str ne $dir.parent.Str {   # stop at filesystem root
        if $dir.add('META6.json').e {
            $root = $dir.absolute;
            last;
        }
        $dir = $dir.parent;
    }
    %!root-cache{$uri} = $root
}

#| The project's `lib/` directory, if it has one. Used for document links.
method !project-lib(Str $uri) {
    my $root = self!project-root($uri) orelse return Str;
    my $lib  = $root.IO.add('lib');
    $lib.d ?? $lib.Str !! Str
}

#| Ordered list of directories to put on the buffer's module-search path,
#| highest priority first:
#|   * the owning project's `META6.json` directory (`.`, so its `provides` is
#|     honored) and its `lib/`;
#|   * the file's own directory, so sibling modules `use`d by a script or test
#|     resolve even outside a project layout.
#| Only existing dirs, de-duplicated.
method !search-prefixes(Str $uri) {
    my @prefixes;
    # Never the filesystem root: a repo rooted there makes every failed module
    # lookup walk the whole disk.
    my &add = -> $io {
        @prefixes.push: $io.absolute
            if $io.defined && $io.d && $io.absolute ne $io.parent.absolute;
    };

    with self!project-root($uri) -> $root {
        add($root.IO);            # .   — the META6.json directory
        add($root.IO.add('lib')); # lib
    }
    add(self!uri-to-path($uri).IO.parent);   # the file's current directory

    my %seen;
    @prefixes.grep({ !%seen{$_}++ })
}

#| A cached module-search repo chain for a buffer: the search prefixes chained
#| ahead of the process default (installed dependencies), highest priority as the
#| chain head. Nil when there are no candidate directories.
#| Absolute prefixes of every repo already reachable from a chain.
method !chain-prefixes($start) {
    my %seen;
    my $repo = $start;
    while $repo.defined {
        with (try $repo.prefix) -> $p { %seen{$p.absolute} = True }
        $repo = try $repo.next-repo;
    }
    %seen
}

#| The buffer's module-search chain. Rebuilt on every call, never cached — see
#| below for why that is load-bearing rather than wasteful.
method !repo-chain(Str $uri) {
    my @prefixes = self!search-prefixes($uri);

    # Prefixes already reachable from `$*REPO` are left out: they resolve through
    # it anyway, and adding them would only create more shared links to re-point.
    my %on-chain = self!chain-prefixes($*REPO);
    @prefixes .= grep({ !%on-chain{$_} });
    return Nil unless @prefixes;

    # `CompUnit::Repository::FileSystem` interns ONE instance per prefix, process
    # wide, and ignores the `next-repo` passed to a repeat `.new`. So any two
    # documents sharing a prefix — every pair of files in the same project —
    # share those objects and their links. Whichever document built its chain
    # last wins, and the other one's own directory is silently orphaned:
    # opening examples/test1/x.rakuconfig and then examples/test2/y.rakuconfig
    # left the second unable to find its sibling module at all.
    #
    # Assigning `next-repo` afterwards does take effect, so the chain is re-linked
    # on every use instead. That keeps it correct for the document being analyzed
    # right now, which is all that is needed: analysis is synchronous, and the
    # chain is consumed immediately by the caller's `my $*REPO = …` block.
    my $chain = $*REPO;
    for @prefixes.reverse -> $p {      # lowest priority first, so [0] ends up head
        my $repo = CompUnit::Repository::FileSystem.new(prefix => $p);
        $repo.next-repo = $chain;
        $chain = $repo;
    }
    $chain
}

#| Compile the buffer to a RakuAST tree, with the owning project and the file's
#| own directory on the module search path so `use`d modules resolve. Returns
#| (ast, error).
method !compile(Raku::LanguageServer::Document:D $doc) {
    my $repo = try self!repo-chain($doc.uri);
    return (try $doc.text.AST), $! unless $repo;

    my ($ast, $err);
    {
        my $*REPO = $repo;
        $ast = try $doc.text.AST;
        $err = $!;
    }
    ($ast, $err)
}

#| Ensure $doc has fresh analysis for its current text. Cheap no-op if already
#| analyzed. Never throws: compile failures are captured, not propagated.
method analyze(Raku::LanguageServer::Document:D $doc) {
    return if $doc.analyzed;
    my ($ast, $err) = self!compile($doc);
    if $ast.defined && !$err {
        $doc.ast           = $ast;
        $doc.ast-version   = $doc.version;
        $doc.symbols       = self.extract-symbols($ast);
        $doc.compile-error = Nil;
    }
    else {
        # Keep the last good AST/symbols; record why this parse failed.
        $doc.compile-error = $err // Exception;
    }
    $doc.analyzed = True;
}

#| Human-facing kind + SymbolKind for a declaration node, or Nil if the node is
#| not a declaration we surface.
method !classify($node) {
    # A role/grammar body desugars into a synthetic routine that is-a Sub; skip
    # it so its real members hoist up under the package.
    return Nil if $node ~~ RakuAST::RoleBody;
    given $node {
        when RakuAST::Package {
            my $n = .^name;
            return $n.contains('Grammar') ?? (SK-Class,     'grammar')
                !! $n.contains('Role')    ?? (SK-Interface, 'role')
                !! $n.contains('Module')  ?? (SK-Module,    'module')
                !! $n.contains('Class')   ?? (SK-Class,     'class')
                !!                           (SK-Package,   'package');
        }
        when RakuAST::Method    { return SK-Method,   'method'    }
        when RakuAST::Sub       { return SK-Function, 'sub'       }
        when RakuAST::Regex     { return SK-Method,   'regex'     }
        when RakuAST::VarDeclaration::Simple {
            my $scope = ~(.scope // 'my');
            return $scope eq 'has' ?? (SK-Field, 'has')
                !! $scope eq 'our' ?? (SK-Variable, 'our')
                !!                    (SK-Variable, $scope);
        }
        default { return Nil }
    }
}

#| Best-effort declared name for a node (string form). RakuAST name accessors
#| may return native `str` values, so results are coerced with `~`.
method !decl-name($node --> Str) {
    my $raw = do given $node {
        when RakuAST::Package { try $node.name.canonicalize }
        default {
            my $x = try $node.name;
            $x ~~ RakuAST::Name ?? (try $x.canonicalize) !! $x
        }
    }
    $raw.defined ?? ~$raw !! Str
}

#| Char span of just the declared name, for the LSP selection range. Falls back
#| to the whole node span when a precise name origin isn't available.
method !name-span($node, $from, $to) {
    if $node ~~ RakuAST::Package {
        with (try $node.name.origin) -> $o {
            return $o.from, $o.to if $o.defined;
        }
    }
    # For routines the name is a plain string, but a child Name node carries the
    # precise origin of the identifier.
    if $node ~~ RakuAST::Routine {
        my @origins;
        $node.visit-children: -> $c {
            if $c ~~ RakuAST::Name {
                with (try $c.origin) -> $o {
                    @origins.push: ($o.from, $o.to) if $o.defined;
                }
            }
        }
        return |@origins[0] if @origins;
    }
    $from, $to
}

#| Build the hierarchical symbol tree for an AST subtree. Declarations found
#| inside a declaration become its children; other nodes are transparent.
method extract-symbols($root) {
    self!collect($root)
}

method !collect($node) {
    my @syms;
    return @syms unless $node ~~ RakuAST::Node;
    $node.visit-children: -> $child {
        my @found := self!node-symbol($child);
        @syms.append: @found;
    }
    @syms
}

#| Return a one-element list with the Symbol for $child (with its own children
#| collected), or the flattened symbols from within a non-declaration child.
method !node-symbol($child) {
    my ($kind, $detail) = |(self!classify($child) // ());
    my $o = $child.?origin;
    if $kind.defined && $o.defined {
        my ($from, $to) = $o.from, $o.to;
        my ($sf, $st)   = self!name-span($child, $from, $to);
        my $name = self!decl-name($child) // '(anon)';
        my $sym = Raku::LanguageServer::Symbol.new(
            :$name, :$kind, :$detail, :$from, :$to,
            :sel-from($sf), :sel-to($st), :node($child),
            :children(self!collect($child)),
        );
        return ($sym,);
    }
    # Transparent node: hoist any declarations found inside it.
    self!collect($child)
}

#| The identifier or variable token covering a char offset, from the source
#| text: `{ text, from, to }`, or Nil. Sigils and twigils are part of a
#| variable token, so `$x` and `@y` come back whole.
method identifier-at(Raku::LanguageServer::Document:D $doc, Int $offset) {
    my $text = $doc.text;
    return Nil unless 0 <= $offset <= $text.chars;
    my $found;
    for $text ~~ m:g/ [<[$@%&]> <[.!^*?=~]>?]? <[_A..Za..z]> \w* [<[\-']> \w+]* / -> $m {
        if $m.from <= $offset <= $m.to {
            $found = { text => ~$m, from => $m.from.Int, to => $m.to.Int };
            last;
        }
    }
    $found
}

#| First child `Name` node origin span (from, to), or Nil. The precise location
#| of a routine's or call's identifier.
method !child-name-span($node) {
    my $span;
    $node.visit-children: -> $c {
        if !$span.defined && $c ~~ RakuAST::Name {
            with (try $c.origin) -> $o { $span = ($o.from, $o.to) if $o.defined }
        }
    }
    $span
}

#| All name occurrences in the document — declarations and uses of variables,
#| routines, packages, and type/name references — as
#| `{ text, from, to, kind, node }` where `kind` is 'decl' or 'use' and
#| `from`/`to` bound just the identifier. Occurrences come from the AST, so
#| matches never fall inside strings or comments. Resolution is name-based
#| (best-effort across scopes), which drives definition/references/rename.
method occurrences(Raku::LanguageServer::Document:D $doc) {
    my $ast  = $doc.ast orelse return [];
    my $text = $doc.text;
    my @occ;
    my &add = -> $node, $from, $to, $kind {
        if $from.defined && $to.defined && $to > $from {
            @occ.push: {
                text => $text.substr($from, $to - $from),
                :$from, :$to, :$kind, :$node,
            };
        }
    };
    sub visit($node) {
        return unless $node ~~ RakuAST::Node;
        given $node {
            when RakuAST::VarDeclaration::Simple {
                with .origin -> $o {
                    add($node, $o.from, $o.from + (~.name).chars, 'decl') if $o.defined;
                }
            }
            when RakuAST::Var {
                with .origin -> $o { add($node, $o.from, $o.to, 'use') if $o.defined }
            }
            when RakuAST::Routine {
                with self!child-name-span($node) -> $s { add($node, $s[0], $s[1], 'decl') }
            }
            when RakuAST::Package {
                with (try .name.origin) -> $o { add($node, $o.from, $o.to, 'decl') if $o.defined }
            }
            when RakuAST::Call::Name {
                # Parenthesized calls lack a child Name origin; fall back to the
                # call's own origin, whose identifier sits at the start.
                with self!child-name-span($node) -> $s {
                    add($node, $s[0], $s[1], 'use');
                }
                orwith .origin -> $o {
                    my $nm = try ~.name.canonicalize;
                    add($node, $o.from, $o.from + $nm.chars, 'use') if $o.defined && $nm;
                }
            }
            when RakuAST::Name {
                with .origin -> $o { add($node, $o.from, $o.to, 'use') if $o.defined }
            }
        }
        $node.visit-children(&visit);
    }
    visit($ast);

    # Deduplicate by span; a declaration classification wins over a use.
    my %at;
    my @out;
    for @occ -> $o {
        my $key = "{$o<from>}..{$o<to>}";
        if %at{$key}:exists {
            @out[%at{$key}]<kind> = 'decl' if $o<kind> eq 'decl';
        }
        else {
            %at{$key} = @out.elems;
            @out.push: $o;
        }
    }
    @out
}

#| Deepest RakuAST node whose origin span contains the char offset. Used by
#| hover, definition, and signature help. Returns Nil if nothing matches.
method node-at(Raku::LanguageServer::Document:D $doc, Int $offset) {
    my $ast = $doc.ast orelse return Nil;
    my $best;
    my $best-span = Inf;
    sub visit($node) {
        return unless $node ~~ RakuAST::Node;
        with $node.origin -> $o {
            if $o.from <= $offset < $o.to {
                my $span = $o.to - $o.from;
                if $span < $best-span {
                    $best      = $node;
                    $best-span = $span;
                }
            }
        }
        $node.visit-children(&visit);
    }
    visit($ast);
    $best
}

#| The innermost routine (sub/method/submethod/regex) whose body contains the
#| char offset, or Nil. Drives call hierarchy (which routine a call sits in).
method enclosing-routine(Raku::LanguageServer::Document:D $doc, Int $offset) {
    my $ast = $doc.ast orelse return Nil;
    my $best;
    my $best-span = Inf;
    sub visit($n) {
        return unless $n ~~ RakuAST::Node;
        if $n ~~ RakuAST::Routine {
            with $n.origin -> $o {
                if $o.defined && $o.from <= $offset < $o.to && ($o.to - $o.from) < $best-span {
                    $best      = $n;
                    $best-span = $o.to - $o.from;
                }
            }
        }
        $n.visit-children(&visit);
    }
    visit($ast);
    $best
}

#| Char-offset spans of every AST node whose origin contains the offset,
#| deduplicated and ordered smallest-first (innermost → outermost). Drives
#| selection-range (smart expand).
method ancestors-at(Raku::LanguageServer::Document:D $doc, Int $offset) {
    my $ast = $doc.ast orelse return [];
    my @spans;
    sub visit($node) {
        return unless $node ~~ RakuAST::Node;
        with $node.origin -> $o {
            @spans.push: ($o.from, $o.to)
                if $o.defined && $o.from <= $offset <= $o.to && $o.to > $o.from;
        }
        $node.visit-children(&visit);
    }
    visit($ast);
    my %seen;
    my @out;
    for @spans.sort({ ($^a[1] - $^a[0]) <=> ($^b[1] - $^b[0]) }) -> $s {
        my $key = "{$s[0]}..{$s[1]}";
        @out.push: $s unless %seen{$key}++;
    }
    @out
}

#| `use`/`need`/`import` module references as `{ module, from, to }`, where
#| from/to bound the module name. Drives document links.
method use-statements(Raku::LanguageServer::Document:D $doc) {
    my $ast = $doc.ast orelse return [];
    my @uses;
    sub visit($node) {
        return unless $node ~~ RakuAST::Node;
        if $node ~~ RakuAST::Statement::Use {
            my $mn = try $node.module-name;
            if $mn.defined {
                my $name = try $mn.canonicalize;
                my $o    = (try $mn.origin) // (try $node.origin);
                @uses.push: %( module => ~$name, from => $o.from, to => $o.to )
                    if $name.defined && $o.defined;
            }
        }
        $node.visit-children(&visit);
    }
    visit($ast);
    @uses
}

#| Resolve a module name to a source file within the owning project's `lib/`
#| (the case worth linking). Returns an absolute path, or Nil.
method resolve-module-file(Raku::LanguageServer::Document:D $doc, Str $mod) {
    my $lib = self!project-lib($doc.uri) orelse return Nil;
    my $rel = $mod.split('::').join('/');
    for <.rakumod .rakudoc .pm6 .pm> -> $ext {
        my $f = $lib.IO.add($rel ~ $ext);
        return $f.absolute if $f.e;
    }
    Nil
}

#| Path of the file a module lives in — the project's `lib/`, any of the buffer's
#| search prefixes, or an installed distribution's `sources/`. Nil if not found.
method module-file(Raku::LanguageServer::Document:D $doc, Str $mod) {
    with self.resolve-module-file($doc, $mod) -> $f { return $f }

    my $rel = $mod.split('::').join('/');
    for self!search-prefixes($doc.uri) -> $prefix {
        for <.rakumod .rakudoc .pm6 .pm> -> $ext {
            my $f = $prefix.IO.add($rel ~ $ext);
            return $f.absolute if $f.e;
        }
    }

    # Installed distributions keep sources under `<prefix>/sources/<sha>`. The
    # filename is a hash rather than a name, but the content is the real source,
    # so jumping there still lands on the declaration.
    my $repo = (try self!repo-chain($doc.uri)) // $*REPO;
    while $repo.defined {
        if $repo.can('candidates') && (try $repo.prefix).defined {
            for ((try $repo.candidates($mod)) // ()).List -> $dist {
                my $prov = ((try $dist.meta<provides>) // {}){$mod} orelse next;
                my $sha  = do given $prov {
                    when Associative { (try .values[0]<file>) // (try .keys[0]) }
                    default          { $_ }
                };
                next unless $sha;
                my $f = $repo.prefix.add('sources').add(~$sha);
                return $f.absolute if $f.e;
            }
        }
        $repo = try $repo.next-repo;
    }
    Nil
}

# ---------------------------------------------------------------------------
# Cross-file lookup: finding a declaration that lives in another file.
# ---------------------------------------------------------------------------

#| Declaration keywords that can introduce a name at file scope.
my @DECL-KEYWORDS = <
    class role grammar module package subset enum monitor
    sub method submethod token rule regex macro constant
>;

#| Char spans of every declaration of a name in a file's text, found by scanning
#| rather than by compiling.
#|
#| Compiling other files is NOT an option here: `.AST` resolves and runs BEGIN,
#| so analyzing a project's own sources inside the server re-registers their
#| packages in this process. Scanning for a name that happened to be absent once
#| compiled every file under `lib/` and gave the server a second, incompatible
#| copy of its own `Transport` class mid-request. A scan also works on files that
#| do not compile standalone, which is most of them.
#|
#| The cost is precision: a declaration-shaped phrase inside a string or comment
#| matches too. For jumping to a definition that is a fair trade.
#| True when an offset sits after a `#` on its own line, i.e. inside a line
#| comment. Prose describing a declaration (`# the `class Foo` below`) otherwise
#| matches as readily as the declaration itself — that is not hypothetical, it
#| sent this very lookup to a comment in a test file.
sub in-comment(Str $text, Int $pos) {
    my $bol = ($text.rindex("\n", $pos) // -1) + 1;
    so $text.substr($bol, $pos - $bol).contains('#')
}

sub declaration-spans(Str $text, Str $name, Bool :$short) {
    my @out;

    if $name ~~ / ^ <[$@%&]> / {
        # `my $x`, `our @y`, `has $.z`, `has $!z` — the sigil is part of the name
        # but a twigil sits between sigil and identifier.
        my $sigil = $name.substr(0, 1);
        my $bare  = $name.substr(1);
        for $text ~~ m:g/ « [ 'my' | 'our' | 'has' | 'state' ] \h+
                          [ <[A..Z]> <[\w:]>* \h+ ]?              # optional type
                          ( $sigil <[.!]>? $bare ) » / -> $m {
            @out.push: ($m[0].from, $m[0].to) unless in-comment($text, $m[0].from);
        }
        return @out;
    }

    # The declared name is captured whole and compared afterwards, because
    # packages are routinely declared fully qualified — `grammar A::B::Parser` —
    # while the cursor may sit on any one segment of the reference.
    for $text ~~ m:g/ « [ 'multi' \h+ ]? @DECL-KEYWORDS \h+ ( <[_A..Za..z]> \w*
                        [ '-' \w+ ]* [ '::' <[_A..Za..z]> \w* [ '-' \w+ ]* ]* ) » / -> $m {
        my $decl = ~$m[0];
        # `:short` accepts a bare last segment (`class Bar` for a reference to
        # `Foo::Bar`) and is only passed for the file of `Foo` itself, where the
        # enclosing package really does qualify the name. Accepting it everywhere
        # made a private `my class Request`, nested inside an unrelated role,
        # answer a jump to `Cro::HTTP::Request`.
        next unless $decl eq $name
                 || $decl.ends-with("::$name")     # `grammar A::B::Parser` ← `Parser`
                 || ($short && $decl eq $name.split('::').tail);
        next if in-comment($text, $m[0].from);
        @out.push: ($m[0].from, $m[0].to);
    }
    @out
}

#| The name under a char offset including any `::` qualification, so a cursor
#| anywhere in `Cro::WebApp::Template::Parser` yields the whole thing. Kept
#| separate from `identifier-at`, which every other feature relies on to return
#| a single segment.
method qualified-name-at(Raku::LanguageServer::Document:D $doc, Int $offset) {
    my $text = $doc.text;
    return Nil unless 0 <= $offset <= $text.chars;
    for $text ~~ m:g/ <[_A..Za..z]> \w* [ '-' \w+ ]*
                      [ '::' <[_A..Za..z]> \w* [ '-' \w+ ]* ]* / -> $m {
        return ~$m if $m.from <= $offset <= $m.to;
    }
    Nil
}

#| File contents, cached per path and invalidated by mtime. Kept separate from
#| the analyzed Document so a candidate file can be rejected on a cheap string
#| search before paying to compile it.
method !file-text(Str $path) {
    my $io = $path.IO;
    return Str unless $io.f;
    my $stamp = ~(try $io.modified);
    with %!file-text-cache{$path} -> %entry {
        return %entry<text> if %entry<stamp> eq $stamp;
    }
    my $text = try $io.slurp;
    return Str unless $text.defined;
    %!file-text-cache{$path} = %( :$stamp, :$text );
    $text
}

#| Files that could hold a declaration the buffer refers to, nearest first: the
#| modules it `use`s, then every other source file in its search prefixes. The
#| buffer's own file is excluded — its declarations are already searched
#| directly, and re-reading it from disk would use stale text.
#| Every source file in the buffer's search prefixes — the last-resort sweep for
#| a name that no `use` chain led to.
method !project-files(Raku::LanguageServer::Document:D $doc) {
    my @paths;
    my %seen-prefix;
    my @peer-roots = @!peer-uris.map({ self!project-root($_) }).grep(*.defined);
    my @prefixes = |self!search-prefixes($doc.uri), |@!workspace-roots, |@peer-roots;
    for @prefixes.grep({ $_ && !%seen-prefix{$_}++ }) -> $prefix {
        my @todo = $prefix.IO;
        while @todo {
            my $dir = @todo.shift;
            for ((try $dir.dir) // ()).List -> $entry {
                if $entry.d {
                    @todo.push: $entry unless $entry.basename.starts-with('.');
                }
                elsif (try $entry.extension) eq any <rakumod rakudoc raku rakutest pm6 pm p6> {
                    @paths.push: $entry.absolute;
                }
            }
        }
    }
    @paths
}

#| Declarations of a name in the buffer's own text, found by scanning instead of
#| through the AST. The AST is the better source when there is one, but a buffer
#| that does not currently compile has none — and that is exactly when someone is
#| mid-edit and still wants to jump to a definition. Without this the search
#| falls through to other files and can land somewhere unrelated.
method local-declaration-spans(Raku::LanguageServer::Document:D $doc, Str $name) {
    return [] unless $name;
    declaration-spans($doc.text, $name).map({ %( uri => $doc.uri, range => $doc.range(.[0], .[1]) ) })
}

#| Word-boundary occurrences of a name in a chunk of source, skipping comments.
#| Sigilled names cannot take a leading word boundary — `«` before `$` never
#| matches — so the pattern differs for those.
sub reference-spans(Str $text, Str $name) {
    my @out;
    my @matches = $name ~~ / ^ <[$@%&]> /
        ?? ($text ~~ m:g/ $name » /)
        !! ($text ~~ m:g/ « $name » /);
    for @matches -> $m {
        @out.push: ($m.from, $m.to) unless in-comment($text, $m.from);
    }
    @out
}

#| Occurrences of a name in the buffer's own text. The AST is the better source
#| when there is one, but a buffer that does not compile — a big module whose
#| dependencies are not all resolvable, or one being edited — has none, and
#| returning nothing for its own file is worse than a text scan.
method local-reference-spans(Raku::LanguageServer::Document:D $doc, Str $name,
                             Bool :$include-declarations = True) {
    return [] unless $name;
    my @spans = reference-spans($doc.text, $name);
    unless $include-declarations {
        my %decl = declaration-spans($doc.text, $name).map({ .[0] => True });
        @spans .= grep({ !%decl{.[0]} });
    }
    @spans.map({ %( uri => $doc.uri, range => $doc.range(.[0], .[1]) ) })
}

#| Every occurrence of a name in project files other than the buffer, as LSP
#| Locations. Text-based, so unlike the buffer's own AST-derived occurrences it
#| can match inside a string literal; that is the price of not compiling other
#| files. With `:!include-declarations`, spans that are themselves declarations
#| are dropped.
method references-across-files(Raku::LanguageServer::Document:D $doc, Str $name,
                               Bool :$include-declarations = True) {
    return [] unless $name;
    my $self-path = self!uri-to-path($doc.uri);
    my $scanned   = 0;
    my %seen;
    my @out;
    for self!project-files($doc) -> $path {
        next if norm-path($path) eq $self-path || %seen{$path}++;
        last if $scanned >= MAX-FILES-SCANNED;
        my $text = self!file-text($path);
        next unless $text.defined && $text.contains($name);
        $scanned++;
        my @spans = reference-spans($text, $name);
        next unless @spans;
        unless $include-declarations {
            my %decl = declaration-spans($text, $name).map({ .[0] => True });
            @spans .= grep({ !%decl{.[0]} });
        }
        next unless @spans;
        my $other = Raku::LanguageServer::Document.new(
            uri => path-to-uri($path), :$text);
        for @spans -> ($from, $to) {
            @out.push: %( uri => $other.uri, range => $other.range($from, $to) );
        }
    }
    @out
}

#| Char spans of the NAME of every package in a chunk of source that consumes a
#| given role or class — the `RouteSet` in `class RouteSet does Cro::Transform`.
#| The span is the consumer's own name so a jump lands on it, not on the role.
#| Both the qualified name and its last segment are accepted, since a consumer
#| may refer to an imported role either way.
sub consumer-spans(Str $text, Str $name) {
    my $last = $name.split('::').tail;
    my @out;
    for $text ~~ m:g/ « [ 'class' | 'role' | 'grammar' | 'monitor' ] \h+
                      ( <[_A..Za..z]> \w* [ '-' \w+ ]*
                        [ '::' <[_A..Za..z]> \w* [ '-' \w+ ]* ]* )
                      <-[{;\n]>*? « [ 'does' | 'is' ] » \h+ [ $name | $last ] » / -> $m {
        @out.push: ($m[0].from, $m[0].to) unless in-comment($text, $m[0].from);
    }
    @out
}

#| Every package that consumes a role or class, across the buffer and the
#| project, as LSP Locations. This is what "go to implementation" of a role
#| means; searching only the open buffer found nothing the moment the role came
#| from elsewhere.
method consumers-of(Raku::LanguageServer::Document:D $doc, Str $name) {
    return [] unless $name;
    my $last = $name.split('::').tail;
    my @out;

    # The buffer first, from its live text rather than from disk.
    for consumer-spans($doc.text, $name) -> ($from, $to) {
        @out.push: %( uri => $doc.uri, range => $doc.range($from, $to) );
    }

    my $self-path = self!uri-to-path($doc.uri);
    my $scanned   = 0;
    my %seen;
    for self!project-files($doc) -> $path {
        next if norm-path($path) eq $self-path || %seen{$path}++;
        last if $scanned >= MAX-FILES-SCANNED;
        my $text = self!file-text($path);
        next unless $text.defined && $text.contains($last);
        $scanned++;
        next unless $text.contains('does') || $text.contains(' is ');
        my @spans = consumer-spans($text, $name);
        next unless @spans;
        my $other = Raku::LanguageServer::Document.new(
            uri => path-to-uri($path), :$text);
        for @spans -> ($from, $to) {
            @out.push: %( uri => $other.uri, range => $other.range($from, $to) );
        }
    }

    # Library code before test code: a test that consumes a role is a real
    # implementation, but it is rarely the one someone is looking for, and
    # directory order otherwise puts `t/` first.
    @out.sort({ consumer-rank(.<uri>) })
}

#| Sort key for an implementation location: the closer to the project's real
#| code, the lower.
sub consumer-rank(Str $uri --> Int) {
    return 2 if $uri.contains('/t/') || $uri.contains('.rakutest');
    return 0 if $uri.contains('/lib/');
    1
}

#| Declarations of a name in files other than the buffer, as LSP Locations.
#|
#| Files are visited in order of how likely they are to hold the declaration,
#| and the search stops at the first file that does:
#|
#|   1. the name read as a module name, and its parent namespaces — `Cro::Transform`
#|      lives in `Cro/Transform.rakumod`;
#|   2. a breadth-first walk of the `use` graph: the buffer's own `use`
#|      statements, then the `use` statements of each file that reaches, and so
#|      on. This is what finds a type whose module is named nothing like it —
#|      `RootConfig` inside `Test1Config`, or anything Cro re-exports two hops
#|      down. Following one hop only would miss it;
#|   3. every source file in the buffer's search prefixes, as a last resort.
#|
#| The graph is walked over file TEXT, never by compiling: see `declaration-spans`.
method cross-file-declarations(Raku::LanguageServer::Document:D $doc, Str $name) {
    return [] unless $name;

    my $self-path = self!uri-to-path($doc.uri);
    my %seen-file;
    my $scanned = 0;
    my @out;

    # Scan one file; True once the declaration is found.
    my &found-in = -> $path, Bool :$short --> Bool {
        my $ok = False;
        if $path.defined && norm-path($path) ne $self-path && !%seen-file{$path}++
           && $scanned < MAX-FILES-SCANNED {
            my $text = self!file-text($path);
            # A file whose text does not even mention the name cannot declare it;
            # this keeps the expensive part off almost every candidate.
            if $text.defined && $text.contains($name.split('::').tail) {
                $scanned++;
                my @spans = declaration-spans($text, $name, :$short);
                if @spans {
                    # A Document purely for its coordinate index; NOT analyzed.
                    my $other = Raku::LanguageServer::Document.new(
                        uri => path-to-uri($path), :$text);
                    for @spans -> ($from, $to) {
                        @out.push: %( uri => $other.uri, range => $other.range($from, $to) );
                    }
                    $ok = True;
                }
            }
        }
        $ok
    };

    # 1. the name itself as a module, then its parent namespaces. Only the
    #    parents get `:short`, since a declaration inside module `Foo` spells
    #    `Foo::Bar` as just `Bar`.
    if $name ~~ / ^ <[A..Z_]> / {
        return @out if found-in(self.module-file($doc, $name));
        my @parts = $name.split('::');
        @parts.pop;
        while @parts {
            return @out if found-in(self.module-file($doc, @parts.join('::')), :short);
            @parts.pop;
        }
    }

    # 2. breadth-first over the `use` graph
    my @queue = self.used-module-names($doc);
    my %seen-mod;
    while @queue && $scanned < MAX-FILES-SCANNED {
        my $mod = @queue.shift;
        next if %seen-mod{$mod}++;
        my $path = self.module-file($doc, $mod) orelse next;
        return @out if found-in($path);
        # Not here: follow what this module itself pulls in.
        with self!file-text($path) -> $text {
            @queue.append: used-names-in-text($text);
        }
    }

    # 3. anything else in the project
    for self!project-files($doc) -> $path {
        return @out if found-in($path);
    }
    @out
}

# ---------------------------------------------------------------------------
# Completion support: what a name could be, and what a `use`d module adds.
# ---------------------------------------------------------------------------

#| A module name safe to interpolate into an EVAL.
sub sane-module-name(Str $name --> Bool) {
    so $name ~~ / ^ <[A..Za..z_]> <[\w]>* [ '::' <[A..Za..z_]> <[\w]>* ]* $ /
}

#| Every routine in CORE, desigilized (`say`, `map`, `unique`, …) — the real
#| builtin list (~400 names) rather than a hand-kept subset. Operators and
#| `:sym`-qualified names are left out; they are not useful as plain labels.
method core-routines() {
    state @core = CORE::.keys
        .grep({ / ^ '&' <[_A..Za..z]> <[\w\-]>* $ / })
        .map(*.substr(1))
        .sort;
    @core
}

#| Trait names usable after `is` — the named parameters of every `trait_mod:<is>`
#| candidate, which is how traits are actually declared. Core only; see
#| `module-traits` for the ones a module adds.
method core-traits() {
    state @traits = trait-names-of(try &trait_mod:<is>);
    @traits
}

#| The named-parameter names of a `trait_mod` multi — i.e. the trait keywords it
#| implements. `()` for anything that isn't a routine with candidates.
sub trait-names-of($tm) {
    my @c = ((try $tm.candidates) // ()).List;
    my %seen;
    @c.map({ ((try .signature.params) // ()).grep({ try .named }) })
      .flat
      .map({ (try .usage-name) // '' })
      .grep({ $_ && !%seen{$_}++ })
      .sort
}

#| The type object for a name, or Nil. Core and already-loaded types resolve
#| directly; anything else goes through a one-off module load. `use Str` would
#| fail, so the direct lookup has to come first.
#| Returned as a 0-or-1 element list rather than a type-object-or-Nil: a type
#| object is undefined, and assigning `Nil` to a scalar resets it to `Any`, so
#| neither `.defined` nor `=== Nil` can tell success from failure here.
method !type-object(Raku::LanguageServer::Document:D $doc, Str $name) {
    my $direct = try ::($name);
    return ($direct,) if $direct !~~ Failure && (try $direct.^name) eq $name;
    self!ensure-type-loaded($doc, $name);
    %!type-cache{$name}:exists ?? (%!type-cache{$name},) !! ()
}

#| Public method names of a type, for `Foo.` completion — core types, types from
#| the buffer's own project, and types from installed modules alike. `[]` when
#| the type can't be resolved. With `:own`, only what the type itself declares
#| (its attribute accessors and methods), not the `Any`/`Mu` inheritance — which
#| is what a caller actually meant to pick from.
method type-methods(Raku::LanguageServer::Document:D $doc, Str $type-name, Bool :$own) {
    self.type-method-info($doc, $type-name)
        .grep({ !$own || .<own> })
        .map({ .<name> })
        .Array
}

#| A method's parameter list rendered for display — `($who)`, `(Int $n, $sep)` —
#| or `''` when it takes nothing worth showing. The invocant and the implicit
#| `%_` are dropped; an untyped parameter shows just its name.
sub params-summary($sig) {
    my @p = ((try $sig.params) // ()).grep({
        !(try .invocant) && (((try .name) // '') ne '%_')
    });
    return '' unless @p;
    '(' ~ @p.map({
        my $t = (try .type.^name) // 'Any';
        my $n = (try .name) // '';
        $n && $t ne 'Any' ?? "$t $n" !! ($n || $t)
    }).join(', ') ~ ')'
}

#| The names a routine accepts as named arguments (`:verbose`, `:where`), which
#| is what belongs after a `:` in an argument list.
sub named-params($sig) {
    ((try $sig.params) // ()).grep({
        (try .named) && (((try .name) // '') ne '%_')
    }).map({ ((try .usage-name) // '') }).grep({ $_ }).unique
}

#| True for a type that comes from the Raku setting (`Int`, `Str`, `Hash`), as
#| opposed to one the user wrote. Lets completion tell a nested config section
#| from a plain scalar field.
method core-type(Str $name --> Bool) {
    state %core = CORE::.keys.Set;
    so %core{$name}
}

#| Every method of a type with where it was defined: `{ name, from, own }`.
#| `from` is the declaring package (`RootConfig`, `Configuration::Node`, `Any`),
#| which is what lets completion say whether a name belongs to the class in front
#| of the cursor or was inherited. `own` covers what the type declares directly,
#| including methods flattened in from roles.
method type-method-info(Raku::LanguageServer::Document:D $doc, Str $type-name) {
    my @found = self!type-object($doc, $type-name);
    return [] unless @found;
    my $type = @found[0];

    # Attribute-backed methods are the interesting ones for a data-shaped class:
    # their accessor signature says nothing (`:($: *%_)`), but the attribute's
    # declared type is exactly what a caller needs to know.
    my %attr-type;
    for (((try $type.^attributes) // ()).List) -> $a {
        next unless (try $a.has_accessor);
        my $n = (try $a.name) // '';
        next unless $n.chars > 2;
        %attr-type{$n.substr(2)} = (try $a.type.^name) // '';
    }

    my %seen;
    my @out;
    for (((try $type.^methods(:all)) // ()).List) -> $m {
        my $name = (try $m.name) // '';
        next unless $name && $name ~~ / ^ <[_A..Za..z]> <[\w\-]>* $ /;
        next if %seen{$name}++;
        my $from = (try $m.package.^name) // '';
        @out.push: %(
            :$name, :$from,
            own       => $from eq $type-name,
            attr-type => %attr-type{$name} // '',
            params    => params-summary(try $m.signature),
            named     => named-params(try $m.signature).List,
        );
    }
    @out.sort({ .<name> }).Array
}

#| Lexical symbols an empty compilation already has — the baseline that makes an
#| import diff meaningful. Computed once.
method !baseline-symbols() {
    state %base = (((try EVAL 'MY::.keys.List') // ()).map({ ~$_ })).Set;
    %base
}

#| Names a module brings into scope: `&some-sub`, `&infix:<~~~>`, `&term:<HERE>`,
#| `SomeType`. Found by diffing the lexical scope after a `use` against an empty
#| one, rather than by reading `Mod::EXPORT::DEFAULT` — that stash only exists
#| for files written as `unit module Foo;`, and the ones that install custom
#| declarators can't be (EXPORTHOW has to sit at compunit scope). The diff also
#| covers modules that export through a hand-written `sub EXPORT`.
#| Cached per module name.
method module-exports(Raku::LanguageServer::Document:D $doc, Str $mod) {
    return @(%!export-cache{$mod}) if %!export-cache{$mod}:exists;
    my @names;
    if sane-module-name($mod) {
        my $repo = (try self!repo-chain($doc.uri)) // $*REPO;
        {
            my $*REPO = $repo;
            my @after = (((try EVAL "use $mod; MY::.keys.List") // ()).map({ ~$_ }));
            my %base  = self!baseline-symbols;
            # `?` and `=` mark compiler-internal lexicals (`%?LANG`, `$=finish`).
            @names = @after.grep({ !%base{$_} && !.contains(any('?', '=')) }).sort;
        }
    }
    %!export-cache{$mod} = @names;
    @names
}

#| Trait names a module adds (`is table`, `is serial`, …), read off the
#| `trait_mod:<is>` candidates it exports.
method module-traits(Raku::LanguageServer::Document:D $doc, Str $mod) {
    return @(%!trait-cache{$mod}) if %!trait-cache{$mod}:exists;
    my @names;
    if sane-module-name($mod) {
        my $repo = (try self!repo-chain($doc.uri)) // $*REPO;
        {
            my $*REPO = $repo;
            @names = trait-names-of(try EVAL "use $mod; MY::\{'&trait_mod:<is>'\}");
        }
    }
    %!trait-cache{$mod} = @names;
    @names
}

#| Source text of a module — the owning project's `lib/`, one of the buffer's
#| search prefixes, or an installed distribution. Nil when it can't be located.
method module-source-text(Raku::LanguageServer::Document:D $doc, Str $mod) {
    my $rel = $mod.split('::').join('/');

    with self.resolve-module-file($doc, $mod) -> $f {
        return (try $f.IO.slurp);
    }
    for self!search-prefixes($doc.uri) -> $prefix {
        for <.rakumod .pm6 .pm> -> $ext {
            my $f = $prefix.IO.add($rel ~ $ext);
            return (try $f.slurp) if $f.e;
        }
    }

    # Installed distributions: the dist's `provides` maps the module name to the
    # file entry its repo can hand back.
    my $repo = (try self!repo-chain($doc.uri)) // $*REPO;
    while $repo.defined {
        if $repo.can('candidates') {
            for ((try $repo.candidates($mod)) // ()).List -> $dist {
                my $prov = ((try $dist.meta<provides>) // {}){$mod} orelse next;
                my $key  = $prov ~~ Associative ?? $prov.keys[0] !! $prov;
                my $text = try $dist.content($key).open(:r).slurp;
                return $text if $text.defined;
            }
        }
        $repo = try $repo.next-repo;
    }
    Nil
}

#| Module names found by walking a directory for source files, as `Foo::Bar`.
#| A leading `lib/` is dropped: that directory is a search prefix in its own
#| right, so `lib::Foo::Bar` is never a name anyone can `use`.
sub module-names-under(IO() $root) {
    my @out;
    my @todo = $root;
    while @todo {
        my $dir = @todo.shift;
        for ((try $dir.dir) // ()).List -> $entry {
            if $entry.d {
                @todo.push: $entry unless $entry.basename.starts-with('.');
            }
            elsif (try $entry.extension) eq any <rakumod pm6 pm> {
                my $rel = $entry.relative($root).subst(/ '.' \w+ $/, '');
                my @parts = $rel.split('/');
                @parts.shift if @parts > 1 && @parts[0] eq 'lib';
                @out.push: @parts.join('::');
            }
        }
    }
    @out
}

#| Module names that could follow `use`: everything the buffer's own project and
#| search prefixes provide, plus everything installed in its repo chain. Walked
#| once per analyzer.
method known-modules(Raku::LanguageServer::Document:D $doc) {
    return @!known-modules if @!known-modules;

    my @names;
    @names.append: module-names-under($_) for self!search-prefixes($doc.uri);

    my $repo = (try self!repo-chain($doc.uri)) // $*REPO;
    while $repo.defined {
        if $repo.can('installed') {
            for ((try $repo.installed) // ()).List -> $dist {
                @names.append: (((try $dist.meta<provides>) // {}).keys).List;
            }
        }
        $repo = try $repo.next-repo;
    }

    my %seen;
    @!known-modules = @names.grep({ $_ && !%seen{$_}++ }).sort
}

#| Interior char span (start, end) of the `{ … }` block that follows $from,
#| by brace matching. Nil when there is no balanced block.
sub brace-block(Str $src, Int $from) {
    my $open = $src.index('{', $from) // return Nil;
    my $depth = 0;
    loop (my $i = $open; $i < $src.chars; $i++) {
        my $c = $src.substr($i, 1);
        $depth++ if $c eq '{';
        if $c eq '}' {
            $depth--;
            return ($open + 1, $i) if $depth == 0;
        }
    }
    Nil
}

#| Custom package declarators a module installs — `model` from Red, `actor`,
#| `monitor`, … These come from the compile-time `EXPORTHOW::DECLARE` hook:
#|
#|     my package EXPORTHOW { package DECLARE { constant model = SomeHOW; } }
#|
#| which the compiler consumes without leaving anything reachable at runtime
#| (`CompUnit::Handle.export-how-package` comes back empty, and `::("EXPORTHOW")`
#| after a `use` finds nothing). So this reads the module's source instead.
#| Brace matching rather than a flat regex, but still text: a `{` inside a string
#| literal in an EXPORTHOW block would throw it off. Cached per module name.
method module-declarators(Raku::LanguageServer::Document:D $doc, Str $mod) {
    return @(%!declarator-cache{$mod}) if %!declarator-cache{$mod}:exists;

    my @names;
    with self.module-source-text($doc, $mod) -> $src {
        # Match the block openers, not the bare words — prose mentioning
        # EXPORTHOW in a comment would otherwise capture the wrong braces.
        for ($src ~~ m:g/ 'EXPORTHOW' \s* '{' /) -> $hit {
            my ($hs, $he) = |(brace-block($src, $hit.from) // ());
            next unless $hs.defined;
            my $how = $src.substr($hs, $he - $hs);
            for ($how ~~ m:g/ 'DECLARE' \s* '{' /) -> $dhit {
                my ($ds, $de) = |(brace-block($how, $dhit.from) // ());
                next unless $ds.defined;
                my $body = $how.substr($ds, $de - $ds);
                @names.append: ($body ~~ m:g/ 'constant' \s+ (<[\w\-]>+) /).map({ ~.[0] });
            }
        }
        my %seen;
        @names .= grep({ !%seen{$_}++ });
        @names .= sort;
    }
    %!declarator-cache{$mod} = @names;
    @names
}

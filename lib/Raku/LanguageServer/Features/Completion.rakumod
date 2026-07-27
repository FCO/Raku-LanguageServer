use v6.d;
use Raku::LanguageServer::Features::Support;

#| Completion. What gets offered depends on where the cursor is: methods after a
#| dot, same-sigil variables after a sigil, module names after `use`, trait names
#| after `is`, and otherwise the full term set — keywords, core routines, what
#| the buffer declares, and what its `use`d modules bring in (exported routines,
#| operators, types, and custom `model`-style declarators).
unit module Raku::LanguageServer::Features::Completion;

# LSP CompletionItemKind
my constant CK-Method   = 2;
my constant CK-Function = 3;
my constant CK-Field    = 5;
my constant CK-Variable = 6;
my constant CK-Class    = 7;
my constant CK-Module   = 9;
my constant CK-Keyword  = 14;
my constant CK-Snippet  = 15;
my constant CK-Constant = 21;
my constant CK-Operator = 24;

# Sort groups. Lower sorts first, so what the buffer itself declares outranks the
# ~230 core routines and the keyword list instead of drowning in them.
my constant SG-Local    = '1';
my constant SG-Member   = '2';
my constant SG-Imported = '3';
my constant SG-Core     = '4';
my constant SG-Keyword  = '5';
# Only ever appears in method position, where it sinks inherited Any/Mu methods
# below the type's own.
my constant SG-Inherited = '6';

# LSP SymbolKind → CompletionItemKind for declared symbols.
my %sym-to-completion = (
    2 => CK-Class, 4 => CK-Class, 5 => CK-Class, 11 => CK-Class,
    6 => CK-Method, 8 => CK-Field, 12 => CK-Function, 13 => CK-Variable,
    14 => CK-Variable,
);
my constant SK-Method   = 6;
my constant SK-Function = 12;

my @KEYWORDS = <
    my our has state anon augment supersede
    sub method submethod multi proto only macro
    class role grammar module package enum subset constant
    token rule regex
    if elsif else unless with without
    for while until repeat loop given when default
    do gather take return return-rt make
    try catch control CATCH CONTROL
    BEGIN END ENTER LEAVE KEEP UNDO FIRST NEXT LAST PRE POST
    use need import require unit
    is does of returns handles where
    True False Nil Any Mu self
>;

#| What the cursor is positioned to complete, read from the raw text rather than
#| the AST on purpose: a buffer mid-keystroke (`$foo.`, `use `) usually does not
#| parse, and the last-good AST's offsets are stale exactly where the user is
#| typing. Returns:
#|   kind     — 'method' | 'variable' | 'module' | 'trait' | 'term'
#|   prefix   — the partial token already typed
#|   from     — char offset where the replacement starts (includes the sigil)
#|   invocant — for 'method', the expression left of the dot
sub cursor-context(Str $text, Int $offset --> Hash) {
    my $before = $text.substr(0, $offset);
    my $line   = $before.split("\n").tail // '';
    my &ctx    = -> $kind, $prefix, *%rest {
        %( :$kind, :$prefix, from => $offset - $prefix.chars, :$offset, |%rest )
    };

    with $line ~~ / ^ \h* ['use' | 'need' | 'require'] \h+ ( <[\w:]>* ) $ / {
        return ctx('module', ~.[0]);
    }
    with $before ~~ / [^^ | \s] ['is' | 'does'] \h+ ( <[\w\-]>* ) $ / {
        return ctx('trait', ~.[0]);
    }
    # `.section:` — the colon form passes arguments to the method named before it,
    # so what belongs after it is an argument, not another member. Triggered by
    # the colon itself, with or without a space: `:` is a trigger character, and
    # waiting for a space would mean typing it produces nothing.
    with $before ~~ / '.' ( <[\w\-]>+ ) ':' ( \h* ) ( <[\w\-]>* ) $ / {
        # `.db:{ … }` is not the colon-call form — it needs the space. If the
        # colon was only just typed, the insertion has to supply it.
        return ctx('argument', ~.[2], callee => ~.[0],
                   pad => (~.[1] ?? '' !! ' '));
    }
    # `foo(:` / `foo(1, :` — a named argument of the call being written.
    with $before ~~ / ( <[\w\-]>+ ) '(' <-[()]>* ':' ( <[\w\-]>* ) $ / {
        return ctx('argument', ~.[1], callee => ~.[0], named => True);
    }
    with $before ~~ / ( <[\w\-\$\@\%\&\:\!\.]>+ ) '.' ( <[\w\-]>* ) $ / {
        return ctx('method', ~.[1], invocant => ~.[0]);
    }
    # A dot with no invocant in front of it calls on the topic: `.a = 1` inside a
    # block. Common in config-style DSLs, where every line starts this way.
    with $before ~~ / '.' ( <[\w\-]>* ) $ / {
        return ctx('method', ~.[0], invocant => '$_');
    }
    # The sigil is part of the token, so it has to be inside the replaced range —
    # otherwise the client filters `$fo` against a `foo` label and inserts `$$foo`.
    with $before ~~ / ( <[$@%&]> <[.!^*?=~]>? <[\w\-]>* ) $ / {
        return ctx('variable', ~.[0]);
    }
    with $before ~~ / ( <[\w\-]>* ) $ / {
        return ctx('term', ~.[0]);
    }
    ctx('term', '')
}

#| One completion item, carrying an explicit `textEdit` so the sigil-bearing and
#| hyphenated labels replace the right span regardless of the client's idea of a
#| word.
sub item($doc, %ctx, Str $label, Int $kind, Str $group,
         Mu :$detail, Mu :$origin, Mu :$signature, Mu :$insert, Mu :$snippet, Mu :$filter) {
    my %i = %(
        label      => $label,
        kind       => $kind,
        sortText   => $group ~ $label,
        # A label the user would not type verbatim — `&say`, `{ … }` — needs its
        # own filter text, or the client matches what was typed against the
        # decoration and throws the item away.
        filterText => $filter // $label,
        textEdit   => %(
            range   => $doc.range(%ctx<from>, %ctx<offset>),
            newText => (%ctx<pad> // '') ~ ($snippet // $insert // $label),
        ),
    );
    %i<detail> = $detail if $detail.defined;
    %i<insertTextFormat> = 2 if $snippet.defined;   # 2 = snippet
    # `labelDetails` renders beside the label itself, which is where the type and
    # the "where did this come from" marker are readable while scrolling:
    # `detail` sits right after the name, `description` right-aligns.
    if $origin.defined || $signature.defined {
        my %ld;
        %ld<detail>      = $signature if $signature.defined;
        %ld<description> = $origin    if $origin.defined;
        %i<labelDetails> = %ld;
    }
    %i
}

sub flat-symbols(@syms) {
    gather for @syms -> $s { take $s; take $_ for flat-symbols($s.children) }
}

#| The type of the topic at an offset, taken from the nearest enclosing block
#| whose signature names one: `-> RootConfig $_ { … }`. Brace depth is tracked so
#| a block that has already closed stops counting — in a nested config the outer
#| type has to come back once the inner block ends. Nil when nothing types `$_`.
#| Braces inside string literals would fool this; nothing cheaper is available
#| while the buffer does not parse.
sub topic-type(Str $before) {
    my @open;                 # one entry per unclosed brace: its topic type or Str
    my $pending = Str;
    loop (my $i = 0; $i < $before.chars; $i++) {
        my $c = $before.substr($i, 1);
        if $c eq '-' && $before.substr($i, 2) eq '->' {
            with $before.substr($i) ~~ / ^ '->' \h* ( <[A..Z]> <[\w:]>* ) \h+ '$_' / {
                $pending = ~.[0];
            }
        }
        elsif $c eq '{' { @open.push: $pending; $pending = Str }
        elsif $c eq '}' { @open.pop if @open }
    }
    @open.reverse.first({ .defined })
}

#| The type name an invocant refers to, or Nil. Text-based for the same reason as
#| `cursor-context`: the declaration is in the part of the buffer that still
#| parses, but the cursor is in the part that does not.
sub invocant-type(Str $text, Int $offset, Str $invocant) {
    return $invocant if $invocant ~~ / ^ <[A..Z]> <[\w:]>* $ /;

    my $before = $text.substr(0, $offset);
    if $invocant eq '$_' {
        return topic-type($before);
    }
    if $invocant eq 'self' {
        # The nearest enclosing package declaration that precedes the cursor.
        my @decl = ($before ~~ m:g/ ['class' | 'role' | 'grammar' | 'monitor'] \h+
                                    ( <[A..Za..z_]> <[\w:]>* ) /).map({ ~.[0] });
        return @decl.tail if @decl;
        return Nil;
    }
    if $invocant ~~ / ^ <[$@%&]> / {
        my $bare = $invocant.substr(1).subst(/^ <[.!^*?=~]> /, '');
        return Nil unless $bare;
        # `my Foo $x`, `has Foo $.x`, …
        my @typed = ($before ~~ m:g/ ['my' | 'our' | 'has' | 'state'] \h+
                                     ( <[A..Z]> <[\w:]>* ) \h+
                                     <[$@%&]> <[.!]>? $bare » /).map({ ~.[0] });
        return @typed.tail if @typed;
    }
    Nil
}

#| Methods offered after a dot: the real method table of the invocant's type when
#| we can name it, otherwise the methods the buffer itself declares.
sub method-items($analyzer, $doc, %ctx) {
    my @items;
    my $type = invocant-type($doc.text, %ctx<offset>, %ctx<invocant> // '');

    with $type {
        # What the type itself declares ranks above what it inherits from Any/Mu,
        # so a config's own fields are not buried under `ACCEPTS`, and each item
        # says where it came from. SHOUTY names are Raku's object protocol
        # (POPULATE, WHICH, AT-KEY): the type's own, but never what anyone is
        # reaching for, so they sink with the inherited ones.
        for $analyzer.type-method-info($doc, $type) -> %m {
            my $local = %m<own> && %m<name> !~~ / ^ <[A..Z_\-]>+ $ /;
            # What to show beside the name: a real parameter list where there is
            # one, otherwise the attribute's declared type. Accessors have
            # neither a useful signature nor a return type, so the attribute type
            # is the only honest answer for them.
            my $sig = %m<params> || %m<attr-type>;
            @items.push: item($doc, %ctx, %m<name>, CK-Method,
                $local ?? SG-Member !! SG-Inherited,
                detail => $local ?? "local to $type" !! "inherited from {%m<from> || 'Any'}",
                origin => %m<from> || $type,
                signature => $sig || Nil,
            );
        }
    }
    return @items if @items;

    my %seen;
    for flat-symbols($doc.symbols).grep({ .kind == SK-Method }) -> $sym {
        @items.push: item($doc, %ctx, $sym.name, CK-Method, SG-Member, detail => $sym.detail)
            unless %seen{$sym.name}++;
    }
    @items
}

#| What can follow `.section: `. When the method is backed by an attribute of a
#| user-defined type, the argument is almost always a block over that type, so a
#| ready-made `-> Type $_ { … }` is offered first; the ordinary term set follows,
#| since anything else nameable is still valid there.
sub argument-items($analyzer, $doc, %ctx) {
    my @items;
    my $type   = invocant-type($doc.text, %ctx<offset>, '$_');
    my $callee = %ctx<callee> // '';

    my %m;
    with $type {
        %m = $analyzer.type-method-info($doc, $type).first({ .<name> eq $callee }) // %();
    }

    # Named arguments the callee accepts. The colon that triggered this is
    # already typed, so only the name gets inserted.
    for |(%m<named> // ()) -> $named {
        @items.push: item($doc, %ctx, $named, CK-Field, SG-Local,
            detail => "named argument of $callee", origin => $type);
    }

    # A field holding a user-defined type is written as a block over that type; a
    # core-typed one (`Int`, `Str`) is assigned instead. A `&`-sigiled or
    # Callable parameter asks for the same thing outright.
    my $block-type = (%m<attr-type> && !$analyzer.core-type(%m<attr-type>))
        ?? %m<attr-type> !! Str;
    my $wants-callable = $block-type.defined
        || (%m<params> // '').contains('&')
        || (%m<params> // '').contains('Callable');

    return (|@items, |callable-items($analyzer, $doc, %ctx, $block-type)) if $wants-callable;

    @items.append: term-items($analyzer, $doc, %ctx);
    @items
}

#| What can stand where a Callable is expected: the block forms, then every
#| routine in reach — declared here, imported, or from CORE — offered with the
#| `&` sigil that makes them a reference rather than a call.
sub callable-items($analyzer, $doc, %ctx, $block-type) {
    my @items;

    with $block-type {
        @items.push: item($doc, %ctx, "-> $_ \$_ \{ … \}", CK-Snippet, SG-Local,
            detail  => "block over $_",
            origin  => $_,
            snippet => "-> $_ \$_ \{\n\t\$0\n\}",
            filter  => '->');
    }
    @items.push: item($doc, %ctx, '{ … }', CK-Snippet, SG-Local,
        detail => 'bare block', snippet => "\{\n\t\$0\n\}", filter => '{');
    @items.push: item($doc, %ctx, '-> $_ { … }', CK-Snippet, SG-Local,
        detail => 'block with a named topic', snippet => "-> \$_ \{\n\t\$0\n\}", filter => '->');

    my %seen;
    my &offer = -> $name, $group, $detail {
        unless %seen{$name}++ {
            @items.push: item($doc, %ctx, "&$name", CK-Function, $group,
                :$detail, filter => $name, insert => "&$name");
        }
    };

    for flat-symbols($doc.symbols).grep({ .kind == SK-Function }) -> $sym {
        offer($sym.name, SG-Local, 'declared in this file');
    }
    for $analyzer.used-module-names($doc) -> $mod {
        for $analyzer.module-exports($doc, $mod) -> $name {
            offer($name.substr(1), SG-Imported, "from $mod")
                if $name.starts-with('&') && !$name.contains(':');
        }
    }
    offer($_, SG-Core, 'core routine') for $analyzer.core-routines;
    @items
}

#| Variables declared in the buffer whose sigil matches what was typed.
sub variable-items($analyzer, $doc, %ctx) {
    my $sigil = (%ctx<prefix> // '$').substr(0, 1);
    my %seen;
    my @items;
    for $analyzer.occurrences($doc).grep({ .<kind> eq 'decl' }) -> $occ {
        my $label = $occ<text>;
        next unless $label.starts-with($sigil);
        @items.push: item($doc, %ctx, $label, CK-Variable, SG-Local)
            unless %seen{$label}++;
    }
    @items
}

#| Module names to offer after `use`.
sub module-items($analyzer, $doc, %ctx) {
    $analyzer.known-modules($doc).map({ item($doc, %ctx, $_, CK-Module, SG-Imported) })
}

#| Trait names after `is` — core traits plus whatever the `use`d modules add.
sub trait-items($analyzer, $doc, %ctx) {
    my %seen;
    my @names = |$analyzer.core-traits;
    @names.append: |$analyzer.module-traits($doc, $_) for $analyzer.used-module-names($doc);
    @names.grep({ !%seen{$_}++ })
          .map({ item($doc, %ctx, $_, CK-Keyword, SG-Imported) })
}

#| An exported stash name (`&some-sub`, `&infix:<+>`, `&term:<HERE>`, `SomeType`)
#| as a usable label and kind, or Nil for things with no plain spelling.
sub export-item($doc, %ctx, Str $name, Str $mod) {
    my $detail = "from $mod";
    if $name ~~ / ^ '&' [ 'term' | 'circumfix' ] ':<' (.+) '>' $ / {
        return item($doc, %ctx, ~$0, CK-Constant, SG-Imported, :$detail);
    }
    if $name ~~ / ^ '&' [ 'infix' | 'prefix' | 'postfix' ] ':<' (.+) '>' $ / {
        return item($doc, %ctx, ~$0, CK-Operator, SG-Imported, :$detail);
    }
    return Nil if $name.contains(':');           # trait_mod and friends: not terms
    if $name.starts-with('&') {
        return item($doc, %ctx, $name.substr(1), CK-Function, SG-Imported, :$detail);
    }
    item($doc, %ctx, $name, CK-Class, SG-Imported, :$detail)
}

#| Everything nameable in term position.
sub term-items($analyzer, $doc, %ctx) {
    my @items;
    my %seen;
    my &offer = -> $label, $kind, $group, $detail? {
        @items.push: item($doc, %ctx, $label, $kind, $group, :$detail)
            unless %seen{$group ~ $label}++;
    };

    # What this buffer declares.
    for $analyzer.occurrences($doc).grep({ .<kind> eq 'decl' }) -> $occ {
        offer($occ<text>, CK-Variable, SG-Local);
    }
    for flat-symbols($doc.symbols) -> $sym {
        offer($sym.name, %sym-to-completion{$sym.kind} // CK-Variable, SG-Local, $sym.detail);
    }

    # What its modules bring in: declarators first — a `model` or `actor` is the
    # thing you are about to type, not a footnote.
    for $analyzer.used-module-names($doc) -> $mod {
        for $analyzer.module-declarators($doc, $mod) -> $decl {
            offer($decl, CK-Keyword, SG-Imported, "declarator from $mod");
        }
        for $analyzer.module-exports($doc, $mod) -> $name {
            with export-item($doc, %ctx, $name, $mod) -> %i {
                @items.push: %i unless %seen{SG-Imported ~ %i<label>}++;
            }
        }
    }

    offer($_, CK-Function, SG-Core)  for $analyzer.core-routines;
    offer($_, CK-Keyword,  SG-Keyword) for @KEYWORDS;
    @items
}

sub register-completion($server, $analyzer) is export {
    $server.on-request: 'textDocument/completion', -> %params, $srv {
        my @items;
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            my %ctx = cursor-context($doc.text, param-offset($doc, %params));
            @items = do given %ctx<kind> {
                when 'method'   { method-items($analyzer, $doc, %ctx)   }
                when 'argument' { argument-items($analyzer, $doc, %ctx) }
                when 'variable' { variable-items($analyzer, $doc, %ctx) }
                when 'module'   { module-items($analyzer, $doc, %ctx)   }
                when 'trait'    { trait-items($analyzer, $doc, %ctx)    }
                default         { term-items($analyzer, $doc, %ctx)     }
            }
        }
        { isIncomplete => False, items => [@items] }
    };
}

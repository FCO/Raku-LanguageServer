use v6.d;
use experimental :rakuast;
use Raku::LanguageServer::Features::Support;

#| Refactorings offered as code actions. Everything here is driven by the
#| cursor position or the selected range, not by a diagnostic, so these are
#| available whenever the relevant construct is under the cursor.
#|
#| The edits are computed from source text spans rather than by re-deparsing the
#| tree: deparse rewrites the whole document, which is fine for "beautify" but
#| unacceptable for a refactor, where everything the user did not ask to change
#| must stay byte-for-byte identical.
unit module Raku::LanguageServer::Features::Refactor;

#| LSP code action kinds, so clients can group and filter them.
my constant EXTRACT = 'refactor.extract';
my constant INLINE  = 'refactor.inline';
my constant REWRITE = 'refactor.rewrite';
my constant ORGANIZE = 'source.organizeImports';

#| Itemized on the way out. A lone hash inside an array composer — `[ edit ]` —
#| flattens into its pairs, while two of them do not; that asymmetry silently
#| produced edits with no range for every single-edit action.
sub edit-at($doc, Int $from, Int $to, Str $new) {
    %( range => $doc.range($from, $to), newText => $new ).item
}

#| A CodeAction carrying edits for the current document. The hashes are itemized
#| so list context cannot flatten them into pairs.
sub action(Str $title, $doc, @edits, Str :$kind = REWRITE) {
    %(
        title => $title,
        kind  => $kind,
        edit  => %( changes => %( $doc.uri => @edits.map(*.item).Array ) ),
    ).item
}

#| Char-offset span of the request's `range`, or Nil when it is empty (a bare
#| cursor rather than a selection).
sub selection($doc, %params) {
    my %r = %params<range> // return Nil;
    my $from = $doc.offset-at(%r<start>);
    my $to   = $doc.offset-at(%r<end>);
    $to > $from ?? ($from, $to) !! Nil
}

#| Where the cursor is for a code-action request. These carry a `range`, not a
#| `position`; `param-offset` would silently answer with the top of the file.
sub cursor-offset($doc, %params --> Int) {
    with %params<range><start> -> %start { return $doc.offset-at(%start) }
    param-offset($doc, %params)
}

sub indent-at($doc, Int $offset --> Str) {
    my $line = $doc.position.offset-to-position($offset)<line>;
    my $src  = $doc.text.lines[$line] // '';
    $src ~~ / ^ (\h*) / ?? ~$0 !! ''
}

#| Offset of the start of the line containing an offset.
sub line-start($doc, Int $offset --> Int) {
    my $line = $doc.position.offset-to-position($offset)<line>;
    $doc.position.position-to-offset({ line => $line, character => 0 })
}

# --- extract ---------------------------------------------------------------

#| Selected expression → `my $name = <expr>;` on the line above, the selection
#| replaced by the variable. The name is a placeholder the user renames after;
#| choosing one automatically guesses worse than the person who wrote the code.
sub extract-variable($doc, %params) {
    my ($from, $to) = |(selection($doc, %params) // return ());
    my $expr = $doc.text.substr($from, $to - $from).trim;
    return () unless $expr && !$expr.contains("\n");

    my $bol    = line-start($doc, $from);
    my $indent = indent-at($doc, $from);
    ( action('Extract to variable', $doc, [
        edit-at($doc, $bol, $bol, "{$indent}my \$extracted = $expr;\n"),
        edit-at($doc, $from, $to, '$extracted'),
      ], kind => EXTRACT), )
}

#| Selected statements → a new `sub` above the enclosing routine (or above the
#| selection at file scope), with a call left in their place. Free variables are
#| NOT computed into parameters: that needs real scope analysis, and a wrong
#| signature is worse than an obvious empty one.
sub extract-routine($doc, $analyzer, %params) {
    my ($from, $to) = |(selection($doc, %params) // return ());
    my $body = $doc.text.substr($from, $to - $from);
    return () unless $body.trim;

    # Place the new routine before the enclosing routine when there is one, so
    # it does not land inside another routine's body.
    my $anchor = $from;
    with $analyzer.enclosing-routine($doc, $from) -> $routine {
        with (try $routine.origin) -> $o { $anchor = $o.from if $o.defined }
    }
    my $at     = line-start($doc, $anchor);
    my $indent = indent-at($doc, $anchor);
    my $inner  = $body.lines.map({ $_ eq '' ?? '' !! "$indent    " ~ .trim-leading }).join("\n");

    ( action('Extract to routine', $doc, [
        edit-at($doc, $at, $at, "{$indent}sub extracted() \{\n$inner\n$indent\}\n\n"),
        edit-at($doc, $from, $to, 'extracted()'),
      ], kind => EXTRACT), )
}

# --- inline ----------------------------------------------------------------

#| `my $x = <expr>;` with the cursor on the declaration → every use of `$x`
#| replaced by the expression and the declaration removed. Offered only when the
#| initialiser is a single line and the variable is used at least once, and
#| never when the variable is assigned again — inlining past a reassignment
#| changes behaviour.
sub inline-variable($doc, $analyzer, %params) {
    my $offset = cursor-offset($doc, %params);
    my $id     = $analyzer.identifier-at($doc, $offset) orelse return ();
    my $name   = $id<text>;
    return () unless $name.starts-with('$');

    my $text = $doc.text;
    my $decl = $text ~~ / « 'my' \h+ [ <[A..Z]> <[\w:]>* \h+ ]? $name \h* '=' \h* ( <-[;\n]>+ ) \h* ';' \h* \n? /;
    return () unless $decl;
    my $init = ~$decl[0];

    # Any further assignment means the value is not constant through its scope.
    my $rest = $text.substr($decl.to);
    return () if $rest ~~ / « $name \h* [ '=' <!before '='> | '+=' | '-=' | '~=' | '//=' ] /;

    my @uses = ($rest ~~ m:g/ $name » /).map({ %( from => $decl.to + .from, to => $decl.to + .to ) });
    return () unless @uses;

    my @edits;
    @edits.push: edit-at($doc, $decl.from, $decl.to, '');
    @edits.push: edit-at($doc, .<from>, .<to>, "($init)") for @uses;
    ( action("Inline $name", $doc, @edits, kind => INLINE), )
}

# --- rewrite ---------------------------------------------------------------

#| `if COND { BODY }` on one statement ⇄ `BODY if COND;`. Only offered for a
#| single-statement body with no `else`, where the two really are equivalent.
sub toggle-postfix-if($doc, %params) {
    my $offset = cursor-offset($doc, %params);
    my $line   = $doc.position.offset-to-position($offset)<line>;
    my $src    = $doc.text.lines[$line] // return ();
    my $bol    = $doc.position.position-to-offset({ :$line, character => 0 });
    my $eol    = $bol + $src.chars;

    with $src ~~ / ^ (\h*) ('if' | 'unless') \h+ (.+?) \h* '{' \h* (.+?) \h* '}' \h* $ / {
        my ($indent, $kw, $cond, $body) = ~$0, ~$1, ~$2, ~$3;
        return () if $body.contains('{') || $body.contains('}');
        my $stmt = $body.ends-with(';') ?? $body !! "$body;";
        return ( action("Use postfix '$kw'", $doc,
            [ edit-at($doc, $bol, $eol, "$indent$stmt.chomp(';') $kw $cond;") ]), );
    }
    with $src ~~ / ^ (\h*) (.+?) \h+ ('if' | 'unless') \h+ (.+?) \h* ';' \h* $ / {
        my ($indent, $body, $kw, $cond) = ~$0, ~$1, ~$2, ~$3;
        return ( action("Use block '$kw'", $doc,
            [ edit-at($doc, $bol, $eol, "$indent$kw $cond \{ $body; \}") ]), );
    }
    ()
}

#| `'text'` ⇄ `"text"`. Only when flipping cannot change meaning: no escapes, no
#| `$`/`@`/`%`/`\` that would start interpolating, no quote of the other kind.
sub toggle-quotes($doc, %params) {
    my $offset = cursor-offset($doc, %params);
    my $text   = $doc.text;
    for $text ~~ m:g/ \' <-[\'\\]>* \' | \" <-[\"\\]>* \" / -> $m {
        next unless $m.from <= $offset <= $m.to;
        my $body = ~$m;
        my $inner = $body.substr(1, $body.chars - 2);
        # Anything that would start interpolating means the two forms differ.
        next if $inner ~~ / <[\$\@\%\\]> /;
        my ($to-quote, $label) = $body.starts-with("'")
            ?? ('"', 'Convert to double quotes')
            !! ("'", 'Convert to single quotes');
        return ( action($label, $doc,
            [ edit-at($doc, $m.from, $m.to, $to-quote ~ $inner ~ $to-quote) ]), );
    }
    ()
}

#| Add `is export` to the routine or package declaration under the cursor.
sub add-is-export($doc, %params) {
    my $offset = cursor-offset($doc, %params);
    my $line   = $doc.position.offset-to-position($offset)<line>;
    my $src    = $doc.text.lines[$line] // return ();
    return () if $src.contains('is export');

    with $src ~~ / ^ \h* ['my' \h+ | 'our' \h+ | 'multi' \h+ | 'proto' \h+ ]?
                   ('sub' | 'method' | 'class' | 'role' | 'grammar' | 'subset' | 'constant')
                   \h+ <[\w:$@%&-]>+ / {
        my $bol  = $doc.position.position-to-offset({ :$line, character => 0 });
        # Before the block or the statement end, whichever comes first.
        my $stop = min(($src.index('{') // $src.chars), ($src.index(';') // $src.chars));
        my $at   = $bol + $src.substr(0, $stop).trim-trailing.chars;
        return ( action('Add "is export"', $doc, [ edit-at($doc, $at, $at, ' is export') ]), );
    }
    ()
}

#| `has $.x` ⇄ `has $!x`: give an attribute a public accessor, or take it away.
sub toggle-accessor($doc, %params) {
    my $offset = cursor-offset($doc, %params);
    my $line   = $doc.position.offset-to-position($offset)<line>;
    my $src    = $doc.text.lines[$line] // return ();
    my $bol    = $doc.position.position-to-offset({ :$line, character => 0 });

    with $src ~~ / « 'has' \h+ [ <[A..Z]> <[\w:]>* \h+ ]? <[$@%]> ('.' | '!') / {
        my $twigil = ~$0;
        my $at     = $bol + $0.from;
        my ($new, $label) = $twigil eq '.'
            ?? ('!', 'Make attribute private (has $!x)')
            !! ('.', 'Add public accessor (has $.x)');
        return ( action($label, $doc, [ edit-at($doc, $at, $at + 1, $new) ]), );
    }
    ()
}

#| Wrap the selection in `try { … }`.
sub wrap-in-try($doc, %params) {
    my ($from, $to) = |(selection($doc, %params) // return ());
    my $body = $doc.text.substr($from, $to - $from);
    return () unless $body.trim;
    my $indent = indent-at($doc, $from);
    my $inner  = $body.lines.map({ $_ eq '' ?? '' !! "    " ~ $_ }).join("\n");
    ( action('Wrap in try', $doc,
        [ edit-at($doc, line-start($doc, $from), $to, "{$indent}try \{\n$inner\n$indent\}") ]), )
}

#| Sort the leading run of `use`/`need` statements alphabetically. Only the
#| unbroken block at the top is touched, and only when it is not already
#| sorted — a `use` further down may depend on something above it.
sub organize-imports($doc) {
    my @lines = $doc.text.lines;
    my ($start, $end) = Int, Int;
    for @lines.kv -> $i, $l {
        if $l ~~ / ^ \h* ['use' | 'need'] \h+ <[A..Za..z_]> / {
            $start //= $i;
            $end = $i;
        }
        elsif $start.defined && ($l.trim eq '' || $l ~~ / ^ \h* '#' /) { }
        elsif $start.defined { last }
    }
    return () unless $start.defined && $end > $start;

    my @block  = @lines[$start .. $end];
    my @uses   = @block.grep({ / ^ \h* ['use' | 'need'] \h+ / });
    my @sorted = @uses.sort({ .trim });
    return () if @uses eqv @sorted;
    # Only rewrite a clean run: comments interleaved would be reordered blindly.
    return () unless @uses.elems == @block.grep({ .trim ne '' }).elems;

    my $from = $doc.position.position-to-offset({ line => $start, character => 0 });
    my $to   = $doc.position.position-to-offset({ line => $end, character => @lines[$end].chars });
    ( action('Sort use statements', $doc,
        [ edit-at($doc, $from, $to, @sorted.join("\n")) ], kind => ORGANIZE), )
}

#| Every refactor applicable at the request's position/range.
#| Each provider is appended separately on purpose: iterating a list of lists
#| would flatten one level too far and turn the action hashes into pairs.
sub refactor-actions($doc, $analyzer, %params) is export {
    my @actions;
    @actions.append: extract-variable($doc, %params);
    @actions.append: extract-routine($doc, $analyzer, %params);
    @actions.append: inline-variable($doc, $analyzer, %params);
    @actions.append: toggle-postfix-if($doc, %params);
    @actions.append: toggle-quotes($doc, %params);
    @actions.append: add-is-export($doc, %params);
    @actions.append: toggle-accessor($doc, %params);
    @actions.append: wrap-in-try($doc, %params);
    @actions.append: organize-imports($doc);
    @actions
}

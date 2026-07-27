use v6.d;
use experimental :rakuast;
use Raku::LanguageServer::Features::Support;

#| Code actions. Diagnostic-driven quick-fixes read the FULL compiler message
#| from `$doc.compile-error` (published diagnostics are shortened), so compiler
#| suggestions are available. Plus an always-available "beautify" source action.
#|
#| Quick-fixes: declare an undeclared variable with `my`; apply a "Did you mean"
#| spelling suggestion; stub an undeclared routine; add a `use` for an undeclared
#| type. Source action: reformat the whole document via RakuAST deparse.
unit module Raku::LanguageServer::Features::CodeAction;

sub indent-of($doc, Int $line --> Str) {
    my $src = $doc.text.lines[$line] // '';
    $src ~~ / ^ (\s*) / ?? ~$0 !! ''
}

#| A TextEdit for a single point / range (line/character based).
sub text-edit(Int $l0, Int $c0, Int $l1, Int $c1, Str $new --> Hash) {
    %(
        range   => %( start => %( line => $l0, character => $c0 ),
                      end   => %( line => $l1, character => $c1 ) ),
        newText => $new,
    )
}

#| A CodeAction wrapping edits on the current document. Edits and diagnostics are
#| itemized (`.item`) so their hashes aren't flattened into pairs by list context.
sub make-action(Str $title, $doc, @edits, @diags, Str :$kind = 'quickfix', :$preferred --> Hash) {
    my %a = (
        title       => $title,
        kind        => $kind,
        diagnostics => @diags.map(*.item).Array,
        edit        => %( changes => %( $doc.uri => @edits.map(*.item).Array ) ),
    );
    %a<isPreferred> = True if $preferred;
    %a
}

sub error-line($doc, $pos --> Int) {
    $pos.defined ?? $doc.position.offset-to-position($pos)<line> !! 0
}

# --- diagnostic-driven quick-fix providers ---

sub declare-var($doc, $analyzer, Str $msg, $pos, @diags) {
    return () unless $msg ~~ / "Variable '" (<[$@%&]> <-[']>*) "' is not declared" /;
    my $var    = ~$0;
    my $line   = error-line($doc, $pos);
    my $edit   = text-edit($line, 0, $line, 0, indent-of($doc, $line) ~ "my $var;\n");
    ( make-action("Declare $var with 'my'", $doc, [ $edit ], @diags, :preferred), )
}

sub did-you-mean($doc, $analyzer, Str $msg, $pos, @diags) {
    return () unless $msg.contains('Did you mean') && $pos.defined;
    my $tail = $msg.substr($msg.index('Did you mean'));
    my @sugg = ($tail ~~ m:g/ "'" (<-[']>+) "'" /).map({ ~.[0] });
    my $id   = $analyzer.identifier-at($doc, $pos) orelse return ();
    my $range = %(
        start => $doc.position.offset-to-position($id<from>),
        end   => $doc.position.offset-to-position($id<to>),
    );
    @sugg.map(-> $s {
        my $edit = %( :$range, newText => $s );
        make-action("Change '$id<text>' to '$s'", $doc, [ $edit ], @diags)
    })
}

sub routine-stub($doc, $analyzer, Str $msg, $pos, @diags) {
    return () unless $msg.contains('Undeclared routine');
    return () unless $msg ~~ / (<[A..Za..z_]> <[\w '-]>*) \s+ 'used at' /;
    my $name = ~$0;
    my $line = error-line($doc, $pos);
    my $edit = text-edit($line, 0, $line, 0,
        indent-of($doc, $line) ~ "sub $name " ~ '{ !!! }' ~ "\n");
    ( make-action("Create stub 'sub $name'", $doc, [ $edit ], @diags), )
}

sub add-use($doc, $analyzer, Str $msg, $pos, @diags) {
    return () unless $msg ~~ / "Type '" (<[A..Za..z_]> <[\w :]>*) "' is not declared" /;
    my $type = ~$0;
    # Insert after any leading use/unit/need lines (a `use` before `unit` is illegal).
    my $at = 0;
    for $doc.text.lines.kv -> $i, $l {
        if    $l ~~ / ^ \s* ['use' | 'unit' | 'need' | 'no'] >> / { $at = $i + 1 }
        elsif $l ~~ / ^ \s* '#' / || $l.trim eq ''                { }
        else                                                       { last }
    }
    my $edit = text-edit($at, 0, $at, 0, "use $type;\n");
    ( make-action("Add 'use $type;'", $doc, [ $edit ], @diags), )
}

# --- always-available source action ---

sub beautify($doc) {
    return () unless $doc.ast-current;
    my $formatted = try $doc.ast.DEPARSE;
    return () unless $formatted.defined && $formatted ne $doc.text;
    my $edit = %( range => $doc.range(0, $doc.text.chars), newText => ~$formatted );
    ( make-action('Beautify (RakuAST deparse)', $doc, [ $edit ], [], :kind<source>), )
}

sub register-code-action($server, $analyzer) is export {
    $server.on-request: 'textDocument/codeAction', -> %params, $srv {
        with analyzed-doc($srv, $analyzer, %params) -> $doc {
            my @diags = |(%params<context><diagnostics> // ());
            my @actions;

            with $doc.compile-error -> $err {
                my $msg = ~$err.message;
                my $pos = try $err.pos;
                $pos = $doc.offset-at(@diags[0]<range><start>) if !$pos.defined && @diags;
                for &declare-var, &did-you-mean, &routine-stub, &add-use -> &provider {
                    for provider($doc, $analyzer, $msg, $pos, @diags) -> $action {
                        @actions.push: $action;
                    }
                }
            }
            for beautify($doc) -> $action { @actions.push: $action }

            [ @actions ]
        }
        else { [] }
    };
}

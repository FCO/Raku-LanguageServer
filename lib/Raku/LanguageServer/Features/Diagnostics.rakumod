use v6.d;
use Raku::LanguageServer::Document;
use Raku::LanguageServer::Protocol;

#| Publishes compile diagnostics for a document. Diagnostics come from the
#| in-process `.AST` compile captured by the Analyzer as `$doc.compile-error`.
unit module Raku::LanguageServer::Features::Diagnostics;

# LSP DiagnosticSeverity
my constant Error   = 1;
my constant Warning = 2;

#| Flatten an `X::Comp::Group` into its component compile errors; pass a single
#| exception through unchanged. Panics are errors; worries are warnings.
sub comp-parts($err) {
    my @parts;
    if $err ~~ X::Comp::Group {
        @parts.push: ($_, Error)   for |(try $err.sorrows) // ();
        @parts.push: ($err.panic, Error) if (try $err.panic).defined;
        @parts.push: ($_, Warning) for |(try $err.worries) // ();
    }
    @parts.push: ($err, Error) unless @parts;
    @parts
}

#| Build one LSP Diagnostic from a compile exception, using its `.pos`/`.line`.
sub to-diagnostic(Raku::LanguageServer::Document:D $doc, $err, Int $severity --> Hash) {
    my $text = $doc.text;
    my $pos  = try $err.pos;
    my $line = try $err.line;

    my ($from, $to);
    if $pos.defined && $pos >= 0 && $pos <= $text.chars {
        $from = $pos;
        # Highlight from the error position to the end of its line.
        $to   = $text.index("\n", $from) // $text.chars;
        $to   = $from if $to < $from;
    }
    elsif $line.defined && $line >= 1 {
        # Fall back to highlighting the whole indicated line.
        my $ln = $line - 1;
        my $p  = $doc.position;
        $from  = $p.position-to-offset({ :line($ln), :character(0) });
        $to    = $p.position-to-offset({ :line($ln + 1), :character(0) });
        $to    = $text.chars if $to > $text.chars;
    }
    else {
        $from = 0; $to = 0;
    }

    {
        range    => $doc.range($from, $to),
        severity => $severity,
        source   => 'raku',
        message  => clean-message(~$err.message),
    }
}

#| Reduce a raw Rakudo compile message to a readable one-liner: prefer the line
#| stating the root cause, drop the `===SORRY!===` banners, source-pointer lines
#| and the module-repository path list, and turn a serialized deferred import
#| failure (cached precompilation failure) back into a plain "module not found".
sub clean-message(Str $raw --> Str) {
    if $raw.contains('UnsatisfiedDependency') || $raw.contains('Import failed') {
        my $mod = ($raw ~~ / '"short-name"' \s* ':' \s* '"' (<-["]>+) '"' /) ?? ~$0
               !! ($raw ~~ /:i 'find ' (<[\w:]>+) /)                        ?? ~$0
               !!                                                              Str;
        return $mod ?? "Cannot find used module: $mod"
                    !! "Cannot load a used module (unsatisfied dependency)";
    }

    my @lines = $raw.lines.map(*.trim).grep(*.chars);
    my $core =
        @lines.first({ / 'Could not find' | 'Undeclared' | 'Malformed'
                          | 'Undefined'  | 'not declared' | 'Missing' / })
        // @lines.first({
               !.starts-with('===SORRY!===') && !.starts-with('at ')
               && !.starts-with('------>')   && !.starts-with('expecting')
               && !.starts-with('/')         && !.starts-with('CompUnit::')
               && .chars > 3
           })
        // @lines[0] // $raw;
    $core.subst(/ \s* 'in:' \s* $/, '')
}

#| All diagnostics for a document's current analysis state.
sub diagnostics-for(Raku::LanguageServer::Document:D $doc --> Array) is export {
    my @diags;
    with $doc.compile-error -> $err {
        for comp-parts($err) -> ($e, $sev) {
            @diags.push: to-diagnostic($doc, $e, $sev);
        }
    }
    @diags
}

#| Compute and publish diagnostics for a document to the client.
sub publish-diagnostics($server, $analyzer, Raku::LanguageServer::Document:D $doc) is export {
    $analyzer.analyze($doc);
    $server.notify: 'textDocument/publishDiagnostics', {
        uri         => $doc.uri,
        version     => $doc.version,
        diagnostics => diagnostics-for($doc),
    };
}

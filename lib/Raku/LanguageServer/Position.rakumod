use v6.d;

#| Converts between the two coordinate systems the server juggles:
#|
#|  * **char offset** — an index into the Raku source `Str` (what RakuAST's
#|    `.origin.from`/`.to` return). Raku strings are grapheme (NFG) based, so
#|    one index is one grapheme.
#|  * **LSP position** — a `{ line, character }` pair. `line` is 0-based. The
#|    unit of `character` depends on the negotiated encoding: UTF-16 code units
#|    (LSP default) or UTF-8 bytes.
#|
#| A `Position` object indexes one immutable document text so repeated
#| conversions are cheap: it precomputes the char offset where each line starts.
unit class Raku::LanguageServer::Position;

has Str $.text is required;
has Str $.encoding = 'utf-16';

#| Char offset of the first character of each line (line 0 starts at 0).
has @!line-starts;

submethod TWEAK {
    @!line-starts = 0;
    # Raku's line-boundary handling recognizes \n, \r\n and \r uniformly when
    # we scan graphemes: a \r\n pair is a single grapheme, so counting works.
    my int $i = 0;
    my int $n = $!text.chars;
    while $i < $n {
        my $ch = $!text.substr($i, 1);
        if $ch eq "\n" || $ch eq "\r\n" || $ch eq "\r" {
            @!line-starts.push: $i + 1;
        }
        $i++;
    }
}

#| Number of lines in the document.
method line-count(--> Int) { @!line-starts.elems }

#| Width of a substring in the negotiated encoding's units.
method !width(Str $s --> Int) {
    given $!encoding {
        when 'utf-8'  { $s.encode('utf-8').elems }
        when 'utf-16' { $s.encode('utf-16').elems }   # code units (16-bit each)
        default       { $s.chars }
    }
}

#| Convert a char offset into an LSP `{ line, character }` position.
method offset-to-position(Int $offset --> Hash) {
    my $off = $offset;
    $off = 0            if $off < 0;
    $off = $!text.chars if $off > $!text.chars;

    # Binary search for the last line-start <= $off.
    my $lo = 0;
    my $hi = @!line-starts.end;
    while $lo < $hi {
        my $mid = ($lo + $hi + 1) div 2;
        if @!line-starts[$mid] <= $off { $lo = $mid }
        else                           { $hi = $mid - 1 }
    }
    my $line       = $lo;
    my $line-start = @!line-starts[$line];
    my $character  = self!width: $!text.substr($line-start, $off - $line-start);
    { :$line, :$character }
}

#| Convert an LSP `{ line, character }` position into a char offset.
#| Positions past the end of a line clamp to the line end; positions past the
#| end of the document clamp to the document end.
method position-to-offset(%pos --> Int) {
    my $line = %pos<line> // 0;
    my $char = %pos<character> // 0;
    return $!text.chars if $line > @!line-starts.end;
    return 0            if $line < 0;

    my $line-start = @!line-starts[$line];
    my $line-end   = $line < @!line-starts.end
        ?? @!line-starts[$line + 1]
        !! $!text.chars;

    # Walk graphemes from the line start, accumulating encoded width until we
    # reach the requested character column.
    my $off   = $line-start;
    my $width = 0;
    while $off < $line-end && $width < $char {
        $width += self!width: $!text.substr($off, 1);
        $off++;
    }
    $off
}

#| Build an LSP `Range` (`{ start, end }`) from a char-offset span.
method range(Int $from, Int $to --> Hash) {
    {
        start => self.offset-to-position($from),
        end   => self.offset-to-position($to),
    }
}

use v6.d;
use JSON::Fast;

#| Reads and writes LSP messages over a byte stream using the
#| `Content-Length` header framing defined by the Language Server Protocol.
#|
#| Framing (one message):
#|
#|     Content-Length: 123\r\n
#|     \r\n
#|     {...123 bytes of UTF-8 JSON...}
#|
#| The reader is binary-safe: it counts *bytes* (not characters) for the body,
#| then decodes as UTF-8. `$*OUT` is reserved for this protocol traffic, so
#| callers must log elsewhere (e.g. `$*ERR`).
unit class Raku::LanguageServer::Transport;

has $.in    is built = $*IN;
has $.out   is built = $*OUT;
has Lock $!write-lock .= new;

#| Buffer of bytes already read from the input handle but not yet consumed.
has buf8 $!pending .= new;

submethod TWEAK {
    # Ensure we operate on raw bytes, not decoded text, on both ends.
    $!in.encoding: 'bin'  if $!in.^can('encoding');
    $!out.encoding: 'bin' if $!out.^can('encoding');
}

#| Read exactly $n more bytes into the pending buffer (blocking).
#| Returns False on EOF before $n bytes are available.
method !fill(Int $n --> Bool) {
    while $!pending.elems < $n {
        my $chunk = $!in.read(4096);
        return False unless $chunk && $chunk.elems;
        $!pending.append: $chunk;
    }
    True
}

#| Find the index just past the header terminator (\r\n\r\n) in $!pending,
#| reading more bytes as needed. Returns the byte index, or Nil on EOF.
method !find-header-end(--> Int) {
    my int $i = 0;
    loop {
        # Need at least 4 bytes from $i to test for the terminator.
        return Nil unless self!fill($i + 4);
        if      $!pending[$i]   == 0x0D   # \r
            &&  $!pending[$i+1] == 0x0A   # \n
            &&  $!pending[$i+2] == 0x0D   # \r
            &&  $!pending[$i+3] == 0x0A { # \n
            return $i + 4;
        }
        $i++;
    }
}

#| Read one framed message and return the decoded JSON (Hash/Array), or Nil on
#| a clean EOF. Malformed headers throw.
method read-message() {
    my $header-end = self!find-header-end orelse return Nil;

    my $header-bytes = buf8.new: $!pending[^$header-end];
    $!pending .= subbuf($header-end);
    my $header-text = $header-bytes.decode('latin-1');   # headers are ASCII

    my $length;
    for $header-text.split(/\r\n/) -> $line {
        if $line ~~ /^ \s* 'Content-Length' \s* ':' \s* (\d+) \s* $/ {
            $length = +$0;
        }
    }
    die "Missing Content-Length header" unless $length.defined;

    self!fill($length) or die "Unexpected EOF reading message body";
    my $body-bytes = buf8.new: $!pending[^$length];
    $!pending .= subbuf($length);

    from-json $body-bytes.decode('utf-8')
}

#| Serialize a message to JSON and write it with a Content-Length header.
#| Thread-safe: writes are serialized so responses never interleave.
method write-message($message --> Nil) {
    my $body    = to-json($message, :!pretty).encode('utf-8');
    my $header  = "Content-Length: {$body.elems}\r\n\r\n".encode('latin-1');
    $!write-lock.protect: {
        $!out.write: $header;
        $!out.write: $body;
        $!out.flush;
    }
}

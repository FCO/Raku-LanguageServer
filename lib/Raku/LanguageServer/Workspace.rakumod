use v6.d;
use Raku::LanguageServer::Document;

#| The set of documents currently open in the editor, keyed by URI. Full
#| document sync: `open` and `change` both install the complete text.
unit class Raku::LanguageServer::Workspace;

has %.documents;   #| uri → Raku::LanguageServer::Document
has Str $.encoding is rw = 'utf-16';

method open(Str $uri, Str $text, Int $version --> Raku::LanguageServer::Document) {
    my $doc = Raku::LanguageServer::Document.new(:$uri, :$!encoding);
    $doc.update($text, $version);
    %!documents{$uri} = $doc;
}

method change(Str $uri, Str $text, Int $version --> Raku::LanguageServer::Document) {
    with %!documents{$uri} -> $doc {
        $doc.update($text, $version);
        $doc;
    }
    else {
        self.open($uri, $text, $version);
    }
}

method close(Str $uri) {
    %!documents{$uri}:delete;
}

method get(Str $uri --> Raku::LanguageServer::Document) {
    %!documents{$uri}
}

method all() { %!documents.values }

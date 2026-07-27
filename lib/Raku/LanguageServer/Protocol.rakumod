use v6.d;

unit module Raku::LanguageServer::Protocol;

#| JSON-RPC 2.0 message helpers used by the language server.
#|
#| The LSP wire format is JSON-RPC 2.0. This module knows nothing about
#| transport (framing); it only builds and classifies message payloads that
#| the Transport layer serializes.

#| Standard JSON-RPC 2.0 error codes plus the LSP-specific ones.
our constant ParseError            is export = -32700;
our constant InvalidRequest        is export = -32600;
our constant MethodNotFound        is export = -32601;
our constant InvalidParams         is export = -32602;
our constant InternalError         is export = -32603;
our constant ServerNotInitialized  is export = -32002;
our constant RequestFailed         is export = -32803;
our constant RequestCancelled      is export = -32800;

#| True if the decoded message is a request (has an id and a method).
sub is-request($msg --> Bool) is export {
    $msg ~~ Associative && ($msg<method>:exists) && ($msg<id>:exists)
}

#| True if the decoded message is a notification (method, no id).
sub is-notification($msg --> Bool) is export {
    $msg ~~ Associative && ($msg<method>:exists) && !($msg<id>:exists)
}

#| Build a successful JSON-RPC response for the given request id.
sub response($id, $result --> Hash) is export {
    { :jsonrpc('2.0'), :$id, :$result }
}

#| Build a JSON-RPC error response for the given request id.
sub error-response($id, Int $code, Str $message, $data?  --> Hash) is export {
    my %error = :$code, :$message;
    %error<data> = $data if $data.defined;
    { :jsonrpc('2.0'), :$id, :error(%error) }
}

#| Build a server-to-client notification (no id, no response expected).
sub notification(Str $method, $params --> Hash) is export {
    { :jsonrpc('2.0'), :$method, :$params }
}

#| Build a server-to-client request (client is expected to respond).
sub request($id, Str $method, $params --> Hash) is export {
    { :jsonrpc('2.0'), :$id, :$method, :$params }
}

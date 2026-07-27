use v6.d;
use Raku::LanguageServer::Transport;
use Raku::LanguageServer::Protocol;
use Raku::LanguageServer::Workspace;

#| The LSP server: owns the transport, the open-document workspace, and a
#| registry of request/notification handlers. It enforces the LSP lifecycle
#| (initialize → initialized → … → shutdown → exit) and routes each incoming
#| message to a handler.
#|
#| Handlers are plain callables registered by method name, keeping features
#| decoupled from the core loop. A handler receives ($params, $server) and, for
#| requests, returns the JSON-RPC `result`. Any exception a handler throws is
#| turned into a JSON-RPC error (requests) or logged and swallowed
#| (notifications) so buffer code can never take down the loop.
unit class Raku::LanguageServer::Server;

has Raku::LanguageServer::Transport $.transport is required;
has Raku::LanguageServer::Workspace $.workspace .= new;

#| method name → Callable($params, $server) returning a result
has %.request-handlers;
#| method name → Callable($params, $server)
has %.notification-handlers;

#| Client capabilities as received in `initialize` (feature negotiation).
has %.client-capabilities;
#| Directories the client reports as its workspace, from `initialize`.
has @.workspace-roots is rw;
#| Negotiated position encoding: "utf-16" (default) or "utf-8".
has Str $.position-encoding is rw = 'utf-16';

has Bool $!initialized = False;
has Bool $!shutting-down = False;
has Bool $.running is rw = True;

#| Semantic token legend, shared with the SemanticTokens feature and advertised
#| in server capabilities. Order defines the numeric indices on the wire.
our @TOKEN-TYPES is export = <
    namespace type class enum interface struct typeParameter parameter
    variable property function method keyword modifier comment string
    number regexp operator
>;
our @TOKEN-MODIFIERS is export = <
    declaration definition readonly static deprecated defaultLibrary
>;

#| Write to stderr; stdout is reserved for protocol traffic.
method log(*@parts) {
    note '[raku-ls] ', @parts.join;
}

#| Register a request handler (returns a result).
method on-request(Str $method, &handler) {
    %!request-handlers{$method} = &handler;
}

#| Register a notification handler (no response).
method on-notification(Str $method, &handler) {
    %!notification-handlers{$method} = &handler;
}

#| Send a notification to the client.
method notify(Str $method, $params) {
    $.transport.write-message: notification($method, $params);
}

#| Server capabilities advertised in the initialize response. Reflects every
#| feature the server implements.
method capabilities(--> Hash) {
    {
        positionEncoding => $!position-encoding,
        textDocumentSync => {
            openClose => True,
            change    => 1,       # 1 = Full document sync
        },
        documentSymbolProvider     => True,
        workspaceSymbolProvider    => True,
        hoverProvider              => True,
        definitionProvider         => True,
        declarationProvider        => True,
        typeDefinitionProvider     => True,
        implementationProvider     => True,
        referencesProvider         => True,
        documentHighlightProvider  => True,
        documentFormattingProvider => True,
        foldingRangeProvider       => True,
        selectionRangeProvider     => True,
        inlayHintProvider          => True,
        callHierarchyProvider      => True,
        codeLensProvider           => { resolveProvider => False },
        codeActionProvider         => { codeActionKinds => [ 'quickfix', 'source' ] },
        typeHierarchyProvider      => True,
        documentLinkProvider       => { resolveProvider => False },
        renameProvider             => { prepareProvider => True },
        completionProvider         => {
            triggerCharacters => [ '$', '@', '%', '&', ':', '.', '-', '>' ],
        },
        signatureHelpProvider      => {
            triggerCharacters => [ '(', ',' ],
        },
        semanticTokensProvider     => {
            legend => {
                tokenTypes     => [@TOKEN-TYPES],
                tokenModifiers => [@TOKEN-MODIFIERS],
            },
            full  => True,
            range => True,
        },
    }
}

#| Handle the `initialize` request: negotiate position encoding and report
#| capabilities. This is the only request allowed before initialization.
method !handle-initialize(%params) {
    %!client-capabilities = %params<capabilities> // {};

    # Honor utf-8 if the client lists it, to make position conversion a no-op.
    my @encodings = |(%!client-capabilities<general><positionEncodings> // ());
    $!position-encoding = 'utf-8' if @encodings.grep('utf-8');

    # Hand the negotiated encoding to the workspace, which passes it to every
    # Document it opens. Without this the server advertises one encoding and
    # measures in another: Neovim negotiates utf-8, the documents stayed on the
    # utf-16 default, and every column on a line containing a non-ASCII
    # character was wrong in both directions.
    $!workspace.encoding = $!position-encoding;

    # Remember where the editor thinks the project is. A buffer opened from a
    # dependency (`~/.raku/sources/<sha>`) has no useful project of its own, so
    # project-wide searches fall back on these.
    my @roots = |(%params<workspaceFolders> // ()).map({ .<uri> // Str }),
                %params<rootUri> // Str;
    @!workspace-roots = @roots.grep(*.defined)
        .map({ .starts-with('file://') ?? .subst(/^ 'file://' <-[/]>* /, '') !! $_ })
        .grep({ $_ && .IO.d })
        .unique;

    {
        capabilities => self.capabilities,
        serverInfo   => { name => 'Raku::LanguageServer', version => '0.0.1' },
    }
}

#| Dispatch a single decoded message. Called once per framed message.
method handle($msg) {
    if is-request($msg) {
        self!handle-request($msg);
    }
    elsif is-notification($msg) {
        self!handle-notification($msg);
    }
    # Responses to server→client requests would land here; none are awaited yet.
}

method !handle-request($msg) {
    my $id     = $msg<id>;
    my $method = $msg<method>;
    my %params = |($msg<params> // {});

    # Lifecycle gating.
    if $method eq 'initialize' {
        return self!reply-error($id, InvalidRequest, 'Server already initialized')
            if $!initialized;
        my $result = self!handle-initialize(%params);
        $!initialized = True;
        return self!reply($id, $result);
    }
    if !$!initialized {
        return self!reply-error($id, ServerNotInitialized, 'Server not initialized');
    }
    if $method eq 'shutdown' {
        $!shutting-down = True;
        return self!reply($id, Any);
    }
    if $!shutting-down {
        return self!reply-error($id, InvalidRequest, 'Server is shutting down');
    }

    with %!request-handlers{$method} -> &handler {
        my $result = try handler(%params, self);
        if $! {
            self.log("request $method failed: ", $!.message);
            return self!reply-error($id, RequestFailed, $!.message);
        }
        return self!reply($id, $result);
    }

    self!reply-error($id, MethodNotFound, "Unknown method: $method");
}

method !handle-notification($msg) {
    my $method = $msg<method>;
    my %params = |($msg<params> // {});

    if $method eq 'exit' {
        # Clean exit code 0 only if shutdown was requested first.
        $.running = False;
        exit($!shutting-down ?? 0 !! 1);
    }
    return unless $!initialized;      # ignore pre-init notifications (e.g. before initialized)

    if $method eq 'initialized' {
        return;   # nothing to do; some servers register capabilities here
    }

    with %!notification-handlers{$method} -> &handler {
        my $ = try handler(%params, self);
        self.log("notification $method failed: ", $!.message) if $!;
    }
}

method !reply($id, $result) {
    $.transport.write-message: response($id, $result);
}

method !reply-error($id, Int $code, Str $message) {
    $.transport.write-message: error-response($id, $code, $message);
}

#| Run the read/dispatch loop until EOF or `exit`.
method run() {
    while $.running {
        my $msg = $.transport.read-message;
        last unless $msg.defined;     # EOF
        self.handle($msg);
    }
}

package lsp

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"

// --- Public types ----------------------------------------------------------

DiagnosticSeverity :: enum {
	Error       = 1,
	Warning     = 2,
	Information = 3,
	Hint        = 4,
}

// One LSP-reported issue against a document. Coordinates are 0-based per the
// LSP spec.
Diagnostic :: struct {
	start_line:   i32,
	start_column: i32,
	end_line:     i32,
	end_column:   i32,
	severity:     DiagnosticSeverity,
	message:      string, // owned
	source:       string, // owned ("ols", "rustc", ...)
}

// Tracked per open file so didChange notifications carry monotonically
// increasing version numbers.
DocumentState :: struct {
	version: i32,
	is_open: bool,
}

// What we're waiting on for each outgoing request. Routed when the matching
// response arrives.
PendingRequestKind :: enum {
	Other,
	Initialize,
	Hover,
	Completion,
	SignatureHelp,
}

PendingRequest :: struct {
	kind:      PendingRequestKind,
	file_path: string, // owned; the file the request was issued for (where applicable)
	line:      i32,    // 0-based; for hover/completion staleness check
	column:    i32,
}

// Latest hover popup payload. The editor's render path reads this when
// `is_valid` is true. Reset to empty on each new request.
HoverResult :: struct {
	is_valid:   bool,
	file_path:  string, // owned
	line:       i32,
	column:     i32,
	text:       string, // owned
}

CompletionItem :: struct {
	label:       string, // owned
	detail:      string, // owned
	insert_text: string, // owned
	kind:        int,
}

// Latest completion result for the most recently issued request.
CompletionResult :: struct {
	is_valid:  bool,
	file_path: string, // owned
	line:      i32,
	column:    i32,
	items:     [dynamic]CompletionItem, // owned
}

// One signature returned by `textDocument/signatureHelp`. `parameter_ranges`
// holds byte spans within `label` for each parameter — used by the renderer
// to highlight the active one.
SignatureInformation :: struct {
	label:            string, // owned, full signature text e.g. "proc(x: int, y: int) -> int"
	documentation:    string, // owned, optional markdown blurb
	parameter_ranges: [dynamic]SignatureParameterRange, // owned
}

SignatureParameterRange :: struct {
	start_byte: i32,
	end_byte:   i32,
}

// Latest signatureHelp result. `active_signature` selects which of
// `signatures` to display (for overloaded procs); `active_parameter`
// indexes into that signature's parameters.
SignatureHelpResult :: struct {
	is_valid:         bool,
	file_path:        string, // owned
	line:             i32,
	column:           i32,
	signatures:       [dynamic]SignatureInformation, // owned
	active_signature: int,
	active_parameter: int,
}

// --- Client ---------------------------------------------------------------

Client :: struct {
	process_state: ProcessState, // platform-specific (process_windows.odin / process_other.odin)
	reader_thread: ^thread.Thread,
	is_alive:      bool,

	// Inbound JSON messages from the server. The reader thread writes here
	// under the mutex; `client_poll` drains it on the main thread and
	// dispatches. Each entry is one fully-framed payload (allocator-owned).
	inbound_messages: [dynamic][]u8,
	inbound_mutex:    sync.Mutex,

	// Reader-thread accumulator. Not touched by the main thread.
	read_buffer: [dynamic]u8,

	next_request_id: i64,
	pending_requests: map[i64]PendingRequest,

	is_initialized:                      bool,
	has_sent_initialized_notification:   bool,
	workspace_root_uri:                  string, // owned, file:// URI

	open_documents: map[string]DocumentState,            // file_path (lower) → state
	diagnostics:    map[string][dynamic]Diagnostic,      // file_path (lower) → diagnostics (owned)

	hover:          HoverResult,
	completion:     CompletionResult,
	signature_help: SignatureHelpResult,
}

// --- Lifecycle ------------------------------------------------------------

// Spawn the language server and start the reader. Sends an `initialize`
// request immediately; the editor can begin opening documents straight away
// — the messages queue and get flushed once `is_initialized` flips true.
client_new :: proc(command_tokens: []string, workspace_directory: string = "") -> ^Client {
	if len(command_tokens) == 0 { return nil }
	client := new(Client)
	client.is_alive = true

	if !process_spawn(&client.process_state, command_tokens, workspace_directory) {
		free(client)
		return nil
	}

	client.workspace_root_uri = path_to_file_uri(workspace_directory, context.allocator)
	client.next_request_id    = 1
	client.reader_thread      = thread.create_and_start_with_data(client, reader_thread_proc)

	send_initialize_request(client, workspace_directory)
	return client
}

client_destroy :: proc(client: ^Client) {
	if client == nil { return }

	// Try to be polite — send shutdown + exit. If the pipe is broken these
	// just no-op.
	send_shutdown_request(client)
	send_exit_notification(client)

	client.is_alive = false
	process_close(&client.process_state)

	if client.reader_thread != nil {
		thread.join(client.reader_thread)
		thread.destroy(client.reader_thread)
		client.reader_thread = nil
	}
	process_finalize(&client.process_state)

	// Inbound queue: each payload is its own allocation.
	for payload in client.inbound_messages { delete(payload) }
	if cap(client.inbound_messages) > 0 { delete(client.inbound_messages) }

	if cap(client.read_buffer) > 0 { delete(client.read_buffer) }

	for _, request in client.pending_requests {
		if len(request.file_path) > 0 { delete(request.file_path) }
	}
	delete(client.pending_requests)

	if len(client.workspace_root_uri) > 0 { delete(client.workspace_root_uri) }

	for file_path, doc_state in client.open_documents {
		_ = doc_state
		delete(file_path)
	}
	delete(client.open_documents)

	for file_path, diag_list in client.diagnostics {
		for diagnostic in diag_list {
			if len(diagnostic.message) > 0 { delete(diagnostic.message) }
			if len(diagnostic.source)  > 0 { delete(diagnostic.source) }
		}
		if cap(diag_list) > 0 { delete(diag_list) }
		delete(file_path)
	}
	delete(client.diagnostics)

	hover_result_clear(&client.hover)
	completion_result_clear(&client.completion)
	signature_help_result_clear(&client.signature_help)

	free(client)
}

// Drain the inbound queue and dispatch each message. Must be called from the
// main thread once per frame so server notifications and responses land
// promptly.
client_poll :: proc(client: ^Client) {
	if client == nil { return }
	for {
		payload, ok := pop_inbound_message(client)
		if !ok { break }
		defer delete(payload)
		dispatch_message(client, payload)
	}
}

// --- Document tracking ---------------------------------------------------

// Send didOpen for a freshly-loaded file. Idempotent — sending twice on the
// same path just bumps the version.
client_did_open :: proc(client: ^Client, file_path, language_id, content_text: string) {
	if client == nil || !client.is_initialized { return }
	key := strings.clone(file_path)
	if existing, exists := client.open_documents[key]; exists {
		_ = existing
		delete(key)
		key = file_path_intern_key(client, file_path)
	}
	state := DocumentState{ version = 1, is_open = true }
	client.open_documents[key] = state
	send_did_open_notification(client, file_path, language_id, content_text, state.version)
}

// Send didChange for an existing open document. Caller hands us the *full*
// post-edit text (we use full-sync mode). Bumps the version automatically.
client_did_change :: proc(client: ^Client, file_path, content_text: string) {
	if client == nil || !client.is_initialized { return }
	key := file_path_intern_key(client, file_path)
	state := client.open_documents[key]
	if !state.is_open { return }
	state.version += 1
	client.open_documents[key] = state
	send_did_change_notification(client, file_path, content_text, state.version)
}

client_did_close :: proc(client: ^Client, file_path: string) {
	if client == nil || !client.is_initialized { return }
	key, has_entry := lookup_intern_key(client, file_path); if !has_entry { return }
	send_did_close_notification(client, file_path)
	state := client.open_documents[key]
	state.is_open = false
	client.open_documents[key] = state
}

// --- Diagnostics accessor -------------------------------------------------

client_diagnostics_for :: proc(client: ^Client, file_path: string) -> []Diagnostic {
	if client == nil { return nil }
	key, has_entry := lookup_intern_key(client, file_path); if !has_entry { return nil }
	list, has_list := client.diagnostics[key]; if !has_list { return nil }
	return list[:]
}

// --- Hover / completion requests -----------------------------------------

client_request_hover :: proc(client: ^Client, file_path: string, line, column: i32) {
	if client == nil || !client.is_initialized { return }
	hover_result_clear(&client.hover)
	send_hover_request(client, file_path, line, column)
}

client_request_completion :: proc(client: ^Client, file_path: string, line, column: i32) {
	if client == nil || !client.is_initialized { return }
	completion_result_clear(&client.completion)
	send_completion_request(client, file_path, line, column)
}

client_request_signature_help :: proc(client: ^Client, file_path: string, line, column: i32) {
	if client == nil || !client.is_initialized { return }
	signature_help_result_clear(&client.signature_help)
	send_signature_help_request(client, file_path, line, column)
}

// --- Internal helpers -----------------------------------------------------

@(private)
file_path_intern_key :: proc(client: ^Client, file_path: string) -> string {
	for key in client.open_documents {
		if path_equals(key, file_path) { return key }
	}
	return strings.clone(file_path)
}

@(private)
lookup_intern_key :: proc(client: ^Client, file_path: string) -> (string, bool) {
	for key in client.open_documents {
		if path_equals(key, file_path) { return key, true }
	}
	for key in client.diagnostics {
		if path_equals(key, file_path) { return key, true }
	}
	return "", false
}

@(private)
path_equals :: proc(a, b: string) -> bool {
	if len(a) != len(b) { return false }
	for byte_index in 0..<len(a) {
		left  := a[byte_index]
		right := b[byte_index]
		if left >= 'A' && left <= 'Z' { left  += 32 }
		if right >= 'A' && right <= 'Z' { right += 32 }
		if left == '\\' { left = '/' }
		if right == '\\' { right = '/' }
		if left != right { return false }
	}
	return true
}

// Convert an OS path to a `file:///` URI. Owned by `allocator`. Empty input
// yields an empty string (no URI = root unset).
@(private)
path_to_file_uri :: proc(path: string, allocator := context.allocator) -> string {
	if len(path) == 0 { return "" }
	builder: strings.Builder
	strings.builder_init(&builder, 0, len(path) + 8, allocator)
	strings.write_string(&builder, "file:///")
	// Forward-slash the separators; leave the drive letter alone.
	for byte_index in 0..<len(path) {
		current_byte := path[byte_index]
		if current_byte == '\\' { current_byte = '/' }
		strings.write_byte(&builder, current_byte)
	}
	return strings.to_string(builder)
}

// Strip the `file:///` prefix and turn slashes back into the local platform
// separator (Windows: backslashes). Returns a fresh owned string.
@(private)
file_uri_to_path :: proc(uri: string, allocator := context.allocator) -> string {
	body := uri
	if strings.has_prefix(body, "file:///") { body = body[len("file:///"):] }
	else if strings.has_prefix(body, "file://") { body = body[len("file://"):] }
	builder: strings.Builder
	strings.builder_init(&builder, 0, len(body), allocator)
	strings.write_string(&builder, body)
	return strings.to_string(builder)
}

// Public so the editor can release hover strings as part of its acknowledge
// path; also called internally on each fresh response.
hover_result_clear :: proc(hover: ^HoverResult) {
	if len(hover.file_path) > 0 { delete(hover.file_path) }
	if len(hover.text)      > 0 { delete(hover.text) }
	hover^ = HoverResult{}
}

// Public so the editor's acknowledge path can fully release the strings/
// dynamic-arrays once it has copied what it needs onto the popup. Called
// internally too when a new response replaces the previous one.
completion_result_clear :: proc(completion: ^CompletionResult) {
	if len(completion.file_path) > 0 { delete(completion.file_path) }
	for item in completion.items {
		if len(item.label)       > 0 { delete(item.label) }
		if len(item.detail)      > 0 { delete(item.detail) }
		if len(item.insert_text) > 0 { delete(item.insert_text) }
	}
	if cap(completion.items) > 0 { delete(completion.items) }
	completion^ = CompletionResult{}
	_ = fmt.tprintf // keep core:fmt imported even if no debug printing
}

// Public for the same reason `completion_result_clear` is — the editor's
// signature-popup acknowledge calls this once it's done snapshotting.
signature_help_result_clear :: proc(signature_help: ^SignatureHelpResult) {
	if len(signature_help.file_path) > 0 { delete(signature_help.file_path) }
	for signature in signature_help.signatures {
		if len(signature.label)         > 0 { delete(signature.label) }
		if len(signature.documentation) > 0 { delete(signature.documentation) }
		if cap(signature.parameter_ranges) > 0 { delete(signature.parameter_ranges) }
	}
	if cap(signature_help.signatures) > 0 { delete(signature_help.signatures) }
	signature_help^ = SignatureHelpResult{}
}

@(private)
pop_inbound_message :: proc(client: ^Client) -> (payload: []u8, ok: bool) {
	sync.lock(&client.inbound_mutex)
	defer sync.unlock(&client.inbound_mutex)
	if len(client.inbound_messages) == 0 { return nil, false }
	payload = client.inbound_messages[0]
	ordered_remove(&client.inbound_messages, 0)
	return payload, true
}

@(private)
push_inbound_message :: proc(client: ^Client, payload: []u8) {
	sync.lock(&client.inbound_mutex)
	defer sync.unlock(&client.inbound_mutex)
	append(&client.inbound_messages, payload)
}

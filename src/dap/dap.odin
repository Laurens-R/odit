package dap

import "core:strings"
import "core:sync"
import "core:thread"

// --- Public types ---------------------------------------------------------

// One DAP-reported frame in the current callstack. Coordinates are 1-based as
// they come over the wire (DAP `linesStartAt1=true`).
StackFrame :: struct {
	id:        i64,
	name:      string, // owned
	file_path: string, // owned ("" when the frame has no source)
	line:      i32,    // 1-based
	column:    i32,    // 1-based
}

// One variable scope at the selected stack frame — "Locals", "Globals",
// "Registers", etc. The `variables_reference` is the handle DAP wants for
// the follow-up `variables` request.
Scope :: struct {
	name:                 string, // owned
	variables_reference:  i64,
	variables:            [dynamic]Variable, // owned; populated by a follow-up `variables` response
	expensive:            bool,
	resolved:             bool, // true once we've fetched the variables list
}

Variable :: struct {
	name:                string, // owned
	value:               string, // owned
	type_name:           string, // owned
	variables_reference: i64,    // non-zero when this var is a compound (struct, array, pointer)
}

// One breakpoint snapshot for `setBreakpoints`. Same shape on the way out
// (request) and on the way back (response) — `verified` and `id` are only
// populated on the response.
SourceBreakpoint :: struct {
	line:      i32, // 1-based
	condition: string,
}

VerifiedBreakpoint :: struct {
	id:       i64,
	verified: bool,
	line:     i32, // 1-based
	message:  string, // owned; the adapter's reason for an unverified bp
}

// What kind of stop the program just hit. Populated from the `stopped` event.
StopReason :: enum {
	Unknown,
	Step,
	Breakpoint,
	Exception,
	Pause,
	Entry,
}

// What we asked for; routed when the matching response arrives. Most DAP
// requests are fire-and-forget for the editor (we just want the eventual
// state change), but stackTrace / scopes / variables thread some context
// through the round-trip.
@(private)
PendingRequestKind :: enum {
	Other,
	Initialize,
	Launch,
	Attach,
	SetBreakpoints,
	ConfigurationDone,
	Threads,
	StackTrace,
	Scopes,
	Variables,
	VariableChildren,
	Continue,
	Next,
	StepIn,
	StepOut,
	Pause,
	Terminate,
	Disconnect,
	SetExceptionBreakpoints,
}

@(private)
PendingRequest :: struct {
	kind:                PendingRequestKind,
	thread_id:           i64,    // for stack-trace / step / continue
	scope_index:         int,    // for `.Variables`: which scope to populate
	variables_reference: i64,    // for `.VariableChildren`: which parent to populate under
	file_path:           string, // owned; for setBreakpoints
}

// --- Client ---------------------------------------------------------------

Client :: struct {
	process_state: ProcessState,
	reader_thread: ^thread.Thread,
	is_alive:      bool,

	inbound_messages: [dynamic][]u8,
	inbound_mutex:    sync.Mutex,
	read_buffer:      [dynamic]u8,

	next_request_seq: i64,
	pending_requests: map[i64]PendingRequest,

	// Handshake state.
	is_initialized:                       bool,  // set on `initialize` response
	got_initialized_event:                bool,  // set on `initialized` event
	supports_configuration_done_request:  bool,  // capability from initialize response
	queued_launch_arguments_json:         string, // owned; sent right after the `initialized` event arrives
	queued_launch_request_command:        string, // owned; "launch" or "attach" — paired with the args above

	// Session state.
	is_running:           bool,
	is_stopped:           bool,
	stop_reason:          StopReason,
	current_thread_id:    i64,
	exited:               bool,
	exit_code:            i32,

	// Latest stack trace + scopes + variables for the currently selected
	// frame. Replaced wholesale on each `stopped` event so the editor always
	// looks at fresh data. Owned strings — destroyed by `client_destroy`.
	stack_frames: [dynamic]StackFrame,
	scopes:       [dynamic]Scope,
	selected_frame_index: int,

	// Cache of fetched children of compound variables (struct fields, array
	// elements, …) keyed by the parent's `variablesReference`. The list is
	// inserted empty when a fetch is dispatched and filled in on the
	// matching `.VariableChildren` response — keying on "ref is present"
	// suppresses duplicate fetches without a separate set. Cleared on every
	// stop transition; the adapter invalidates these refs on continue/step.
	variable_children: map[i64][dynamic]Variable,

	// Adapter-reported breakpoint state, keyed by file path (case folded
	// outside this module). Replaced wholesale per `setBreakpoints` response.
	verified_breakpoints: map[string][dynamic]VerifiedBreakpoint,

	// Adapter stdout/stderr text — surfaces from `output` events. Capped to
	// a few KB by the editor so it doesn't grow unbounded.
	output_log: [dynamic]u8,
	output_mutex: sync.Mutex,
}

// --- Lifecycle ------------------------------------------------------------

client_new :: proc(command_tokens: []string, working_directory: string = "") -> ^Client {
	if len(command_tokens) == 0 { return nil }
	client := new(Client)
	client.is_alive = true
	client.next_request_seq = 1

	if !process_spawn(&client.process_state, command_tokens, working_directory) {
		free(client)
		return nil
	}
	client.reader_thread = thread.create_and_start_with_data(client, reader_thread_proc)

	send_initialize_request(client)
	return client
}

client_destroy :: proc(client: ^Client) {
	if client == nil { return }

	// Polite shutdown — best-effort. lldb-dap exits when its stdin closes
	// anyway, but `disconnect` lets it tear down the inferior cleanly.
	send_disconnect_request(client, true)

	client.is_alive = false
	process_close(&client.process_state)
	if client.reader_thread != nil {
		thread.join(client.reader_thread)
		thread.destroy(client.reader_thread)
		client.reader_thread = nil
	}
	process_finalize(&client.process_state)

	for payload in client.inbound_messages { delete(payload) }
	if cap(client.inbound_messages) > 0 { delete(client.inbound_messages) }
	if cap(client.read_buffer)      > 0 { delete(client.read_buffer)      }
	if cap(client.output_log)       > 0 { delete(client.output_log)       }

	for _, request in client.pending_requests {
		if len(request.file_path) > 0 { delete(request.file_path) }
	}
	delete(client.pending_requests)

	if len(client.queued_launch_arguments_json)  > 0 { delete(client.queued_launch_arguments_json)  }
	if len(client.queued_launch_request_command) > 0 { delete(client.queued_launch_request_command) }

	clear_stack_frames(client)
	if cap(client.stack_frames) > 0 { delete(client.stack_frames) }
	clear_scopes(client)
	if cap(client.scopes) > 0 { delete(client.scopes) }
	clear_variable_children(client)
	delete(client.variable_children)

	for file_path, bp_list in client.verified_breakpoints {
		for bp in bp_list { if len(bp.message) > 0 { delete(bp.message) } }
		if cap(bp_list) > 0 { delete(bp_list) }
		delete(file_path)
	}
	delete(client.verified_breakpoints)

	free(client)
}

// Pull inbound messages off the queue and dispatch each one. Called from the
// main loop once per frame.
client_poll :: proc(client: ^Client) {
	if client == nil { return }
	for {
		payload, ok := pop_inbound_message(client)
		if !ok { break }
		defer delete(payload)
		dispatch_message(client, payload)
	}
}

// --- Public requests ------------------------------------------------------

// Launch (or attach to) the inferior. `arguments_json` is a fully-formed
// JSON object string holding adapter-specific fields ("program", "args",
// "cwd", "pid", ...) — the editor builds it from the active debug
// configuration. `request_command` is the DAP wire-level command:
// "launch" for normal start, "attach" for attaching to a running process.
// If the adapter hasn't fired its `initialized` event yet, the request is
// queued and sent once the handshake completes (the protocol requires that
// order).
client_launch :: proc(client: ^Client, arguments_json: string, request_command: string = "launch") {
	if client == nil { return }
	if client.got_initialized_event {
		send_launch_or_attach_request(client, request_command, arguments_json)
	} else {
		if len(client.queued_launch_arguments_json) > 0 { delete(client.queued_launch_arguments_json) }
		if len(client.queued_launch_request_command) > 0 { delete(client.queued_launch_request_command) }
		client.queued_launch_arguments_json = strings.clone(arguments_json)
		client.queued_launch_request_command = strings.clone(request_command)
	}
}

// Set the full breakpoint list for `file_path`. DAP replaces, never merges —
// send all breakpoints for the file in one call.
client_set_breakpoints :: proc(client: ^Client, file_path: string, breakpoints: []SourceBreakpoint) {
	if client == nil || !client.is_initialized { return }
	send_set_breakpoints_request(client, file_path, breakpoints)
}

client_continue   :: proc(client: ^Client) { if client != nil { send_step_request(client, "continue", .Continue) } }
client_step_over  :: proc(client: ^Client) { if client != nil { send_step_request(client, "next",     .Next)     } }
client_step_in    :: proc(client: ^Client) { if client != nil { send_step_request(client, "stepIn",   .StepIn)   } }
client_step_out   :: proc(client: ^Client) { if client != nil { send_step_request(client, "stepOut",  .StepOut)  } }
client_pause      :: proc(client: ^Client) { if client != nil { send_pause_request(client) } }
client_terminate  :: proc(client: ^Client) { if client != nil { send_disconnect_request(client, true) } }

// Fetch the children of a compound variable (variables_reference != 0).
// First call dispatches a `variables` request and inserts a sentinel empty
// list so subsequent calls during the in-flight window are no-ops. The
// children appear in `client_children` once the response arrives.
client_request_children :: proc(client: ^Client, variables_reference: i64) {
	if client == nil || !client.is_initialized { return }
	if variables_reference == 0 { return }
	if _, already := client.variable_children[variables_reference]; already { return }
	// Mark in-flight up front so a double-click doesn't double-fetch.
	empty_list: [dynamic]Variable
	empty_list.allocator = context.allocator
	client.variable_children[variables_reference] = empty_list
	send_variable_children_request(client, variables_reference)
}

// Fetch a scope's variables on demand. Used for `expensive` scopes (Globals,
// Registers) that the auto-fetch path in `ingest_scopes_response` skips.
// No-op if the scope index is out of range or its variables have already
// been resolved.
client_request_scope_variables :: proc(client: ^Client, scope_index: int) {
	if client == nil || !client.is_initialized { return }
	if scope_index < 0 || scope_index >= len(client.scopes) { return }
	scope := &client.scopes[scope_index]
	if scope.resolved { return }
	if scope.variables_reference == 0 { return }
	send_variables_request(client, scope.variables_reference, scope_index)
}

// --- Accessors ------------------------------------------------------------

client_stack_frames :: proc(client: ^Client) -> []StackFrame {
	if client == nil { return nil }
	return client.stack_frames[:]
}

client_scopes :: proc(client: ^Client) -> []Scope {
	if client == nil { return nil }
	return client.scopes[:]
}

// Returns the cached children for a compound variable, plus a flag for
// whether a fetch has been issued at all. `fetched=false` means the editor
// hasn't asked yet; `fetched=true` with an empty slice means the response is
// pending (or the variable genuinely has no children).
client_children :: proc(client: ^Client, variables_reference: i64) -> (children: []Variable, fetched: bool) {
	if client == nil { return nil, false }
	if variables_reference == 0 { return nil, false }
	list, has := client.variable_children[variables_reference]
	if !has { return nil, false }
	return list[:], true
}

client_stack_frames_top_id :: proc(client: ^Client, frame_index: int) -> i64 {
	if client == nil { return 0 }
	if frame_index < 0 || frame_index >= len(client.stack_frames) { return 0 }
	return client.stack_frames[frame_index].id
}

client_verified_breakpoints :: proc(client: ^Client, file_path: string) -> []VerifiedBreakpoint {
	if client == nil { return nil }
	key, has := find_verified_key(client, file_path); if !has { return nil }
	list := client.verified_breakpoints[key]
	return list[:]
}

// Drains the adapter's stdout/stderr `output` events into a buffer for the
// editor to display. Returns the bytes since last drain; ownership transfers
// to the caller, who must `delete()` it.
client_drain_output :: proc(client: ^Client) -> []u8 {
	if client == nil { return nil }
	sync.lock(&client.output_mutex)
	defer sync.unlock(&client.output_mutex)
	if len(client.output_log) == 0 { return nil }
	out := make([]u8, len(client.output_log))
	copy(out, client.output_log[:])
	clear(&client.output_log)
	return out
}

// True when the adapter has accepted at least one stop event — used by the
// editor to decide whether to show the "stopped" UI affordances.
client_is_stopped :: proc(client: ^Client) -> bool {
	if client == nil { return false }
	return client.is_stopped
}

client_is_running :: proc(client: ^Client) -> bool {
	if client == nil { return false }
	return client.is_running && !client.is_stopped && !client.exited
}

client_has_exited :: proc(client: ^Client) -> bool {
	if client == nil { return true }
	return client.exited
}

// --- Internal helpers -----------------------------------------------------

@(private)
clear_stack_frames :: proc(client: ^Client) {
	for frame in client.stack_frames {
		if len(frame.name)      > 0 { delete(frame.name)      }
		if len(frame.file_path) > 0 { delete(frame.file_path) }
	}
	clear(&client.stack_frames)
}

@(private)
clear_scopes :: proc(client: ^Client) {
	for scope in client.scopes {
		if len(scope.name) > 0 { delete(scope.name) }
		clear_variables(scope.variables)
		if cap(scope.variables) > 0 { delete(scope.variables) }
	}
	clear(&client.scopes)
}

@(private)
clear_variables :: proc(variables: [dynamic]Variable) {
	for variable in variables {
		if len(variable.name)      > 0 { delete(variable.name)      }
		if len(variable.value)     > 0 { delete(variable.value)     }
		if len(variable.type_name) > 0 { delete(variable.type_name) }
	}
}

// Free every cached compound-variable child list. Called on `client_destroy`
// and on each new stop, since the adapter invalidates variables_references
// on continue/step.
@(private)
clear_variable_children :: proc(client: ^Client) {
	for _, child_list in client.variable_children {
		clear_variables(child_list)
		if cap(child_list) > 0 { delete(child_list) }
	}
	clear(&client.variable_children)
}

@(private)
find_verified_key :: proc(client: ^Client, file_path: string) -> (string, bool) {
	for key in client.verified_breakpoints {
		if path_equals_case_insensitive(key, file_path) { return key, true }
	}
	return "", false
}

@(private)
path_equals_case_insensitive :: proc(a, b: string) -> bool {
	if len(a) != len(b) { return false }
	for byte_index in 0..<len(a) {
		left  := a[byte_index]
		right := b[byte_index]
		if left  >= 'A' && left  <= 'Z' { left  += 32 }
		if right >= 'A' && right <= 'Z' { right += 32 }
		if left  == '\\' { left  = '/' }
		if right == '\\' { right = '/' }
		if left != right { return false }
	}
	return true
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

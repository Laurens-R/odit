package dap

import "core:fmt"
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

	// Editor-side breakpoint cache. The editor flushes its current
	// per-file lists right after spawn (when the adapter hasn't yet sent
	// its `initialized` event), so we stash them here and replay during
	// `finalize_configuration` — otherwise breakpoints get silently
	// dropped. Owned: each key is a cloned path; each value owns its
	// SourceBreakpoint entries (the `condition` field in particular).
	cached_breakpoints: map[string][dynamic]SourceBreakpoint,

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

	for file_path, bp_list in client.cached_breakpoints {
		for bp in bp_list { if len(bp.condition) > 0 { delete(bp.condition) } }
		if cap(bp_list) > 0 { delete(bp_list) }
		delete(file_path)
	}
	delete(client.cached_breakpoints)

	free(client)
}

// Pull inbound messages off the queue and dispatch each one. Called from the
// main loop once per frame. Also drains stderr and watches for unexpected
// process exit — without those, an adapter that crashes before sending its
// `initialize` response would leave the editor waiting forever with no
// diagnostic in the output log.
client_poll :: proc(client: ^Client) {
	if client == nil { return }
	for {
		payload, ok := pop_inbound_message(client)
		if !ok { break }
		defer delete(payload)
		dispatch_message(client, payload)
	}

	drain_stderr(client)
	check_unexpected_exit(client)
}

@(private)
drain_stderr :: proc(client: ^Client) {
	scratch: [4096]u8
	for {
		bytes_read, ok := process_read_stderr(&client.process_state, scratch[:])
		if !ok || bytes_read == 0 { return }
		// Tag the chunk so the user can tell at a glance which stream it
		// came from. lldb-dap normally only writes JSON to stdout, so any
		// stderr bytes are almost always diagnostic output worth flagging.
		append_output(client, "[stderr] ")
		append_output(client, string(scratch[:bytes_read]))
		if scratch[bytes_read - 1] != '\n' { append_output(client, "\n") }
	}
}

@(private)
check_unexpected_exit :: proc(client: ^Client) {
	if client.exited { return }
	exited, exit_code := process_check_exit(&client.process_state)
	if !exited { return }
	client.exited     = true
	client.exit_code  = exit_code
	client.is_running = false
	client.is_stopped = false
	// Surface a synthetic notice so the editor's output pane shows the
	// failure instead of silently going idle. The `terminated`/`exited`
	// event handlers don't run when the adapter dies before sending them.
	append_output(client, format_unexpected_exit_notice(exit_code))
}

// Translate a Win32 exit code into a human-friendly explanation. The handful
// of NT status values listed here are the ones we've actually seen people hit
// with lldb-dap on Windows; everything else falls through to a generic note.
@(private="file")
format_unexpected_exit_notice :: proc(exit_code: i32) -> string {
	switch u32(exit_code) {
	case 0xC0000135:
		return fmt.tprintf(
			"[dap] adapter failed to start (exit 0x%08X: STATUS_DLL_NOT_FOUND)\n" +
			"      lldb-dap.exe was found, but Windows couldn't load one of its DLLs (typically liblldb.dll or a VC++ runtime).\n" +
			"      Fix: download the full LLVM release from https://github.com/llvm/llvm-project/releases (the LLVM-*-win64.exe installer), make sure its bin/ directory is on PATH, and confirm liblldb.dll sits next to lldb-dap.exe.\n" +
			"      Workaround: point settings.json directly at a known-good binary — `\"dap\": { \"lldb\": { \"command\": [\"C:/Program Files/LLVM/bin/lldb-dap.exe\"] } }`.\n",
			u32(exit_code))
	case 0xC0000139:
		return fmt.tprintf(
			"[dap] adapter failed to start (exit 0x%08X: STATUS_ENTRYPOINT_NOT_FOUND)\n" +
			"      A required DLL was found but is the wrong version (mismatched LLVM/clang install). Reinstall LLVM from a single release.\n",
			u32(exit_code))
	case 0xC0000142:
		return fmt.tprintf(
			"[dap] adapter failed to start (exit 0x%08X: STATUS_DLL_INIT_FAILED)\n" +
			"      One of the adapter's DLLs failed during initialization — usually a Visual C++ Redistributable mismatch.\n",
			u32(exit_code))
	case 0xC0000005:
		return fmt.tprintf(
			"[dap] adapter crashed (exit 0x%08X: ACCESS_VIOLATION) — likely a bug in lldb-dap itself or an incompatibility with the target binary.\n",
			u32(exit_code))
	case 0:
		return "[dap] adapter exited cleanly without producing any DAP traffic — check that the command in settings.json actually points at lldb-dap (and not, say, lldb itself).\n"
	}
	return fmt.tprintf("[dap] adapter process exited unexpectedly (code %d / 0x%08X) — check the command in settings.json (dap.<adapter>.command).\n", exit_code, u32(exit_code))
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
// send all breakpoints for the file in one call. Always cached (so we can
// replay during `finalize_configuration` if the editor flushed before the
// adapter's initialized event arrived). If we're already past that event,
// the request is also dispatched right away so the adapter sees in-session
// edits immediately.
client_set_breakpoints :: proc(client: ^Client, file_path: string, breakpoints: []SourceBreakpoint) {
	if client == nil || len(file_path) == 0 { return }
	cache_breakpoints(client, file_path, breakpoints)
	if client.got_initialized_event {
		send_set_breakpoints_request(client, file_path, breakpoints)
	}
}

@(private)
cache_breakpoints :: proc(client: ^Client, file_path: string, breakpoints: []SourceBreakpoint) {
	// Drop the previous cache entry for this path (case-insensitive lookup
	// matches the verified_breakpoints map's convention) before swapping in
	// the new list. Owned strings — caller's `condition` slices are cloned.
	for existing_key in client.cached_breakpoints {
		if path_equals_case_insensitive(existing_key, file_path) {
			previous_list := client.cached_breakpoints[existing_key]
			for entry in previous_list { if len(entry.condition) > 0 { delete(entry.condition) } }
			if cap(previous_list) > 0 { delete(previous_list) }
			delete_key(&client.cached_breakpoints, existing_key)
			delete(existing_key)
			break
		}
	}
	if len(breakpoints) == 0 { return }

	new_list: [dynamic]SourceBreakpoint
	new_list.allocator = context.allocator
	for bp in breakpoints {
		condition_clone := len(bp.condition) > 0 ? strings.clone(bp.condition) : ""
		append(&new_list, SourceBreakpoint{ line = bp.line, condition = condition_clone })
	}
	client.cached_breakpoints[strings.clone(file_path)] = new_list
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

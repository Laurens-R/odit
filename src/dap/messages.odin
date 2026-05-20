package dap

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// --- Initialize -----------------------------------------------------------

@(private)
send_initialize_request :: proc(client: ^Client) {
	builder: strings.Builder
	strings.builder_init(&builder, 0, 256, context.temp_allocator)
	strings.write_string(&builder, `{`)
	strings.write_string(&builder, `"clientID":"odit","clientName":"Odit",`)
	strings.write_string(&builder, `"adapterID":"lldb",`)
	strings.write_string(&builder, `"linesStartAt1":true,"columnsStartAt1":true,`)
	strings.write_string(&builder, `"pathFormat":"path",`)
	strings.write_string(&builder, `"supportsVariableType":true,`)
	strings.write_string(&builder, `"supportsVariablePaging":false,`)
	strings.write_string(&builder, `"supportsRunInTerminalRequest":false,`)
	strings.write_string(&builder, `"locale":"en-US"`)
	strings.write_string(&builder, `}`)
	send_request(client, "initialize", strings.to_string(builder), PendingRequest{ kind = .Initialize })
}

@(private)
ingest_initialize_response :: proc(client: ^Client, body: json.Value) {
	client.is_initialized = true
	body_object, is_object := body.(json.Object); if !is_object { return }
	if v, ok := body_object["supportsConfigurationDoneRequest"]; ok {
		client.supports_configuration_done_request = json_to_bool(v)
	}
}

// --- Launch / attach ------------------------------------------------------

@(private)
send_launch_or_attach_request :: proc(client: ^Client, request_command: string, arguments_json: string) {
	// "launch" and "attach" are wire-level twins — same JSON shape on the
	// way out, same response handler. Routing by request_command lets the
	// editor pick which one the active configuration wants.
	if request_command == "attach" {
		send_request(client, "attach", arguments_json, PendingRequest{ kind = .Attach })
	} else {
		send_request(client, "launch", arguments_json, PendingRequest{ kind = .Launch })
	}
}

@(private)
send_configuration_done_request :: proc(client: ^Client) {
	send_request(client, "configurationDone", "{}", PendingRequest{ kind = .ConfigurationDone })
}

@(private)
send_set_exception_breakpoints_request :: proc(client: ^Client) {
	// Empty filter list means "no exception breakpoints". Sending the
	// request is required by some adapters during the initial handshake;
	// lldb-dap tolerates it being skipped, but lldb 18+ logs a warning
	// without it.
	send_request(client, "setExceptionBreakpoints", `{"filters":[]}`, PendingRequest{ kind = .SetExceptionBreakpoints })
}

// Public helper used by the editor right after the `initialized` event fires.
// Sends the breakpoint flush + exception filter + configurationDone in the
// canonical order, and then the queued launch (if any).
@(private)
finalize_configuration :: proc(client: ^Client) {
	send_set_exception_breakpoints_request(client)
	if client.supports_configuration_done_request {
		send_configuration_done_request(client)
	}
	if len(client.queued_launch_arguments_json) > 0 {
		args := client.queued_launch_arguments_json
		client.queued_launch_arguments_json = ""
		defer delete(args)
		request_command := client.queued_launch_request_command
		client.queued_launch_request_command = ""
		defer if len(request_command) > 0 { delete(request_command) }
		send_launch_or_attach_request(client, request_command, args)
	}
}

// --- Breakpoints ----------------------------------------------------------

@(private)
send_set_breakpoints_request :: proc(client: ^Client, file_path: string, breakpoints: []SourceBreakpoint) {
	builder: strings.Builder
	strings.builder_init(&builder, 0, 256, context.temp_allocator)
	strings.write_string(&builder, `{"source":{"path":`)
	write_json_string(&builder, file_path)
	strings.write_string(&builder, `},"breakpoints":[`)
	for bp, bp_index in breakpoints {
		if bp_index > 0 { strings.write_byte(&builder, ',') }
		strings.write_string(&builder, `{"line":`)
		fmt.sbprintf(&builder, "%d", bp.line)
		if len(bp.condition) > 0 {
			strings.write_string(&builder, `,"condition":`)
			write_json_string(&builder, bp.condition)
		}
		strings.write_byte(&builder, '}')
	}
	strings.write_string(&builder, `],"sourceModified":false}`)
	send_request(client, "setBreakpoints", strings.to_string(builder), PendingRequest{
		kind      = .SetBreakpoints,
		file_path = strings.clone(file_path),
	})
}

@(private)
ingest_set_breakpoints_response :: proc(client: ^Client, file_path: string, body: json.Value) {
	body_object, is_object := body.(json.Object); if !is_object { return }
	bp_array_value, has_bps := body_object["breakpoints"]; if !has_bps { return }
	bp_array, is_array := bp_array_value.(json.Array); if !is_array { return }

	// Drop any previous entries for this file.
	for existing_key, existing_list in client.verified_breakpoints {
		if path_equals_case_insensitive(existing_key, file_path) {
			for bp in existing_list { if len(bp.message) > 0 { delete(bp.message) } }
			if cap(existing_list) > 0 { delete(existing_list) }
			delete_key(&client.verified_breakpoints, existing_key)
			delete(existing_key)
			break
		}
	}

	new_list: [dynamic]VerifiedBreakpoint
	new_list.allocator = context.allocator
	for entry in bp_array {
		entry_object, ok := entry.(json.Object); if !ok { continue }
		verified := false
		if v, has := entry_object["verified"]; has { verified = json_to_bool(v) }
		line := i32(0)
		if v, has := entry_object["line"];     has { line = json_to_i32(v) }
		id := i64(0)
		if v, has := entry_object["id"];       has { id = json_to_i64(v) }
		message := ""
		if v, has := entry_object["message"];  has { message = strings.clone(json_to_string(v)) }
		append(&new_list, VerifiedBreakpoint{
			id       = id,
			verified = verified,
			line     = line,
			message  = message,
		})
	}
	client.verified_breakpoints[strings.clone(file_path)] = new_list
}

// --- Stack / scopes / variables -------------------------------------------

@(private)
send_stack_trace_request :: proc(client: ^Client, thread_id: i64) {
	args := fmt.tprintf(`{{"threadId":%d,"startFrame":0,"levels":64}}`, thread_id)
	send_request(client, "stackTrace", args, PendingRequest{ kind = .StackTrace, thread_id = thread_id })
}

@(private)
ingest_stack_trace_response :: proc(client: ^Client, body: json.Value) {
	body_object, is_object := body.(json.Object); if !is_object { return }
	frames_value, has := body_object["stackFrames"]; if !has { return }
	frames_array, is_array := frames_value.(json.Array); if !is_array { return }

	clear_stack_frames(client)
	for entry in frames_array {
		obj, ok := entry.(json.Object); if !ok { continue }
		id := json_to_i64(obj["id"])
		name := strings.clone(json_to_string(obj["name"]))
		line := json_to_i32(obj["line"])
		column := json_to_i32(obj["column"])
		file_path := ""
		if source_value, has_source := obj["source"]; has_source {
			if source_obj, source_is_object := source_value.(json.Object); source_is_object {
				file_path = strings.clone(json_to_string(source_obj["path"]))
			}
		}
		append(&client.stack_frames, StackFrame{
			id        = id,
			name      = name,
			file_path = file_path,
			line      = line,
			column    = column,
		})
	}
	client.selected_frame_index = 0
	// Top frame's scopes are what the user almost always wants to see first.
	if len(client.stack_frames) > 0 {
		send_scopes_request(client, client.stack_frames[0].id)
	}
}

@(private)
send_scopes_request :: proc(client: ^Client, frame_id: i64) {
	args := fmt.tprintf(`{{"frameId":%d}}`, frame_id)
	send_request(client, "scopes", args, PendingRequest{ kind = .Scopes })
}

@(private)
ingest_scopes_response :: proc(client: ^Client, body: json.Value, thread_id: i64) {
	_ = thread_id
	body_object, is_object := body.(json.Object); if !is_object { return }
	scopes_value, has := body_object["scopes"]; if !has { return }
	scopes_array, is_array := scopes_value.(json.Array); if !is_array { return }

	clear_scopes(client)
	for entry, scope_index in scopes_array {
		obj, ok := entry.(json.Object); if !ok { continue }
		name := strings.clone(json_to_string(obj["name"]))
		variables_reference := json_to_i64(obj["variablesReference"])
		expensive := json_to_bool(obj["expensive"])
		new_scope := Scope{
			name                = name,
			variables_reference = variables_reference,
			expensive           = expensive,
			resolved            = false,
		}
		new_scope.variables.allocator = context.allocator
		append(&client.scopes, new_scope)

		// Auto-fetch the cheap scopes — Locals, Arguments, etc. The user
		// will usually want them right away. `expensive` scopes (Globals,
		// Registers in some adapters) wait until they're expanded.
		if !expensive && variables_reference != 0 {
			send_variables_request(client, variables_reference, scope_index)
		}
	}
}

@(private)
send_variables_request :: proc(client: ^Client, variables_reference: i64, scope_index: int) {
	args := fmt.tprintf(`{{"variablesReference":%d}}`, variables_reference)
	send_request(client, "variables", args, PendingRequest{
		kind        = .Variables,
		scope_index = scope_index,
	})
}

@(private)
send_variable_children_request :: proc(client: ^Client, variables_reference: i64) {
	args := fmt.tprintf(`{{"variablesReference":%d}}`, variables_reference)
	send_request(client, "variables", args, PendingRequest{
		kind                = .VariableChildren,
		variables_reference = variables_reference,
	})
}

@(private)
ingest_variable_children_response :: proc(client: ^Client, variables_reference: i64, body: json.Value) {
	body_object, is_object := body.(json.Object); if !is_object { return }
	variables_value, has := body_object["variables"]; if !has { return }
	variables_array, is_array := variables_value.(json.Array); if !is_array { return }

	// `client_request_children` always inserts a sentinel empty list when it
	// dispatches the request, so the map entry exists. Refill in place so the
	// list pointer stays stable and we don't churn allocations.
	child_list, has_entry := client.variable_children[variables_reference]
	if !has_entry {
		child_list.allocator = context.allocator
	}
	clear_variables(child_list)
	clear(&child_list)
	for entry in variables_array {
		obj, ok := entry.(json.Object); if !ok { continue }
		append(&child_list, Variable{
			name                = strings.clone(json_to_string(obj["name"])),
			value               = strings.clone(json_to_string(obj["value"])),
			type_name           = strings.clone(json_to_string(obj["type"])),
			variables_reference = json_to_i64(obj["variablesReference"]),
		})
	}
	client.variable_children[variables_reference] = child_list
}

@(private)
ingest_variables_response :: proc(client: ^Client, body: json.Value, scope_index: int) {
	body_object, is_object := body.(json.Object); if !is_object { return }
	variables_value, has := body_object["variables"]; if !has { return }
	variables_array, is_array := variables_value.(json.Array); if !is_array { return }

	if scope_index < 0 || scope_index >= len(client.scopes) { return }
	scope := &client.scopes[scope_index]

	// Replace the variable list with the freshly returned one.
	clear_variables(scope.variables)
	clear(&scope.variables)

	for entry in variables_array {
		obj, ok := entry.(json.Object); if !ok { continue }
		append(&scope.variables, Variable{
			name                = strings.clone(json_to_string(obj["name"])),
			value               = strings.clone(json_to_string(obj["value"])),
			type_name           = strings.clone(json_to_string(obj["type"])),
			variables_reference = json_to_i64(obj["variablesReference"]),
		})
	}
	scope.resolved = true
}

// --- Step / continue / pause ----------------------------------------------

@(private)
send_step_request :: proc(client: ^Client, command: string, kind: PendingRequestKind) {
	if client.current_thread_id == 0 { return }
	args := fmt.tprintf(`{{"threadId":%d}}`, client.current_thread_id)
	send_request(client, command, args, PendingRequest{ kind = kind, thread_id = client.current_thread_id })
}

@(private)
send_pause_request :: proc(client: ^Client) {
	if client.current_thread_id == 0 { return }
	args := fmt.tprintf(`{{"threadId":%d}}`, client.current_thread_id)
	send_request(client, "pause", args, PendingRequest{ kind = .Pause })
}

@(private)
send_disconnect_request :: proc(client: ^Client, terminate_debuggee: bool) {
	if !client.is_initialized && !client.is_running {
		// Nothing to disconnect from yet.
		return
	}
	terminate_value := terminate_debuggee ? "true" : "false"
	args := fmt.tprintf(`{{"terminateDebuggee":%s}}`, terminate_value)
	send_request(client, "disconnect", args, PendingRequest{ kind = .Disconnect })
}

// --- Events ---------------------------------------------------------------

@(private)
ingest_stopped_event :: proc(client: ^Client, body: json.Value) {
	body_object, is_object := body.(json.Object); if !is_object { return }
	client.is_stopped = true
	if v, ok := body_object["threadId"]; ok { client.current_thread_id = json_to_i64(v) }

	// Every variables_reference from the previous stop is now stale — drop
	// the cached children so the next expand round-trips fresh.
	clear_variable_children(client)

	reason_string := json_to_string(body_object["reason"])
	switch reason_string {
	case "step":                client.stop_reason = .Step
	case "breakpoint":          client.stop_reason = .Breakpoint
	case "exception":           client.stop_reason = .Exception
	case "pause":               client.stop_reason = .Pause
	case "entry":               client.stop_reason = .Entry
	case:                       client.stop_reason = .Unknown
	}

	// Immediately request the stack frames so the panel can paint them on
	// the next poll.
	if client.current_thread_id != 0 {
		send_stack_trace_request(client, client.current_thread_id)
	}
}

@(private)
ingest_continued_event :: proc(client: ^Client, body: json.Value) {
	_ = body
	client.is_stopped = false
}

@(private)
ingest_exited_event :: proc(client: ^Client, body: json.Value) {
	body_object, is_object := body.(json.Object); if !is_object { return }
	if v, ok := body_object["exitCode"]; ok { client.exit_code = json_to_i32(v) }
	client.exited = true
	client.is_running = false
}

@(private)
ingest_output_event :: proc(client: ^Client, body: json.Value) {
	body_object, is_object := body.(json.Object); if !is_object { return }
	output_text := json_to_string(body_object["output"])
	if len(output_text) == 0 { return }
	append_output(client, output_text)
}

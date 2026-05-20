package dap

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"

// --- Reader thread --------------------------------------------------------
//
// DAP frames look exactly like LSP frames — `Content-Length: N\r\n\r\n<N bytes>`.
// We accumulate bytes off the adapter's stdout and slice frames off as soon
// as each is fully present.

@(private)
reader_thread_proc :: proc(thread_argument: rawptr) {
	client := cast(^Client)thread_argument
	scratch: [4096]u8

	for client.is_alive {
		bytes_read, ok := process_read(&client.process_state, scratch[:])
		if !ok { break }
		if bytes_read == 0 { continue }
		for byte_index in 0..<bytes_read {
			append(&client.read_buffer, scratch[byte_index])
		}
		for try_extract_frame(client) { /* loop */ }
	}
}

@(private="file")
try_extract_frame :: proc(client: ^Client) -> bool {
	buffer_view := client.read_buffer[:]
	header_end := find_double_crlf(buffer_view)
	if header_end < 0 { return false }

	content_length := parse_content_length(buffer_view[:header_end])
	if content_length < 0 { return false }

	payload_start := header_end + 4
	total_required := payload_start + content_length
	if len(buffer_view) < total_required { return false }

	payload := make([]u8, content_length)
	copy(payload, buffer_view[payload_start : payload_start + content_length])
	push_inbound_message(client, payload)

	remaining := len(buffer_view) - total_required
	if remaining > 0 {
		copy(client.read_buffer[:remaining], buffer_view[total_required:])
	}
	resize(&client.read_buffer, remaining)
	return true
}

@(private="file")
find_double_crlf :: proc(buffer: []u8) -> int {
	if len(buffer) < 4 { return -1 }
	for byte_index in 0..=len(buffer) - 4 {
		if buffer[byte_index]   == '\r' && buffer[byte_index+1] == '\n' &&
		   buffer[byte_index+2] == '\r' && buffer[byte_index+3] == '\n' {
			return byte_index
		}
	}
	return -1
}

@(private="file")
parse_content_length :: proc(header_bytes: []u8) -> int {
	header_text := string(header_bytes)
	prefix := "Content-Length:"
	for line in strings.split_lines_iterator(&header_text) {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, prefix) { continue }
		value_string := strings.trim_space(trimmed[len(prefix):])
		if parsed, ok := strconv.parse_int(value_string); ok && parsed >= 0 {
			return parsed
		}
		return -1
	}
	return -1
}

// --- Outbound -------------------------------------------------------------

@(private)
allocate_seq :: proc(client: ^Client) -> i64 {
	seq := client.next_request_seq
	client.next_request_seq += 1
	return seq
}

@(private)
send_raw_payload :: proc(client: ^Client, json_payload: string) {
	if client == nil || len(json_payload) == 0 { return }
	header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(json_payload))
	process_write(&client.process_state, transmute([]u8)header)
	process_write(&client.process_state, transmute([]u8)json_payload)
}

// Build a DAP request frame:
//   {"seq":N,"type":"request","command":"...","arguments":{...}}
//
// `arguments_json` may be empty — we write `{}` in that case (DAP rejects
// missing argument objects for several commands).
@(private)
send_request :: proc(client: ^Client, command: string, arguments_json: string, pending: PendingRequest) -> i64 {
	seq := allocate_seq(client)
	client.pending_requests[seq] = pending

	builder: strings.Builder
	strings.builder_init(&builder, 0, len(arguments_json) + 80, context.temp_allocator)
	strings.write_string(&builder, `{"seq":`)
	fmt.sbprintf(&builder, "%d", seq)
	strings.write_string(&builder, `,"type":"request","command":`)
	write_json_string(&builder, command)
	strings.write_string(&builder, `,"arguments":`)
	if len(arguments_json) == 0 { strings.write_string(&builder, "{}") } else { strings.write_string(&builder, arguments_json) }
	strings.write_byte(&builder, '}')

	send_raw_payload(client, strings.to_string(builder))
	return seq
}

// --- JSON encoding helpers ------------------------------------------------

@(private)
write_json_string :: proc(builder: ^strings.Builder, text: string) {
	strings.write_byte(builder, '"')
	for byte_index in 0..<len(text) {
		current_byte := text[byte_index]
		switch current_byte {
		case '"':  strings.write_string(builder, `\"`)
		case '\\': strings.write_string(builder, `\\`)
		case '\n': strings.write_string(builder, `\n`)
		case '\r': strings.write_string(builder, `\r`)
		case '\t': strings.write_string(builder, `\t`)
		case '\b': strings.write_string(builder, `\b`)
		case '\f': strings.write_string(builder, `\f`)
		case:
			if current_byte < 0x20 {
				strings.write_string(builder, fmt.tprintf("\\u%04x", current_byte))
			} else {
				strings.write_byte(builder, current_byte)
			}
		}
	}
	strings.write_byte(builder, '"')
}

// --- Inbound dispatch -----------------------------------------------------

@(private)
dispatch_message :: proc(client: ^Client, payload: []u8) {
	parsed_value, parse_error := json.parse(payload, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if parse_error != .None { return }
	root, is_object := parsed_value.(json.Object); if !is_object { return }

	type_value, has_type := root["type"]; if !has_type { return }
	type_string, type_is_string := type_value.(string); if !type_is_string { return }

	switch type_string {
	case "response":  handle_response(client, root)
	case "event":     handle_event(client, root)
	case "request":   handle_reverse_request(client, root)
	}
}

@(private="file")
handle_response :: proc(client: ^Client, root: json.Object) {
	request_seq_value, has_seq := root["request_seq"]; if !has_seq { return }
	request_seq := json_to_i64(request_seq_value)
	pending, has_pending := client.pending_requests[request_seq]; if !has_pending { return }
	delete_key(&client.pending_requests, request_seq)
	defer if len(pending.file_path) > 0 { delete(pending.file_path) }

	success_value, _ := root["success"]
	success_bool, _ := success_value.(bool)

	body_value, _ := root["body"]

	if !success_bool {
		handle_response_failure(client, pending, root)
		return
	}

	handle_response_success(client, pending, body_value)
}

@(private="file")
handle_response_success :: proc(client: ^Client, pending: PendingRequest, body: json.Value) {
	switch pending.kind {
	case .Initialize:
		ingest_initialize_response(client, body)
	case .Launch, .Attach:
		client.is_running = true
	case .SetBreakpoints:
		ingest_set_breakpoints_response(client, pending.file_path, body)
	case .ConfigurationDone:
		// No body; just an acknowledgment.
	case .Threads:
		// We don't track threads explicitly — we use `current_thread_id`
		// from the `stopped` event. Response is a no-op.
	case .StackTrace:
		ingest_stack_trace_response(client, body)
	case .Scopes:
		ingest_scopes_response(client, body, pending.thread_id)
	case .Variables:
		ingest_variables_response(client, body, pending.scope_index)
	case .VariableChildren:
		ingest_variable_children_response(client, pending.variables_reference, body)
	case .Continue, .Next, .StepIn, .StepOut:
		client.is_stopped = false
	case .Pause:
		// Pause is asynchronous — the stop event will arrive separately.
	case .Terminate, .Disconnect:
		client.is_running = false
	case .SetExceptionBreakpoints:
		// Acknowledged; nothing to do.
	case .Other:
	}
}

@(private="file")
handle_response_failure :: proc(client: ^Client, pending: PendingRequest, root: json.Object) {
	// Record adapter errors to the output log so the user sees them in the
	// debug-panel console rather than silently dropping them.
	if message_value, ok := root["message"]; ok {
		if message_string, is_string := message_value.(string); is_string {
			append_output(client, "error: ")
			append_output(client, message_string)
			append_output(client, "\n")
		}
	}
	switch pending.kind {
	case .Launch, .Attach:
		client.is_running = false
		client.exited     = true
	case .Initialize:
		client.is_initialized = false
	case .Other, .SetBreakpoints, .ConfigurationDone, .Threads, .StackTrace,
	     .Scopes, .Variables, .VariableChildren, .Continue, .Next, .StepIn,
	     .StepOut, .Pause, .Terminate, .Disconnect, .SetExceptionBreakpoints:
	}
}

@(private="file")
handle_event :: proc(client: ^Client, root: json.Object) {
	event_value, has_event := root["event"]; if !has_event { return }
	event_string, _ := event_value.(string)
	body_value, _ := root["body"]

	switch event_string {
	case "initialized":
		client.got_initialized_event = true
		// Canonical DAP order: client sends setBreakpoints, then
		// setExceptionBreakpoints + configurationDone, then launch. The
		// editor's already queued setBreakpoints calls and a launch payload
		// by this point — flush them now so the adapter sees them in spec
		// order.
		finalize_configuration(client)
	case "stopped":
		ingest_stopped_event(client, body_value)
	case "continued":
		ingest_continued_event(client, body_value)
	case "exited":
		ingest_exited_event(client, body_value)
	case "terminated":
		client.exited     = true
		client.is_running = false
		client.is_stopped = false
	case "output":
		ingest_output_event(client, body_value)
	case "thread":
		// We don't track threads beyond `current_thread_id`. Ignore.
	case "breakpoint":
		// Adapter-side breakpoint state changed (verified, moved, etc.).
		// We refresh state on the next setBreakpoints round-trip; ignore here.
	case "module", "loadedSource", "process", "capabilities":
		// Informational only.
	}
}

@(private="file")
handle_reverse_request :: proc(client: ^Client, root: json.Object) {
	// lldb-dap occasionally fires reverse requests (`runInTerminal`). We
	// refuse them politely so it doesn't stall waiting for a response — we
	// don't have a runInTerminal capability and never advertised one.
	seq_value, has_seq := root["seq"]; if !has_seq { return }
	command_value, _ := root["command"]
	command_string, _ := command_value.(string)

	seq := json_to_i64(seq_value)
	builder: strings.Builder
	strings.builder_init(&builder, 0, 96, context.temp_allocator)
	strings.write_string(&builder, `{"seq":`)
	fmt.sbprintf(&builder, "%d", allocate_seq(client))
	strings.write_string(&builder, `,"type":"response","request_seq":`)
	fmt.sbprintf(&builder, "%d", seq)
	strings.write_string(&builder, `,"success":false,"command":`)
	write_json_string(&builder, command_string)
	strings.write_string(&builder, `,"message":"unsupported"}`)
	send_raw_payload(client, strings.to_string(builder))
}

// --- Output buffering -----------------------------------------------------

@(private)
append_output :: proc(client: ^Client, text: string) {
	if len(text) == 0 { return }
	sync.lock(&client.output_mutex)
	defer sync.unlock(&client.output_mutex)
	for byte_index in 0..<len(text) {
		append(&client.output_log, text[byte_index])
	}
	// Cap the buffer so a chatty inferior can't grow it unboundedly.
	max_log_bytes :: 64 * 1024
	if len(client.output_log) > max_log_bytes {
		excess := len(client.output_log) - max_log_bytes
		copy(client.output_log[:], client.output_log[excess:])
		resize(&client.output_log, max_log_bytes)
	}
}

// --- json helpers ---------------------------------------------------------

@(private)
json_to_i64 :: proc(value: json.Value) -> i64 {
	#partial switch v in value {
	case i64: return v
	case f64: return i64(v)
	}
	return 0
}

@(private)
json_to_i32 :: proc(value: json.Value) -> i32 {
	return i32(json_to_i64(value))
}

@(private)
json_to_string :: proc(value: json.Value) -> string {
	if s, ok := value.(string); ok { return s }
	return ""
}

@(private)
json_to_bool :: proc(value: json.Value) -> bool {
	if b, ok := value.(bool); ok { return b }
	return false
}

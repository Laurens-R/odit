package lsp

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"

// --- Reader thread ---------------------------------------------------------
//
// Runs for the lifetime of the client. Pulls bytes off the server's stdout,
// accumulates them in `client.read_buffer`, and as soon as one full
// `Content-Length: N\r\n\r\n<N bytes>` frame is present, slices out the
// payload and hands it to the inbound queue. The main thread parses each
// payload in `dispatch_message`.

@(private)
reader_thread_proc :: proc(thread_argument: rawptr) {
	client := cast(^Client)thread_argument
	scratch: [4096]u8

	for client.is_alive {
		bytes_read, read_succeeded := process_read(&client.process_state, scratch[:])
		if !read_succeeded { break }
		if bytes_read == 0 { continue }
		for byte_index in 0..<bytes_read {
			append(&client.read_buffer, scratch[byte_index])
		}
		// Try to slice off as many complete frames as the accumulator now holds.
		for try_extract_frame(client) { /* loop */ }
	}
}

// Look for the next `Content-Length: N\r\n\r\n` header in the accumulator;
// if the full payload is also present, hand it off and shrink the buffer.
// Returns true when a frame was extracted (caller loops to try the next).
@(private="file")
try_extract_frame :: proc(client: ^Client) -> bool {
	buffer_view := client.read_buffer[:]
	header_end_index := find_double_crlf(buffer_view)
	if header_end_index < 0 { return false }

	content_length_value := parse_content_length(buffer_view[:header_end_index])
	if content_length_value < 0 { return false }

	payload_start := header_end_index + 4 // length of \r\n\r\n
	total_required := payload_start + content_length_value
	if len(buffer_view) < total_required { return false }

	payload_copy := make([]u8, content_length_value)
	copy(payload_copy, buffer_view[payload_start : payload_start + content_length_value])

	push_inbound_message(client, payload_copy)

	// Shift the rest of the buffer down.
	remaining_byte_count := len(buffer_view) - total_required
	if remaining_byte_count > 0 {
		copy(client.read_buffer[:remaining_byte_count], buffer_view[total_required:])
	}
	resize(&client.read_buffer, remaining_byte_count)
	return true
}

@(private="file")
find_double_crlf :: proc(buffer: []u8) -> int {
	if len(buffer) < 4 { return -1 }
	for byte_index in 0..=len(buffer) - 4 {
		if buffer[byte_index] == '\r' && buffer[byte_index+1] == '\n' && buffer[byte_index+2] == '\r' && buffer[byte_index+3] == '\n' {
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
		if parsed_value, ok := strconv.parse_int(value_string); ok && parsed_value >= 0 {
			return parsed_value
		}
		return -1
	}
	return -1
}

// --- Outbound send --------------------------------------------------------

@(private)
allocate_request_id :: proc(client: ^Client) -> i64 {
	id := client.next_request_id
	client.next_request_id += 1
	return id
}

@(private)
send_raw_payload :: proc(client: ^Client, json_payload: string) {
	if client == nil || len(json_payload) == 0 { return }
	header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(json_payload))
	process_write(&client.process_state, transmute([]u8)header)
	process_write(&client.process_state, transmute([]u8)json_payload)
}

// Build a JSON-RPC request frame: `{"jsonrpc":"2.0","id":N,"method":...,"params":...}`.
// `params_json` should already be a serialized JSON object/array string.
@(private)
send_request :: proc(client: ^Client, method: string, params_json: string, pending: PendingRequest) -> i64 {
	id := allocate_request_id(client)
	client.pending_requests[id] = pending

	builder: strings.Builder
	strings.builder_init(&builder, 0, len(params_json) + 64, context.temp_allocator)
	strings.write_string(&builder, `{"jsonrpc":"2.0","id":`)
	fmt.sbprintf(&builder, "%d", id)
	strings.write_string(&builder, `,"method":`)
	write_json_string(&builder, method)
	strings.write_string(&builder, `,"params":`)
	if len(params_json) == 0 { strings.write_string(&builder, "null") } else { strings.write_string(&builder, params_json) }
	strings.write_string(&builder, "}")

	send_raw_payload(client, strings.to_string(builder))
	return id
}

@(private)
send_notification :: proc(client: ^Client, method: string, params_json: string) {
	builder: strings.Builder
	strings.builder_init(&builder, 0, len(params_json) + 64, context.temp_allocator)
	strings.write_string(&builder, `{"jsonrpc":"2.0","method":`)
	write_json_string(&builder, method)
	strings.write_string(&builder, `,"params":`)
	if len(params_json) == 0 { strings.write_string(&builder, "null") } else { strings.write_string(&builder, params_json) }
	strings.write_string(&builder, "}")
	send_raw_payload(client, strings.to_string(builder))
}

// Reply to a server-to-client request with a null result. Used for the
// `workspace/configuration` and other rarely-handled callbacks so the
// server's pending requests don't pile up.
@(private)
send_response_null :: proc(client: ^Client, id_json_token: json.Value) {
	builder: strings.Builder
	strings.builder_init(&builder, 0, 64, context.temp_allocator)
	strings.write_string(&builder, `{"jsonrpc":"2.0","id":`)
	write_json_value(&builder, id_json_token)
	strings.write_string(&builder, `,"result":null}`)
	send_raw_payload(client, strings.to_string(builder))
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

@(private="file")
write_json_value :: proc(builder: ^strings.Builder, value: json.Value) {
	switch v in value {
	case json.Null:    strings.write_string(builder, "null")
	case bool:         strings.write_string(builder, v ? "true" : "false")
	case i64:          fmt.sbprintf(builder, "%d", v)
	case f64:          fmt.sbprintf(builder, "%g", v)
	case string:       write_json_string(builder, v)
	case json.Array:
		strings.write_byte(builder, '[')
		for entry, entry_index in v {
			if entry_index > 0 { strings.write_byte(builder, ',') }
			write_json_value(builder, entry)
		}
		strings.write_byte(builder, ']')
	case json.Object:
		strings.write_byte(builder, '{')
		first := true
		for object_key, object_value in v {
			if !first { strings.write_byte(builder, ',') }
			first = false
			write_json_string(builder, object_key)
			strings.write_byte(builder, ':')
			write_json_value(builder, object_value)
		}
		strings.write_byte(builder, '}')
	}
}

// --- Inbound dispatch -----------------------------------------------------

@(private)
dispatch_message :: proc(client: ^Client, payload: []u8) {
	parsed_value, parse_error := json.parse(payload, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if parse_error != .None { return }
	root, is_object := parsed_value.(json.Object); if !is_object { return }

	id_value,     has_id     := root["id"]
	method_value, has_method := root["method"]

	if has_method && has_id {
		// Server-to-client request — reply with null so we don't stall it.
		_ = method_value
		send_response_null(client, id_value)
		return
	}

	if has_method {
		// Notification from the server.
		method_string, method_is_string := method_value.(string); if !method_is_string { return }
		params_value, _ := root["params"]
		handle_server_notification(client, method_string, params_value)
		return
	}

	if has_id {
		// Response to one of our requests.
		id_int, id_is_int := id_value.(i64)
		if !id_is_int {
			if id_float, id_is_float := id_value.(f64); id_is_float { id_int = i64(id_float); id_is_int = true }
		}
		if !id_is_int { return }
		request, has_request := client.pending_requests[id_int]; if !has_request { return }
		delete_key(&client.pending_requests, id_int)
		defer if len(request.file_path) > 0 { delete(request.file_path) }

		if error_value, has_error := root["error"]; has_error {
			_ = error_value
			handle_response_error(client, request)
			return
		}
		result_value, has_result := root["result"]
		if !has_result { return }
		handle_response_result(client, request, result_value)
	}
}

@(private="file")
handle_response_result :: proc(client: ^Client, request: PendingRequest, result_value: json.Value) {
	switch request.kind {
	case .Initialize:
		client.is_initialized = true
		send_initialized_notification(client)
		flush_pending_open_documents(client)
	case .Hover:
		ingest_hover_response(client, request, result_value)
	case .Completion:
		ingest_completion_response(client, request, result_value)
	case .SignatureHelp:
		ingest_signature_help_response(client, request, result_value)
	case .Other:
		// Nothing to do — caller cared only about the side effect of issuing the request.
	}
}

@(private="file")
handle_response_error :: proc(client: ^Client, request: PendingRequest) {
	switch request.kind {
	case .Initialize: client.is_initialized = false
	case .Hover:      hover_result_clear(&client.hover)
	case .Completion: completion_result_clear(&client.completion)
	case .SignatureHelp: signature_help_result_clear(&client.signature_help)
	case .Other:
	}
}

@(private="file")
handle_server_notification :: proc(client: ^Client, method: string, params: json.Value) {
	switch method {
	case "textDocument/publishDiagnostics":
		ingest_publish_diagnostics(client, params)
	case:
		// window/logMessage, window/showMessage, $/progress, etc. — swallow.
	}
}

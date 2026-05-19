package lsp

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// --- Initialize / shutdown ------------------------------------------------

@(private)
send_initialize_request :: proc(client: ^Client, workspace_directory: string) {
	root_uri := client.workspace_root_uri
	params := strings.Builder{}
	strings.builder_init(&params, 0, 256, context.temp_allocator)

	process_id_string := fmt.tprintf("%d", get_process_id_for_lsp())

	strings.write_string(&params, `{`)
	strings.write_string(&params, `"processId":`)
	strings.write_string(&params, process_id_string)
	strings.write_string(&params, `,"clientInfo":{"name":"odit","version":"0.1"}`)
	strings.write_string(&params, `,"rootUri":`)
	if len(root_uri) > 0 { write_json_string(&params, root_uri) } else { strings.write_string(&params, "null") }
	strings.write_string(&params, `,"capabilities":{`)
	strings.write_string(&params, `"workspace":{"workspaceFolders":true,"configuration":true}`)
	strings.write_string(&params, `,"textDocument":{`)
	strings.write_string(&params, `"synchronization":{"didSave":false,"willSave":false,"willSaveWaitUntil":false}`)
	strings.write_string(&params, `,"publishDiagnostics":{"relatedInformation":false}`)
	strings.write_string(&params, `,"hover":{"contentFormat":["plaintext","markdown"]}`)
	strings.write_string(&params, `,"completion":{"completionItem":{"snippetSupport":false,"documentationFormat":["plaintext"]}}`)
	strings.write_string(&params, `,"signatureHelp":{"signatureInformation":{"documentationFormat":["plaintext","markdown"],"parameterInformation":{"labelOffsetSupport":true}}}`)
	strings.write_string(&params, `}`)
	strings.write_string(&params, `}`)
	if len(root_uri) > 0 {
		// Send workspaceFolders too for servers that prefer that path.
		strings.write_string(&params, `,"workspaceFolders":[{"uri":`)
		write_json_string(&params, root_uri)
		strings.write_string(&params, `,"name":"workspace"}]`)
	}
	strings.write_string(&params, `}`)

	_ = workspace_directory
	send_request(client, "initialize", strings.to_string(params), PendingRequest{ kind = .Initialize })
}

@(private)
send_initialized_notification :: proc(client: ^Client) {
	if client.has_sent_initialized_notification { return }
	client.has_sent_initialized_notification = true
	send_notification(client, "initialized", "{}")
}

@(private)
send_shutdown_request :: proc(client: ^Client) {
	if !client.is_initialized { return }
	send_request(client, "shutdown", "null", PendingRequest{ kind = .Other })
}

@(private)
send_exit_notification :: proc(client: ^Client) {
	send_notification(client, "exit", "null")
}

// --- Document sync --------------------------------------------------------

@(private)
send_did_open_notification :: proc(client: ^Client, file_path, language_id, content_text: string, version: i32) {
	uri := path_to_file_uri(file_path, context.temp_allocator)
	params := strings.Builder{}
	strings.builder_init(&params, 0, len(content_text) + 128, context.temp_allocator)
	strings.write_string(&params, `{"textDocument":{"uri":`)
	write_json_string(&params, uri)
	strings.write_string(&params, `,"languageId":`)
	write_json_string(&params, language_id)
	strings.write_string(&params, `,"version":`)
	fmt.sbprintf(&params, "%d", version)
	strings.write_string(&params, `,"text":`)
	write_json_string(&params, content_text)
	strings.write_string(&params, `}}`)
	send_notification(client, "textDocument/didOpen", strings.to_string(params))
}

@(private)
send_did_change_notification :: proc(client: ^Client, file_path, content_text: string, version: i32) {
	uri := path_to_file_uri(file_path, context.temp_allocator)
	params := strings.Builder{}
	strings.builder_init(&params, 0, len(content_text) + 128, context.temp_allocator)
	strings.write_string(&params, `{"textDocument":{"uri":`)
	write_json_string(&params, uri)
	strings.write_string(&params, `,"version":`)
	fmt.sbprintf(&params, "%d", version)
	strings.write_string(&params, `},"contentChanges":[{"text":`)
	write_json_string(&params, content_text)
	strings.write_string(&params, `}]}`)
	send_notification(client, "textDocument/didChange", strings.to_string(params))
}

@(private)
send_did_close_notification :: proc(client: ^Client, file_path: string) {
	uri := path_to_file_uri(file_path, context.temp_allocator)
	params := strings.Builder{}
	strings.builder_init(&params, 0, 64, context.temp_allocator)
	strings.write_string(&params, `{"textDocument":{"uri":`)
	write_json_string(&params, uri)
	strings.write_string(&params, `}}`)
	send_notification(client, "textDocument/didClose", strings.to_string(params))
}

// Pending-open documents queued before the initialize handshake completed
// would just sit there indefinitely — there's nothing to flush since
// `client_did_open` already gates on `is_initialized`. Editors should retry
// their open after we flip initialized; for the MVP we expect the editor to
// either open after init or accept that early opens get dropped.
@(private)
flush_pending_open_documents :: proc(client: ^Client) {
	_ = client
}

// --- Hover ----------------------------------------------------------------

@(private)
send_hover_request :: proc(client: ^Client, file_path: string, line, column: i32) {
	uri := path_to_file_uri(file_path, context.temp_allocator)
	params := strings.Builder{}
	strings.builder_init(&params, 0, 128, context.temp_allocator)
	strings.write_string(&params, `{"textDocument":{"uri":`)
	write_json_string(&params, uri)
	strings.write_string(&params, `},"position":{"line":`)
	fmt.sbprintf(&params, "%d", line)
	strings.write_string(&params, `,"character":`)
	fmt.sbprintf(&params, "%d", column)
	strings.write_string(&params, `}}`)
	send_request(client, "textDocument/hover", strings.to_string(params), PendingRequest{
		kind = .Hover,
		file_path = strings.clone(file_path),
		line = line, column = column,
	})
}

@(private)
ingest_hover_response :: proc(client: ^Client, request: PendingRequest, result_value: json.Value) {
	hover_text := ""

	if _, is_null := result_value.(json.Null); !is_null {
		if root, is_object := result_value.(json.Object); is_object {
			if contents_value, has_contents := root["contents"]; has_contents {
				text_buffer: strings.Builder
				strings.builder_init(&text_buffer, 0, 128, context.allocator)
				append_hover_text(&text_buffer, contents_value)
				hover_text = strings.to_string(text_buffer)
				if len(hover_text) == 0 {
					delete(hover_text)
					hover_text = ""
				}
			}
		}
	}

	// Always mark valid (even when the result was null / empty). The
	// editor's hover popup checks `is_valid` to know a response landed;
	// empty text just renders a "no info" message rather than spinning
	// on "loading" forever.
	if len(hover_text) == 0 { hover_text = strings.clone("(no hover info)") }

	hover_result_clear(&client.hover)
	client.hover = HoverResult{
		is_valid  = true,
		file_path = strings.clone(request.file_path),
		line      = request.line,
		column    = request.column,
		text      = hover_text,
	}
}

@(private="file")
append_hover_text :: proc(builder: ^strings.Builder, value: json.Value) {
	switch v in value {
	case string:
		strings.write_string(builder, v)
	case json.Array:
		for entry, entry_index in v {
			if entry_index > 0 { strings.write_byte(builder, '\n') }
			append_hover_text(builder, entry)
		}
	case json.Object:
		// MarkupContent / MarkedString — pull the "value" key.
		if value_field, has_value := v["value"]; has_value {
			if text, is_string := value_field.(string); is_string { strings.write_string(builder, text) }
		}
	case json.Null, bool, i64, f64:
		// Nothing meaningful to render.
	}
}

// --- Signature help -------------------------------------------------------

@(private)
send_signature_help_request :: proc(client: ^Client, file_path: string, line, column: i32) {
	uri := path_to_file_uri(file_path, context.temp_allocator)
	params := strings.Builder{}
	strings.builder_init(&params, 0, 128, context.temp_allocator)
	strings.write_string(&params, `{"textDocument":{"uri":`)
	write_json_string(&params, uri)
	strings.write_string(&params, `},"position":{"line":`)
	fmt.sbprintf(&params, "%d", line)
	strings.write_string(&params, `,"character":`)
	fmt.sbprintf(&params, "%d", column)
	strings.write_string(&params, `}}`)
	send_request(client, "textDocument/signatureHelp", strings.to_string(params), PendingRequest{
		kind = .SignatureHelp,
		file_path = strings.clone(file_path),
		line = line, column = column,
	})
}

@(private)
ingest_signature_help_response :: proc(client: ^Client, request: PendingRequest, result_value: json.Value) {
	signature_help_result_clear(&client.signature_help)

	// Null result = "nothing to show" (cursor isn't inside a call argument
	// list, etc.). Mark valid + empty so the popup can decide to close
	// rather than spinning indefinitely.
	if _, is_null := result_value.(json.Null); is_null {
		client.signature_help.is_valid  = true
		client.signature_help.file_path = strings.clone(request.file_path)
		client.signature_help.line      = request.line
		client.signature_help.column    = request.column
		return
	}

	root, is_object := result_value.(json.Object); if !is_object { return }
	signatures_value, has_signatures := root["signatures"]; if !has_signatures { return }
	signatures_array, is_array := signatures_value.(json.Array); if !is_array { return }

	active_signature_int := 0
	if value, ok := root["activeSignature"]; ok {
		if value_int, is_int := value.(i64); is_int { active_signature_int = int(value_int) }
	}
	top_active_parameter_int := 0
	if value, ok := root["activeParameter"]; ok {
		if value_int, is_int := value.(i64); is_int { top_active_parameter_int = int(value_int) }
	}

	collected_signatures: [dynamic]SignatureInformation
	collected_signatures.allocator = context.allocator
	for signature_entry in signatures_array {
		signature_object, is_sig_object := signature_entry.(json.Object); if !is_sig_object { continue }
		label_value,    _ := signature_object["label"]
		params_value,   _ := signature_object["parameters"]
		docs_value,     _ := signature_object["documentation"]

		label_string, label_is_string := label_value.(string); if !label_is_string { continue }

		documentation_string := ""
		if docs_text, is_string := docs_value.(string); is_string {
			documentation_string = docs_text
		} else if docs_object, is_object := docs_value.(json.Object); is_object {
			if value_field, ok := docs_object["value"]; ok {
				if value_text, is_string := value_field.(string); is_string { documentation_string = value_text }
			}
		}

		// Compute parameter byte ranges within `label`. LSP allows the
		// `label` field of a Parameter to be either a string (substring of
		// the signature) or a `[start, end]` integer pair pointing into
		// the signature's UTF-16 offsets. We honor both.
		parameter_ranges: [dynamic]SignatureParameterRange
		parameter_ranges.allocator = context.allocator
		if params_array, is_params_array := params_value.(json.Array); is_params_array {
			for parameter_entry in params_array {
				parameter_object, is_param_object := parameter_entry.(json.Object); if !is_param_object { continue }
				param_label_value, _ := parameter_object["label"]
				switch v in param_label_value {
				case string:
					// Substring match against the signature label.
					if index := strings.index(label_string, v); index >= 0 {
						append(&parameter_ranges, SignatureParameterRange{
							start_byte = i32(index),
							end_byte   = i32(index + len(v)),
						})
					}
				case json.Array:
					if len(v) >= 2 {
						a, a_ok := v[0].(i64)
						b, b_ok := v[1].(i64)
						if a_ok && b_ok {
							append(&parameter_ranges, SignatureParameterRange{
								start_byte = i32(a),
								end_byte   = i32(b),
							})
						}
					}
				case bool, i64, f64, json.Null, json.Object:
					// Ignore other shapes.
				}
			}
		}

		append(&collected_signatures, SignatureInformation{
			label            = strings.clone(label_string),
			documentation    = strings.clone(documentation_string),
			parameter_ranges = parameter_ranges,
		})
	}

	client.signature_help = SignatureHelpResult{
		is_valid         = true,
		file_path        = strings.clone(request.file_path),
		line             = request.line,
		column           = request.column,
		signatures       = collected_signatures,
		active_signature = active_signature_int,
		active_parameter = top_active_parameter_int,
	}
}

// --- Completion -----------------------------------------------------------

@(private)
send_completion_request :: proc(client: ^Client, file_path: string, line, column: i32) {
	uri := path_to_file_uri(file_path, context.temp_allocator)
	params := strings.Builder{}
	strings.builder_init(&params, 0, 128, context.temp_allocator)
	strings.write_string(&params, `{"textDocument":{"uri":`)
	write_json_string(&params, uri)
	strings.write_string(&params, `},"position":{"line":`)
	fmt.sbprintf(&params, "%d", line)
	strings.write_string(&params, `,"character":`)
	fmt.sbprintf(&params, "%d", column)
	strings.write_string(&params, `}}`)
	send_request(client, "textDocument/completion", strings.to_string(params), PendingRequest{
		kind = .Completion,
		file_path = strings.clone(file_path),
		line = line, column = column,
	})
}

@(private)
ingest_completion_response :: proc(client: ^Client, request: PendingRequest, result_value: json.Value) {
	items_array: json.Array
	have_items := false

	if direct_array, is_array := result_value.(json.Array); is_array {
		items_array = direct_array
		have_items = true
	} else if list_object, is_object := result_value.(json.Object); is_object {
		if items_value, has_items := list_object["items"]; has_items {
			if list_items_array, is_array := items_value.(json.Array); is_array {
				items_array = list_items_array
				have_items = true
			}
		}
	}

	// A null / empty result is a perfectly valid "no completions here"
	// answer. Still publish an `is_valid` result with zero items so the
	// popup transitions from "loading…" to "no completions" instead of
	// hanging forever.
	if !have_items {
		empty_items: [dynamic]CompletionItem
		empty_items.allocator = context.allocator
		completion_result_clear(&client.completion)
		client.completion = CompletionResult{
			is_valid  = true,
			file_path = strings.clone(request.file_path),
			line      = request.line,
			column    = request.column,
			items     = empty_items,
		}
		return
	}

	collected: [dynamic]CompletionItem
	collected.allocator = context.allocator
	for entry in items_array {
		entry_object, is_object := entry.(json.Object); if !is_object { continue }
		label_value,  _ := entry_object["label"]
		detail_value, _ := entry_object["detail"]
		insert_value, _ := entry_object["insertText"]
		kind_value,   _ := entry_object["kind"]

		label_string, label_is_string := label_value.(string); if !label_is_string || len(label_string) == 0 { continue }

		insert_text_string := label_string
		if explicit_insert, is_string := insert_value.(string); is_string && len(explicit_insert) > 0 {
			insert_text_string = explicit_insert
		}

		detail_string := ""
		if detail_text, is_string := detail_value.(string); is_string { detail_string = detail_text }

		kind_int: int = 0
		if kind_int_value, is_i64 := kind_value.(i64); is_i64 { kind_int = int(kind_int_value) }

		append(&collected, CompletionItem{
			label       = strings.clone(label_string),
			detail      = strings.clone(detail_string),
			insert_text = strings.clone(insert_text_string),
			kind        = kind_int,
		})
	}

	completion_result_clear(&client.completion)
	client.completion = CompletionResult{
		is_valid  = true,
		file_path = strings.clone(request.file_path),
		line      = request.line,
		column    = request.column,
		items     = collected,
	}
}

// --- Diagnostics ----------------------------------------------------------

@(private)
ingest_publish_diagnostics :: proc(client: ^Client, params: json.Value) {
	root, is_object := params.(json.Object); if !is_object { return }
	uri_value,         has_uri    := root["uri"];         if !has_uri    { return }
	diagnostics_value, has_diags  := root["diagnostics"]; if !has_diags  { return }

	uri_string, uri_is_string := uri_value.(string); if !uri_is_string { return }
	diagnostics_array, is_array := diagnostics_value.(json.Array); if !is_array { return }

	file_path := file_uri_to_path(uri_string, context.allocator)
	defer if !is_known_path_key(client, file_path) { delete(file_path) }

	// Free any existing diagnostics for this file before replacing.
	for existing_path, existing_list in client.diagnostics {
		if path_equals(existing_path, file_path) {
			for entry in existing_list {
				if len(entry.message) > 0 { delete(entry.message) }
				if len(entry.source)  > 0 { delete(entry.source) }
			}
			if cap(existing_list) > 0 { delete(existing_list) }
			delete_key(&client.diagnostics, existing_path)
			delete(existing_path)
			break
		}
	}

	new_list: [dynamic]Diagnostic
	new_list.allocator = context.allocator
	for diagnostic_entry in diagnostics_array {
		entry_object, entry_is_object := diagnostic_entry.(json.Object); if !entry_is_object { continue }
		range_value,    has_range    := entry_object["range"];    if !has_range    { continue }
		message_value,  _            := entry_object["message"]
		severity_value, _            := entry_object["severity"]
		source_value,   _            := entry_object["source"]

		range_object, range_is_object := range_value.(json.Object); if !range_is_object { continue }
		start_object, start_is_object := range_object["start"].(json.Object); if !start_is_object { continue }
		end_object,   end_is_object   := range_object["end"].(json.Object);   if !end_is_object   { continue }

		start_line   := json_int(start_object["line"])
		start_column := json_int(start_object["character"])
		end_line     := json_int(end_object["line"])
		end_column   := json_int(end_object["character"])

		severity := DiagnosticSeverity.Error
		if severity_int, is_i64 := severity_value.(i64); is_i64 {
			switch severity_int {
			case 1: severity = .Error
			case 2: severity = .Warning
			case 3: severity = .Information
			case 4: severity = .Hint
			}
		}

		message_string := ""
		if message_text, is_string := message_value.(string); is_string { message_string = strings.clone(message_text) }
		source_string := ""
		if source_text, is_string := source_value.(string); is_string { source_string = strings.clone(source_text) }

		append(&new_list, Diagnostic{
			start_line   = start_line,
			start_column = start_column,
			end_line     = end_line,
			end_column   = end_column,
			severity     = severity,
			message      = message_string,
			source       = source_string,
		})
	}

	// Key the map by an owned string. If we reused an existing key above
	// (path was already tracked elsewhere), `file_path` was freed already.
	key := strings.clone(file_path)
	client.diagnostics[key] = new_list
}

@(private="file")
is_known_path_key :: proc(client: ^Client, path: string) -> bool {
	for key in client.diagnostics {
		if path_equals(key, path) { return true }
	}
	for key in client.open_documents {
		if path_equals(key, path) { return true }
	}
	return false
}

@(private="file")
json_int :: proc(value: json.Value) -> i32 {
	switch v in value {
	case i64: return i32(v)
	case f64: return i32(v)
	case bool, string, json.Null, json.Array, json.Object:
		return 0
	}
	return 0
}

// --- Process ID helper ----------------------------------------------------

@(private)
get_process_id_for_lsp :: proc() -> int {
	return get_process_id_platform()
}

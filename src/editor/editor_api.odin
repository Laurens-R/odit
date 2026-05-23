package editor

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "vendor:sdl3"

import binding_pkg "./binding"
import "../dap"
import "../document"
import "../lsp"
import "../markdown"
import "../syntax"

// `binding.EditorAPI` implementations. Each entry is a tiny
// trampoline: cast `editor_ptr` back to `^Editor` and delegate to
// the existing editor-side proc. Grouped here so the editor's plugin
// surface lives in one file rather than scattered across editor.odin.

// --- Pane / document ops -----------------------------------------------

@(private)
editor_api_find_open_document :: proc(editor_ptr: rawptr, file_path: string) -> (pane_index, background_index: int) {
	editor := cast(^Editor)editor_ptr
	return editor_find_open_document(editor, file_path)
}

@(private)
editor_api_open_string_in_pane :: proc(editor_ptr: rawptr, pane_index: int, content: string, file_path: string) {
	editor := cast(^Editor)editor_ptr
	editor_open_string_in_pane(editor, pane_index, content, file_path)
}

@(private)
editor_api_swap_background_into_pane :: proc(editor_ptr: rawptr, pane_index, background_index: int) {
	editor := cast(^Editor)editor_ptr
	editor_swap_background_into_pane(editor, pane_index, background_index)
}

@(private)
editor_api_active_pane_index :: proc(editor_ptr: rawptr) -> int {
	editor := cast(^Editor)editor_ptr
	return editor.active_pane_index
}

@(private)
editor_api_set_active_pane_index :: proc(editor_ptr: rawptr, pane_index: int) {
	editor := cast(^Editor)editor_ptr
	editor.active_pane_index = pane_index
}

@(private)
editor_api_set_split_active :: proc(editor_ptr: rawptr, value: bool) {
	editor := cast(^Editor)editor_ptr
	editor.split_active = value
}

@(private)
editor_api_project_root :: proc(editor_ptr: rawptr) -> string {
	editor := cast(^Editor)editor_ptr
	return editor.project_root
}

@(private)
editor_api_set_project_root :: proc(editor_ptr: rawptr, path: string) {
	editor := cast(^Editor)editor_ptr
	editor_set_project_root(editor, path)
}

@(private)
editor_api_path_inside_project_root :: proc(editor_ptr: rawptr, path: string) -> bool {
	editor := cast(^Editor)editor_ptr
	return editor_path_inside_project_root(editor, path)
}

@(private)
editor_api_line_height :: proc(editor_ptr: rawptr) -> i32 {
	editor := cast(^Editor)editor_ptr
	return editor.line_height
}

@(private)
editor_api_character_width :: proc(editor_ptr: rawptr) -> i32 {
	editor := cast(^Editor)editor_ptr
	return editor.character_width
}

@(private="file")
EDITOR_API_MAX_FILE_BYTES :: 256 * 1024 * 1024 // 256 MiB

@(private)
editor_api_open_file_at_path :: proc(editor_ptr: rawptr, path: string, split_secondary: bool, allocator: runtime.Allocator) -> (error_message: string) {
	editor := cast(^Editor)editor_ptr

	existing_pane_index, existing_background_index := editor_find_open_document(editor, path)
	if existing_pane_index >= 0 {
		editor.active_pane_index = existing_pane_index
		return ""
	}
	if existing_background_index >= 0 {
		target_pane_index := editor.active_pane_index
		if split_secondary {
			editor.split_active = true
			target_pane_index   = 1
			editor.active_pane_index = 1
		}
		editor_swap_background_into_pane(editor, target_pane_index, existing_background_index)
		return ""
	}

	file_data, read_file_error := os.read_entire_file_from_path(path, context.allocator)
	if read_file_error != nil {
		return fmt.aprintf("Cannot open %s: %v", filepath.base(path), read_file_error, allocator = allocator)
	}
	defer delete(file_data)

	if len(file_data) > EDITOR_API_MAX_FILE_BYTES {
		return fmt.aprintf("File %s is too large (%d bytes)", filepath.base(path), len(file_data), allocator = allocator)
	}

	file_content := strings.clone(string(file_data))

	target_pane_index := editor.active_pane_index
	if split_secondary {
		editor.split_active = true
		target_pane_index   = 1
		editor.active_pane_index = 1
	}

	editor_open_string_in_pane(editor, target_pane_index, file_content, path)
	return ""
}

@(private)
editor_api_jump_active_pane_to :: proc(editor_ptr: rawptr, line, column: u32) {
	editor := cast(^Editor)editor_ptr
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }

	document_line_count := document.document_line_count(&editor_pane.document)
	target_line := line
	if target_line >= document_line_count { target_line = document_line_count - 1 }

	line_start_offset := document.document_line_start(&editor_pane.document, target_line)
	line_text         := document.document_get_line(&editor_pane.document, target_line, context.temp_allocator)
	target_column     := column
	if int(target_column) > len(line_text) { target_column = u32(len(line_text)) }

	editor_pane.cursor_line      = target_line
	editor_pane.cursor_column    = target_column
	editor_pane.cursor_offset    = line_start_offset + target_column
	editor_pane.selection_active = false

	editor.cursor_visible = true
	editor.cursor_timer   = 0

	if editor.diff_state.active || editor.line_height <= 0 {
		sync_cursor_from_offset(editor)
	} else {
		target_scroll_y := f32(target_line) * f32(editor.line_height)
		if target_scroll_y < 0 { target_scroll_y = 0 }
		editor_pane.scroll_y        = target_scroll_y
		editor_pane.scroll_y_target = target_scroll_y
		editor_pane.scroll_line     = target_line
	}
}

@(private)
editor_api_active_pane_file_path :: proc(editor_ptr: rawptr) -> string {
	editor := cast(^Editor)editor_ptr
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return "" }
	return editor_pane.file_path
}

@(private)
editor_api_active_pane_short_selection :: proc(editor_ptr: rawptr, max_bytes: int, allocator: runtime.Allocator) -> (text: string, ok: bool) {
	editor := cast(^Editor)editor_ptr
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return "", false }
	if !editor_pane.selection_active                                          { return "", false }

	low_offset, high_offset, has_selection := editor_pane_selection_range(editor_pane)
	if !has_selection                       { return "", false }
	if int(high_offset - low_offset) > max_bytes { return "", false }

	selection_text := document.document_get_slice(&editor_pane.document, low_offset, high_offset - low_offset, context.temp_allocator)
	for byte_value in transmute([]u8)selection_text {
		if byte_value == '\n' { return "", false }
	}
	return strings.clone(selection_text, allocator), true
}

@(private)
editor_api_open_string_in_opposite_pane :: proc(editor_ptr: rawptr, source_pane_index: int, content: string, file_path_for_syntax: string, display_title_override: string) {
	editor := cast(^Editor)editor_ptr
	opposite_pane_index := 1 - source_pane_index
	if opposite_pane_index < 0 || opposite_pane_index >= len(editor.panes) { return }

	editor.split_active = true
	editor_open_string_in_pane(editor, opposite_pane_index, content, "")
	if opposite_pane := pane_as_editor(&editor.panes[opposite_pane_index]); opposite_pane != nil {
		opposite_pane.language               = syntax.get_definition_for_path(file_path_for_syntax)
		opposite_pane.display_title_override = display_title_override
		pane_rebuild_symbols(opposite_pane)
		opposite_pane.symbols_dirty      = false
		opposite_pane.last_analysis_time = editor.clock
	}
	editor.active_pane_index = opposite_pane_index
}

// --- LSP popups (hover / signature / completion) ----------------------

// Resolve the LSP client + editor pane for the active pane. Returns
// ok=false when nothing is wired up (no editor pane, no file path,
// no client for the language, client not initialized, pane hasn't
// sent didOpen yet).
@(private="file")
editor_api_active_lsp :: proc(editor: ^Editor) -> (client: ^lsp.Client, editor_pane: ^EditorPane, ok: bool) {
	editor_pane = editor_active_editor_pane(editor); if editor_pane == nil { return nil, nil, false }
	if len(editor_pane.file_path) == 0 { return nil, nil, false }
	language_id := lsp_language_id_for(editor_pane.language); if len(language_id) == 0 { return nil, nil, false }
	found_client, has_client := editor.lsp_clients[language_id]; if !has_client { return nil, nil, false }
	if !found_client.is_initialized        { return nil, nil, false }
	if !editor_pane.lsp_did_open_sent      { return nil, nil, false }
	return found_client, editor_pane, true
}

@(private)
editor_api_lsp_request_hover :: proc(editor_ptr: rawptr) -> bool {
	editor := cast(^Editor)editor_ptr
	client, editor_pane, ok := editor_api_active_lsp(editor)
	if !ok { return false }
	editor_lsp_flush_pending_change(editor, editor_pane)
	lsp.client_request_hover(client, editor_pane.file_path, i32(editor_pane.cursor_line), i32(editor_pane.cursor_column))
	return true
}

@(private)
editor_api_lsp_poll_hover :: proc(editor_ptr: rawptr, allocator: runtime.Allocator) -> (text: string, ok: bool) {
	editor := cast(^Editor)editor_ptr
	for _, client in editor.lsp_clients {
		if !client.hover.is_valid { continue }
		cloned := strings.clone(client.hover.text, allocator)
		lsp.hover_result_clear(&client.hover)
		return cloned, true
	}
	return "", false
}

@(private)
editor_api_lsp_request_signature_help :: proc(editor_ptr: rawptr) -> bool {
	editor := cast(^Editor)editor_ptr
	client, editor_pane, ok := editor_api_active_lsp(editor)
	if !ok { return false }
	editor_lsp_flush_pending_change(editor, editor_pane)
	lsp.client_request_signature_help(client, editor_pane.file_path, i32(editor_pane.cursor_line), i32(editor_pane.cursor_column))
	return true
}

@(private)
editor_api_lsp_poll_signature_help :: proc(editor_ptr: rawptr, allocator: runtime.Allocator) -> (info: binding_pkg.SignatureInfo, ok: bool) {
	editor := cast(^Editor)editor_ptr
	for _, client in editor.lsp_clients {
		if !client.signature_help.is_valid { continue }

		if len(client.signature_help.signatures) == 0 {
			lsp.signature_help_result_clear(&client.signature_help)
			return binding_pkg.SignatureInfo{ active_start = -1, active_end = -1 }, true
		}

		active_signature_index := client.signature_help.active_signature
		if active_signature_index < 0                                       { active_signature_index = 0 }
		if active_signature_index >= len(client.signature_help.signatures)  { active_signature_index = len(client.signature_help.signatures) - 1 }

		signature := client.signature_help.signatures[active_signature_index]
		active_parameter_index := client.signature_help.active_parameter
		if active_parameter_index < 0                                  { active_parameter_index = 0 }
		if active_parameter_index >= len(signature.parameter_ranges)   { active_parameter_index = -1 }

		result := binding_pkg.SignatureInfo{
			label         = strings.clone(signature.label,         allocator),
			documentation = strings.clone(signature.documentation, allocator),
			active_start  = -1,
			active_end    = -1,
		}
		if active_parameter_index >= 0 {
			active_range := signature.parameter_ranges[active_parameter_index]
			result.active_start = active_range.start_byte
			result.active_end   = active_range.end_byte
		}
		lsp.signature_help_result_clear(&client.signature_help)
		return result, true
	}
	return {}, false
}

@(private)
editor_api_lsp_request_completion :: proc(editor_ptr: rawptr) -> bool {
	editor := cast(^Editor)editor_ptr
	client, editor_pane, ok := editor_api_active_lsp(editor)
	if !ok { return false }
	editor_lsp_flush_pending_change(editor, editor_pane)
	lsp.client_request_completion(client, editor_pane.file_path, i32(editor_pane.cursor_line), i32(editor_pane.cursor_column))
	return true
}

@(private)
editor_api_lsp_poll_completion :: proc(editor_ptr: rawptr, allocator: runtime.Allocator) -> (items: []binding_pkg.CompletionItem, ok: bool) {
	editor := cast(^Editor)editor_ptr
	for _, client in editor.lsp_clients {
		if !client.completion.is_valid { continue }
		converted := make([]binding_pkg.CompletionItem, len(client.completion.items), allocator)
		for raw_item, item_index in client.completion.items {
			converted[item_index] = binding_pkg.CompletionItem{
				label       = strings.clone(raw_item.label,       allocator),
				detail      = strings.clone(raw_item.detail,      allocator),
				insert_text = strings.clone(raw_item.insert_text, allocator),
			}
		}
		lsp.completion_result_clear(&client.completion)
		return converted, true
	}
	return nil, false
}

@(private)
editor_api_apply_completion_at_cursor :: proc(editor_ptr: rawptr, pane_index: int, insert_text: string) {
	editor := cast(^Editor)editor_ptr
	if pane_index < 0 || pane_index >= len(editor.panes) { return }
	editor_pane := pane_as_editor(&editor.panes[pane_index]); if editor_pane == nil { return }

	cursor_offset := editor_pane.cursor_offset
	prefix_start  := cursor_offset
	for prefix_start > 0 {
		previous_byte := editor_api_document_byte_at(editor_pane, prefix_start - 1)
		if !editor_api_is_identifier_byte(previous_byte) { break }
		prefix_start -= 1
	}
	if prefix_start < cursor_offset {
		document.document_delete(&editor_pane.document, prefix_start, cursor_offset - prefix_start)
		editor_pane.cursor_offset = prefix_start
	}
	document.document_insert(&editor_pane.document, editor_pane.cursor_offset, insert_text)
	editor_pane.cursor_offset += u32(len(insert_text))
	pane_mark_document_modified(editor, editor_pane)
	sync_cursor_from_offset(editor)
}

@(private="file")
editor_api_document_byte_at :: proc(editor_pane: ^EditorPane, offset: u32) -> u8 {
	byte_slice := document.document_get_slice(&editor_pane.document, offset, 1, context.temp_allocator)
	if len(byte_slice) == 0 { return 0 }
	return byte_slice[0]
}

@(private="file")
editor_api_is_identifier_byte :: proc(byte_value: u8) -> bool {
	return (byte_value >= 'a' && byte_value <= 'z') ||
	       (byte_value >= 'A' && byte_value <= 'Z') ||
	       (byte_value >= '0' && byte_value <= '9') ||
	       byte_value == '_'
}

// --- Render context / pane geometry / theme ---------------------------

@(private)
editor_api_markdown_context :: proc(editor_ptr: rawptr, renderer: ^sdl3.Renderer) -> markdown.Context {
	editor := cast(^Editor)editor_ptr
	return editor_markdown_context(editor, renderer)
}

@(private)
editor_api_active_pane_cursor :: proc(editor_ptr: rawptr) -> binding_pkg.ActivePaneCursor {
	editor := cast(^Editor)editor_ptr
	result := binding_pkg.ActivePaneCursor{
		pane_index = editor.active_pane_index,
	}
	if active_editor_pane := editor_active_editor_pane(editor); active_editor_pane != nil {
		result.cursor_line   = active_editor_pane.cursor_line
		result.cursor_column = active_editor_pane.cursor_column
		result.cursor_offset = active_editor_pane.cursor_offset
		result.is_editor     = true
	}
	return result
}

@(private)
editor_api_pane_anchor :: proc(editor_ptr: rawptr, pane_index: int, anchor_line: u32) -> binding_pkg.PaneAnchor {
	editor := cast(^Editor)editor_ptr
	if pane_index < 0 || pane_index >= len(editor.panes) { return {} }
	pane := &editor.panes[pane_index]
	editor_pane := pane_as_editor(pane); if editor_pane == nil { return {} }

	title_bar_height    := editor_title_bar_height(editor)
	cursor_screen_top_y := pane.rectangle.y + title_bar_height + editor.padding_y + i32(anchor_line) * editor.line_height - i32(editor_pane.scroll_y)
	return binding_pkg.PaneAnchor{
		cursor_screen_top_y = cursor_screen_top_y,
		cursor_line_height  = editor.line_height,
		character_width     = editor.character_width,
		pane_left_x         = pane.rectangle.x,
		pane_top_y          = pane.rectangle.y + title_bar_height,
		text_left_x         = pane.rectangle.x + editor.padding_x + editor_pane.gutter_width,
	}
}

@(private)
editor_api_theme :: proc(editor_ptr: rawptr) -> binding_pkg.Theme {
	editor := cast(^Editor)editor_ptr
	return binding_pkg.Theme{
		background_color          = editor.background_color,
		foreground_color          = editor.foreground_color,
		status_bar_background     = editor.status_bar_background,
		status_bar_foreground     = editor.status_bar_foreground,
		divider_color             = editor.divider_color,
		cursor_color              = editor.cursor_color,
		selection_color           = editor.selection_color,
		line_number_color         = editor.line_number_color,
		syntax_keyword_foreground = editor.syntax_keyword_foreground,
		syntax_type_foreground    = editor.syntax_type_foreground,
		breakpoint_color          = editor.breakpoint_color,
		breakpoint_disabled_color = editor.breakpoint_disabled_color,
		git_deleted_foreground    = editor.git_deleted_foreground,
	}
}

// --- DAP primitives ---------------------------------------------------

@(private)
editor_api_active_dap_client :: proc(editor_ptr: rawptr) -> ^dap.Client {
	editor := cast(^Editor)editor_ptr
	return editor.active_dap_client
}

@(private)
editor_api_dap_action :: proc(editor_ptr: rawptr, action: binding_pkg.DapAction) {
	editor := cast(^Editor)editor_ptr
	switch action {
	case .StartSession: editor_dap_start_session(editor)
	case .StopSession:  editor_dap_stop_session(editor)
	case .Continue:     dap.client_continue(editor.active_dap_client)
	case .StepOver:     dap.client_step_over(editor.active_dap_client)
	case .StepInto:     dap.client_step_in(editor.active_dap_client)
	case .StepOut:      dap.client_step_out(editor.active_dap_client)
	}
}

@(private)
editor_api_dap_flush_file_breakpoints :: proc(editor_ptr: rawptr, path: string) {
	editor := cast(^Editor)editor_ptr
	editor_dap_flush_file_breakpoints(editor, path)
}

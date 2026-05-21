package editor

import "core:fmt"
import "core:strings"
import "vendor:sdl3"

import "../document"
import "../lsp"
import "../ui"

// --- State ----------------------------------------------------------------

// Completion popup state. The popup lives next to a specific pane's cursor;
// `pane_index` + `anchor_line/anchor_column` snapshot the position the
// request was issued at so we can detect staleness (cursor moved → close).
@(private)
CompletionPopup :: struct {
	is_visible:        bool,
	pane_index:        int,
	anchor_line:       u32,
	anchor_column:     u32,
	filter_buffer:     [dynamic]u8,
	selected_index:    int,
	scroll_offset:     int,
	last_request_time: f64,
	request_pending:   bool,
	items_snapshot:    [dynamic]CompletionPopupItem,

	// Where the popup paints — rewritten each frame by the renderer so
	// the input path can hit-test mouse clicks (future) against the same
	// rect the user sees.
	panel_rectangle:   sdl3.FRect,
}

@(private)
CompletionPopupItem :: struct {
	label:       string, // owned
	detail:      string, // owned
	insert_text: string, // owned

	// Pre-measured pixel widths captured at snapshot time so the render
	// path doesn't have to round-trip TTF per item every frame. On a
	// long completion list this turns the per-frame measure loop from
	// O(N · TTF_call) into O(N · field_read) — the difference between
	// scrolling a 500-item list feeling stuck and feeling instant.
	label_pixel_width:  i32,
	detail_pixel_width: i32,
}

@(private)
completion_popup_destroy :: proc(popup: ^CompletionPopup) {
	completion_popup_clear_items(popup)
	if cap(popup.items_snapshot) > 0 { delete(popup.items_snapshot) }
	if cap(popup.filter_buffer)  > 0 { delete(popup.filter_buffer) }
	popup^ = CompletionPopup{}
}

@(private)
completion_popup_clear_items :: proc(popup: ^CompletionPopup) {
	for item in popup.items_snapshot {
		if len(item.label)       > 0 { delete(item.label) }
		if len(item.detail)      > 0 { delete(item.detail) }
		if len(item.insert_text) > 0 { delete(item.insert_text) }
	}
	clear(&popup.items_snapshot)
}

// --- Open / close ---------------------------------------------------------

@(private)
completion_popup_close :: proc(editor: ^Editor) {
	popup := &editor.completion_popup
	completion_popup_clear_items(popup)
	clear(&popup.filter_buffer)
	popup.is_visible       = false
	popup.request_pending  = false
	popup.selected_index   = 0
	popup.scroll_offset    = 0
}

// Bound to Ctrl+Space. Sends a completion request at the cursor and parks
// the popup in a "waiting" state until a response arrives.
@(private)
completion_popup_trigger_at_cursor :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	if len(editor_pane.file_path) == 0 { return }
	language_id := lsp_language_id_for(editor_pane.language); if len(language_id) == 0 { return }
	client, has_client := editor.lsp_clients[language_id]; if !has_client { return }

	// Don't even open the popup if the LSP isn't ready — the request
	// would be silently dropped, leaving the popup stuck on "loading…".
	if !client.is_initialized { return }
	if !editor_pane.lsp_did_open_sent { return }

	// Flush any debounced didChange so the server's view of the document
	// includes the keystroke that triggered this completion (e.g. the
	// auto-fire after typing `.`).
	editor_lsp_flush_pending_change(editor, editor_pane)

	completion_popup_close(editor)
	popup := &editor.completion_popup
	popup.is_visible        = true
	popup.pane_index        = editor.active_pane_index
	popup.anchor_line       = editor_pane.cursor_line
	popup.anchor_column     = editor_pane.cursor_column
	popup.last_request_time = editor.clock
	popup.request_pending   = true

	lsp.client_request_completion(client, editor_pane.file_path, i32(editor_pane.cursor_line), i32(editor_pane.cursor_column))
}

// --- Update tick ----------------------------------------------------------

// Called from `editor_lsp_update`. Picks up a fresh completion result from
// any client and copies it into the popup snapshot. Also closes the popup
// when the cursor moved off the anchor since the request was issued.
@(private)
completion_popup_update :: proc(editor: ^Editor) {
	popup := &editor.completion_popup
	if !popup.is_visible { return }

	// Sanity: the originating pane must still exist as an editor pane.
	if popup.pane_index < 0 || popup.pane_index >= len(editor.panes) { completion_popup_close(editor); return }
	editor_pane := pane_as_editor(&editor.panes[popup.pane_index]); if editor_pane == nil { completion_popup_close(editor); return }

	// Auto-close on context loss:
	//   * pane switch (user Ctrl+Tab'd away or clicked the other pane)
	//   * cursor on a different row than the trigger
	//   * cursor backspaced past the trigger column (column drifted left)
	// The third check accepts the cursor being slightly to the LEFT of
	// anchor because the trigger character itself sits between anchor and
	// the first typed filter char. One byte of slack is enough for the `.`
	// / `"` / `:` triggers we currently fire on.
	if popup.pane_index != editor.active_pane_index            { completion_popup_close(editor); return }
	if editor_pane.cursor_line != popup.anchor_line             { completion_popup_close(editor); return }
	if u32(editor_pane.cursor_column + 1) < popup.anchor_column { completion_popup_close(editor); return }

	if popup.request_pending {
		for _, client in editor.lsp_clients {
			if !client.completion.is_valid { continue }
			completion_popup_clear_items(popup)

			// One-shot UI context for the measurement pass — ui.text_size
			// only reads `font` so we can leave renderer nil. Measuring
			// each item once at snapshot time replaces the per-frame
			// re-measure that turned the popup sluggish on long lists.
			measure_context := ui.Context{
				font            = editor.font,
				engine          = editor.text_engine,
				character_width = editor.character_width,
				line_height     = editor.line_height,
			}

			for item in client.completion.items {
				label_copy  := strings.clone(item.label)
				detail_copy := strings.clone(item.detail)
				insert_copy := strings.clone(item.insert_text)
				label_width:  i32 = 0
				detail_width: i32 = 0
				if len(label_copy)  > 0 { label_width,  _ = ui.text_size(&measure_context, label_copy)  }
				if len(detail_copy) > 0 { detail_width, _ = ui.text_size(&measure_context, detail_copy) }
				append(&popup.items_snapshot, CompletionPopupItem{
					label              = label_copy,
					detail             = detail_copy,
					insert_text        = insert_copy,
					label_pixel_width  = label_width,
					detail_pixel_width = detail_width,
				})
			}
			popup.request_pending = false
			popup.selected_index  = 0
			popup.scroll_offset   = 0
			completion_acknowledge(client)
			break
		}
	}
}


@(private="file")
completion_acknowledge :: proc(client: ^lsp.Client) {
	// Fully release the strings + items dynamic now that the popup has
	// copied what it needs — without this, a one-shot Ctrl+Space leaks
	// the response until shutdown.
	lsp.completion_result_clear(&client.completion)
}

// --- Filtering / navigation ----------------------------------------------

@(private)
completion_popup_handle_key :: proc(editor: ^Editor, event: ^sdl3.Event) -> bool {
	popup := &editor.completion_popup
	if !popup.is_visible { return false }
	if event.type != .KEY_DOWN { return false }
	pressed_key := event.key.key
	switch pressed_key {
	case sdl3.K_ESCAPE:
		completion_popup_close(editor)
		return true
	case sdl3.K_UP:
		completion_popup_move(editor, -1)
		return true
	case sdl3.K_DOWN:
		completion_popup_move(editor, +1)
		return true
	case sdl3.K_PAGEUP:
		completion_popup_move(editor, -8)
		return true
	case sdl3.K_PAGEDOWN:
		completion_popup_move(editor, +8)
		return true
	case sdl3.K_RETURN, sdl3.K_TAB:
		completion_popup_accept(editor)
		return true
	}
	return false
}

@(private="file")
completion_popup_move :: proc(editor: ^Editor, delta: int) {
	popup := &editor.completion_popup
	filtered := completion_popup_filtered_indices(popup)
	defer delete(filtered)
	if len(filtered) == 0 { return }
	new_index := popup.selected_index + delta
	if new_index < 0                 { new_index = 0 }
	if new_index >= len(filtered)    { new_index = len(filtered) - 1 }
	popup.selected_index = new_index
}

// Returns indices into items_snapshot that match the current filter buffer.
// Caller owns the slice.
@(private="file")
completion_popup_filtered_indices :: proc(popup: ^CompletionPopup) -> []int {
	indices: [dynamic]int
	filter_string := string(popup.filter_buffer[:])
	filter_lower := strings.to_lower(filter_string, context.temp_allocator)
	for item, item_index in popup.items_snapshot {
		if len(filter_lower) == 0 {
			append(&indices, item_index)
			continue
		}
		label_lower := strings.to_lower(item.label, context.temp_allocator)
		if strings.contains(label_lower, filter_lower) {
			append(&indices, item_index)
		}
	}
	return indices[:]
}

// --- Accept ---------------------------------------------------------------

@(private="file")
completion_popup_accept :: proc(editor: ^Editor) {
	popup := &editor.completion_popup
	filtered := completion_popup_filtered_indices(popup); defer delete(filtered)
	if len(filtered) == 0 || popup.selected_index < 0 || popup.selected_index >= len(filtered) {
		completion_popup_close(editor)
		return
	}
	item_index := filtered[popup.selected_index]
	if item_index < 0 || item_index >= len(popup.items_snapshot) { completion_popup_close(editor); return }
	item := popup.items_snapshot[item_index]

	if popup.pane_index < 0 || popup.pane_index >= len(editor.panes) { completion_popup_close(editor); return }
	editor_pane := pane_as_editor(&editor.panes[popup.pane_index]); if editor_pane == nil { completion_popup_close(editor); return }

	// Replace the identifier prefix the user already typed (anchor_offset
	// .. cursor_offset) with the completion's insert_text. Walking back
	// from the anchor handles cursor moves between request and accept.
	cursor_offset := editor_pane.cursor_offset
	prefix_start  := cursor_offset
	for prefix_start > 0 {
		previous_byte := document_byte_at(editor_pane, prefix_start - 1)
		if !is_identifier_byte(previous_byte) { break }
		prefix_start -= 1
	}
	if prefix_start < cursor_offset {
		document.document_delete(&editor_pane.document, prefix_start, cursor_offset - prefix_start)
		editor_pane.cursor_offset = prefix_start
	}
	document.document_insert(&editor_pane.document, editor_pane.cursor_offset, item.insert_text)
	editor_pane.cursor_offset += u32(len(item.insert_text))
	pane_mark_document_modified(editor, editor_pane)
	sync_cursor_from_offset(editor)

	completion_popup_close(editor)
}

@(private="file")
document_byte_at :: proc(editor_pane: ^EditorPane, offset: u32) -> u8 {
	slice := document.document_get_slice(&editor_pane.document, offset, 1, context.temp_allocator)
	if len(slice) == 0 { return 0 }
	return slice[0]
}

@(private="file")
is_identifier_byte :: proc(byte_value: u8) -> bool {
	return (byte_value >= 'a' && byte_value <= 'z') ||
	       (byte_value >= 'A' && byte_value <= 'Z') ||
	       (byte_value >= '0' && byte_value <= '9') ||
	       byte_value == '_'
}

// --- Filter buffer mutation ------------------------------------------------

// Called from the editor's text-input handler so the popup tracks what the
// user is typing while it's open.
@(private)
completion_popup_consume_text :: proc(editor: ^Editor, input_text: string) -> bool {
	popup := &editor.completion_popup
	if !popup.is_visible || popup.request_pending { return false }
	if len(input_text) == 0 { return false }
	for byte_value in transmute([]u8)input_text { append(&popup.filter_buffer, byte_value) }
	popup.selected_index = 0
	popup.scroll_offset  = 0
	// Let the keystroke ALSO fall through to the document edit path so the
	// pane keeps recording what the user types. Returning false here.
	return false
}

@(private)
completion_popup_consume_backspace :: proc(editor: ^Editor) -> bool {
	popup := &editor.completion_popup
	if !popup.is_visible || popup.request_pending { return false }
	if len(popup.filter_buffer) == 0 { return false }
	new_end := len(popup.filter_buffer) - 1
	for new_end > 0 && (popup.filter_buffer[new_end] & 0xC0) == 0x80 { new_end -= 1 }
	resize(&popup.filter_buffer, new_end)
	return false
}

// --- Rendering -----------------------------------------------------------

@(private)
completion_popup_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, viewport_width, viewport_height: i32) {
	popup := &editor.completion_popup
	if !popup.is_visible { return }
	if popup.pane_index < 0 || popup.pane_index >= len(editor.panes) { return }
	pane := &editor.panes[popup.pane_index]
	editor_pane := pane_as_editor(pane); if editor_pane == nil { return }

	ui_context := editor_make_ui_context(editor, renderer)
	theme := ui.default_theme()

	// Filter and decide what's visible.
	filtered := completion_popup_filtered_indices(popup); defer delete(filtered)

	// Empty state — show a "loading…" / "no matches" stub line so the user
	// sees the popup do something.
	visible_lines := len(filtered)
	if visible_lines > 12 { visible_lines = 12 }
	stub_message := ""
	if popup.request_pending     { stub_message = "loading…" }
	else if visible_lines == 0   { stub_message = "no completions" }

	line_step          := editor.line_height
	character_width    := editor.character_width
	horizontal_padding: i32 = 8
	popup_min_width:    i32 = 28 * character_width
	popup_max_width:    i32 = 60 * character_width

	max_label_width: i32 = 0
	max_detail_width: i32 = 0
	if len(stub_message) > 0 {
		stub_width, _ := ui.text_size(&ui_context, stub_message)
		max_label_width = stub_width
	} else {
		// Pre-measured widths live on each item — this loop is now just
		// field reads plus comparisons. Hot path on big completion lists.
		for index in filtered {
			item := &popup.items_snapshot[index]
			if item.label_pixel_width  > max_label_width  { max_label_width  = item.label_pixel_width }
			if item.detail_pixel_width > max_detail_width { max_detail_width = item.detail_pixel_width }
		}
	}

	gap_between_columns: i32 = max_detail_width > 0 ? 16 : 0
	popup_width := horizontal_padding * 2 + max_label_width + gap_between_columns + max_detail_width
	if popup_width < popup_min_width { popup_width = popup_min_width }
	if popup_width > popup_max_width { popup_width = popup_max_width }

	row_count := visible_lines
	if len(stub_message) > 0 { row_count = 1 }
	popup_height := i32(row_count) * line_step + 8

	// Anchor below the cursor row.
	title_bar_height := editor_title_bar_height(editor)
	cursor_screen_y_top := pane.rectangle.y + title_bar_height + editor.padding_y + i32(popup.anchor_line) * line_step - i32(editor_pane.scroll_y)
	popup_y := cursor_screen_y_top + line_step + 2
	if popup_y + popup_height > viewport_height - 4 {
		popup_y = cursor_screen_y_top - popup_height - 2
		if popup_y < 4 { popup_y = 4 }
	}
	popup_x := pane.rectangle.x + i32(popup.anchor_column) * character_width + editor_pane.gutter_width + editor.padding_x
	if popup_x + popup_width > viewport_width - 4 {
		popup_x = viewport_width - 4 - popup_width
		if popup_x < 4 { popup_x = 4 }
	}

	popup.panel_rectangle = sdl3.FRect{f32(popup_x), f32(popup_y), f32(popup_width), f32(popup_height)}

	// Background + border.
	sdl3.SetRenderDrawColorFloat(renderer, editor.background_color.r, editor.background_color.g, editor.background_color.b, editor.background_color.a)
	sdl3.RenderFillRect(renderer, &popup.panel_rectangle)
	sdl3.SetRenderDrawColorFloat(renderer, editor.divider_color.r, editor.divider_color.g, editor.divider_color.b, editor.divider_color.a)
	sdl3.RenderRect(renderer, &popup.panel_rectangle)

	if len(stub_message) > 0 {
		render_string(editor, renderer, stub_message, popup_x + horizontal_padding, popup_y + 4, editor.line_number_color)
		_ = fmt.tprint  // keep core:fmt alive
		_ = theme       // theme reserved
		return
	}

	// Scroll so the selection is visible. Single-step scroll for now.
	if popup.selected_index < popup.scroll_offset                   { popup.scroll_offset = popup.selected_index }
	if popup.selected_index >= popup.scroll_offset + visible_lines  { popup.scroll_offset = popup.selected_index - visible_lines + 1 }
	if popup.scroll_offset < 0 { popup.scroll_offset = 0 }

	end_row := popup.scroll_offset + visible_lines
	if end_row > len(filtered) { end_row = len(filtered) }

	for visible_row_index in popup.scroll_offset..<end_row {
		item := popup.items_snapshot[filtered[visible_row_index]]
		row_y := popup_y + 4 + i32(visible_row_index - popup.scroll_offset) * line_step
		is_selected := visible_row_index == popup.selected_index
		if is_selected {
			highlight_rectangle := sdl3.FRect{f32(popup_x + 2), f32(row_y), f32(popup_width - 4), f32(line_step)}
			sdl3.SetRenderDrawColorFloat(renderer, editor.selection_color.r, editor.selection_color.g, editor.selection_color.b, editor.selection_color.a)
			sdl3.RenderFillRect(renderer, &highlight_rectangle)
		}
		label_color  := is_selected ? editor.cursor_color : editor.foreground_color
		detail_color := editor.line_number_color
		render_string(editor, renderer, item.label, popup_x + horizontal_padding, row_y, label_color)
		if len(item.detail) > 0 {
			detail_x := popup_x + popup_width - horizontal_padding
			detail_width := item.detail_pixel_width
			detail_x -= detail_width
			if detail_x < popup_x + horizontal_padding + max_label_width + gap_between_columns {
				detail_x = popup_x + horizontal_padding + max_label_width + gap_between_columns
			}
			render_string(editor, renderer, item.detail, detail_x, row_y, detail_color)
		}
	}
}

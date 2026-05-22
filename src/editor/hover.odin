package editor

import "vendor:sdl3"

import "../document"
import hover_pkg "./hover"
import "../lsp"

// Editor-side glue for the Ctrl+K hover popup. The popup state itself
// (visibility, anchor, parsed markdown, layout cache, render code) lives
// in the `hover` subpackage; this file owns the LSP request / response
// wiring + anchor-position computation against editor panes — both of
// which depend on `^Editor` and would drag the subpackage back into the
// editor if they lived there.

// Build a fresh snapshot of the host's cursor for the hover popup's
// auto-close stickiness check. `pane_is_editor` lets the popup treat a
// switch to a terminal / preview / output pane the same as the cursor
// moving off — we don't want the bubble lingering over unrelated content.
@(private="file")
hover_cursor_state :: proc(editor: ^Editor) -> hover_pkg.CursorState {
	cursor_state := hover_pkg.CursorState{
		active_pane_index = editor.active_pane_index,
	}
	if active_editor_pane := editor_active_editor_pane(editor); active_editor_pane != nil {
		cursor_state.cursor_line    = active_editor_pane.cursor_line
		cursor_state.cursor_column  = active_editor_pane.cursor_column
		cursor_state.pane_is_editor = true
	}
	return cursor_state
}

// Compute the on-screen anchor (cursor position) for the popup's renderer
// from the originating pane + the popup's stored anchor line.
@(private)
hover_anchor_screen_position :: proc(editor: ^Editor) -> hover_pkg.AnchorScreenPosition {
	popup := &editor.hover_popup
	if popup.anchor_pane_index < 0 || popup.anchor_pane_index >= len(editor.panes) { return {} }
	pane := &editor.panes[popup.anchor_pane_index]
	editor_pane := pane_as_editor(pane); if editor_pane == nil { return {} }

	title_bar_height    := editor_title_bar_height(editor)
	cursor_screen_top_y := pane.rectangle.y + title_bar_height + editor.padding_y + i32(popup.anchor_line) * editor.line_height - i32(editor_pane.scroll_y)

	return hover_pkg.AnchorScreenPosition{
		cursor_screen_top_y = cursor_screen_top_y,
		cursor_line_height  = editor.line_height,
		pane_left_x         = pane.rectangle.x,
		character_width     = editor.character_width,
	}
}

@(private)
hover_popup_close :: proc(editor: ^Editor) {
	hover_pkg.close(&editor.hover_popup)
	editor.hover_popup_request_pending = false
	for _, client in editor.lsp_clients {
		hover_acknowledge(client)
	}
}

// Bound to the Ctrl+K hotkey and the "Help on Symbol" menu item. Sends
// an LSP hover request at the active pane's cursor; the response is
// picked up by `hover_popup_update` next frame.
@(private)
hover_popup_request_at_cursor :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	if len(editor_pane.file_path) == 0 { return }
	language_id := lsp_language_id_for(editor_pane.language); if len(language_id) == 0 { return }
	client, has_client := editor.lsp_clients[language_id]; if !has_client { return }

	// Don't issue the request before the server's seen the file —
	// `client_request_hover` would otherwise no-op (or ols would reject
	// the unknown URI), leaving us waiting on a response that never comes.
	if !client.is_initialized        { return }
	if !editor_pane.lsp_did_open_sent { return }

	editor_lsp_flush_pending_change(editor, editor_pane)

	hover_popup_close(editor)
	lsp.client_request_hover(client, editor_pane.file_path, i32(editor_pane.cursor_line), i32(editor_pane.cursor_column))
	editor.hover_popup_request_pending = true

	// Default "stickiness" range: the identifier-like span around the
	// cursor. Tightens later when we pull the LSP hover `range` out of
	// the response — for now this keeps the popup from auto-closing the
	// instant the cursor moves by one character.
	range_start, range_end := identifier_span_around_cursor(editor_pane)
	hover_pkg.set_anchor(&editor.hover_popup, editor.active_pane_index,
		editor_pane.cursor_line, editor_pane.cursor_column,
		range_start, range_end)
}

// Called from `editor_lsp_update`. Polls for a fresh LSP hover result and
// hands it to the popup; runs the cursor-movement stickiness check
// either way so an open popup auto-closes when the user wanders off.
@(private)
hover_popup_update :: proc(editor: ^Editor) {
	if editor.hover_popup.visible {
		cursor_state := hover_cursor_state(editor)
		if hover_pkg.auto_close_if_cursor_moved(&editor.hover_popup, cursor_state) {
			editor.hover_popup_request_pending = false
			for _, client in editor.lsp_clients { hover_acknowledge(client) }
			return
		}
	}

	if !editor.hover_popup_request_pending { return }
	for _, client in editor.lsp_clients {
		if !client.hover.is_valid { continue }
		hover_pkg.set_content(&editor.hover_popup, client.hover.text)
		editor.hover_popup_request_pending = false
		hover_acknowledge(client)
		return
	}
}

@(private="file")
hover_acknowledge :: proc(client: ^lsp.Client) {
	// Release strings via the LSP module's owner so the cleanup logic
	// stays in one place. The editor only ever consumes a hover once
	// per request.
	lsp.hover_result_clear(&client.hover)
}

// Return the [start, end) column range of the identifier-like token
// under the cursor, expanded one byte outward to cover the cursor-just-
// past-token case. Used to compute the hover popup's stickiness range.
@(private="file")
identifier_span_around_cursor :: proc(editor_pane: ^EditorPane) -> (start_column, end_column: u32) {
	line_text := document.document_get_line(&editor_pane.document, editor_pane.cursor_line, context.temp_allocator)
	cursor_column := int(editor_pane.cursor_column)
	left  := cursor_column
	right := cursor_column
	for left > 0 && hover_is_identifier_byte(line_text[left - 1])           { left  -= 1 }
	for right < len(line_text) && hover_is_identifier_byte(line_text[right]) { right += 1 }
	// Pad one byte each side so a click-just-past the symbol still keeps
	// the popup open. Won't extend past line bounds because of the clamps.
	if left  > 0           { left  -= 1 }
	if right < len(line_text) { right += 1 }
	return u32(left), u32(right)
}

@(private="file")
hover_is_identifier_byte :: proc(byte_value: u8) -> bool {
	return (byte_value >= 'a' && byte_value <= 'z') ||
	       (byte_value >= 'A' && byte_value <= 'Z') ||
	       (byte_value >= '0' && byte_value <= '9') ||
	       byte_value == '_'
}

// --- Render orchestration -------------------------------------------------

@(private)
hover_popup_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, viewport_width, viewport_height: i32) {
	if !editor.hover_popup.visible { return }
	md_ctx := editor_markdown_context(editor, renderer)
	chrome := hover_pkg.Chrome{
		background = editor.status_bar_background,
		border     = editor.divider_color,
	}
	anchor := hover_anchor_screen_position(editor)
	hover_pkg.render(&editor.hover_popup, &md_ctx, chrome, viewport_width, viewport_height, anchor)
}

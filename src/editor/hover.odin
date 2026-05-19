package editor

import "core:strings"
import "vendor:sdl3"

import "../document"
import "../lsp"
import "../ui"

// Hover popup pinned next to the editor cursor. The text comes back from the
// LSP as markdown (ols emits ` ```odin … ``` ` for type signatures plus
// prose), so we reuse the markdown-preview block parser + block layout for
// rendering instead of treating the response as plain text.
//
// State layout mirrors MarkdownPreviewPane in miniature:
//   * `text` is the raw payload (kept so we can lay out fresh on resize).
//   * `blocks` is the parsed markdown — re-parsed when the text changes.
//   * `layouted_blocks` is the per-width measurement + ttf.Text* cache —
//     rebuilt when the popup width changes (which depends on the active
//     pane / window size).
@(private)
HoverPopup :: struct {
	is_visible:        bool,
	text:              string, // owned, raw markdown
	anchor_line:       u32,
	anchor_column:     u32,
	anchor_pane_index: int,
	// "Stickiness" range — while the cursor sits anywhere in this byte
	// span on `anchor_line`, the popup stays open. We seed it with a
	// generous default around the cursor and tighten it later if/when
	// we start pulling the LSP hover `range` field through.
	range_start_column: u32,
	range_end_column:   u32,

	blocks:            [dynamic]MarkdownBlock,
	layouted_blocks:   [dynamic]LayoutedBlock,
	layout_width:      i32,
}

@(private)
hover_popup_destroy :: proc(popup: ^HoverPopup) {
	markdown_clear_layouted_blocks(&popup.layouted_blocks)
	if cap(popup.layouted_blocks) > 0 { delete(popup.layouted_blocks) }
	markdown_clear_blocks(&popup.blocks)
	if cap(popup.blocks)          > 0 { delete(popup.blocks) }
	if len(popup.text) > 0 { delete(popup.text) }
	popup^ = HoverPopup{}
}

@(private)
hover_popup_close :: proc(editor: ^Editor) {
	hover_popup_destroy(&editor.hover_popup)
	editor.hover_popup_request_pending = false
	for _, client in editor.lsp_clients {
		hover_acknowledge(client)
	}
}

// Bound to the Ctrl+K hotkey and the "Help on Symbol" menu item. Sends an
// LSP hover request at the active pane's cursor; the response is picked up
// by `hover_popup_update` next frame.
@(private)
hover_popup_request_at_cursor :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	if len(editor_pane.file_path) == 0 { return }
	language_id := lsp_language_id_for(editor_pane.language); if len(language_id) == 0 { return }
	client, has_client := editor.lsp_clients[language_id]; if !has_client { return }

	// Don't issue the request before the server's seen the file —
	// `client_request_hover` would otherwise no-op (or ols would reject
	// the unknown URI), leaving us waiting on a response that never comes.
	if !client.is_initialized { return }
	if !editor_pane.lsp_did_open_sent { return }

	editor_lsp_flush_pending_change(editor, editor_pane)

	hover_popup_close(editor)
	lsp.client_request_hover(client, editor_pane.file_path, i32(editor_pane.cursor_line), i32(editor_pane.cursor_column))
	editor.hover_popup_request_pending  = true
	editor.hover_popup.anchor_line       = editor_pane.cursor_line
	editor.hover_popup.anchor_column     = editor_pane.cursor_column
	editor.hover_popup.anchor_pane_index = editor.active_pane_index

	// Default "stickiness" range: the identifier-like span around the cursor.
	// Tightens later if/when we pull the LSP hover `range` out of the
	// response — for now this keeps the popup from auto-closing the
	// instant the cursor moves by one character.
	range_start, range_end := identifier_span_around_cursor(editor_pane)
	editor.hover_popup.range_start_column = range_start
	editor.hover_popup.range_end_column   = range_end
}

// Return the [start, end) column range of the identifier-like token under
// the cursor, expanded one byte outward to cover the cursor-just-past-token
// case. Used to compute the hover popup's stickiness range.
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

// Called from `editor_lsp_update`. Surfaces a freshly-arrived hover result
// onto the popup state and clears the LSP-side flag so a subsequent request
// can fire cleanly. Parses the markdown body once here so the renderer's
// per-frame work is just layout + draw. Also auto-closes the popup when
// the cursor wanders off the symbol the request was anchored on.
@(private)
hover_popup_update :: proc(editor: ^Editor) {
	if editor.hover_popup.is_visible {
		popup := &editor.hover_popup
		// Auto-close on context loss: pane gone, pane switch, cursor on
		// a different row, or cursor outside the stickiness column range.
		if popup.anchor_pane_index < 0 || popup.anchor_pane_index >= len(editor.panes) { hover_popup_close(editor); return }
		if popup.anchor_pane_index != editor.active_pane_index                          { hover_popup_close(editor); return }
		editor_pane := pane_as_editor(&editor.panes[popup.anchor_pane_index]); if editor_pane == nil { hover_popup_close(editor); return }
		if editor_pane.cursor_line != popup.anchor_line                                 { hover_popup_close(editor); return }
		if editor_pane.cursor_column < popup.range_start_column ||
		   editor_pane.cursor_column > popup.range_end_column                           { hover_popup_close(editor); return }
	}

	if !editor.hover_popup_request_pending { return }
	for _, client in editor.lsp_clients {
		if !client.hover.is_valid { continue }
		text_copy := strings.clone(client.hover.text)

		// Capture every "where was the request issued" field before the
		// destroy() zeros the struct. Forgetting to snapshot any of these
		// makes the next-frame auto-close check immediately slam the
		// popup shut (range columns default to 0, so cursor_column > 0
		// trips the "off the symbol" guard).
		anchor_line         := editor.hover_popup.anchor_line
		anchor_column       := editor.hover_popup.anchor_column
		anchor_pane_index   := editor.hover_popup.anchor_pane_index
		range_start_column  := editor.hover_popup.range_start_column
		range_end_column    := editor.hover_popup.range_end_column

		hover_popup_destroy(&editor.hover_popup)
		editor.hover_popup.is_visible         = true
		editor.hover_popup.text               = text_copy
		editor.hover_popup.anchor_line        = anchor_line
		editor.hover_popup.anchor_column      = anchor_column
		editor.hover_popup.anchor_pane_index  = anchor_pane_index
		editor.hover_popup.range_start_column = range_start_column
		editor.hover_popup.range_end_column   = range_end_column

		// Parse markdown once; the renderer handles layout each frame.
		markdown_preview_parse_into(text_copy, &editor.hover_popup.blocks)

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

// --- Rendering ------------------------------------------------------------

@(private)
hover_popup_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, viewport_width, viewport_height: i32) {
	popup := &editor.hover_popup
	if !popup.is_visible || len(popup.text) == 0 || len(popup.blocks) == 0 { return }
	if popup.anchor_pane_index < 0 || popup.anchor_pane_index >= len(editor.panes) { return }

	pane := &editor.panes[popup.anchor_pane_index]
	editor_pane := pane_as_editor(pane); if editor_pane == nil { return }

	// Markdown fonts are loaded lazily on first F5; do the same here so a
	// user who's never opened a markdown preview still gets a styled popup.
	// Uses the editor-scale-aware loader so the very first hover popup
	// after a Ctrl+Wheel zoom still loads at the right size.
	markdown_fonts_ensure_loaded_at_editor_scale(&editor.markdown_fonts, editor.font_size)

	// Pick a sensible body-content width — clamped between a readable
	// minimum and ~70 chars of the editor's monospace, then to the viewport.
	character_width := editor.character_width; if character_width <= 0 { character_width = 8 }
	target_width:    i32 = character_width * 70
	if target_width > viewport_width - 60 { target_width = viewport_width - 60 }
	if target_width < character_width * 20 { target_width = character_width * 20 }

	horizontal_padding: i32 = 10
	vertical_padding:   i32 = 6
	usable_text_pixels := target_width

	// Re-layout when the chosen width drifts from what's cached — and the
	// first time around when nothing is laid out yet.
	if popup.layout_width != usable_text_pixels || len(popup.layouted_blocks) != len(popup.blocks) {
		markdown_clear_layouted_blocks(&popup.layouted_blocks)
		if cap(popup.layouted_blocks) < len(popup.blocks) {
			if cap(popup.layouted_blocks) > 0 { delete(popup.layouted_blocks) }
			popup.layouted_blocks = make([dynamic]LayoutedBlock, 0, len(popup.blocks), context.allocator)
		}
		for block_index in 0..<len(popup.blocks) {
			append(&popup.layouted_blocks, layout_block(editor, &popup.blocks[block_index], usable_text_pixels))
		}
		popup.layout_width = usable_text_pixels
	}

	// Sum block heights to pick the popup size. Trim a bit of trailing
	// whitespace so the bubble doesn't have dead space below the last line.
	total_content_height: i32 = 0
	for layouted in popup.layouted_blocks {
		total_content_height += layouted.height_pixels
	}

	popup_width  := usable_text_pixels + horizontal_padding * 2
	popup_height := total_content_height + vertical_padding * 2
	if popup_height > viewport_height - 40 { popup_height = viewport_height - 40 }

	// Anchor below the cursor row in the originating pane; flip above if
	// the bubble would otherwise clip the bottom of the window.
	body_line_height := editor.markdown_fonts.body_line_height
	if body_line_height <= 0 { body_line_height = editor.line_height }
	title_bar_height    := editor_title_bar_height(editor)
	cursor_screen_y_top := pane.rectangle.y + title_bar_height + editor.padding_y + i32(popup.anchor_line) * editor.line_height - i32(editor_pane.scroll_y)
	popup_y := cursor_screen_y_top + editor.line_height + 4
	if popup_y + popup_height > viewport_height - 4 {
		popup_y = cursor_screen_y_top - popup_height - 4
		if popup_y < 4 { popup_y = 4 }
	}
	popup_x := pane.rectangle.x + 24
	if popup_x + popup_width > viewport_width - 4 {
		popup_x = viewport_width - 4 - popup_width
		if popup_x < 4 { popup_x = 4 }
	}

	popup_rectangle := sdl3.FRect{f32(popup_x), f32(popup_y), f32(popup_width), f32(popup_height)}
	sdl3.SetRenderDrawColorFloat(renderer, editor.status_bar_background.r, editor.status_bar_background.g, editor.status_bar_background.b, editor.status_bar_background.a)
	sdl3.RenderFillRect(renderer, &popup_rectangle)
	sdl3.SetRenderDrawColorFloat(renderer, editor.divider_color.r, editor.divider_color.g, editor.divider_color.b, editor.divider_color.a)
	sdl3.RenderRect(renderer, &popup_rectangle)

	// Clip so block contents (especially code blocks with full-width
	// backgrounds) don't bleed outside the bubble.
	clip_rectangle := sdl3.Rect{popup_x, popup_y, popup_width, popup_height}
	sdl3.SetRenderClipRect(renderer, &clip_rectangle)
	defer sdl3.SetRenderClipRect(renderer, nil)

	content_x := popup_x + horizontal_padding
	current_y := popup_y + vertical_padding
	bottom_y  := popup_y + popup_height
	for layouted_index in 0..<len(popup.layouted_blocks) {
		layouted := &popup.layouted_blocks[layouted_index]
		block_height := layouted.height_pixels
		if current_y + block_height >= popup_y && current_y < bottom_y {
			markdown_render_layouted_block(editor, renderer, layouted, content_x, current_y, usable_text_pixels)
		}
		current_y += block_height
		if current_y >= bottom_y { break }
	}

	_ = document.document_length // keep core:document import
	_ = ui.Context{}             // keep core:ui import for future tweaks
}

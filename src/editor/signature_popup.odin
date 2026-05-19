package editor

import "core:fmt"
import "core:strings"
import "vendor:sdl3"

import "../lsp"

// Small popup that shows a procedure's signature while the user is inside
// the argument list. Triggered automatically when `(` is typed, refreshed
// on `,` / cursor moves within the same call, and closed by the matching
// `)`, Esc, a cursor jump to a different row, or the user moving back past
// the opening paren.
//
// Visually similar to the hover popup but content is just the signature
// label with the active parameter underlined; documentation, when ols
// provides it, renders as plain text below the signature.
@(private)
SignaturePopup :: struct {
	is_visible:        bool,
	pane_index:        int,
	anchor_line:       u32,
	open_paren_offset: u32,    // byte offset of the `(` that triggered the popup
	request_pending:   bool,

	// If a `,` (or another paren-list cursor move) arrives while a previous
	// request is still in flight, we DON'T fire a second one — that'd pile
	// up on a slow server. We just flip this flag; the moment the in-flight
	// response lands, the update path immediately fires the latest position
	// and clears the flag. End state always converges on the cursor's
	// current location.
	needs_refresh:     bool,

	// Snapshotted from the latest server response so re-renders don't
	// need to peek at the LSP client's state.
	signature_label:   string, // owned
	documentation:     string, // owned
	active_start:      i32,    // byte range of the highlighted parameter within `signature_label`
	active_end:        i32,

	// Markdown render cache for the `documentation` portion. Parsed once
	// on each fresh response, laid out lazily on render at the popup
	// width. Mirrors HoverPopup's cache so the two popups share the same
	// markdown infrastructure.
	doc_blocks:           [dynamic]MarkdownBlock,
	doc_layouted_blocks:  [dynamic]LayoutedBlock,
	doc_layout_width:     i32,
}

@(private)
signature_popup_destroy :: proc(popup: ^SignaturePopup) {
	markdown_clear_layouted_blocks(&popup.doc_layouted_blocks)
	if cap(popup.doc_layouted_blocks) > 0 { delete(popup.doc_layouted_blocks) }
	markdown_clear_blocks(&popup.doc_blocks)
	if cap(popup.doc_blocks) > 0 { delete(popup.doc_blocks) }
	if len(popup.signature_label) > 0 { delete(popup.signature_label) }
	if len(popup.documentation)   > 0 { delete(popup.documentation) }
	popup^ = SignaturePopup{}
}

@(private)
signature_popup_close :: proc(editor: ^Editor) {
	signature_popup_destroy(&editor.signature_popup)
	for _, client in editor.lsp_clients {
		signature_acknowledge(client)
	}
}

@(private="file")
signature_acknowledge :: proc(client: ^lsp.Client) {
	// Fully release the signatures array + every owned label/doc/range
	// inside it. Skipping this would leak everything past the last
	// signature request until editor shutdown.
	lsp.signature_help_result_clear(&client.signature_help)
}

// Fired from the text-input path when the user types `(` (or `,` to nudge
// the active-parameter underline along). Opens or refreshes the popup; the
// in-flight request, if any, is coalesced rather than stacked.
@(private)
signature_popup_request_at_cursor :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	if len(editor_pane.file_path) == 0 { return }
	language_id := lsp_language_id_for(editor_pane.language); if len(language_id) == 0 { return }
	client, has_client := editor.lsp_clients[language_id]; if !has_client { return }
	if !client.is_initialized               { return }
	if !editor_pane.lsp_did_open_sent       { return }

	editor_lsp_flush_pending_change(editor, editor_pane)

	popup := &editor.signature_popup

	// First-time open (popup not visible) — reset state and capture the
	// `(` position. Subsequent refreshes (typing `,` while the popup is
	// already up) keep the existing anchor/pane and just update the
	// position the LSP is asked about.
	if !popup.is_visible {
		signature_popup_destroy(popup)
		popup.is_visible         = true
		popup.pane_index         = editor.active_pane_index
		popup.anchor_line        = editor_pane.cursor_line
		popup.open_paren_offset  = editor_pane.cursor_offset
	}

	// Coalesce: if a previous request is still in flight, just mark that
	// we need another fire after it lands. Avoids piling up requests on
	// slow servers while the user is mashing through arguments.
	if popup.request_pending {
		popup.needs_refresh = true
		return
	}

	popup.request_pending = true
	lsp.client_request_signature_help(client, editor_pane.file_path, i32(editor_pane.cursor_line), i32(editor_pane.cursor_column))
}

// Called from `editor_lsp_update`. Copies fresh signature data into the
// popup, also auto-closes when the cursor has moved off the call expression.
@(private)
signature_popup_update :: proc(editor: ^Editor) {
	popup := &editor.signature_popup
	if !popup.is_visible { return }

	// Auto-close on context loss: cursor on a different row, cursor before
	// the opening paren, or the originating pane is gone.
	if popup.pane_index < 0 || popup.pane_index >= len(editor.panes) { signature_popup_close(editor); return }
	editor_pane := pane_as_editor(&editor.panes[popup.pane_index]); if editor_pane == nil { signature_popup_close(editor); return }
	if editor_pane.cursor_line != popup.anchor_line                  { signature_popup_close(editor); return }
	if editor_pane.cursor_offset < popup.open_paren_offset           { signature_popup_close(editor); return }

	if !popup.request_pending { return }

	for _, client in editor.lsp_clients {
		if !client.signature_help.is_valid { continue }
		popup.request_pending = false

		// No signatures from the server (or null result) — keep the popup
		// closed rather than showing an empty rectangle.
		if len(client.signature_help.signatures) == 0 {
			signature_popup_close(editor)
			return
		}

		active_signature_index := client.signature_help.active_signature
		if active_signature_index < 0                                       { active_signature_index = 0 }
		if active_signature_index >= len(client.signature_help.signatures)  { active_signature_index = len(client.signature_help.signatures) - 1 }

		signature := client.signature_help.signatures[active_signature_index]
		active_parameter_index := client.signature_help.active_parameter
		if active_parameter_index < 0                                            { active_parameter_index = 0 }
		if active_parameter_index >= len(signature.parameter_ranges)             { active_parameter_index = -1 }

		// Free previous strings + the markdown cache before overwriting.
		markdown_clear_layouted_blocks(&popup.doc_layouted_blocks)
		markdown_clear_blocks(&popup.doc_blocks)
		popup.doc_layout_width = 0
		if len(popup.signature_label) > 0 { delete(popup.signature_label); popup.signature_label = "" }
		if len(popup.documentation)   > 0 { delete(popup.documentation);   popup.documentation   = "" }

		popup.signature_label = strings.clone(signature.label)
		popup.documentation   = strings.clone(signature.documentation)

		// Parse the docs markdown once; layout happens lazily during render.
		if len(popup.documentation) > 0 {
			markdown_preview_parse_into(popup.documentation, &popup.doc_blocks)
		}
		popup.active_start    = -1
		popup.active_end      = -1
		if active_parameter_index >= 0 {
			active_range := signature.parameter_ranges[active_parameter_index]
			popup.active_start = active_range.start_byte
			popup.active_end   = active_range.end_byte
		}

		signature_acknowledge(client)

		// If `,` (or another paren-list move) arrived while we were
		// waiting, fire one more request now against the live cursor so
		// the active-parameter underline catches up.
		if popup.needs_refresh {
			popup.needs_refresh = false
			signature_popup_request_at_cursor(editor)
		}
		return
	}
}

// --- Render ---------------------------------------------------------------

@(private)
signature_popup_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, viewport_width, viewport_height: i32) {
	popup := &editor.signature_popup
	if !popup.is_visible || len(popup.signature_label) == 0 { return }
	if popup.pane_index < 0 || popup.pane_index >= len(editor.panes) { return }
	pane := &editor.panes[popup.pane_index]
	editor_pane := pane_as_editor(pane); if editor_pane == nil { return }

	markdown_fonts_ensure_loaded_at_editor_scale(&editor.markdown_fonts, editor.font_size)

	horizontal_padding: i32 = 10
	vertical_padding:   i32 = 6
	character_width    := editor.character_width
	line_step          := editor.line_height

	signature_width, _ := signature_popup_text_size(editor, popup.signature_label)

	// Pick a width that comfortably holds the signature and is wide enough
	// for the markdown docs to flow without wrapping each phrase.
	popup_width := signature_width + horizontal_padding * 2
	preferred_width := character_width * 70
	if popup_width < preferred_width  { popup_width = preferred_width }
	if popup_width > viewport_width - 40 { popup_width = viewport_width - 40 }

	docs_usable_pixels := popup_width - horizontal_padding * 2

	// (Re-)layout markdown docs whenever the popup width changes (or on
	// the first frame after a fresh response). Mirrors HoverPopup's logic.
	docs_height: i32 = 0
	if len(popup.doc_blocks) > 0 {
		if popup.doc_layout_width != docs_usable_pixels || len(popup.doc_layouted_blocks) != len(popup.doc_blocks) {
			markdown_clear_layouted_blocks(&popup.doc_layouted_blocks)
			if cap(popup.doc_layouted_blocks) < len(popup.doc_blocks) {
				if cap(popup.doc_layouted_blocks) > 0 { delete(popup.doc_layouted_blocks) }
				popup.doc_layouted_blocks = make([dynamic]LayoutedBlock, 0, len(popup.doc_blocks), context.allocator)
			}
			for block_index in 0..<len(popup.doc_blocks) {
				append(&popup.doc_layouted_blocks, layout_block(editor, &popup.doc_blocks[block_index], docs_usable_pixels))
			}
			popup.doc_layout_width = docs_usable_pixels
		}
		for layouted in popup.doc_layouted_blocks {
			docs_height += layouted.height_pixels
		}
	}

	signature_row_height := line_step
	body_gap_between_sig_and_docs: i32 = docs_height > 0 ? 4 : 0
	popup_height := vertical_padding + signature_row_height + body_gap_between_sig_and_docs + docs_height + vertical_padding
	if popup_height > viewport_height - 40 { popup_height = viewport_height - 40 }

	// Anchor above the cursor row so the popup sits where it blocks the
	// least typing; flip below if it would clip the top of the pane.
	title_bar_height := editor_title_bar_height(editor)
	cursor_screen_y_top := pane.rectangle.y + title_bar_height + editor.padding_y + i32(popup.anchor_line) * line_step - i32(editor_pane.scroll_y)
	popup_y := cursor_screen_y_top - popup_height - 2
	if popup_y < pane.rectangle.y + title_bar_height + 2 {
		popup_y = cursor_screen_y_top + line_step + 2
	}
	popup_x := pane.rectangle.x + editor.padding_x + editor_pane.gutter_width
	if popup_x + popup_width > viewport_width - 4 {
		popup_x = viewport_width - 4 - popup_width
		if popup_x < 4 { popup_x = 4 }
	}

	popup_rectangle := sdl3.FRect{f32(popup_x), f32(popup_y), f32(popup_width), f32(popup_height)}
	sdl3.SetRenderDrawColorFloat(renderer, editor.status_bar_background.r, editor.status_bar_background.g, editor.status_bar_background.b, editor.status_bar_background.a)
	sdl3.RenderFillRect(renderer, &popup_rectangle)
	sdl3.SetRenderDrawColorFloat(renderer, editor.divider_color.r, editor.divider_color.g, editor.divider_color.b, editor.divider_color.a)
	sdl3.RenderRect(renderer, &popup_rectangle)

	clip_rectangle := sdl3.Rect{popup_x, popup_y, popup_width, popup_height}
	sdl3.SetRenderClipRect(renderer, &clip_rectangle)
	defer sdl3.SetRenderClipRect(renderer, nil)

	// Signature line: monospace + active-param underline.
	signature_y := popup_y + vertical_padding
	render_string(editor, renderer, popup.signature_label, popup_x + horizontal_padding, signature_y, editor.cursor_color)
	if popup.active_start >= 0 && popup.active_end > popup.active_start && int(popup.active_end) <= len(popup.signature_label) {
		prefix_width:    i32 = 0
		active_width:    i32 = 0
		if popup.active_start > 0 {
			prefix_width, _ = signature_popup_text_size(editor, popup.signature_label[:popup.active_start])
		}
		active_width, _ = signature_popup_text_size(editor, popup.signature_label[popup.active_start:popup.active_end])

		underline_y := signature_y + line_step - 2
		underline_color := editor.syntax_keyword_foreground
		sdl3.SetRenderDrawColorFloat(renderer, underline_color.r, underline_color.g, underline_color.b, underline_color.a)
		sdl3.RenderLine(renderer, f32(popup_x + horizontal_padding + prefix_width), f32(underline_y), f32(popup_x + horizontal_padding + prefix_width + active_width - 1), f32(underline_y))
		render_string(editor, renderer, popup.signature_label[popup.active_start:popup.active_end], popup_x + horizontal_padding + prefix_width, signature_y, underline_color)
	}

	// Markdown docs below the signature. Reuses the preview's per-block
	// renderer; code spans / fences / bold etc. now look the same as in
	// hover and F5.
	if len(popup.doc_layouted_blocks) > 0 {
		docs_origin_x := popup_x + horizontal_padding
		current_y := signature_y + signature_row_height + body_gap_between_sig_and_docs
		bottom_y  := popup_y + popup_height - vertical_padding
		for layouted_index in 0..<len(popup.doc_layouted_blocks) {
			layouted := &popup.doc_layouted_blocks[layouted_index]
			block_height := layouted.height_pixels
			if current_y + block_height >= popup_y && current_y < bottom_y {
				markdown_render_layouted_block(editor, renderer, layouted, docs_origin_x, current_y, docs_usable_pixels)
			}
			current_y += block_height
			if current_y >= bottom_y { break }
		}
	}

	_ = fmt.tprint // keep core:fmt import alive
}

@(private="file")
signature_popup_text_size :: proc(editor: ^Editor, text: string) -> (width, height: i32) {
	if len(text) == 0 || editor.character_width <= 0 { return 0, editor.line_height }
	// Use the editor's monospace metrics — signatures look right in
	// monospace regardless of whether the markdown body font is loaded.
	return i32(len(text)) * editor.character_width, editor.line_height
}

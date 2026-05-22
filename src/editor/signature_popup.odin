package editor

import "vendor:sdl3"

import "../lsp"
import signature_popup_pkg "./signature_popup"

// Editor-side glue for the signature-help popup. State + render live in
// the `signature_popup` subpackage; this file owns the LSP request /
// response wiring and computes the on-screen anchor position from pane
// + cursor state — both of which need `^Editor` and would drag the
// subpackage back into the editor if they lived there.

@(private)
signature_popup_close :: proc(editor: ^Editor) {
	signature_popup_pkg.close(&editor.signature_popup)
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

// Fired from the text-input path when the user types `(` (or `,` to
// nudge the active-parameter underline along). Opens or refreshes the
// popup; the in-flight request, if any, is coalesced rather than stacked.
@(private)
signature_popup_request_at_cursor :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	if len(editor_pane.file_path) == 0 { return }
	language_id := lsp_language_id_for(editor_pane.language); if len(language_id) == 0 { return }
	client, has_client := editor.lsp_clients[language_id]; if !has_client { return }
	if !client.is_initialized        { return }
	if !editor_pane.lsp_did_open_sent { return }

	editor_lsp_flush_pending_change(editor, editor_pane)

	signature_popup_pkg.open(&editor.signature_popup, editor.active_pane_index, editor_pane.cursor_line, editor_pane.cursor_offset)

	// Coalesce: if a request is already in flight, just flip the "refire
	// when it lands" flag and skip the actual spawn. Avoids piling up
	// requests on slow servers while the user is mashing through args.
	if signature_popup_pkg.should_coalesce_request(&editor.signature_popup) { return }

	signature_popup_pkg.mark_request_pending(&editor.signature_popup)
	lsp.client_request_signature_help(client, editor_pane.file_path, i32(editor_pane.cursor_line), i32(editor_pane.cursor_column))
}

// Called from `editor_lsp_update`. Drives the stickiness auto-close, and
// pulls a fresh LSP response into the popup when one is available.
@(private)
signature_popup_update :: proc(editor: ^Editor) {
	popup := &editor.signature_popup
	if !popup.visible { return }

	if signature_popup_pkg.auto_close_if_cursor_moved(popup, signature_cursor_state(editor)) {
		for _, client in editor.lsp_clients { signature_acknowledge(client) }
		return
	}

	if !popup.request_pending { return }

	for _, client in editor.lsp_clients {
		if !client.signature_help.is_valid { continue }

		// No signatures from the server (or null result) — keep the
		// popup closed rather than showing an empty rectangle.
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

		content := signature_popup_pkg.Content{
			signature_label = signature.label,
			documentation   = signature.documentation,
			active_start    = -1,
			active_end      = -1,
		}
		if active_parameter_index >= 0 {
			active_range := signature.parameter_ranges[active_parameter_index]
			content.active_start = active_range.start_byte
			content.active_end   = active_range.end_byte
		}

		needs_refire := signature_popup_pkg.set_content(popup, content)
		signature_acknowledge(client)

		// If a `,` (or another paren-list move) arrived while we were
		// waiting, fire one more request now against the live cursor so
		// the active-parameter underline catches up.
		if needs_refire {
			signature_popup_request_at_cursor(editor)
		}
		return
	}
}

@(private="file")
signature_cursor_state :: proc(editor: ^Editor) -> signature_popup_pkg.CursorState {
	cursor_state := signature_popup_pkg.CursorState{
		pane_index = editor.active_pane_index,
	}
	if active_editor_pane := editor_active_editor_pane(editor); active_editor_pane != nil {
		cursor_state.cursor_line    = active_editor_pane.cursor_line
		cursor_state.cursor_offset  = active_editor_pane.cursor_offset
		cursor_state.pane_is_editor = true
	}
	return cursor_state
}

// --- Render orchestration -------------------------------------------------

@(private)
signature_popup_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, viewport_width, viewport_height: i32) {
	popup := &editor.signature_popup
	if !popup.visible { return }
	if popup.pane_index < 0 || popup.pane_index >= len(editor.panes) { return }
	pane := &editor.panes[popup.pane_index]
	editor_pane := pane_as_editor(pane); if editor_pane == nil { return }

	md_ctx := editor_markdown_context(editor, renderer)
	chrome := signature_popup_pkg.Chrome{
		background             = editor.status_bar_background,
		border                 = editor.divider_color,
		signature_color        = editor.cursor_color,
		active_underline_color = editor.syntax_keyword_foreground,
	}
	title_bar_height    := editor_title_bar_height(editor)
	cursor_screen_top_y := pane.rectangle.y + title_bar_height + editor.padding_y + i32(popup.anchor_line) * editor.line_height - i32(editor_pane.scroll_y)
	anchor := signature_popup_pkg.AnchorScreenPosition{
		cursor_screen_top_y = cursor_screen_top_y,
		cursor_line_height  = editor.line_height,
		character_width     = editor.character_width,
		text_left_x         = pane.rectangle.x + editor.padding_x + editor_pane.gutter_width,
		pane_top_y          = pane.rectangle.y + title_bar_height,
	}
	signature_popup_pkg.render(popup, &md_ctx, chrome, viewport_width, viewport_height, anchor)
}

package editor

import "vendor:sdl3"

import "../document"
import "../lsp"
import completion_popup_pkg "./completion_popup"

// Editor-side glue for the Ctrl+Space LSP completion popup. State +
// render live in the `completion_popup` subpackage; this file owns the
// LSP request / response wiring, the document edit that applies an
// accepted completion, and computes the on-screen anchor from pane +
// font state.

@(private)
completion_popup_close :: proc(editor: ^Editor) {
	completion_popup_pkg.close(&editor.completion_popup)
}

// Bound to Ctrl+Space. Sends a completion request at the cursor and
// parks the popup in a "waiting" state until a response arrives.
@(private)
completion_popup_trigger_at_cursor :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	if len(editor_pane.file_path) == 0 { return }
	language_id := lsp_language_id_for(editor_pane.language); if len(language_id) == 0 { return }
	client, has_client := editor.lsp_clients[language_id]; if !has_client { return }

	// Don't even open the popup if the LSP isn't ready — the request
	// would be silently dropped, leaving the popup stuck on "loading…".
	if !client.is_initialized        { return }
	if !editor_pane.lsp_did_open_sent { return }

	// Flush any debounced didChange so the server's view of the document
	// includes the keystroke that triggered this completion (e.g. the
	// auto-fire after typing `.`).
	editor_lsp_flush_pending_change(editor, editor_pane)

	completion_popup_pkg.open(&editor.completion_popup, editor.active_pane_index, editor_pane.cursor_line, editor_pane.cursor_column)

	lsp.client_request_completion(client, editor_pane.file_path, i32(editor_pane.cursor_line), i32(editor_pane.cursor_column))
}

// Called from `editor_lsp_update`. Drives the cursor-drift auto-close,
// and drains any fresh LSP completion result into the popup snapshot.
@(private)
completion_popup_update :: proc(editor: ^Editor) {
	popup := &editor.completion_popup
	if !popup.visible { return }

	if completion_popup_pkg.auto_close_if_cursor_moved(popup, completion_cursor_state(editor)) { return }

	if !popup.request_pending { return }

	for _, client in editor.lsp_clients {
		if !client.completion.is_valid { continue }

		// Build the lightweight source-list view for the popup. The
		// popup clones strings into its own storage; the
		// `lsp.completion_result_clear` below frees the server-side
		// copies.
		sources := make([]completion_popup_pkg.ItemSource, len(client.completion.items), context.temp_allocator)
		for item, item_index in client.completion.items {
			sources[item_index] = completion_popup_pkg.ItemSource{
				label       = item.label,
				detail      = item.detail,
				insert_text = item.insert_text,
			}
		}
		ui_context := editor_make_ui_context(editor, nil) // measurement only — renderer not needed
		completion_popup_pkg.set_items(popup, &ui_context, sources)
		completion_acknowledge(client)
		break
	}
}

@(private="file")
completion_acknowledge :: proc(client: ^lsp.Client) {
	// Fully release the strings + items dynamic now that the popup has
	// copied what it needs — without this, a one-shot Ctrl+Space leaks
	// the response until shutdown.
	lsp.completion_result_clear(&client.completion)
}

@(private="file")
completion_cursor_state :: proc(editor: ^Editor) -> completion_popup_pkg.CursorState {
	cursor_state := completion_popup_pkg.CursorState{
		pane_index = editor.active_pane_index,
	}
	if active_editor_pane := editor_active_editor_pane(editor); active_editor_pane != nil {
		cursor_state.cursor_line    = active_editor_pane.cursor_line
		cursor_state.cursor_column  = active_editor_pane.cursor_column
		cursor_state.pane_is_editor = true
	}
	return cursor_state
}

// --- Input dispatch -------------------------------------------------------

@(private)
completion_popup_handle_key :: proc(editor: ^Editor, event: ^sdl3.Event) -> bool {
	intent, consumed, needs_redraw := completion_popup_pkg.handle_key(&editor.completion_popup, event)
	if needs_redraw { editor_mark_dirty(editor) }
	if intent != nil {
		#partial switch accept in intent {
		case completion_popup_pkg.Accept:
			apply_completion_accept(editor, accept.insert_text)
		}
	}
	return consumed
}

// Insert the completion's text at the cursor, first replacing whatever
// identifier prefix the user already typed (walks back over a-zA-Z0-9_).
// Mirrors the original inline `completion_popup_accept` body — kept here
// because it needs `^Editor` and the document API.
@(private="file")
apply_completion_accept :: proc(editor: ^Editor, insert_text: string) {
	popup := &editor.completion_popup
	if popup.pane_index < 0 || popup.pane_index >= len(editor.panes) { return }
	editor_pane := pane_as_editor(&editor.panes[popup.pane_index]); if editor_pane == nil { return }

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
	document.document_insert(&editor_pane.document, editor_pane.cursor_offset, insert_text)
	editor_pane.cursor_offset += u32(len(insert_text))
	pane_mark_document_modified(editor, editor_pane)
	sync_cursor_from_offset(editor)
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

// --- Filter buffer pass-through ------------------------------------------

@(private)
completion_popup_consume_text :: proc(editor: ^Editor, input_text: string) -> bool {
	consumed, needs_redraw := completion_popup_pkg.consume_text(&editor.completion_popup, input_text)
	if needs_redraw { editor_mark_dirty(editor) }
	return consumed
}

@(private)
completion_popup_consume_backspace :: proc(editor: ^Editor) -> bool {
	consumed, needs_redraw := completion_popup_pkg.consume_backspace(&editor.completion_popup)
	if needs_redraw { editor_mark_dirty(editor) }
	return consumed
}

// --- Render orchestration ------------------------------------------------

@(private)
completion_popup_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, viewport_width, viewport_height: i32) {
	popup := &editor.completion_popup
	if !popup.visible { return }
	if popup.pane_index < 0 || popup.pane_index >= len(editor.panes) { return }
	pane := &editor.panes[popup.pane_index]
	editor_pane := pane_as_editor(pane); if editor_pane == nil { return }

	ui_context := editor_make_ui_context(editor, renderer)

	chrome := completion_popup_pkg.Chrome{
		background     = editor.background_color,
		border         = editor.divider_color,
		selection      = editor.selection_color,
		label          = editor.foreground_color,
		label_selected = editor.cursor_color,
		detail         = editor.line_number_color,
		stub           = editor.line_number_color,
	}

	title_bar_height    := editor_title_bar_height(editor)
	cursor_screen_top_y := pane.rectangle.y + title_bar_height + editor.padding_y + i32(popup.anchor_line) * editor.line_height - i32(editor_pane.scroll_y)
	cursor_screen_x     := pane.rectangle.x + i32(popup.anchor_column) * editor.character_width + editor_pane.gutter_width + editor.padding_x

	anchor := completion_popup_pkg.AnchorScreenPosition{
		cursor_screen_top_y = cursor_screen_top_y,
		cursor_line_height  = editor.line_height,
		character_width     = editor.character_width,
		cursor_screen_x     = cursor_screen_x,
	}

	completion_popup_pkg.render(popup, &ui_context, chrome, anchor, viewport_width, viewport_height)
}

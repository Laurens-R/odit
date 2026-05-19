package editor

import "core:fmt"
import "core:strings"
import "vendor:sdl3"

import "../document"
import "../ui"

// --- Types ----------------------------------------------------------------

// Where the open document lives at the moment the F4 dialog is open. The
// active pane's doc is listed too — selecting it is a no-op, but its absence
// would read as "the file I'm looking at is gone" when scanning the list.
@(private)
OpenDocsEntryLocation :: enum {
	ActivePane,
	OtherPane,
	Background,
}

@(private)
OpenDocsEntry :: struct {
	location:         OpenDocsEntryLocation,
	pane_index:       int,    // valid when location == .OtherPane
	background_index: int,    // valid when location == .Background; index into Editor.background_documents
	is_dirty:         bool,
	label:            string, // owned; the user-visible text used for both display and filtering
}

@(private)
OpenDocsDialog :: struct {
	source_pane_index: int,             // pane the user opened the dialog from — target for "switch to" actions
	entries:           [dynamic]OpenDocsEntry,
	filtered_indices:  [dynamic]int,
	filter_buffer:     [dynamic]u8,
	selected_index:    int,
	scroll_offset:     int,
	visible_row_count: int,
}

// --- Lifecycle ------------------------------------------------------------

@(private)
open_docs_dialog_destroy :: proc(dialog: ^OpenDocsDialog) {
	open_docs_clear_entries(dialog)
	if cap(dialog.entries)          > 0 { delete(dialog.entries) }
	if cap(dialog.filtered_indices) > 0 { delete(dialog.filtered_indices) }
	if cap(dialog.filter_buffer)    > 0 { delete(dialog.filter_buffer) }
	dialog^ = OpenDocsDialog{}
}

@(private="file")
open_docs_clear_entries :: proc(dialog: ^OpenDocsDialog) {
	for entry in dialog.entries {
		if len(entry.label) > 0 { delete(entry.label) }
	}
	clear(&dialog.entries)
}

@(private)
open_docs_dialog_open :: proc(editor: ^Editor) {
	// Only meaningful on an editor pane — picking a doc would try to swap
	// into a terminal / markdown preview otherwise.
	if editor_active_editor_pane(editor) == nil { return }

	dialog := &editor.open_docs_dialog
	dialog.source_pane_index = editor.active_pane_index
	dialog.selected_index    = 0
	dialog.scroll_offset     = 0
	clear(&dialog.filter_buffer)
	open_docs_rebuild_entries(editor, dialog)
	open_docs_apply_filter(editor)
	editor.show_open_docs = true
}

@(private)
open_docs_dialog_close :: proc(editor: ^Editor) {
	editor.show_open_docs = false
	open_docs_clear_entries(&editor.open_docs_dialog)
	clear(&editor.open_docs_dialog.filtered_indices)
}

// --- Entry construction ---------------------------------------------------

@(private="file")
open_docs_rebuild_entries :: proc(editor: ^Editor, dialog: ^OpenDocsDialog) {
	open_docs_clear_entries(dialog)

	// Source pane (active) first so the user's current doc is the top row —
	// gives them an anchor for the rest of the list.
	if source_editor_pane := pane_as_editor(&editor.panes[dialog.source_pane_index]); source_editor_pane != nil {
		append(&dialog.entries, OpenDocsEntry{
			location   = .ActivePane,
			pane_index = dialog.source_pane_index,
			is_dirty   = document.document_is_dirty(&source_editor_pane.document),
			label      = open_docs_format_label(source_editor_pane, dialog.source_pane_index, .ActivePane),
		})
	}

	// Other-pane doc, if a split is active.
	if editor.split_active {
		for visible_pane_index in 0..<len(editor.panes) {
			if visible_pane_index == dialog.source_pane_index { continue }
			other_editor_pane := pane_as_editor(&editor.panes[visible_pane_index])
			if other_editor_pane == nil { continue }
			append(&dialog.entries, OpenDocsEntry{
				location   = .OtherPane,
				pane_index = visible_pane_index,
				is_dirty   = document.document_is_dirty(&other_editor_pane.document),
				label      = open_docs_format_label(other_editor_pane, visible_pane_index, .OtherPane),
			})
		}
	}

	// Background documents — listed most-recently-stashed first so the user's
	// previous doc is the top suggestion.
	for reverse_index := len(editor.background_documents) - 1; reverse_index >= 0; reverse_index -= 1 {
		background_editor_pane := &editor.background_documents[reverse_index]
		append(&dialog.entries, OpenDocsEntry{
			location         = .Background,
			background_index = reverse_index,
			is_dirty         = document.document_is_dirty(&background_editor_pane.document),
			label            = open_docs_format_label(background_editor_pane, -1, .Background),
		})
	}
}

@(private="file")
open_docs_format_label :: proc(editor_pane: ^EditorPane, pane_index: int, location: OpenDocsEntryLocation) -> string {
	dirty_marker := document.document_is_dirty(&editor_pane.document) ? "* " : "  "

	display_name: string
	full_path:    string
	switch {
	case len(editor_pane.display_title_override) > 0:
		display_name = editor_pane.display_title_override
	case len(editor_pane.file_path) > 0:
		display_name = open_docs_filepath_base(editor_pane.file_path)
		full_path    = editor_pane.file_path
	case:
		display_name = "untitled"
	}

	location_tag: string
	switch location {
	case .ActivePane: location_tag = "[active]"
	case .OtherPane:  location_tag = fmt.tprintf("[Pane %d]", pane_index + 1)
	case .Background: location_tag = ""
	}

	if len(full_path) > 0 && len(location_tag) > 0 {
		return strings.clone(fmt.tprintf("%s%s — %s    %s", dirty_marker, display_name, full_path, location_tag))
	}
	if len(full_path) > 0 {
		return strings.clone(fmt.tprintf("%s%s — %s", dirty_marker, display_name, full_path))
	}
	if len(location_tag) > 0 {
		return strings.clone(fmt.tprintf("%s%s    %s", dirty_marker, display_name, location_tag))
	}
	return strings.clone(fmt.tprintf("%s%s", dirty_marker, display_name))
}

// Local basename helper — render.odin's copy is file-private.
@(private="file")
open_docs_filepath_base :: proc(file_path: string) -> string {
	if len(file_path) == 0 { return file_path }
	for character_index := len(file_path) - 1; character_index >= 0; character_index -= 1 {
		current_character := file_path[character_index]
		if current_character == '/' || current_character == '\\' { return file_path[character_index+1:] }
	}
	return file_path
}

// --- Filter / navigation --------------------------------------------------

@(private="file")
open_docs_apply_filter :: proc(editor: ^Editor) {
	dialog := &editor.open_docs_dialog
	clear(&dialog.filtered_indices)

	filter_lowercase := strings.to_lower(string(dialog.filter_buffer[:]), context.temp_allocator)

	for entry, entry_index in dialog.entries {
		if len(filter_lowercase) == 0 {
			append(&dialog.filtered_indices, entry_index)
			continue
		}
		label_lowercase := strings.to_lower(entry.label, context.temp_allocator)
		if strings.contains(label_lowercase, filter_lowercase) {
			append(&dialog.filtered_indices, entry_index)
		}
	}

	filtered_count := len(dialog.filtered_indices)
	if filtered_count == 0 {
		dialog.selected_index = 0
	} else if dialog.selected_index >= filtered_count {
		dialog.selected_index = filtered_count - 1
	}
	if dialog.selected_index < 0 { dialog.selected_index = 0 }
}

@(private="file")
open_docs_move_selection :: proc(editor: ^Editor, selection_delta: int) {
	dialog := &editor.open_docs_dialog
	filtered_count := len(dialog.filtered_indices)
	if filtered_count == 0 { return }
	new_selection := dialog.selected_index + selection_delta
	if new_selection < 0 { new_selection = 0 }
	if new_selection >= filtered_count { new_selection = filtered_count - 1 }
	dialog.selected_index = new_selection
}

@(private="file")
open_docs_filter_append :: proc(editor: ^Editor, text_to_append: string) {
	for byte_value in transmute([]u8)text_to_append { append(&editor.open_docs_dialog.filter_buffer, byte_value) }
	open_docs_apply_filter(editor)
}

@(private="file")
open_docs_filter_backspace :: proc(editor: ^Editor) {
	dialog := &editor.open_docs_dialog
	filter_length := len(dialog.filter_buffer)
	if filter_length == 0 { return }
	new_end_index := filter_length - 1
	for new_end_index > 0 && (dialog.filter_buffer[new_end_index] & 0xC0) == 0x80 { new_end_index -= 1 }
	resize(&dialog.filter_buffer, new_end_index)
	open_docs_apply_filter(editor)
}

// --- Activation -----------------------------------------------------------

@(private="file")
open_docs_activate :: proc(editor: ^Editor) {
	dialog := &editor.open_docs_dialog
	filtered_count := len(dialog.filtered_indices)
	if filtered_count == 0 { return }
	if dialog.selected_index < 0 || dialog.selected_index >= filtered_count { return }

	entry_source_index := dialog.filtered_indices[dialog.selected_index]
	if entry_source_index < 0 || entry_source_index >= len(dialog.entries) { return }
	selected_entry := dialog.entries[entry_source_index]

	source_pane_index := dialog.source_pane_index

	switch selected_entry.location {
	case .ActivePane:
		// Already where it is — just close the dialog. The row exists so
		// the user can see what's loaded; selecting it shouldn't surprise.

	case .OtherPane:
		// The doc is in a different visible pane — just move focus there.
		if selected_entry.pane_index >= 0 && selected_entry.pane_index < len(editor.panes) {
			editor.active_pane_index = selected_entry.pane_index
		}

	case .Background:
		// Pull the stashed doc into the pane the dialog opened from. The
		// swap helper handles stashing the current content of that pane
		// back into background_documents.
		editor_swap_background_into_pane(editor, source_pane_index, selected_entry.background_index)
	}

	open_docs_dialog_close(editor)
	editor.cursor_visible = true
	editor.cursor_timer   = 0
}

// --- Input ----------------------------------------------------------------

@(private)
open_docs_dialog_handle_event :: proc(editor: ^Editor, event: ^sdl3.Event) {
	#partial switch event.type {
	case .TEXT_INPUT:
		input_text := string(event.text.text)
		if len(input_text) > 0 { open_docs_filter_append(editor, input_text) }

	case .KEY_DOWN:
		pressed_key := event.key.key
		switch pressed_key {
		case sdl3.K_ESCAPE, sdl3.K_F4:
			open_docs_dialog_close(editor)
		case sdl3.K_UP:
			open_docs_move_selection(editor, -1)
		case sdl3.K_DOWN:
			open_docs_move_selection(editor, 1)
		case sdl3.K_PAGEUP:
			page_step := editor.open_docs_dialog.visible_row_count
			if page_step < 1 { page_step = 1 }
			open_docs_move_selection(editor, -page_step)
		case sdl3.K_PAGEDOWN:
			page_step := editor.open_docs_dialog.visible_row_count
			if page_step < 1 { page_step = 1 }
			open_docs_move_selection(editor, page_step)
		case sdl3.K_HOME:
			open_docs_move_selection(editor, -len(editor.open_docs_dialog.filtered_indices))
		case sdl3.K_END:
			open_docs_move_selection(editor, len(editor.open_docs_dialog.filtered_indices))
		case sdl3.K_RETURN, sdl3.K_KP_ENTER:
			open_docs_activate(editor)
		case sdl3.K_BACKSPACE:
			open_docs_filter_backspace(editor)
		}
	}
}

// --- Rendering ------------------------------------------------------------

@(private)
open_docs_dialog_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, viewport_width, viewport_height: i32) {
	dialog := &editor.open_docs_dialog

	ui_context := ui.Context{
		renderer        = renderer,
		font            = editor.font,
		engine          = editor.text_engine,
		character_width = editor.character_width,
		line_height     = editor.line_height,
	}
	theme := ui.default_theme()

	ui.draw_dim_overlay(&ui_context, viewport_width, viewport_height, theme.overlay)

	desired_columns: i32 = 80
	desired_rows:    i32 = 24
	dialog_width  := min(desired_columns * editor.character_width + 32, viewport_width  - 40)
	dialog_height := min(desired_rows * editor.line_height + 40,        viewport_height - 40)
	if dialog_width  < 320 { dialog_width  = min(viewport_width  - 16, 320) }
	if dialog_height < 200 { dialog_height = min(viewport_height - 16, 200) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	content_rectangle := ui.draw_window(&ui_context, dialog_rectangle, "Open documents", theme)

	line_step     := editor.line_height
	content_x     := i32(content_rectangle.x)
	content_y     := i32(content_rectangle.y)
	content_width := i32(content_rectangle.w)

	// Filter field
	filter_string := string(dialog.filter_buffer[:])
	ui.draw_input_field(&ui_context, content_x, content_y, content_width, "Filter: ", filter_string, theme)
	content_y += line_step + 8

	// Footer reservation for the hint line.
	footer_height: i32 = line_step + 12
	list_top_y       := content_y
	list_bottom_y    := i32(dialog_rectangle.y + dialog_rectangle.h) - footer_height - 12
	list_area_height := list_bottom_y - list_top_y
	computed_visible_rows := int(list_area_height / line_step)
	if computed_visible_rows < 1 { computed_visible_rows = 1 }
	dialog.visible_row_count = computed_visible_rows

	if dialog.selected_index < dialog.scroll_offset {
		dialog.scroll_offset = dialog.selected_index
	} else if dialog.selected_index >= dialog.scroll_offset + computed_visible_rows {
		dialog.scroll_offset = dialog.selected_index - computed_visible_rows + 1
	}
	if dialog.scroll_offset < 0 { dialog.scroll_offset = 0 }

	if len(dialog.filtered_indices) == 0 {
		empty_message := len(dialog.filter_buffer) > 0 ? "(no matches)" : "(no other open documents)"
		ui.draw_text(&ui_context, empty_message, content_x + 8, list_top_y, theme.dim_foreground)
	} else {
		filtered_view := dialog.filtered_indices[:]
		end_row_index := min(dialog.scroll_offset + computed_visible_rows, len(filtered_view))
		for row_index := dialog.scroll_offset; row_index < end_row_index; row_index += 1 {
			entry_index    := filtered_view[row_index]
			current_entry  := dialog.entries[entry_index]
			row_y_position := list_top_y + i32(row_index - dialog.scroll_offset) * line_step

			is_selected := row_index == dialog.selected_index
			ui.draw_list_row(&ui_context, content_x, row_y_position, content_width, current_entry.label, is_selected, theme, .File)
		}
	}

	hint_text := "↑/↓ navigate    Enter switch    Type to filter    F4/Esc close"
	hint_width, _ := ui.text_size(&ui_context, hint_text)
	footer_x := i32(dialog_rectangle.x + (dialog_rectangle.w - f32(hint_width)) / 2)
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - line_step - 10
	ui.draw_text(&ui_context, hint_text, footer_x, footer_y, theme.dim_foreground)
}

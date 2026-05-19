package editor

import "core:fmt"
import "core:strings"
import "vendor:sdl3"

import "../ui"

// Ctrl+Shift+F9 modal — lists every open terminal session and lets the user
// switch the active one. Same shape as the F4 open-documents picker
// (`open_docs.odin`); selection just calls into the multi-terminal API.

@(private)
TerminalPicker :: struct {
	filtered_indices:  [dynamic]int, // indices into `editor.terminals`
	filter_buffer:     [dynamic]u8,
	selected_index:    int,
	scroll_offset:     int,
	visible_row_count: int,
}

// --- Lifecycle ------------------------------------------------------------

@(private)
terminal_picker_destroy :: proc(picker: ^TerminalPicker) {
	if cap(picker.filtered_indices) > 0 { delete(picker.filtered_indices) }
	if cap(picker.filter_buffer)    > 0 { delete(picker.filter_buffer) }
	picker^ = TerminalPicker{}
}

@(private)
terminal_picker_open :: proc(editor: ^Editor) {
	// Nothing to pick from — silently drop. The user can spawn one via
	// Ctrl+F9 if they actually want to start a session here.
	if len(editor.terminals) == 0 { return }

	picker := &editor.terminal_picker
	clear(&picker.filter_buffer)
	picker.selected_index = editor.active_terminal_index
	if picker.selected_index < 0 { picker.selected_index = 0 }
	picker.scroll_offset  = 0
	terminal_picker_apply_filter(editor)
	editor.show_terminal_picker = true
}

@(private)
terminal_picker_close :: proc(editor: ^Editor) {
	editor.show_terminal_picker = false
	clear(&editor.terminal_picker.filtered_indices)
}

// --- Filter / navigation --------------------------------------------------

@(private="file")
terminal_picker_apply_filter :: proc(editor: ^Editor) {
	picker := &editor.terminal_picker
	clear(&picker.filtered_indices)

	filter_lowercase := strings.to_lower(string(picker.filter_buffer[:]), context.temp_allocator)

	for entry, entry_index in editor.terminals {
		if len(filter_lowercase) == 0 {
			append(&picker.filtered_indices, entry_index)
			continue
		}
		label_lowercase := strings.to_lower(fmt.tprintf("terminal #%d", entry.display_number), context.temp_allocator)
		if strings.contains(label_lowercase, filter_lowercase) {
			append(&picker.filtered_indices, entry_index)
		}
	}

	filtered_count := len(picker.filtered_indices)
	if filtered_count == 0 {
		picker.selected_index = 0
	} else if picker.selected_index >= filtered_count {
		picker.selected_index = filtered_count - 1
	}
	if picker.selected_index < 0 { picker.selected_index = 0 }
}

@(private="file")
terminal_picker_move_selection :: proc(editor: ^Editor, selection_delta: int) {
	picker := &editor.terminal_picker
	filtered_count := len(picker.filtered_indices)
	if filtered_count == 0 { return }
	new_selection := picker.selected_index + selection_delta
	if new_selection < 0                  { new_selection = 0 }
	if new_selection >= filtered_count    { new_selection = filtered_count - 1 }
	picker.selected_index = new_selection
}

@(private="file")
terminal_picker_filter_append :: proc(editor: ^Editor, text_to_append: string) {
	for byte_value in transmute([]u8)text_to_append { append(&editor.terminal_picker.filter_buffer, byte_value) }
	terminal_picker_apply_filter(editor)
}

@(private="file")
terminal_picker_filter_backspace :: proc(editor: ^Editor) {
	picker := &editor.terminal_picker
	filter_length := len(picker.filter_buffer)
	if filter_length == 0 { return }
	new_end_index := filter_length - 1
	for new_end_index > 0 && (picker.filter_buffer[new_end_index] & 0xC0) == 0x80 { new_end_index -= 1 }
	resize(&picker.filter_buffer, new_end_index)
	terminal_picker_apply_filter(editor)
}

// --- Activation -----------------------------------------------------------

@(private="file")
terminal_picker_activate :: proc(editor: ^Editor) {
	picker := &editor.terminal_picker
	filtered_count := len(picker.filtered_indices)
	if filtered_count == 0 { return }
	if picker.selected_index < 0 || picker.selected_index >= filtered_count { return }

	terminal_index := picker.filtered_indices[picker.selected_index]
	if terminal_index < 0 || terminal_index >= len(editor.terminals) { return }

	editor.active_terminal_index = terminal_index

	// If the slot is already visible, swap the borrowed pointer to the new
	// active terminal. Otherwise show it (stashing whatever was in pane[1]).
	if editor_is_terminal_visible(editor) {
		if terminal_pane, is_terminal := &editor.panes[TERMINAL_PANE_INDEX].content.(TerminalPane); is_terminal {
			terminal_pane.terminal = editor_active_terminal(editor)
		}
		editor.active_pane_index = TERMINAL_PANE_INDEX
	} else {
		editor_terminal_show(editor)
	}

	terminal_picker_close(editor)
}

// --- Input ----------------------------------------------------------------

@(private)
terminal_picker_handle_event :: proc(editor: ^Editor, event: ^sdl3.Event) {
	#partial switch event.type {
	case .TEXT_INPUT:
		input_text := string(event.text.text)
		if len(input_text) > 0 { terminal_picker_filter_append(editor, input_text) }

	case .KEY_DOWN:
		pressed_key   := event.key.key
		key_modifiers := event.key.mod
		ctrl_held     := .LCTRL  in key_modifiers || .RCTRL  in key_modifiers
		shift_held    := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers

		// Ctrl+Shift+F9 from inside the picker is a "close" gesture (mirror
		// of how F4 closes the open-docs dialog). Plain F9 also closes so
		// the toggle key acts as a back-out.
		if pressed_key == sdl3.K_F9 && ctrl_held && shift_held { terminal_picker_close(editor); return }
		if pressed_key == sdl3.K_F9                            { terminal_picker_close(editor); return }

		switch pressed_key {
		case sdl3.K_ESCAPE:
			terminal_picker_close(editor)
		case sdl3.K_UP:
			terminal_picker_move_selection(editor, -1)
		case sdl3.K_DOWN:
			terminal_picker_move_selection(editor, 1)
		case sdl3.K_PAGEUP:
			page_step := editor.terminal_picker.visible_row_count
			if page_step < 1 { page_step = 1 }
			terminal_picker_move_selection(editor, -page_step)
		case sdl3.K_PAGEDOWN:
			page_step := editor.terminal_picker.visible_row_count
			if page_step < 1 { page_step = 1 }
			terminal_picker_move_selection(editor, page_step)
		case sdl3.K_HOME:
			terminal_picker_move_selection(editor, -len(editor.terminal_picker.filtered_indices))
		case sdl3.K_END:
			terminal_picker_move_selection(editor, len(editor.terminal_picker.filtered_indices))
		case sdl3.K_RETURN, sdl3.K_KP_ENTER:
			terminal_picker_activate(editor)
		case sdl3.K_BACKSPACE:
			terminal_picker_filter_backspace(editor)
		}
	}
}

// --- Rendering ------------------------------------------------------------

@(private)
terminal_picker_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, viewport_width, viewport_height: i32) {
	picker := &editor.terminal_picker

	ui_context := ui.Context{
		renderer        = renderer,
		font            = editor.font,
		engine          = editor.text_engine,
		character_width = editor.character_width,
		line_height     = editor.line_height,
	}
	theme := ui.default_theme()

	ui.draw_dim_overlay(&ui_context, viewport_width, viewport_height, theme.overlay)

	desired_columns: i32 = 64
	desired_rows:    i32 = 20
	dialog_width  := min(desired_columns * editor.character_width + 32, viewport_width  - 40)
	dialog_height := min(desired_rows * editor.line_height + 40,        viewport_height - 40)
	if dialog_width  < 320 { dialog_width  = min(viewport_width  - 16, 320) }
	if dialog_height < 200 { dialog_height = min(viewport_height - 16, 200) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	content_rectangle := ui.draw_window(&ui_context, dialog_rectangle, "Open terminals", theme)

	line_step     := editor.line_height
	content_x     := i32(content_rectangle.x)
	content_y     := i32(content_rectangle.y)
	content_width := i32(content_rectangle.w)

	filter_string := string(picker.filter_buffer[:])
	ui.draw_input_field(&ui_context, content_x, content_y, content_width, "Filter: ", filter_string, theme)
	content_y += line_step + 8

	footer_height: i32 = line_step + 12
	list_top_y       := content_y
	list_bottom_y    := i32(dialog_rectangle.y + dialog_rectangle.h) - footer_height - 12
	list_area_height := list_bottom_y - list_top_y
	computed_visible_rows := int(list_area_height / line_step)
	if computed_visible_rows < 1 { computed_visible_rows = 1 }
	picker.visible_row_count = computed_visible_rows

	if picker.selected_index < picker.scroll_offset {
		picker.scroll_offset = picker.selected_index
	} else if picker.selected_index >= picker.scroll_offset + computed_visible_rows {
		picker.scroll_offset = picker.selected_index - computed_visible_rows + 1
	}
	if picker.scroll_offset < 0 { picker.scroll_offset = 0 }

	if len(picker.filtered_indices) == 0 {
		empty_message := len(picker.filter_buffer) > 0 ? "(no matches)" : "(no terminals open)"
		ui.draw_text(&ui_context, empty_message, content_x + 8, list_top_y, theme.dim_foreground)
	} else {
		filtered_view := picker.filtered_indices[:]
		end_row_index := min(picker.scroll_offset + computed_visible_rows, len(filtered_view))
		for row_index := picker.scroll_offset; row_index < end_row_index; row_index += 1 {
			terminal_index := filtered_view[row_index]
			entry          := editor.terminals[terminal_index]
			row_y_position := list_top_y + i32(row_index - picker.scroll_offset) * line_step

			active_marker := terminal_index == editor.active_terminal_index ? "* " : "  "
			row_label := fmt.tprintf("%sTerminal #%d", active_marker, entry.display_number)

			is_selected := row_index == picker.selected_index
			ui.draw_list_row(&ui_context, content_x, row_y_position, content_width, row_label, is_selected, theme)
		}
	}

	hint_text := "↑/↓ navigate    Enter switch    Type to filter    F9/Esc close"
	hint_width, _ := ui.text_size(&ui_context, hint_text)
	footer_x := i32(dialog_rectangle.x + (dialog_rectangle.w - f32(hint_width)) / 2)
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - line_step - 10
	ui.draw_text(&ui_context, hint_text, footer_x, footer_y, theme.dim_foreground)
}

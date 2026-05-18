package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "vendor:sdl3"

import "../ui"

// --- Types -----------------------------------------------------------------

@(private)
BrowsePromptKind :: enum {
	None,
	Rename,
	NewFile,
}

@(private)
BrowsePromptFocus :: enum {
	Input,
	Primary,
	Cancel,
}

// Owns the editable text buffer and tracks which widget is currently focused.
// `target_name` is the original entry name when renaming (for the prompt text
// and for building the old-path side of the rename); empty for NewFile.
// The three `*_rectangle` fields are filled in by the renderer each frame so
// the event handler can mouse hit-test against the actually-drawn geometry.
@(private)
BrowsePrompt :: struct {
	kind:               BrowsePromptKind,
	value_buffer:       [dynamic]u8,
	focused_widget:     BrowsePromptFocus,
	target_name:        string, // owned; original entry name for rename

	input_rectangle:    sdl3.FRect,
	primary_rectangle:  sdl3.FRect,
	cancel_rectangle:   sdl3.FRect,
}

// One reversible file-system change. `path_a` and `path_b` are owned strings.
@(private)
BrowseUndoOp :: enum {
	Rename, // path_a = old absolute path, path_b = new absolute path
	Create, // path_a = created absolute path (path_b unused)
}

@(private)
BrowseUndoEntry :: struct {
	operation: BrowseUndoOp,
	path_a:    string,
	path_b:    string,
}

// --- Lifecycle -------------------------------------------------------------

@(private)
browse_prompt_active :: proc(editor: ^Editor) -> bool {
	return editor.browse_state.prompt_state.kind != .None
}

@(private)
browse_prompt_destroy :: proc(prompt: ^BrowsePrompt) {
	delete(prompt.value_buffer)
	if len(prompt.target_name) > 0 { delete(prompt.target_name) }
	prompt^ = BrowsePrompt{}
}

@(private)
browse_undo_stack_destroy :: proc(undo_stack: ^[dynamic]BrowseUndoEntry) {
	for entry in undo_stack {
		if len(entry.path_a) > 0 { delete(entry.path_a) }
		if len(entry.path_b) > 0 { delete(entry.path_b) }
	}
	delete(undo_stack^)
	undo_stack^ = nil
}

@(private)
browse_prompt_close :: proc(editor: ^Editor) {
	editor.browse_state.prompt_state.kind = .None
	clear(&editor.browse_state.prompt_state.value_buffer)
	if len(editor.browse_state.prompt_state.target_name) > 0 {
		delete(editor.browse_state.prompt_state.target_name)
		editor.browse_state.prompt_state.target_name = ""
	}
}

// --- Open helpers ----------------------------------------------------------

@(private="file")
browse_current_entry :: proc(editor: ^Editor) -> ^BrowseEntry {
	if editor.browse_state.selected_index < 0 || editor.browse_state.selected_index >= len(editor.browse_state.filtered_indices) { return nil }
	source_entry_index := editor.browse_state.filtered_indices[editor.browse_state.selected_index]
	if source_entry_index < 0 || source_entry_index >= len(editor.browse_state.entries) { return nil }
	return &editor.browse_state.entries[source_entry_index]
}

@(private)
browse_prompt_open_rename :: proc(editor: ^Editor) {
	selected_entry := browse_current_entry(editor)
	if selected_entry == nil { return }
	if selected_entry.name == ".." { return } // not a valid rename target

	prompt := &editor.browse_state.prompt_state
	if len(prompt.target_name) > 0 { delete(prompt.target_name) }
	prompt.target_name = strings.clone(selected_entry.name)

	clear(&prompt.value_buffer)
	for byte_value in transmute([]u8)selected_entry.name { append(&prompt.value_buffer, byte_value) }

	prompt.kind           = .Rename
	prompt.focused_widget = .Input
}

@(private)
browse_prompt_open_new_file :: proc(editor: ^Editor) {
	prompt := &editor.browse_state.prompt_state
	if len(prompt.target_name) > 0 {
		delete(prompt.target_name)
		prompt.target_name = ""
	}
	clear(&prompt.value_buffer)
	prompt.kind           = .NewFile
	prompt.focused_widget = .Input
}

// --- Focus / text editing --------------------------------------------------

@(private="file")
prompt_focus_next :: proc(prompt: ^BrowsePrompt) {
	switch prompt.focused_widget {
	case .Input:   prompt.focused_widget = .Primary
	case .Primary: prompt.focused_widget = .Cancel
	case .Cancel:  prompt.focused_widget = .Input
	}
}

@(private="file")
prompt_focus_prev :: proc(prompt: ^BrowsePrompt) {
	switch prompt.focused_widget {
	case .Input:   prompt.focused_widget = .Cancel
	case .Primary: prompt.focused_widget = .Input
	case .Cancel:  prompt.focused_widget = .Primary
	}
}

@(private="file")
prompt_value_append :: proc(prompt: ^BrowsePrompt, text_to_append: string) {
	for byte_value in transmute([]u8)text_to_append {
		append(&prompt.value_buffer, byte_value)
	}
}

@(private="file")
prompt_value_backspace :: proc(prompt: ^BrowsePrompt) {
	value_length := len(prompt.value_buffer)
	if value_length == 0 { return }
	new_end_index := value_length - 1
	for new_end_index > 0 && (prompt.value_buffer[new_end_index] & 0xC0) == 0x80 { new_end_index -= 1 }
	resize(&prompt.value_buffer, new_end_index)
}

// --- Actions ---------------------------------------------------------------

@(private="file")
prompt_execute :: proc(editor: ^Editor) {
	prompt := &editor.browse_state.prompt_state

	new_name := strings.trim_space(string(prompt.value_buffer[:]))
	if len(new_name) == 0 { return }

	switch prompt.kind {
	case .Rename:
		browse_do_rename(editor, prompt.target_name, new_name)
	case .NewFile:
		browse_do_create_file(editor, new_name)
	case .None:
	}
}

@(private="file")
browse_do_rename :: proc(editor: ^Editor, old_name, new_name: string) {
	if old_name == new_name {
		browse_prompt_close(editor)
		return
	}

	old_path_parts := [2]string{editor.browse_state.current_working_directory, old_name}
	new_path_parts := [2]string{editor.browse_state.current_working_directory, new_name}
	old_full_path, _ := filepath.join(old_path_parts[:], context.temp_allocator)
	new_full_path, _ := filepath.join(new_path_parts[:], context.temp_allocator)

	rename_error := os.rename(old_full_path, new_full_path)
	if rename_error != nil {
		browse_set_error(editor, fmt.tprintf("Cannot rename: %v", rename_error))
		return
	}

	append(&editor.browse_state.undo_stack, BrowseUndoEntry{
		operation = .Rename,
		path_a    = strings.clone(old_full_path),
		path_b    = strings.clone(new_full_path),
	})

	browse_prompt_close(editor)

	reload_directory_path := strings.clone(editor.browse_state.current_working_directory, context.temp_allocator)
	browse_load_directory(editor, reload_directory_path)
}

@(private="file")
browse_do_create_file :: proc(editor: ^Editor, file_name: string) {
	path_parts := [2]string{editor.browse_state.current_working_directory, file_name}
	new_full_path, _ := filepath.join(path_parts[:], context.temp_allocator)

	// `write_entire_file` creates the file (or truncates if it exists). For
	// "new file", we want to refuse to clobber an existing one.
	if existing_file_handle, open_error := os.open(new_full_path); open_error == nil {
		os.close(existing_file_handle)
		browse_set_error(editor, fmt.tprintf("File already exists: %s", file_name))
		return
	}

	if write_error := os.write_entire_file(new_full_path, []byte{}); write_error != nil {
		browse_set_error(editor, fmt.tprintf("Cannot create file: %v", write_error))
		return
	}

	append(&editor.browse_state.undo_stack, BrowseUndoEntry{
		operation = .Create,
		path_a    = strings.clone(new_full_path),
		path_b    = "",
	})

	browse_prompt_close(editor)

	reload_directory_path := strings.clone(editor.browse_state.current_working_directory, context.temp_allocator)
	browse_load_directory(editor, reload_directory_path)
}

// Reverse the most recent file-system change. Triggered by Ctrl+Z while the
// browser is open and no prompt is active.
@(private)
browse_undo :: proc(editor: ^Editor) {
	undo_stack_length := len(editor.browse_state.undo_stack)
	if undo_stack_length == 0 { return }

	undo_entry := editor.browse_state.undo_stack[undo_stack_length - 1]
	resize(&editor.browse_state.undo_stack, undo_stack_length - 1)

	defer {
		if len(undo_entry.path_a) > 0 { delete(undo_entry.path_a) }
		if len(undo_entry.path_b) > 0 { delete(undo_entry.path_b) }
	}

	switch undo_entry.operation {
	case .Rename:
		if rename_error := os.rename(undo_entry.path_b, undo_entry.path_a); rename_error != nil {
			browse_set_error(editor, fmt.tprintf("Cannot undo rename: %v", rename_error))
			return
		}
	case .Create:
		if remove_error := os.remove(undo_entry.path_a); remove_error != nil {
			browse_set_error(editor, fmt.tprintf("Cannot undo create: %v", remove_error))
			return
		}
	}

	reload_directory_path := strings.clone(editor.browse_state.current_working_directory, context.temp_allocator)
	browse_load_directory(editor, reload_directory_path)
}

// --- Event handling --------------------------------------------------------

@(private)
browse_prompt_handle_event :: proc(editor: ^Editor, event: ^sdl3.Event) {
	prompt := &editor.browse_state.prompt_state

	#partial switch event.type {
	case .TEXT_INPUT:
		if prompt.focused_widget == .Input {
			input_text := string(event.text.text)
			if len(input_text) > 0 { prompt_value_append(prompt, input_text) }
		}

	case .KEY_DOWN:
		pressed_key   := event.key.key
		key_modifiers := event.key.mod
		shift_held    := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers

		switch pressed_key {
		case sdl3.K_ESCAPE:
			browse_prompt_close(editor)
		case sdl3.K_TAB:
			if shift_held { prompt_focus_prev(prompt) } else { prompt_focus_next(prompt) }
		case sdl3.K_RETURN:
			switch prompt.focused_widget {
			case .Input, .Primary: prompt_execute(editor)
			case .Cancel:          browse_prompt_close(editor)
			}
		case sdl3.K_BACKSPACE:
			if prompt.focused_widget == .Input { prompt_value_backspace(prompt) }
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button == sdl3.BUTTON_LEFT {
			mouse_x, mouse_y := event.button.x, event.button.y
			switch {
			case ui.point_in_rect(prompt.input_rectangle, mouse_x, mouse_y):
				prompt.focused_widget = .Input
			case ui.point_in_rect(prompt.primary_rectangle, mouse_x, mouse_y):
				prompt.focused_widget = .Primary
				prompt_execute(editor)
			case ui.point_in_rect(prompt.cancel_rectangle, mouse_x, mouse_y):
				prompt.focused_widget = .Cancel
				browse_prompt_close(editor)
			}
		}
	}
}

// --- Rendering -------------------------------------------------------------

@(private)
browse_prompt_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, viewport_width, viewport_height: i32) {
	prompt := &editor.browse_state.prompt_state
	if prompt.kind == .None { return }

	ui_context := ui.Context{
		renderer        = renderer,
		font            = editor.font,
		engine          = editor.text_engine,
		character_width = editor.character_width,
		line_height     = editor.line_height,
	}
	theme := ui.default_theme()

	// Extra dim layer over the browse modal so the prompt visually dominates.
	ui.draw_dim_overlay(&ui_context, viewport_width, viewport_height, theme.overlay)

	// Popup sizing (in character cells + small pixel padding).
	popup_width  := min(50 * editor.character_width + 32, viewport_width  - 80)
	popup_height := min(8  * editor.line_height + 40, viewport_height - 80)
	if popup_width  < 240 { popup_width  = min(viewport_width  - 16, 240) }
	if popup_height < 160 { popup_height = min(viewport_height - 16, 160) }
	popup_x := (viewport_width  - popup_width)  / 2
	popup_y := (viewport_height - popup_height) / 2
	popup_rectangle := sdl3.FRect{f32(popup_x), f32(popup_y), f32(popup_width), f32(popup_height)}

	title := prompt.kind == .Rename ? "Rename" : "New File"
	content_rectangle := ui.draw_window(&ui_context, popup_rectangle, title, theme)

	line_step := editor.line_height
	content_x := i32(content_rectangle.x)
	content_y := i32(content_rectangle.y)
	content_width := i32(content_rectangle.w)

	// Prompt headline
	headline_text: string
	switch prompt.kind {
	case .Rename:  headline_text = fmt.tprintf("Rename \"%s\" to:", prompt.target_name)
	case .NewFile: headline_text = "New file name:"
	case .None:    return
	}
	ui.draw_text(&ui_context, headline_text, content_x, content_y, theme.text_foreground)
	content_y += line_step + 6

	// Editable input field
	prompt.input_rectangle = sdl3.FRect{f32(content_x), f32(content_y), f32(content_width), f32(line_step + 4)}
	value_string := string(prompt.value_buffer[:])
	ui.draw_input_field(&ui_context, content_x, content_y, content_width, "", value_string, theme, prompt.focused_widget == .Input)
	content_y += line_step + 16

	// Buttons row anchored to the popup's bottom edge.
	button_width: i32 = 14 * editor.character_width
	button_height: i32 = line_step + 12
	button_gap: i32 = 8
	total_button_row_width := button_width * 2 + button_gap
	button_start_x := content_x + (content_width - total_button_row_width) / 2
	button_y := i32(popup_rectangle.y + popup_rectangle.h) - button_height - 12

	primary_label := prompt.kind == .Rename ? "Rename" : "Create"

	prompt.primary_rectangle = sdl3.FRect{f32(button_start_x),                              f32(button_y), f32(button_width), f32(button_height)}
	prompt.cancel_rectangle  = sdl3.FRect{f32(button_start_x + button_width + button_gap), f32(button_y), f32(button_width), f32(button_height)}

	ui.draw_button(&ui_context, prompt.primary_rectangle, primary_label, prompt.focused_widget == .Primary, theme)
	ui.draw_button(&ui_context, prompt.cancel_rectangle,  "Cancel",      prompt.focused_widget == .Cancel,  theme)
}

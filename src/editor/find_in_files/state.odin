// Package `find_in_files` is the Ctrl+Shift+F modal — recursive
// grep across a directory tree with a results list the user can
// navigate and jump into.
//
// File layout:
//   * `state.odin`    — types + lifecycle + selection/focus/buffer
//                       helpers + result_count getter.
//   * `dispatch.odin` — open / seed_query / set_results / error
//                       helpers (per-frame mutators).
//   * `view.odin`     — handle_event + render.
//   * `binding.odin`  — vtable + Hooks for the editor registry.
package find_in_files

import "core:strings"
import "core:unicode/utf8"
import "vendor:sdl3"

import "../../ui"

State :: struct {
	visible:           bool,
	focus:             Focus,
	path_buffer:       [dynamic]u8,
	query_buffer:      [dynamic]u8,
	results:           [dynamic]Result,
	selected_index:    int,
	scroll_offset:     int,
	visible_row_count: int,
	error_message:     string, // owned

	max_prefix_chars: int,

	cached_line_height: i32,

	path_field_rectangle:    sdl3.FRect,
	query_field_rectangle:   sdl3.FRect,
	find_button_rectangle:   sdl3.FRect,
	clear_button_rectangle:  sdl3.FRect,
	cancel_button_rectangle: sdl3.FRect,
	results_list_rectangle:  sdl3.FRect,
	results_scrollbar:       ui.Scrollbar,
}

Focus :: enum {
	PathInput,
	QueryInput,
	FindButton,
	ClearButton,
	CancelButton,
	Results,
}

Result :: struct {
	file_path:     string, // absolute, owned
	relative_path: string, // owned; relative to the search root for display
	line:          u32,
	column:        u32,
	snippet:       string, // owned; one line of context (already sanitized by the editor)
}

ResultSource :: struct {
	file_path:     string,
	relative_path: string,
	line:          u32,
	column:        u32,
	snippet:       string,
}

Intent :: union {
	ExecuteSearch,
	ActivateResult,
}
ExecuteSearch :: struct {
	path:  string,
	query: string,
}
ActivateResult :: struct {
	file_path:     string,
	relative_path: string,
	line:          u32,
	column:        u32,
}

// --- Lifecycle ------------------------------------------------------------

destroy :: proc(state: ^State) {
	delete(state.path_buffer)
	delete(state.query_buffer)
	clear_results_internal(state)
	delete(state.results)
	if len(state.error_message) > 0 { delete(state.error_message) }
	state^ = State{}
}

close :: proc(state: ^State) {
	state.visible = false
}

result_count :: proc(state: ^State) -> int { return len(state.results) }

// --- Internal helpers (shared by dispatch + view) ------------------------

@(private)
clear_results_internal :: proc(state: ^State) {
	for result in state.results {
		if len(result.file_path)     > 0 { delete(result.file_path)     }
		if len(result.relative_path) > 0 { delete(result.relative_path) }
		if len(result.snippet)       > 0 { delete(result.snippet)       }
	}
	clear(&state.results)
}

@(private)
clear_action :: proc(state: ^State) {
	clear(&state.query_buffer)
	clear_results_internal(state)
	state.selected_index   = 0
	state.scroll_offset    = 0
	state.max_prefix_chars = 0
	clear_error(state)
	state.focus = .QueryInput
}

@(private)
focus_next :: proc(state: ^State) {
	switch state.focus {
	case .PathInput:    state.focus = .QueryInput
	case .QueryInput:   state.focus = .FindButton
	case .FindButton:   state.focus = .ClearButton
	case .ClearButton:  state.focus = .CancelButton
	case .CancelButton: state.focus = .Results
	case .Results:      state.focus = .PathInput
	}
}

@(private)
focus_prev :: proc(state: ^State) {
	switch state.focus {
	case .PathInput:    state.focus = .Results
	case .QueryInput:   state.focus = .PathInput
	case .FindButton:   state.focus = .QueryInput
	case .ClearButton:  state.focus = .FindButton
	case .CancelButton: state.focus = .ClearButton
	case .Results:      state.focus = .CancelButton
	}
}

@(private)
focused_buffer :: proc(state: ^State) -> ^[dynamic]u8 {
	switch state.focus {
	case .PathInput:    return &state.path_buffer
	case .QueryInput:   return &state.query_buffer
	case .FindButton, .ClearButton, .CancelButton, .Results:
		return nil
	}
	return nil
}

@(private)
buffer_append :: proc(buffer: ^[dynamic]u8, text_to_append: string) {
	for byte_value in transmute([]u8)text_to_append {
		if byte_value == '\n' || byte_value == '\r' { continue }
		append(buffer, byte_value)
	}
}

@(private)
buffer_backspace :: proc(buffer: ^[dynamic]u8) {
	buffer_length := len(buffer^)
	if buffer_length == 0 { return }
	new_end_index := buffer_length - 1
	for new_end_index > 0 && ((buffer^)[new_end_index] & 0xC0) == 0x80 { new_end_index -= 1 }
	resize(buffer, new_end_index)
}

@(private)
move_selection :: proc(state: ^State, delta: int) {
	count := len(state.results)
	if count == 0 { return }
	new_index := state.selected_index + delta
	if new_index < 0           { new_index = 0 }
	if new_index >= count      { new_index = count - 1 }
	state.selected_index = new_index

	if state.visible_row_count > 0 {
		if state.selected_index < state.scroll_offset {
			state.scroll_offset = state.selected_index
		} else if state.selected_index >= state.scroll_offset + state.visible_row_count {
			state.scroll_offset = state.selected_index - state.visible_row_count + 1
		}
		if state.scroll_offset < 0 { state.scroll_offset = 0 }
	}
}

@(private)
apply_scrollbar_drag :: proc(state: ^State, mouse_y: f32) {
	if state.cached_line_height <= 0 { return }
	max_offset := max(0, len(state.results) - state.visible_row_count)
	if max_offset == 0 { return }
	max_scroll_pixels := f32(max_offset * int(state.cached_line_height))
	new_scroll_pixels := ui.scrollbar_drag_to(&state.results_scrollbar, mouse_y, max_scroll_pixels)
	new_offset := int(new_scroll_pixels / f32(state.cached_line_height) + 0.5)
	if new_offset < 0          { new_offset = 0 }
	if new_offset > max_offset { new_offset = max_offset }
	state.scroll_offset = new_offset
}

@(private)
try_execute :: proc(state: ^State) -> Intent {
	path_string  := string(state.path_buffer[:])
	query_string := string(state.query_buffer[:])
	if len(query_string) == 0 {
		set_error(state, "Enter a search query")
		return nil
	}
	if len(path_string) == 0 {
		set_error(state, "Enter a search path")
		return nil
	}
	clear_error(state)
	return ExecuteSearch{
		path  = strings.clone(path_string,  context.temp_allocator),
		query = strings.clone(query_string, context.temp_allocator),
	}
}

@(private)
try_activate :: proc(state: ^State) -> Intent {
	if state.selected_index < 0 || state.selected_index >= len(state.results) { return nil }
	result := state.results[state.selected_index]
	return ActivateResult{
		file_path     = strings.clone(result.file_path,     context.temp_allocator),
		relative_path = strings.clone(result.relative_path, context.temp_allocator),
		line          = result.line,
		column        = result.column,
	}
}

@(private)
truncate_to_runes_with_ellipsis :: proc(text: string, max_runes: int, allocator := context.temp_allocator) -> string {
	if max_runes <= 0 { return "" }
	rune_count := utf8.rune_count_in_string(text)
	if rune_count <= max_runes { return text }
	if max_runes <= 3 {
		return strings.repeat(".", max_runes, allocator)
	}
	keep_runes := max_runes - 3
	byte_index := 0
	runes_kept := 0
	for runes_kept < keep_runes && byte_index < len(text) {
		_, byte_count := utf8.decode_rune_in_string(text[byte_index:])
		byte_index += byte_count
		runes_kept += 1
	}
	return strings.concatenate({text[:byte_index], "..."}, allocator)
}

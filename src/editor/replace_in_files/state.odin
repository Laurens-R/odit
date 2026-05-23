// Package `replace_in_files` is the Ctrl+Shift+R modal — recursive
// search + per-match / batch replace across a directory tree.
//
// File layout:
//   * `state.odin`    — types + lifecycle + focus / selection /
//                       buffer helpers.
//   * `walk.odin`     — recursive directory walk, per-file scan +
//                       on-disk replacement engine.
//   * `view.odin`     — handle_event + render + completion popup.
//   * `dispatch.odin` — open / find_all / replace_next / replace_all
//                       / clear_action (per-frame mutators called
//                       by the binding).
//   * `binding.odin`  — vtable + open_via_api for the editor
//                       registry.
package replace_in_files

import "core:strings"
import "vendor:sdl3"

import "../../ui"

Focus :: enum {
	PathInput,
	SearchInput,
	ReplaceInput,
	FindAllButton,
	ReplaceNextButton,
	ReplaceAllButton,
	ClearButton,
	CancelButton,
	Results,
}

Status :: enum {
	Pending,  // matched but not yet replaced — drawn normally
	Replaced, // committed to disk — drawn with a green row tint
}

// One pending or completed replacement. `column` and `match_length`
// are byte offsets within `line`. After a per-match replacement we
// update the columns of any other Pending matches on the same line
// so subsequent operations land on the right bytes.
Result :: struct {
	file_path:     string, // absolute, owned
	relative_path: string, // owned
	line:          u32,
	column:        u32,
	match_length:  u32,
	snippet:       string, // owned
	status:        Status,
}

State :: struct {
	visible:           bool,
	focus:             Focus,
	path_buffer:       [dynamic]u8,
	search_buffer:     [dynamic]u8,
	replace_buffer:    [dynamic]u8,
	results:           [dynamic]Result,
	selected_index:    int,
	scroll_offset:     int,
	visible_row_count: int,
	error_message:     string, // owned
	max_prefix_chars:  int,

	// After a Replace All run we surface a small confirmation popup
	// over the main dialog. Persists across frames; the user must
	// dismiss it explicitly.
	show_completion:   bool,
	completion_count:  int,

	path_field_rectangle:           sdl3.FRect,
	search_field_rectangle:         sdl3.FRect,
	replace_field_rectangle:        sdl3.FRect,
	find_all_button_rectangle:      sdl3.FRect,
	replace_next_button_rectangle:  sdl3.FRect,
	replace_all_button_rectangle:   sdl3.FRect,
	clear_button_rectangle:         sdl3.FRect,
	cancel_button_rectangle:        sdl3.FRect,
	results_list_rectangle:         sdl3.FRect,
	completion_ok_button_rectangle: sdl3.FRect,
	results_scrollbar:              ui.Scrollbar,
}

// --- Lifecycle ----------------------------------------------------------

destroy :: proc(state: ^State) {
	delete(state.path_buffer)
	delete(state.search_buffer)
	delete(state.replace_buffer)
	clear_results_internal(state)
	delete(state.results)
	if len(state.error_message) > 0 { delete(state.error_message) }
	state^ = State{}
}

close :: proc(state: ^State) {
	state.visible         = false
	state.show_completion = false
}

set_error :: proc(state: ^State, message: string) {
	clear_error(state)
	state.error_message = strings.clone(message)
}

clear_error :: proc(state: ^State) {
	if len(state.error_message) > 0 {
		delete(state.error_message)
		state.error_message = ""
	}
}

// --- Internal helpers (shared by walk + dispatch + view) ----------------

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
	clear(&state.search_buffer)
	clear(&state.replace_buffer)
	clear_results_internal(state)
	state.selected_index   = 0
	state.scroll_offset    = 0
	state.max_prefix_chars = 0
	clear_error(state)
	state.focus = .PathInput
}

@(private)
focus_next :: proc(state: ^State) {
	switch state.focus {
	case .PathInput:         state.focus = .SearchInput
	case .SearchInput:       state.focus = .ReplaceInput
	case .ReplaceInput:      state.focus = .FindAllButton
	case .FindAllButton:     state.focus = .ReplaceNextButton
	case .ReplaceNextButton: state.focus = .ReplaceAllButton
	case .ReplaceAllButton:  state.focus = .ClearButton
	case .ClearButton:       state.focus = .CancelButton
	case .CancelButton:      state.focus = .Results
	case .Results:           state.focus = .PathInput
	}
}

@(private)
focus_prev :: proc(state: ^State) {
	switch state.focus {
	case .PathInput:         state.focus = .Results
	case .SearchInput:       state.focus = .PathInput
	case .ReplaceInput:      state.focus = .SearchInput
	case .FindAllButton:     state.focus = .ReplaceInput
	case .ReplaceNextButton: state.focus = .FindAllButton
	case .ReplaceAllButton:  state.focus = .ReplaceNextButton
	case .ClearButton:       state.focus = .ReplaceAllButton
	case .CancelButton:      state.focus = .ClearButton
	case .Results:           state.focus = .CancelButton
	}
}

@(private)
focused_buffer :: proc(state: ^State) -> ^[dynamic]u8 {
	switch state.focus {
	case .PathInput:    return &state.path_buffer
	case .SearchInput:  return &state.search_buffer
	case .ReplaceInput: return &state.replace_buffer
	case .FindAllButton, .ReplaceNextButton, .ReplaceAllButton, .ClearButton, .CancelButton, .Results:
		return nil
	}
	return nil
}

@(private)
buffer_backspace :: proc(buffer: ^[dynamic]u8) {
	length := len(buffer^)
	if length == 0 { return }
	new_end := length - 1
	for new_end > 0 && ((buffer^)[new_end] & 0xC0) == 0x80 { new_end -= 1 }
	resize(buffer, new_end)
}

@(private)
move_selection :: proc(state: ^State, delta: int) {
	result_count := len(state.results)
	if result_count == 0 { return }
	new_index := state.selected_index + delta
	if new_index < 0             { new_index = 0 }
	if new_index >= result_count { new_index = result_count - 1 }
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
apply_scrollbar_drag :: proc(state: ^State, mouse_y: f32, line_height: i32) {
	if line_height <= 0 { return }
	max_offset := max(0, len(state.results) - state.visible_row_count)
	if max_offset == 0 { return }
	max_scroll_pixels := f32(max_offset * int(line_height))
	new_scroll_pixels := ui.scrollbar_drag_to(&state.results_scrollbar, mouse_y, max_scroll_pixels)
	new_offset := int(new_scroll_pixels / f32(line_height) + 0.5)
	if new_offset < 0          { new_offset = 0 }
	if new_offset > max_offset { new_offset = max_offset }
	state.scroll_offset = new_offset
}

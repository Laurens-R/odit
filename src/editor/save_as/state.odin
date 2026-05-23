// Package `save_as` is the Save-As text-input modal. Shown directly
// by Ctrl+Shift+S, indirectly by Ctrl+S on an untitled doc, and
// chained from the Yes branch of the close-confirm dialog.
//
// Structure:
//   * `state.odin`    — State, Focus, Intent, Host types, lifecycle.
//   * `view.odin`     — handle_event + render.
//   * `dispatch.odin` — dispatch_event glue. On Commit it asks the
//                       host to write the file; the host returns an
//                       error message (or "") so the popup can stay
//                       open on failure with the message displayed.
package save_as

import "core:strings"
import "vendor:sdl3"

State :: struct {
	visible:          bool,
	focus:            Focus,
	pane_index:       int,
	path_buffer:      [dynamic]u8,
	error_message:    string, // owned
	close_after_save: bool,

	input_rectangle:  sdl3.FRect,
	ok_rectangle:     sdl3.FRect,
	cancel_rectangle: sdl3.FRect,
}

Focus :: enum {
	PathInput,
	OkButton,
	CancelButton,
}

Intent :: union {
	Commit,
}
Commit :: struct {
	pane_index:       int,
	path:             string, // temp_allocator clone
	close_after_save: bool,
}

// --- Lifecycle ------------------------------------------------------------

destroy :: proc(state: ^State) {
	delete(state.path_buffer)
	if len(state.error_message) > 0 { delete(state.error_message) }
	state^ = State{}
}

close :: proc(state: ^State) {
	state.visible = false
}

// Open the modal seeded with `default_path`. The binding's
// `open_with_hooks` resolves the default path via the host first.
open :: proc(state: ^State, pane_index: int, default_path: string, close_after_save: bool) {
	clear(&state.path_buffer)
	clear_error(state)
	for byte_value in transmute([]u8)default_path { append(&state.path_buffer, byte_value) }
	state.pane_index       = pane_index
	state.close_after_save = close_after_save
	state.focus            = .PathInput
	state.visible          = true
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

// --- Internal helpers ----------------------------------------------------

@(private)
focus_next :: proc(state: ^State) {
	switch state.focus {
	case .PathInput:    state.focus = .OkButton
	case .OkButton:     state.focus = .CancelButton
	case .CancelButton: state.focus = .PathInput
	}
}

@(private)
focus_prev :: proc(state: ^State) {
	switch state.focus {
	case .PathInput:    state.focus = .CancelButton
	case .OkButton:     state.focus = .PathInput
	case .CancelButton: state.focus = .OkButton
	}
}

@(private)
try_commit :: proc(state: ^State) -> (intent: Intent, needs_redraw: bool) {
	path_text := strings.trim_space(string(state.path_buffer[:]))
	if len(path_text) == 0 {
		set_error(state, "Enter a file path")
		return nil, true
	}
	return Commit{
		pane_index       = state.pane_index,
		path             = strings.clone(path_text, context.temp_allocator),
		close_after_save = state.close_after_save,
	}, true
}

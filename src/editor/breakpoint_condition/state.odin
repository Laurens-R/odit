// Package `breakpoint_condition` is the single-input modal for setting
// or editing the condition string of one breakpoint. Opened by
// Shift+click in the gutter. One text-input + OK + Cancel; focus
// cycle on Tab, Enter triggers OK, Esc closes.
//
// Structure inside this package:
//   * `state.odin`    — State, Focus, Intent, Host types, lifecycle
//                       (destroy/close/open), small internal helpers.
//   * `view.odin`     — input event handling + render. The pure UI loop.
//   * `dispatch.odin` — `dispatch_event` glue: drives `handle_event`
//                       and routes returned Intents through `Host`
//                       callbacks the host (editor) registered at init.
//
// The host populates a `Host` struct at startup (function pointers +
// `user_data`). The package never imports the host's package, which
// keeps the import graph acyclic — required for the modal directory
// to contain both UI and dispatch code without Odin's
// one-directory-one-package rule fighting us.
package breakpoint_condition

import "core:strings"
import "vendor:sdl3"

State :: struct {
	visible:         bool,
	focus:           Focus,
	file_path:       string, // owned; locked at open time so a pane switch can't redirect the write
	line:            u32,    // 0-based document line
	had_breakpoint:  bool,   // toggles the title between Edit and Add
	input_buffer:    [dynamic]u8,

	// Filled by the renderer each frame so the event handler can mouse
	// hit-test against the actually-drawn geometry.
	input_rectangle:  sdl3.FRect,
	ok_rectangle:     sdl3.FRect,
	cancel_rectangle: sdl3.FRect,
}

Focus :: enum {
	Input,
	OkButton,
	CancelButton,
}

// Intent returned by `handle_event` on commit. `dispatch_event` routes
// this through the host callback automatically — callers that don't
// want the dispatcher pattern can drive `handle_event` directly and
// react to the Intent themselves.
Intent :: union {
	Commit,
}
Commit :: struct {
	file_path:      string, // temp_allocator clone — caller reads immediately
	line:           u32,
	condition_text: string, // temp_allocator clone; empty => clear condition
}

// Function pointers the host registers at startup. `user_data` is an
// opaque host-side pointer (typically `^editor.Editor`); the host's
// callback procs cast it back. The subpackage never sees the host's
// types directly, so there's no import cycle.
//
// Callback contract:
//   * `existing_condition_at` is invoked at `open` time to seed the
//     input buffer with whatever condition (if any) is already
//     attached to the (file, line) pair. Returning `had_bp = false`
//     just flips the dialog title from "Edit" to "Add".
//   * `set_condition_at` is invoked on commit. An empty
//     `condition_text` means "make this an unconditional breakpoint"
//     (or create one if none was there).
// --- Lifecycle ------------------------------------------------------------

destroy :: proc(state: ^State) {
	if cap(state.input_buffer) > 0 { delete(state.input_buffer) }
	if len(state.file_path)    > 0 { delete(state.file_path)    }
	state^ = State{}
}

close :: proc(state: ^State) {
	state.visible = false
}

// Open the modal at the given (file, line). The binding's
// `open_with_hooks` queries the host first for any existing
// condition and passes it through.
open :: proc(state: ^State, file_path: string, line: u32, existing_condition: string, had_bp: bool) {
	if len(file_path) == 0 { return }

	if len(state.file_path) > 0 { delete(state.file_path) }
	state.file_path      = strings.clone(file_path)
	state.line           = line
	state.focus          = .Input
	state.had_breakpoint = had_bp
	clear(&state.input_buffer)
	for byte_value in transmute([]u8)existing_condition { append(&state.input_buffer, byte_value) }
	state.visible        = true
}

// --- Internal helpers (used by view.odin) ---------------------------------

@(private)
focus_next :: proc(state: ^State) {
	switch state.focus {
	case .Input:        state.focus = .OkButton
	case .OkButton:     state.focus = .CancelButton
	case .CancelButton: state.focus = .Input
	}
}

@(private)
focus_prev :: proc(state: ^State) {
	switch state.focus {
	case .Input:        state.focus = .CancelButton
	case .OkButton:     state.focus = .Input
	case .CancelButton: state.focus = .OkButton
	}
}

@(private)
try_commit :: proc(state: ^State) -> (intent: Intent, needs_redraw: bool) {
	if len(state.file_path) == 0 {
		close(state)
		return nil, true
	}
	// Clone strings into temp_allocator so the caller reads them after
	// the popup closes itself on the same dispatch.
	file_path_clone     := strings.clone(state.file_path, context.temp_allocator)
	condition_clone     := strings.clone(strings.trim_space(string(state.input_buffer[:])), context.temp_allocator)
	line                := state.line
	close(state)
	return Commit{
		file_path      = file_path_clone,
		line           = line,
		condition_text = condition_clone,
	}, true
}

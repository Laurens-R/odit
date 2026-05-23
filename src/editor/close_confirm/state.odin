// Package `close_confirm` is the "You have unsaved changes — save
// before closing?" prompt fired by Ctrl+F4 when the active pane's
// document is dirty.
//
// Structure:
//   * `state.odin`    — State, Focus, Intent, Host types, lifecycle.
//   * `view.odin`     — handle_event + render.
//   * `dispatch.odin` — dispatch_event glue routing intents through Host.
package close_confirm

import "vendor:sdl3"

State :: struct {
	visible:          bool,
	focus:            Focus,
	pane_index:       int,
	yes_rectangle:    sdl3.FRect,
	no_rectangle:     sdl3.FRect,
	cancel_rectangle: sdl3.FRect,
}

Focus :: enum {
	YesButton,
	NoButton,
	CancelButton,
}

Intent :: union {
	SaveAndClose,
	DiscardAndClose,
}
SaveAndClose    :: struct { pane_index: int }
DiscardAndClose :: struct { pane_index: int }

// Host callbacks. The host's `subject_name` returns the human-
// readable name to display in the question ("foo.odin",
// "this untitled file", "this file" fallback). `save_and_close` and
// `discard_and_close` apply the user's choice.
Host :: struct {
	user_data:         rawptr,
	subject_name:      proc(user_data: rawptr, pane_index: int) -> string,
	save_and_close:    proc(user_data: rawptr, pane_index: int),
	discard_and_close: proc(user_data: rawptr, pane_index: int),
}

// --- Lifecycle ------------------------------------------------------------

destroy :: proc(state: ^State) {
	state^ = State{}
}

close :: proc(state: ^State) {
	state.visible = false
}

open :: proc(state: ^State, pane_index: int) {
	state.focus      = .YesButton
	state.pane_index = pane_index
	state.visible    = true
}

// --- Internal helpers ----------------------------------------------------

@(private)
focus_step :: proc(state: ^State, direction: int) {
	if direction > 0 {
		switch state.focus {
		case .YesButton:    state.focus = .NoButton
		case .NoButton:     state.focus = .CancelButton
		case .CancelButton: state.focus = .YesButton
		}
	} else {
		switch state.focus {
		case .YesButton:    state.focus = .CancelButton
		case .NoButton:     state.focus = .YesButton
		case .CancelButton: state.focus = .NoButton
		}
	}
}

@(private)
submit_save :: proc(state: ^State) -> Intent {
	pane_index := state.pane_index
	close(state)
	return SaveAndClose{ pane_index = pane_index }
}

@(private)
submit_discard :: proc(state: ^State) -> Intent {
	pane_index := state.pane_index
	close(state)
	return DiscardAndClose{ pane_index = pane_index }
}

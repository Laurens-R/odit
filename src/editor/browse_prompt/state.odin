// Package `browse_prompt` is the rename / new-file sub-modal that
// opens inside the file browser.
//
// Structure:
//   * `state.odin`    — Kind, Focus, State, Intent, Host types, lifecycle,
//                       small helpers (focus cycle, value edits, submit).
//   * `view.odin`     — handle_event + render.
//   * `dispatch.odin` — dispatch_event glue routing intents through Host.
package browse_prompt

import "core:strings"
import "vendor:sdl3"

Kind :: enum {
	None,
	Rename,
	NewFile,
	NewFolder,
}

Focus :: enum {
	Input,
	Primary,
	Cancel,
}

State :: struct {
	kind:               Kind,
	value_buffer:       [dynamic]u8,
	focused_widget:     Focus,
	target_name:        string, // owned; original entry name for rename

	input_rectangle:    sdl3.FRect,
	primary_rectangle:  sdl3.FRect,
	cancel_rectangle:   sdl3.FRect,
}

// Intent dispatched on submission. Strings cloned into
// `context.temp_allocator` before the popup closes so the host can
// read them after close-on-same-dispatch.
Intent :: union {
	SubmitRename,
	SubmitNewFile,
	SubmitNewFolder,
}
SubmitRename    :: struct { old_name, new_name: string }
SubmitNewFile   :: struct { name: string }
SubmitNewFolder :: struct { name: string }

// Host callbacks. The host applies rename / create as filesystem
// operations (and updates whatever sibling browser state needs
// refreshing).
Host :: struct {
	user_data:        rawptr,
	apply_rename:     proc(user_data: rawptr, old_name, new_name: string),
	apply_new_file:   proc(user_data: rawptr, file_name: string),
	apply_new_folder: proc(user_data: rawptr, folder_name: string),
}

// --- Lifecycle ------------------------------------------------------------

active :: proc(state: ^State) -> bool {
	return state.kind != .None
}

destroy :: proc(state: ^State) {
	delete(state.value_buffer)
	if len(state.target_name) > 0 { delete(state.target_name) }
	state^ = State{}
}

close :: proc(state: ^State) {
	state.kind = .None
	clear(&state.value_buffer)
	if len(state.target_name) > 0 {
		delete(state.target_name)
		state.target_name = ""
	}
}

open_rename :: proc(state: ^State, target_name: string) {
	if len(state.target_name) > 0 { delete(state.target_name) }
	state.target_name = strings.clone(target_name)

	clear(&state.value_buffer)
	for byte_value in transmute([]u8)target_name { append(&state.value_buffer, byte_value) }

	state.kind           = .Rename
	state.focused_widget = .Input
}

open_new_file :: proc(state: ^State) {
	if len(state.target_name) > 0 {
		delete(state.target_name)
		state.target_name = ""
	}
	clear(&state.value_buffer)
	state.kind           = .NewFile
	state.focused_widget = .Input
}

open_new_folder :: proc(state: ^State) {
	if len(state.target_name) > 0 {
		delete(state.target_name)
		state.target_name = ""
	}
	clear(&state.value_buffer)
	state.kind           = .NewFolder
	state.focused_widget = .Input
}

// --- Internal helpers (used by view + dispatch) --------------------------

@(private)
focus_next :: proc(state: ^State) {
	switch state.focused_widget {
	case .Input:   state.focused_widget = .Primary
	case .Primary: state.focused_widget = .Cancel
	case .Cancel:  state.focused_widget = .Input
	}
}

@(private)
focus_prev :: proc(state: ^State) {
	switch state.focused_widget {
	case .Input:   state.focused_widget = .Cancel
	case .Primary: state.focused_widget = .Input
	case .Cancel:  state.focused_widget = .Primary
	}
}

@(private)
append_value :: proc(state: ^State, text_to_append: string) {
	for byte_value in transmute([]u8)text_to_append {
		append(&state.value_buffer, byte_value)
	}
}

@(private)
backspace_value :: proc(state: ^State) {
	value_length := len(state.value_buffer)
	if value_length == 0 { return }
	new_end_index := value_length - 1
	for new_end_index > 0 && (state.value_buffer[new_end_index] & 0xC0) == 0x80 { new_end_index -= 1 }
	resize(&state.value_buffer, new_end_index)
}

@(private)
try_submit :: proc(state: ^State) -> (intent: Intent, needs_redraw: bool) {
	new_name := strings.trim_space(string(state.value_buffer[:]))
	if len(new_name) == 0 { return nil, false }

	kind := state.kind
	old_name_clone: string
	if kind == .Rename {
		old_name_clone = strings.clone(state.target_name, context.temp_allocator)
	}
	new_name_clone := strings.clone(new_name, context.temp_allocator)

	close(state)

	switch kind {
	case .Rename:    return SubmitRename{old_name = old_name_clone, new_name = new_name_clone}, true
	case .NewFile:   return SubmitNewFile{name = new_name_clone}, true
	case .NewFolder: return SubmitNewFolder{name = new_name_clone}, true
	case .None:      return nil, true
	}
	return nil, true
}

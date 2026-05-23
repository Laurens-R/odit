// Package `git_history` is the F3 modal listing commits that touch
// the active pane's file.
//
// File layout:
//   * `state.odin`    — types + lifecycle + selection/focus helpers.
//   * `dispatch.odin` — open / set_entries / set_error / clear_error.
//   * `view.odin`     — handle_event + render.
//   * `binding.odin`  — vtable + Hooks.
package git_history

import "core:strings"
import "vendor:sdl3"

State :: struct {
	visible:           bool,
	focus:             Focus,
	source_pane_index: int,
	file_path:         string, // owned
	entries:           [dynamic]Entry,
	selected_index:    int,
	scroll_offset:     int,
	visible_row_count: int,
	error_message:     string, // owned

	list_rectangle:   sdl3.FRect,
	ok_rectangle:     sdl3.FRect,
	cancel_rectangle: sdl3.FRect,

	// Stashed at open time so `fetch_revision` can run
	// `git show <hash>:<rel-path>` without re-deriving.
	context_file_directory: string, // owned
	context_relative_path:  string, // owned (forward slashes, repo-root-relative)
}

Focus :: enum {
	List,
	OkButton,
	CancelButton,
}

Entry :: struct {
	hash:       string,
	short_hash: string,
	date:       string,
	author:     string,
	subject:    string,
}

EntrySource :: struct {
	hash:       string,
	short_hash: string,
	date:       string,
	author:     string,
	subject:    string,
}

Intent :: union {
	Activate,
}
Activate :: struct {
	hash:       string,
	short_hash: string,
}

// --- Lifecycle ------------------------------------------------------------

destroy :: proc(state: ^State) {
	clear_entries(state)
	if cap(state.entries) > 0 { delete(state.entries) }
	if len(state.file_path)              > 0 { delete(state.file_path)              }
	if len(state.error_message)          > 0 { delete(state.error_message)          }
	if len(state.context_file_directory) > 0 { delete(state.context_file_directory) }
	if len(state.context_relative_path)  > 0 { delete(state.context_relative_path)  }
	state^ = State{}
}

close :: proc(state: ^State) {
	state.visible = false
}

// --- Internal helpers ----------------------------------------------------

@(private)
clear_entries :: proc(state: ^State) {
	for entry in state.entries {
		if len(entry.hash)       > 0 { delete(entry.hash)       }
		if len(entry.short_hash) > 0 { delete(entry.short_hash) }
		if len(entry.date)       > 0 { delete(entry.date)       }
		if len(entry.author)     > 0 { delete(entry.author)     }
		if len(entry.subject)    > 0 { delete(entry.subject)    }
	}
	clear(&state.entries)
}

@(private)
focus_next :: proc(state: ^State) {
	switch state.focus {
	case .List:         state.focus = .OkButton
	case .OkButton:     state.focus = .CancelButton
	case .CancelButton: state.focus = .List
	}
}

@(private)
focus_prev :: proc(state: ^State) {
	switch state.focus {
	case .List:         state.focus = .CancelButton
	case .OkButton:     state.focus = .List
	case .CancelButton: state.focus = .OkButton
	}
}

@(private)
move_selection :: proc(state: ^State, delta: int) {
	entry_count := len(state.entries)
	if entry_count == 0 { return }
	new_index := state.selected_index + delta
	if new_index < 0           { new_index = 0 }
	if new_index >= entry_count { new_index = entry_count - 1 }
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
try_activate :: proc(state: ^State) -> Intent {
	if state.selected_index < 0 || state.selected_index >= len(state.entries) { return nil }
	selected := state.entries[state.selected_index]
	return Activate{
		hash       = strings.clone(selected.hash,       context.temp_allocator),
		short_hash = strings.clone(selected.short_hash, context.temp_allocator),
	}
}

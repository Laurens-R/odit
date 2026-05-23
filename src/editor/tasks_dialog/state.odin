// Package `tasks_dialog` is the F7 modal listing every build profile +
// debug profile defined in the active project's `.odit/project.json`.
//
// File layout:
//   * `state.odin`    — types + lifecycle + selection helper.
//   * `dispatch.odin` — open with entry sources (called by binding).
//   * `view.odin`     — handle_event + render.
//   * `binding.odin`  — vtable + Hooks for the editor registry.
package tasks_dialog

import "vendor:sdl3"

State :: struct {
	visible:           bool,
	entries:           [dynamic]Entry,
	selected_index:    int,
	scroll_offset:     int,
	visible_row_count: int,
	// Rebuilt every render — one rect per visible row.
	row_rectangles:    [dynamic]sdl3.FRect,
}

EntryKind :: enum {
	BuildProfile,
	DebugProfile,
}

Entry :: struct {
	kind:          EntryKind,
	profile_index: int,
	label:         string, // owned — pre-formatted by the editor
}

EntrySource :: struct {
	kind:          EntryKind,
	profile_index: int,
	label:         string,
}

Intent :: union {
	Activate,
}
Activate :: struct {
	kind:          EntryKind,
	profile_index: int,
}

// --- Lifecycle ------------------------------------------------------------

destroy :: proc(state: ^State) {
	clear_entries(state)
	if cap(state.entries)        > 0 { delete(state.entries)        }
	if cap(state.row_rectangles) > 0 { delete(state.row_rectangles) }
	state^ = State{}
}

close :: proc(state: ^State) {
	state.visible = false
}

// --- Internal helpers ----------------------------------------------------

@(private)
clear_entries :: proc(state: ^State) {
	for entry in state.entries {
		if len(entry.label) > 0 { delete(entry.label) }
	}
	clear(&state.entries)
}

@(private)
move_selection :: proc(state: ^State, delta: int) {
	count := len(state.entries)
	if count == 0 { return }
	new_selection := state.selected_index + delta
	if new_selection < 0      { new_selection = 0 }
	if new_selection >= count { new_selection = count - 1 }
	state.selected_index = new_selection
}

@(private)
try_activate :: proc(state: ^State) -> Intent {
	count := len(state.entries)
	if state.selected_index < 0 || state.selected_index >= count { return nil }
	entry := state.entries[state.selected_index]
	return Activate{ kind = entry.kind, profile_index = entry.profile_index }
}


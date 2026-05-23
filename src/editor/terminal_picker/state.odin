// Package `terminal_picker` is the Ctrl+Shift+F9 modal — a small
// filterable list over every open terminal session that lets the user
// switch the active one.
//
// Structure inside this package:
//   * `state.odin`    — State, Entry, Intent, Host types, lifecycle.
//   * `view.odin`     — `handle_event` + `render`.
//   * `dispatch.odin` — top-level `dispatch_event` glue that routes
//                       `Intent.Activate` through `Host.activate`.
//
// Host (registered by the editor at startup) supplies the entries to
// list and the activation callback. The picker snapshots the entry
// list at open time, then operates on the snapshot until it closes.
package terminal_picker

import "core:fmt"
import "core:strings"

State :: struct {
	visible:           bool,
	entries:           [dynamic]Entry,
	filtered_indices:  [dynamic]int,
	filter_buffer:     [dynamic]u8,
	selected_index:    int,
	scroll_offset:     int,
	visible_row_count: int,
}

// One terminal entry. The host populates these from its terminal list
// at open time — picker holds an owned snapshot.
Entry :: struct {
	display_number: int,  // shown as `Terminal #<n>` in the list
	is_active:      bool, // true for the entry currently in the host's terminal slot
}

// Activation intent. Routed through `Host.activate` by
// `dispatch_event`; callers using `handle_event` directly receive it
// as a value.
Intent :: union {
	Activate,
}
Activate :: struct {
	entry_index: int, // index into the snapshot's entries
}

// Host callbacks. Populated once at startup by the editor.
//
//   * `list_entries` is called at `open` time. The returned slice
//     lives in the host-supplied allocator and is consumed
//     immediately; the picker clones what it needs into its own
//     storage.
//   * `initial_selection` returns the entry index the cursor should
//     land on. Bounded inside the picker so an out-of-range value
//     just clamps to 0.
//   * `activate` fires when the user picks a row; the host swaps to
//     that terminal index.
// --- Lifecycle ------------------------------------------------------------

destroy :: proc(state: ^State) {
	if cap(state.entries)          > 0 { delete(state.entries)          }
	if cap(state.filtered_indices) > 0 { delete(state.filtered_indices) }
	if cap(state.filter_buffer)    > 0 { delete(state.filter_buffer)    }
	state^ = State{}
}

close :: proc(state: ^State) {
	state.visible = false
	clear(&state.filtered_indices)
}

// Open the picker over the host's terminal list. No-op when the host
// reports zero entries — the modal stays closed because there's nothing
// meaningful to pick.
open :: proc(state: ^State, entries: []Entry, initial_selection: int) {
	if len(entries) == 0 { return }

	clear(&state.entries)
	for entry in entries { append(&state.entries, entry) }

	initial := initial_selection
	if initial < 0 { initial = 0 }

	clear(&state.filter_buffer)
	state.selected_index = initial
	state.scroll_offset  = 0
	state.visible        = true
	apply_filter(state)
}

// --- Internal helpers shared by view + dispatch --------------------------

@(private)
apply_filter :: proc(state: ^State) {
	clear(&state.filtered_indices)

	filter_lowercase := strings.to_lower(string(state.filter_buffer[:]), context.temp_allocator)

	for entry, entry_index in state.entries {
		if len(filter_lowercase) == 0 {
			append(&state.filtered_indices, entry_index)
			continue
		}
		// Match against the user-visible label, computed cheaply each
		// time the filter buffer changes.
		label_lowercase := strings.to_lower(label_for(entry), context.temp_allocator)
		if strings.contains(label_lowercase, filter_lowercase) {
			append(&state.filtered_indices, entry_index)
		}
	}

	filtered_count := len(state.filtered_indices)
	if filtered_count == 0 {
		state.selected_index = 0
	} else if state.selected_index >= filtered_count {
		state.selected_index = filtered_count - 1
	}
	if state.selected_index < 0 { state.selected_index = 0 }
}

@(private)
move_selection :: proc(state: ^State, selection_delta: int) {
	filtered_count := len(state.filtered_indices)
	if filtered_count == 0 { return }
	new_selection := state.selected_index + selection_delta
	if new_selection < 0                  { new_selection = 0 }
	if new_selection >= filtered_count    { new_selection = filtered_count - 1 }
	state.selected_index = new_selection
}

@(private)
filter_append :: proc(state: ^State, text_to_append: string) {
	for byte_value in transmute([]u8)text_to_append { append(&state.filter_buffer, byte_value) }
	apply_filter(state)
}

@(private)
filter_backspace :: proc(state: ^State) -> (changed: bool) {
	filter_length := len(state.filter_buffer)
	if filter_length == 0 { return false }
	// Step back one UTF-8 codepoint, not one byte, so backspacing
	// through multi-byte characters doesn't leave dangling
	// continuation bytes.
	new_end_index := filter_length - 1
	for new_end_index > 0 && (state.filter_buffer[new_end_index] & 0xC0) == 0x80 { new_end_index -= 1 }
	resize(&state.filter_buffer, new_end_index)
	apply_filter(state)
	return true
}

@(private)
try_activate :: proc(state: ^State) -> Intent {
	filtered_count := len(state.filtered_indices)
	if filtered_count == 0                                                       { return nil }
	if state.selected_index < 0 || state.selected_index >= filtered_count        { return nil }
	return Activate{ entry_index = state.filtered_indices[state.selected_index] }
}

// Filter-match label. Same shape as the visible row but without the
// active-marker prefix, so the user filters against exactly the body
// text they read.
@(private)
label_for :: proc(entry: Entry) -> string {
	return fmt.tprintf("terminal #%d", entry.display_number)
}

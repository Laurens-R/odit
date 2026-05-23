// Package `open_docs` is the F4 open-documents picker — a filterable
// list of every document loaded in the editor (active pane, other
// pane in a split, background-stashed docs). The user picks one and
// the host either focuses the matching pane or swaps the stashed doc
// into the source pane.
//
// Structure:
//   * `state.odin`    — State, Entry, Intent, Host types, lifecycle,
//                       filter/navigation helpers.
//   * `view.odin`     — handle_event + render.
//   * `dispatch.odin` — dispatch_event glue routing Intent.Activate
//                       through Host.activate.
//
// The host snapshots its loaded docs into [EntrySource]s at open time;
// the picker owns the cloned strings until close.
package open_docs

import "core:strings"

State :: struct {
	visible:           bool,
	source_pane_index: int, // pane the user opened the dialog from
	entries:           [dynamic]Entry,
	filtered_indices:  [dynamic]int,
	filter_buffer:     [dynamic]u8,
	selected_index:    int,
	scroll_offset:     int,
	visible_row_count: int,
}

// Where a doc lives at the moment the dialog opens. The active pane
// is listed so the user has an anchor for the rest of the list —
// selecting it is a no-op activation.
EntryLocation :: enum {
	ActivePane,
	OtherPane,
	Background,
}

Entry :: struct {
	location:         EntryLocation,
	pane_index:       int,    // valid when location == .OtherPane
	background_index: int,    // valid when location == .Background
	is_dirty:         bool,
	label:            string, // owned
}

// Lightweight source struct the host hands to `open` via the Host's
// `list_entries` callback. Strings NOT owned by the host after the
// call — the picker clones them.
EntrySource :: struct {
	location:         EntryLocation,
	pane_index:       int,
	background_index: int,
	is_dirty:         bool,
	label:            string,
}

Intent :: union {
	Activate,
}
Activate :: struct {
	location:         EntryLocation,
	pane_index:       int,
	background_index: int,
}

// --- Lifecycle ------------------------------------------------------------

destroy :: proc(state: ^State) {
	clear_entries(state)
	if cap(state.entries)          > 0 { delete(state.entries) }
	if cap(state.filtered_indices) > 0 { delete(state.filtered_indices) }
	if cap(state.filter_buffer)    > 0 { delete(state.filter_buffer) }
	state^ = State{}
}

close :: proc(state: ^State) {
	state.visible = false
	clear_entries(state)
	clear(&state.filtered_indices)
}

// Open the modal with a pre-fetched entry list (binding wrapper
// resolves it via Hooks). `source_pane_index` is what the host
// passes back as the "from where" pane on activate so background
// swaps land in the right place.
open :: proc(state: ^State, source_pane_index: int, sources: []EntrySource) {
	clear_entries(state)
	for source in sources {
		append(&state.entries, Entry{
			location         = source.location,
			pane_index       = source.pane_index,
			background_index = source.background_index,
			is_dirty         = source.is_dirty,
			label            = strings.clone(source.label),
		})
	}

	state.source_pane_index = source_pane_index
	state.selected_index    = 0
	state.scroll_offset     = 0
	clear(&state.filter_buffer)
	state.visible           = true
	apply_filter(state)
}

// --- Internal helpers (used by view + dispatch) --------------------------

@(private)
clear_entries :: proc(state: ^State) {
	for entry in state.entries {
		if len(entry.label) > 0 { delete(entry.label) }
	}
	clear(&state.entries)
}

@(private)
apply_filter :: proc(state: ^State) {
	clear(&state.filtered_indices)
	filter_lowercase := strings.to_lower(string(state.filter_buffer[:]), context.temp_allocator)

	for entry, entry_index in state.entries {
		if len(filter_lowercase) == 0 {
			append(&state.filtered_indices, entry_index)
			continue
		}
		label_lowercase := strings.to_lower(entry.label, context.temp_allocator)
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
	entry_source_index := state.filtered_indices[state.selected_index]
	if entry_source_index < 0 || entry_source_index >= len(state.entries)        { return nil }
	selected_entry := state.entries[entry_source_index]
	return Activate{
		location         = selected_entry.location,
		pane_index       = selected_entry.pane_index,
		background_index = selected_entry.background_index,
	}
}

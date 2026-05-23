// Package `completion_popup` — Ctrl+Space LSP completion popup.
//
// File layout:
//   * `state.odin`    — types + lifecycle + filter/selection helpers.
//   * `dispatch.odin` — open / set_items / consume_text /
//                       consume_backspace / auto-close.
//   * `view.odin`     — handle_key + render.
//   * `binding.odin`  — vtable + Hooks for the editor registry.
package completion_popup

import "core:strings"
import "vendor:sdl3"

State :: struct {
	visible:           bool,
	pane_index:        int,
	anchor_line:       u32,
	anchor_column:     u32,
	filter_buffer:     [dynamic]u8,
	selected_index:    int, // index into filtered indices, not items_snapshot
	scroll_offset:     int,
	request_pending:   bool,
	items_snapshot:    [dynamic]Item,
}

Item :: struct {
	label:              string, // owned
	detail:             string, // owned
	insert_text:        string, // owned
	label_pixel_width:  i32,
	detail_pixel_width: i32,
}

ItemSource :: struct {
	label:       string,
	detail:      string,
	insert_text: string,
}

AnchorScreenPosition :: struct {
	cursor_screen_top_y: i32,
	cursor_line_height:  i32,
	character_width:     i32,
	cursor_screen_x:     i32,
}

CursorState :: struct {
	pane_index:    int,
	cursor_line:   u32,
	cursor_column: u32,
	pane_is_editor: bool,
}

Chrome :: struct {
	background:    sdl3.FColor,
	border:        sdl3.FColor,
	selection:     sdl3.FColor,
	label:         sdl3.FColor,
	label_selected: sdl3.FColor,
	detail:        sdl3.FColor,
	stub:          sdl3.FColor,
}

Intent :: union {
	Accept,
}
Accept :: struct {
	insert_text: string, // lives in temp_allocator
}

// --- Lifecycle ------------------------------------------------------------

destroy :: proc(state: ^State) {
	clear_items(state)
	if cap(state.items_snapshot) > 0 { delete(state.items_snapshot) }
	if cap(state.filter_buffer)  > 0 { delete(state.filter_buffer)  }
	state^ = State{}
}

close :: proc(state: ^State) {
	clear_items(state)
	clear(&state.filter_buffer)
	state.visible         = false
	state.request_pending = false
	state.selected_index  = 0
	state.scroll_offset   = 0
}

// --- Internal helpers (used by dispatch + view) --------------------------

@(private)
clear_items :: proc(state: ^State) {
	for item in state.items_snapshot {
		if len(item.label)       > 0 { delete(item.label) }
		if len(item.detail)      > 0 { delete(item.detail) }
		if len(item.insert_text) > 0 { delete(item.insert_text) }
	}
	clear(&state.items_snapshot)
}

@(private)
move_selection :: proc(state: ^State, delta: int) {
	filtered := filtered_indices(state); defer delete(filtered)
	if len(filtered) == 0 { return }
	new_index := state.selected_index + delta
	if new_index < 0                 { new_index = 0 }
	if new_index >= len(filtered)    { new_index = len(filtered) - 1 }
	state.selected_index = new_index
}

// Indices into `items_snapshot` matching the current filter. Caller
// owns the slice.
@(private)
filtered_indices :: proc(state: ^State) -> []int {
	indices: [dynamic]int
	filter_string := string(state.filter_buffer[:])
	filter_lower := strings.to_lower(filter_string, context.temp_allocator)
	for item, item_index in state.items_snapshot {
		if len(filter_lower) == 0 {
			append(&indices, item_index)
			continue
		}
		label_lower := strings.to_lower(item.label, context.temp_allocator)
		if strings.contains(label_lower, filter_lower) {
			append(&indices, item_index)
		}
	}
	return indices[:]
}

@(private)
try_accept :: proc(state: ^State) -> (intent: Accept, ok: bool) {
	filtered := filtered_indices(state); defer delete(filtered)
	if len(filtered) == 0                                                  { return {}, false }
	if state.selected_index < 0 || state.selected_index >= len(filtered)   { return {}, false }
	item_index := filtered[state.selected_index]
	if item_index < 0 || item_index >= len(state.items_snapshot)           { return {}, false }
	insert_text := state.items_snapshot[item_index].insert_text
	return Accept{ insert_text = strings.clone(insert_text, context.temp_allocator) }, true
}


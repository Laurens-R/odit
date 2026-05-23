// Package `symbols` is the F6 symbol picker — a filterable list of every
// declaration the syntax extractor found in the active editor pane, with
// a tree-structured display that mirrors namespace / type / function
// nesting.
//
// Structure:
//   * `state.odin`    — types (State, Intent, Host), lifecycle, filter /
//                       selection helpers, parent-index computation.
//   * `view.odin`     — handle_event + render.
//   * `dispatch.odin` — dispatch_event + dispatch_render glue routing
//                       intents and fetching the symbols slice / title
//                       from the host.
//
// The subpackage doesn't own the symbol data. The editor pane already
// holds it (`editor_pane.symbols`) — it's used by syntax highlighting
// too. The host returns the slice on each dispatch; the subpackage
// filters / navigates / paints, and routes `Activate{symbol_index}` back
// through the host so the editor can jump the cursor.
package symbols

import "core:strings"

import "../../syntax"

State :: struct {
	visible:           bool,
	source_pane_index: int,
	filtered_indices:  [dynamic]int, // indices into the symbols slice last passed in
	filter_buffer:     [dynamic]u8,
	selected_index:    int,
	scroll_offset:     int,
	visible_row_count: int,
}

// Intent returned on activation. `symbol_index` is into the same
// symbols slice the caller passed to `handle_event`. The popup closes
// itself before returning, so the host can apply the cursor jump
// without worrying about subsequent calls finding the slice dangling.
Intent :: union {
	Activate,
}
Activate :: struct {
	symbol_index: int,
}

// --- Lifecycle -----------------------------------------------------------

destroy :: proc(state: ^State) {
	if cap(state.filtered_indices) > 0 { delete(state.filtered_indices) }
	if cap(state.filter_buffer)    > 0 { delete(state.filter_buffer) }
	state^ = State{}
}

close :: proc(state: ^State) {
	state.visible = false
}

// Begin a session over the symbols on `source_pane_index`. Caller must
// re-run its symbol-extractor before this so the slice the host returns
// on subsequent dispatches is fresh.
open :: proc(state: ^State, source_pane_index: int, symbols: []syntax.Symbol) {
	state.visible           = true
	state.source_pane_index = source_pane_index
	state.selected_index    = 0
	state.scroll_offset     = 0
	clear(&state.filter_buffer)
	apply_filter(state, symbols)
}

// --- Internal helpers (used by view) -------------------------------------

@(private)
kind_tag_string :: proc(symbol_kind: syntax.SymbolKind) -> string {
	switch symbol_kind {
	case .Function: return "fn "
	case .Type:     return "T  "
	case .Variable: return "var"
	case .Module:   return "mod"
	case .Other:    return "   "
	}
	return "   "
}

// Compute each symbol's direct parent (the most recent earlier symbol
// with strictly smaller depth). Symbols are emitted in source order, so
// a parent always sits at a lower index than its children.
@(private)
compute_parent_indices :: proc(symbols: []syntax.Symbol, allocator := context.allocator) -> []int {
	parent_indices := make([]int, len(symbols), allocator)
	for symbol_index in 0..<len(symbols) {
		parent_indices[symbol_index] = -1
		symbol_depth := symbols[symbol_index].depth
		if symbol_depth > 0 {
			for candidate_parent_index := symbol_index - 1; candidate_parent_index >= 0; candidate_parent_index -= 1 {
				if symbols[candidate_parent_index].depth < symbol_depth {
					parent_indices[symbol_index] = candidate_parent_index
					break
				}
			}
		}
	}
	return parent_indices
}

@(private)
apply_filter :: proc(state: ^State, symbols: []syntax.Symbol) {
	clear(&state.filtered_indices)

	filter_lowercase := strings.to_lower(string(state.filter_buffer[:]), context.temp_allocator)

	// Visibility:
	//   * depth 0                       → always show
	//   * deeper, but no parent          → show (the brace was bumped
	//                                     by something the extractor
	//                                     didn't capture — anonymous
	//                                     namespace, `extern "C" { … }`,
	//                                     etc. The user thinks of these
	//                                     as top-level).
	//   * parent is Type or Module AND
	//     parent is shown                → show (Type and Module are
	//                                     transparent containers, so
	//                                     members of namespaces / nested
	//                                     classes propagate).
	// Everything else (locals in a Function, lambda captures, …) stays
	// hidden.
	symbol_count := len(symbols)
	parent_indices := compute_parent_indices(symbols, context.temp_allocator)
	is_visible_symbol := make([]bool, symbol_count, context.temp_allocator)
	for symbol_index in 0..<symbol_count {
		current_symbol := symbols[symbol_index]
		if current_symbol.depth == 0 {
			is_visible_symbol[symbol_index] = true
		} else if parent_indices[symbol_index] < 0 {
			is_visible_symbol[symbol_index] = true
		} else {
			parent_symbol := symbols[parent_indices[symbol_index]]
			if (parent_symbol.kind == .Type || parent_symbol.kind == .Module) && is_visible_symbol[parent_indices[symbol_index]] {
				is_visible_symbol[symbol_index] = true
			}
		}
	}

	for symbol, symbol_index in symbols {
		if !is_visible_symbol[symbol_index] { continue }
		if len(filter_lowercase) == 0 {
			append(&state.filtered_indices, symbol_index)
			continue
		}
		symbol_name_lowercase := strings.to_lower(symbol.name, context.temp_allocator)
		if strings.contains(symbol_name_lowercase, filter_lowercase) {
			append(&state.filtered_indices, symbol_index)
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
filter_append :: proc(state: ^State, symbols: []syntax.Symbol, text_to_append: string) {
	for byte_value in transmute([]u8)text_to_append { append(&state.filter_buffer, byte_value) }
	apply_filter(state, symbols)
}

@(private)
filter_backspace :: proc(state: ^State, symbols: []syntax.Symbol) -> (changed: bool) {
	filter_length := len(state.filter_buffer)
	if filter_length == 0 { return false }
	new_end_index := filter_length - 1
	for new_end_index > 0 && (state.filter_buffer[new_end_index] & 0xC0) == 0x80 { new_end_index -= 1 }
	resize(&state.filter_buffer, new_end_index)
	apply_filter(state, symbols)
	return true
}

@(private)
try_activate :: proc(state: ^State) -> Intent {
	filtered_count := len(state.filtered_indices)
	if filtered_count == 0                                                       { return nil }
	if state.selected_index < 0 || state.selected_index >= filtered_count        { return nil }
	symbol_source_index := state.filtered_indices[state.selected_index]
	return Activate{ symbol_index = symbol_source_index }
}


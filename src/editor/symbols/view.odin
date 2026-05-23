// Event handling + render for the F6 symbol picker.
package symbols

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "vendor:sdl3"

import "../../syntax"
import "../../ui"

handle_event :: proc(state: ^State, event: ^sdl3.Event, symbols: []syntax.Symbol) -> (intent: Intent, needs_redraw: bool) {
	if !state.visible { return nil, false }

	#partial switch event.type {
	case .TEXT_INPUT:
		input_text := string(event.text.text)
		if len(input_text) > 0 {
			filter_append(state, symbols, input_text)
			needs_redraw = true
		}

	case .KEY_DOWN:
		pressed_key := event.key.key
		switch pressed_key {
		case sdl3.K_ESCAPE, sdl3.K_F6:
			close(state)
			needs_redraw = true
		case sdl3.K_UP:
			move_selection(state, -1)
			needs_redraw = true
		case sdl3.K_DOWN:
			move_selection(state, 1)
			needs_redraw = true
		case sdl3.K_PAGEUP:
			page_step := state.visible_row_count
			if page_step < 1 { page_step = 1 }
			move_selection(state, -page_step)
			needs_redraw = true
		case sdl3.K_PAGEDOWN:
			page_step := state.visible_row_count
			if page_step < 1 { page_step = 1 }
			move_selection(state, page_step)
			needs_redraw = true
		case sdl3.K_HOME:
			move_selection(state, -len(state.filtered_indices))
			needs_redraw = true
		case sdl3.K_END:
			move_selection(state, len(state.filtered_indices))
			needs_redraw = true
		case sdl3.K_RETURN:
			intent = try_activate(state)
			if intent != nil {
				close(state)
				needs_redraw = true
			}
		case sdl3.K_BACKSPACE:
			if filter_backspace(state, symbols) { needs_redraw = true }
		}
	}
	return intent, needs_redraw
}

render :: proc(state: ^State, ui_context: ^ui.Context, symbols: []syntax.Symbol, dialog_title: string, viewport_width, viewport_height: i32) {
	theme := ui.default_theme()
	ui.draw_dim_overlay(ui_context, viewport_width, viewport_height, theme.overlay)

	desired_columns: i32 = 64
	desired_rows: i32 = 26
	dialog_width  := min(desired_columns * ui_context.character_width + 32, viewport_width  - 40)
	dialog_height := min(desired_rows * ui_context.line_height + 40, viewport_height - 40)
	if dialog_width  < 240 { dialog_width  = min(viewport_width  - 16, 240) }
	if dialog_height < 200 { dialog_height = min(viewport_height - 16, 200) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	content_rectangle := ui.draw_window(ui_context, dialog_rectangle, dialog_title, theme)

	line_step     := ui_context.line_height
	content_x     := i32(content_rectangle.x)
	content_y     := i32(content_rectangle.y)
	content_width := i32(content_rectangle.w)

	filter_string := string(state.filter_buffer[:])
	ui.draw_input_field(ui_context, content_x, content_y, content_width, "Filter: ", filter_string, theme)
	content_y += line_step + 8

	footer_height: i32 = line_step + 12
	list_top_y       := content_y
	list_bottom_y    := i32(dialog_rectangle.y + dialog_rectangle.h) - footer_height - 12
	list_area_height := list_bottom_y - list_top_y
	computed_visible_rows := int(list_area_height / line_step)
	if computed_visible_rows < 1 { computed_visible_rows = 1 }
	state.visible_row_count = computed_visible_rows

	if state.selected_index < state.scroll_offset {
		state.scroll_offset = state.selected_index
	} else if state.selected_index >= state.scroll_offset + computed_visible_rows {
		state.scroll_offset = state.selected_index - computed_visible_rows + 1
	}
	if state.scroll_offset < 0 { state.scroll_offset = 0 }

	if len(state.filtered_indices) == 0 {
		empty_message := len(symbols) == 0 ? "(no symbols in this file)" : "(no matches)"
		ui.draw_text(ui_context, empty_message, content_x + 8, list_top_y, theme.dim_foreground)
	} else {
		// Precompute parent indices for every symbol, plus a
		// "last visible child" flag keyed by original symbol index.
		// These drive the box-drawing tree prefix in front of each row:
		// the flag for the row itself decides between `├─` and `└─`,
		// while each ancestor in the chain decides between `│ ` (more
		// siblings to come) and `  ` (subtree is done).
		filtered_indices_view := state.filtered_indices[:]
		parent_indices := compute_parent_indices(symbols, context.temp_allocator)

		is_last_by_source_index := make(map[int]bool, 0, context.temp_allocator)
		seen_parent_indices     := make(map[int]bool, 0, context.temp_allocator)
		for reverse_filtered_index := len(filtered_indices_view) - 1; reverse_filtered_index >= 0; reverse_filtered_index -= 1 {
			source_symbol_index := filtered_indices_view[reverse_filtered_index]
			parent_index := parent_indices[source_symbol_index]
			if _, already_seen := seen_parent_indices[parent_index]; !already_seen {
				is_last_by_source_index[source_symbol_index] = true
				seen_parent_indices[parent_index] = true
			}
		}

		end_row_index := min(state.scroll_offset + computed_visible_rows, len(filtered_indices_view))
		for row_index := state.scroll_offset; row_index < end_row_index; row_index += 1 {
			source_symbol_index := filtered_indices_view[row_index]
			current_symbol := symbols[source_symbol_index]
			row_y_position := list_top_y + i32(row_index - state.scroll_offset) * line_step
			kind_tag := kind_tag_string(current_symbol.kind)

			// Walk the ancestor chain (deepest first), then emit one
			// segment per depth level. For depth D the row produces D
			// segments — the last is the tee (├─/└─), the rest are
			// trunks (│ /  ).
			symbol_depth := int(current_symbol.depth)
			prefix_builder: strings.Builder
			strings.builder_init(&prefix_builder, context.temp_allocator)
			if symbol_depth > 0 {
				ancestor_chain := make([]int, symbol_depth, context.temp_allocator)
				current_ancestor := source_symbol_index
				for depth_index := symbol_depth - 1; depth_index >= 0; depth_index -= 1 {
					current_ancestor = parent_indices[current_ancestor]
					ancestor_chain[depth_index] = current_ancestor
				}
				for chain_index in 0..<symbol_depth {
					entity_source_index := source_symbol_index
					if chain_index != symbol_depth - 1 { entity_source_index = ancestor_chain[chain_index+1] }
					entity_is_last := false
					if last_value, has_last := is_last_by_source_index[entity_source_index]; has_last { entity_is_last = last_value }
					if chain_index == symbol_depth - 1 {
						strings.write_string(&prefix_builder, entity_is_last ? "└─ " : "├─ ")
					} else {
						strings.write_string(&prefix_builder, entity_is_last ? "   " : "│  ")
					}
				}
			}
			tree_prefix := strings.to_string(prefix_builder)

			// Pad by display cells (rune count) so the box-drawing
			// chars — which are 3 UTF-8 bytes each but a single cell
			// wide — don't throw off Ln-column alignment the way %-Ns
			// (byte-padded) would.
			name_cell_count := utf8.rune_count_in_string(tree_prefix) + utf8.rune_count_in_string(current_symbol.name)
			target_cell_count := 32
			padding_amount := target_cell_count - name_cell_count
			if padding_amount < 1 { padding_amount = 1 }
			padding_string := strings.repeat(" ", padding_amount, context.temp_allocator)
			row_label := fmt.tprintf("%s  %s%s%s  Ln %d", kind_tag, tree_prefix, current_symbol.name, padding_string, current_symbol.line + 1)

			is_selected := row_index == state.selected_index
			ui.draw_list_row(ui_context, content_x, row_y_position, content_width, row_label, is_selected, theme)
		}
	}

	hint_text := "↑/↓ navigate    Enter jump    Type to filter    Esc close"
	hint_width, _ := ui.text_size(ui_context, hint_text)
	footer_x := i32(dialog_rectangle.x + (dialog_rectangle.w - f32(hint_width)) / 2)
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - line_step - 10
	ui.draw_text(ui_context, hint_text, footer_x, footer_y, theme.dim_foreground)
}

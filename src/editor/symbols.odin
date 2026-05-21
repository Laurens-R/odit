package editor

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "vendor:sdl3"

import "../document"
import "../syntax"
import "../ui"

// --- Per-pane symbol cache ------------------------------------------------

// Walk every line of the pane's doc through the language's symbol patterns
// and rebuild the `symbols` list + `symbol_names` lookup. Called on file load
// and on F6 (so the dialog always shows fresh data).
@(private)
pane_rebuild_symbols :: proc(editor_pane: ^EditorPane) {
	for existing_symbol in editor_pane.symbols { delete(existing_symbol.name) }
	clear(&editor_pane.symbols)
	clear(&editor_pane.symbol_names)

	if editor_pane.language == nil { return }

	total_line_count := document.document_line_count(&editor_pane.document)

	// Materialize every line into a slice once — the syntax matcher works on
	// a whole-file lexeme stream so patterns like
	// `template ... class {NAME} {` can span newlines.
	all_lines := make([]string, total_line_count, context.temp_allocator)
	for line_index in 0..<total_line_count {
		all_lines[line_index] = document.document_get_line(&editor_pane.document, line_index, context.temp_allocator)
	}

	// Pass 1: discover user-declared type names so the `{TYPE}` placeholder
	// can resolve references regardless of declaration order (e.g.
	// `x : MyStruct` on line 10 with `MyStruct :: struct` on line 200).
	// All allocations live in temp_allocator and survive until the end of
	// this proc, after pass 2 has consumed the map.
	known_type_names := make(map[string]bool, 0, context.temp_allocator)
	{
		scratch_symbols: [dynamic]syntax.Symbol
		scratch_symbols.allocator = context.temp_allocator
		syntax.extract_symbols_from_lines(editor_pane.language, all_lines, &scratch_symbols, nil, context.temp_allocator)
		for scratch_symbol in scratch_symbols {
			if scratch_symbol.kind == .Type { known_type_names[scratch_symbol.name] = true }
		}
	}

	// Pass 2: full extraction (names cloned with the long-lived allocator).
	syntax.extract_symbols_from_lines(editor_pane.language, all_lines, &editor_pane.symbols, &known_type_names)

	for extracted_symbol in editor_pane.symbols {
		editor_pane.symbol_names[extracted_symbol.name] = extracted_symbol.kind
	}
}

// --- Dialog state ---------------------------------------------------------

@(private)
SymbolsDialog :: struct {
	source_pane_index: int,          // pane the symbols belong to
	filtered_indices:  [dynamic]int, // indices into source pane's `symbols`
	filter_buffer:     [dynamic]u8,
	selected_index:    int,
	scroll_offset:     int,
	visible_row_count: int,
}

@(private)
symbols_dialog_destroy :: proc(symbols_dialog: ^SymbolsDialog) {
	delete(symbols_dialog.filtered_indices)
	delete(symbols_dialog.filter_buffer)
	symbols_dialog^ = SymbolsDialog{}
}

@(private)
symbols_dialog_open :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor)
	if editor_pane == nil { return }

	// Always refresh the symbol cache when opening the dialog so the user
	// sees the latest declarations (even ones added since the file was
	// loaded — the rest of the highlighter only rebuilds on file load).
	pane_rebuild_symbols(editor_pane)
	// Manual rebuild satisfies the auto-reanalyze contract too, so reset
	// both gates — otherwise editor_update would queue another redundant
	// rebuild moments later.
	editor_pane.symbols_dirty      = false
	editor_pane.last_analysis_time = editor.clock

	editor.symbols_dialog.source_pane_index = editor.active_pane_index
	clear(&editor.symbols_dialog.filter_buffer)
	editor.symbols_dialog.selected_index = 0
	editor.symbols_dialog.scroll_offset  = 0
	symbols_dialog_apply_filter(editor)
	editor.show_symbols = true
}

@(private)
symbols_dialog_close :: proc(editor: ^Editor) {
	editor.show_symbols = false
}

// --- Filter / navigation --------------------------------------------------

@(private="file")
symbols_dialog_apply_filter :: proc(editor: ^Editor) {
	clear(&editor.symbols_dialog.filtered_indices)

	source_editor_pane := pane_as_editor(&editor.panes[editor.symbols_dialog.source_pane_index])
	if source_editor_pane == nil { return }

	filter_lowercase := strings.to_lower(string(editor.symbols_dialog.filter_buffer[:]), context.temp_allocator)

	// Compute each symbol's direct parent (the most recent earlier symbol
	// with strictly smaller depth) and precompute visibility in a single
	// forward pass — symbols are emitted in source order, so a parent
	// always sits at a lower index than its children.
	symbol_count := len(source_editor_pane.symbols)
	parent_indices := make([]int, symbol_count, context.temp_allocator)
	is_visible_symbol := make([]bool, symbol_count, context.temp_allocator)
	for symbol_index in 0..<symbol_count {
		parent_indices[symbol_index] = -1
		symbol_depth := source_editor_pane.symbols[symbol_index].depth
		if symbol_depth != 0 {
			for candidate_parent_index := symbol_index - 1; candidate_parent_index >= 0; candidate_parent_index -= 1 {
				if source_editor_pane.symbols[candidate_parent_index].depth < symbol_depth {
					parent_indices[symbol_index] = candidate_parent_index
					break
				}
			}
		}

		// Visibility:
		//   * depth 0                    → always show
		//   * deeper, but no parent      → show. The brace was bumped by
		//                                  something the extractor didn't
		//                                  capture (anonymous namespace,
		//                                  `extern "C" { … }`, …), so the
		//                                  user thinks of this as top-level.
		//   * parent is Type or Module
		//     AND that parent is shown   → show. Type and Module are
		//                                  transparent containers, so
		//                                  members of namespaces or nested
		//                                  classes / sub-namespaces propagate.
		// Everything else (locals in a Function, lambda captures, etc.)
		// stays hidden.
		current_symbol := source_editor_pane.symbols[symbol_index]
		if current_symbol.depth == 0 {
			is_visible_symbol[symbol_index] = true
		} else if parent_indices[symbol_index] < 0 {
			is_visible_symbol[symbol_index] = true
		} else {
			parent_symbol := source_editor_pane.symbols[parent_indices[symbol_index]]
			if (parent_symbol.kind == .Type || parent_symbol.kind == .Module) && is_visible_symbol[parent_indices[symbol_index]] {
				is_visible_symbol[symbol_index] = true
			}
		}
	}

	for symbol, symbol_index in source_editor_pane.symbols {
		if !is_visible_symbol[symbol_index] { continue }

		if len(filter_lowercase) == 0 {
			append(&editor.symbols_dialog.filtered_indices, symbol_index)
			continue
		}
		symbol_name_lowercase := strings.to_lower(symbol.name, context.temp_allocator)
		if strings.contains(symbol_name_lowercase, filter_lowercase) {
			append(&editor.symbols_dialog.filtered_indices, symbol_index)
		}
	}

	filtered_count := len(editor.symbols_dialog.filtered_indices)
	if filtered_count == 0 {
		editor.symbols_dialog.selected_index = 0
	} else if editor.symbols_dialog.selected_index >= filtered_count {
		editor.symbols_dialog.selected_index = filtered_count - 1
	}
	if editor.symbols_dialog.selected_index < 0 { editor.symbols_dialog.selected_index = 0 }
}

@(private="file")
symbols_dialog_move_selection :: proc(editor: ^Editor, selection_delta: int) {
	filtered_count := len(editor.symbols_dialog.filtered_indices)
	if filtered_count == 0 { return }
	new_selection := editor.symbols_dialog.selected_index + selection_delta
	if new_selection < 0 { new_selection = 0 }
	if new_selection >= filtered_count { new_selection = filtered_count - 1 }
	editor.symbols_dialog.selected_index = new_selection
}

@(private="file")
symbols_dialog_filter_append :: proc(editor: ^Editor, text_to_append: string) {
	for byte_value in transmute([]u8)text_to_append { append(&editor.symbols_dialog.filter_buffer, byte_value) }
	symbols_dialog_apply_filter(editor)
}

@(private="file")
symbols_dialog_filter_backspace :: proc(editor: ^Editor) {
	filter_length := len(editor.symbols_dialog.filter_buffer)
	if filter_length == 0 { return }
	new_end_index := filter_length - 1
	for new_end_index > 0 && (editor.symbols_dialog.filter_buffer[new_end_index] & 0xC0) == 0x80 { new_end_index -= 1 }
	resize(&editor.symbols_dialog.filter_buffer, new_end_index)
	symbols_dialog_apply_filter(editor)
}

@(private="file")
symbols_dialog_activate :: proc(editor: ^Editor) {
	filtered_count := len(editor.symbols_dialog.filtered_indices)
	if filtered_count == 0 { return }
	if editor.symbols_dialog.selected_index < 0 || editor.symbols_dialog.selected_index >= filtered_count { return }

	source_editor_pane := pane_as_editor(&editor.panes[editor.symbols_dialog.source_pane_index])
	if source_editor_pane == nil { return }

	symbol_source_index := editor.symbols_dialog.filtered_indices[editor.symbols_dialog.selected_index]
	if symbol_source_index < 0 || symbol_source_index >= len(source_editor_pane.symbols) { return }
	selected_symbol := source_editor_pane.symbols[symbol_source_index]

	// Focus the source pane and place the cursor on the symbol's name.
	editor.active_pane_index = editor.symbols_dialog.source_pane_index

	document_line_count := document.document_line_count(&source_editor_pane.document)
	target_line := selected_symbol.line
	if target_line >= document_line_count { target_line = document_line_count - 1 }

	line_start_offset := document.document_line_start(&source_editor_pane.document, target_line)
	line_text         := document.document_get_line(&source_editor_pane.document, target_line, context.temp_allocator)
	target_column     := selected_symbol.column
	if int(target_column) > len(line_text) { target_column = u32(len(line_text)) }

	source_editor_pane.cursor_line      = target_line
	source_editor_pane.cursor_column    = target_column
	source_editor_pane.cursor_offset    = line_start_offset + target_column
	source_editor_pane.selection_active = false

	editor.cursor_visible = true
	editor.cursor_timer = 0

	// Position the target line at the top of the pane's text area instead of
	// just making it visible. `scroll_y` is clamped at 0 so we never scroll
	// "above" the first line. The end of the document is intentionally not
	// clamped — when jumping near EOF we accept some empty space below so
	// the symbol stays anchored at the top, matching "scroll up as much as
	// possible" semantics. In diff mode the layout is row-indexed and
	// shared between panes, so we defer to the existing scroll-into-view
	// behaviour there.
	if editor.diff_state.active || editor.line_height <= 0 {
		sync_cursor_from_offset(editor)
	} else {
		target_scroll_y := f32(target_line) * f32(editor.line_height)
		if target_scroll_y < 0 { target_scroll_y = 0 }
		source_editor_pane.scroll_y        = target_scroll_y
		source_editor_pane.scroll_y_target = target_scroll_y
		source_editor_pane.scroll_line     = target_line
	}

	symbols_dialog_close(editor)
}

// --- Input ---------------------------------------------------------------

@(private)
symbols_dialog_handle_event :: proc(editor: ^Editor, event: ^sdl3.Event) {
	#partial switch event.type {
	case .TEXT_INPUT:
		input_text := string(event.text.text)
		if len(input_text) > 0 { symbols_dialog_filter_append(editor, input_text) }

	case .KEY_DOWN:
		pressed_key := event.key.key
		switch pressed_key {
		case sdl3.K_ESCAPE, sdl3.K_F6:
			symbols_dialog_close(editor)
		case sdl3.K_UP:
			symbols_dialog_move_selection(editor, -1)
		case sdl3.K_DOWN:
			symbols_dialog_move_selection(editor, 1)
		case sdl3.K_PAGEUP:
			page_step := editor.symbols_dialog.visible_row_count
			if page_step < 1 { page_step = 1 }
			symbols_dialog_move_selection(editor, -page_step)
		case sdl3.K_PAGEDOWN:
			page_step := editor.symbols_dialog.visible_row_count
			if page_step < 1 { page_step = 1 }
			symbols_dialog_move_selection(editor, page_step)
		case sdl3.K_HOME:
			symbols_dialog_move_selection(editor, -len(editor.symbols_dialog.filtered_indices))
		case sdl3.K_END:
			symbols_dialog_move_selection(editor, len(editor.symbols_dialog.filtered_indices))
		case sdl3.K_RETURN:
			symbols_dialog_activate(editor)
		case sdl3.K_BACKSPACE:
			symbols_dialog_filter_backspace(editor)
		}
	}
}

// --- Rendering ------------------------------------------------------------

@(private="file")
symbol_kind_tag :: proc(symbol_kind: syntax.SymbolKind) -> string {
	switch symbol_kind {
	case .Function: return "fn "
	case .Type:     return "T  "
	case .Variable: return "var"
	case .Module:   return "mod"
	case .Other:    return "   "
	}
	return "   "
}

@(private)
symbols_dialog_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, viewport_width, viewport_height: i32) {
	ui_context := editor_make_ui_context(editor, renderer)
	theme := ui.default_theme()

	ui.draw_dim_overlay(&ui_context, viewport_width, viewport_height, theme.overlay)

	desired_columns: i32 = 64
	desired_rows: i32 = 26
	dialog_width  := min(desired_columns * editor.character_width + 32, viewport_width  - 40)
	dialog_height := min(desired_rows * editor.line_height + 40, viewport_height - 40)
	if dialog_width  < 240 { dialog_width  = min(viewport_width  - 16, 240) }
	if dialog_height < 200 { dialog_height = min(viewport_height - 16, 200) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	// Title — derive from the source pane's file name if any.
	dialog_title: string
	if source_pane := pane_as_editor(&editor.panes[editor.symbols_dialog.source_pane_index]); source_pane != nil {
		display_filename := source_pane.file_path != "" ? filepath_base_in_dialog(source_pane.file_path) : "untitled"
		dialog_title = fmt.tprintf("Symbols — %s", display_filename)
	} else {
		dialog_title = "Symbols"
	}
	content_rectangle := ui.draw_window(&ui_context, dialog_rectangle, dialog_title, theme)

	line_step := editor.line_height
	content_x := i32(content_rectangle.x)
	content_y := i32(content_rectangle.y)
	content_width := i32(content_rectangle.w)

	// Filter field
	filter_string := string(editor.symbols_dialog.filter_buffer[:])
	ui.draw_input_field(&ui_context, content_x, content_y, content_width, "Filter: ", filter_string, theme)
	content_y += line_step + 8

	// Footer reservation
	footer_height: i32 = line_step + 12
	list_top_y     := content_y
	list_bottom_y  := i32(dialog_rectangle.y + dialog_rectangle.h) - footer_height - 12
	list_area_height := list_bottom_y - list_top_y
	computed_visible_rows := int(list_area_height / line_step)
	if computed_visible_rows < 1 { computed_visible_rows = 1 }
	editor.symbols_dialog.visible_row_count = computed_visible_rows

	// Adjust scroll so the selected row is in view.
	if editor.symbols_dialog.selected_index < editor.symbols_dialog.scroll_offset {
		editor.symbols_dialog.scroll_offset = editor.symbols_dialog.selected_index
	} else if editor.symbols_dialog.selected_index >= editor.symbols_dialog.scroll_offset + computed_visible_rows {
		editor.symbols_dialog.scroll_offset = editor.symbols_dialog.selected_index - computed_visible_rows + 1
	}
	if editor.symbols_dialog.scroll_offset < 0 { editor.symbols_dialog.scroll_offset = 0 }

	source_editor_pane := pane_as_editor(&editor.panes[editor.symbols_dialog.source_pane_index])
	if source_editor_pane == nil {
		ui.draw_text(&ui_context, "(no source pane)", content_x + 8, list_top_y, theme.dim_foreground)
	} else if len(editor.symbols_dialog.filtered_indices) == 0 {
		empty_message := len(source_editor_pane.symbols) == 0 ? "(no symbols in this file)" : "(no matches)"
		ui.draw_text(&ui_context, empty_message, content_x + 8, list_top_y, theme.dim_foreground)
	} else {
		// Precompute parent indices for every symbol, plus a "last visible
		// child" flag keyed by original symbol index. These drive the
		// box-drawing tree prefix in front of each row: the flag for the
		// row itself decides between `├─` and `└─`, while the flag of each
		// ancestor in the chain decides between `│ ` (more siblings to come)
		// and `  ` (subtree is done).
		filtered_indices_view := editor.symbols_dialog.filtered_indices[:]
		total_symbol_count    := len(source_editor_pane.symbols)
		parent_indices        := make([]int, total_symbol_count, context.temp_allocator)
		for symbol_index in 0..<total_symbol_count {
			parent_indices[symbol_index] = -1
			symbol_depth := source_editor_pane.symbols[symbol_index].depth
			if symbol_depth > 0 {
				for candidate_parent_index := symbol_index - 1; candidate_parent_index >= 0; candidate_parent_index -= 1 {
					if source_editor_pane.symbols[candidate_parent_index].depth < symbol_depth { parent_indices[symbol_index] = candidate_parent_index; break }
				}
			}
		}

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

		end_row_index := min(editor.symbols_dialog.scroll_offset + computed_visible_rows, len(filtered_indices_view))
		for row_index := editor.symbols_dialog.scroll_offset; row_index < end_row_index; row_index += 1 {
			source_symbol_index := filtered_indices_view[row_index]
			current_symbol := source_editor_pane.symbols[source_symbol_index]
			row_y_position := list_top_y + i32(row_index - editor.symbols_dialog.scroll_offset) * line_step
			kind_tag := symbol_kind_tag(current_symbol.kind)

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

			// Pad by display cells (rune count) so the box-drawing chars —
			// which are 3 UTF-8 bytes each but a single cell wide — don't
			// throw off Ln-column alignment the way %-Ns (byte-padded)
			// would.
			name_cell_count := utf8.rune_count_in_string(tree_prefix) + utf8.rune_count_in_string(current_symbol.name)
			target_cell_count := 32
			padding_amount := target_cell_count - name_cell_count
			if padding_amount < 1 { padding_amount = 1 }
			padding_string := strings.repeat(" ", padding_amount, context.temp_allocator)
			row_label := fmt.tprintf("%s  %s%s%s  Ln %d", kind_tag, tree_prefix, current_symbol.name, padding_string, current_symbol.line + 1)

			is_selected := row_index == editor.symbols_dialog.selected_index
			ui.draw_list_row(&ui_context, content_x, row_y_position, content_width, row_label, is_selected, theme)
		}
	}

	hint_text := "↑/↓ navigate    Enter jump    Type to filter    Esc close"
	hint_width, _ := ui.text_size(&ui_context, hint_text)
	footer_x := i32(dialog_rectangle.x + (dialog_rectangle.w - f32(hint_width)) / 2)
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - line_step - 10
	ui.draw_text(&ui_context, hint_text, footer_x, footer_y, theme.dim_foreground)
}

// Small basename helper, duplicate of the one in render.odin to avoid a
// dependency on filepath at this site.
@(private="file")
filepath_base_in_dialog :: proc(file_path: string) -> string {
	if len(file_path) == 0 { return file_path }
	character_index := len(file_path) - 1
	for character_index >= 0 {
		current_character := file_path[character_index]
		if current_character == '/' || current_character == '\\' { return file_path[character_index+1:] }
		character_index -= 1
	}
	return file_path
}

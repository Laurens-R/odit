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
pane_rebuild_symbols :: proc(v: ^EditorPane) {
	for s in v.symbols { delete(s.name) }
	clear(&v.symbols)
	clear(&v.symbol_names)

	if v.language == nil { return }

	line_count := document.document_line_count(&v.doc)

	// Materialize every line into a slice once — the syntax matcher works on
	// a whole-file lexeme stream so patterns like
	// `template ... class {NAME} {` can span newlines.
	lines := make([]string, line_count, context.temp_allocator)
	for i in 0..<line_count {
		lines[i] = document.document_get_line(&v.doc, i, context.temp_allocator)
	}

	// Pass 1: discover user-declared type names so the `{TYPE}` placeholder
	// can resolve references regardless of declaration order (e.g.
	// `x : MyStruct` on line 10 with `MyStruct :: struct` on line 200).
	// All allocations live in temp_allocator and survive until the end of
	// this proc, after pass 2 has consumed the map.
	known_types := make(map[string]bool, 0, context.temp_allocator)
	{
		scratch: [dynamic]syntax.Symbol
		scratch.allocator = context.temp_allocator
		syntax.extract_symbols_from_lines(v.language, lines, &scratch, nil, context.temp_allocator)
		for s in scratch {
			if s.kind == .Type { known_types[s.name] = true }
		}
	}

	// Pass 2: full extraction (names cloned with the long-lived allocator).
	syntax.extract_symbols_from_lines(v.language, lines, &v.symbols, &known_types)

	for s in v.symbols {
		v.symbol_names[s.name] = s.kind
	}
}

// --- Dialog state ---------------------------------------------------------

@(private)
SymbolsDialog :: struct {
	source_pane:  int,          // pane the symbols belong to
	filtered_idx: [dynamic]int, // indices into source pane's `symbols`
	filter:       [dynamic]u8,
	selected:     int,
	scroll:       int,
	visible_rows: int,
}

@(private)
symbols_dialog_destroy :: proc(d: ^SymbolsDialog) {
	delete(d.filtered_idx)
	delete(d.filter)
	d^ = SymbolsDialog{}
}

@(private)
symbols_dialog_open :: proc(ed: ^Editor) {
	v := editor_active_editor_pane(ed)
	if v == nil { return }

	// Always refresh the symbol cache when opening the dialog so the user
	// sees the latest declarations (even ones added since the file was
	// loaded — the rest of the highlighter only rebuilds on file load).
	pane_rebuild_symbols(v)
	// Manual rebuild satisfies the auto-reanalyze contract too, so reset
	// both gates — otherwise editor_update would queue another redundant
	// rebuild moments later.
	v.symbols_dirty      = false
	v.last_analysis_time = ed.clock

	ed.symbols_dialog.source_pane = ed.active
	clear(&ed.symbols_dialog.filter)
	ed.symbols_dialog.selected = 0
	ed.symbols_dialog.scroll   = 0
	symbols_dialog_apply_filter(ed)
	ed.show_symbols = true
}

@(private)
symbols_dialog_close :: proc(ed: ^Editor) {
	ed.show_symbols = false
}

// --- Filter / navigation --------------------------------------------------

@(private="file")
symbols_dialog_apply_filter :: proc(ed: ^Editor) {
	clear(&ed.symbols_dialog.filtered_idx)

	v := pane_as_editor(&ed.panes[ed.symbols_dialog.source_pane])
	if v == nil { return }

	filter_lower := strings.to_lower(string(ed.symbols_dialog.filter[:]), context.temp_allocator)

	// Compute each symbol's direct parent (the most recent earlier symbol
	// with strictly smaller depth) and precompute visibility in a single
	// forward pass — symbols are emitted in source order, so a parent
	// always sits at a lower index than its children.
	n := len(v.symbols)
	parent_idx := make([]int, n, context.temp_allocator)
	show       := make([]bool, n, context.temp_allocator)
	for i in 0..<n {
		parent_idx[i] = -1
		d := v.symbols[i].depth
		if d != 0 {
			for j := i - 1; j >= 0; j -= 1 {
				if v.symbols[j].depth < d {
					parent_idx[i] = j
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
		s := v.symbols[i]
		if s.depth == 0 {
			show[i] = true
		} else if parent_idx[i] < 0 {
			show[i] = true
		} else {
			p := v.symbols[parent_idx[i]]
			if (p.kind == .Type || p.kind == .Module) && show[parent_idx[i]] {
				show[i] = true
			}
		}
	}

	for sym, i in v.symbols {
		if !show[i] { continue }

		if len(filter_lower) == 0 {
			append(&ed.symbols_dialog.filtered_idx, i)
			continue
		}
		name_lower := strings.to_lower(sym.name, context.temp_allocator)
		if strings.contains(name_lower, filter_lower) {
			append(&ed.symbols_dialog.filtered_idx, i)
		}
	}

	filtered_n := len(ed.symbols_dialog.filtered_idx)
	if filtered_n == 0 {
		ed.symbols_dialog.selected = 0
	} else if ed.symbols_dialog.selected >= filtered_n {
		ed.symbols_dialog.selected = filtered_n - 1
	}
	if ed.symbols_dialog.selected < 0 { ed.symbols_dialog.selected = 0 }
}

@(private="file")
symbols_dialog_move_selection :: proc(ed: ^Editor, delta: int) {
	n := len(ed.symbols_dialog.filtered_idx)
	if n == 0 { return }
	s := ed.symbols_dialog.selected + delta
	if s < 0 { s = 0 }
	if s >= n { s = n - 1 }
	ed.symbols_dialog.selected = s
}

@(private="file")
symbols_dialog_filter_append :: proc(ed: ^Editor, text: string) {
	for b in transmute([]u8)text { append(&ed.symbols_dialog.filter, b) }
	symbols_dialog_apply_filter(ed)
}

@(private="file")
symbols_dialog_filter_backspace :: proc(ed: ^Editor) {
	n := len(ed.symbols_dialog.filter)
	if n == 0 { return }
	i := n - 1
	for i > 0 && (ed.symbols_dialog.filter[i] & 0xC0) == 0x80 { i -= 1 }
	resize(&ed.symbols_dialog.filter, i)
	symbols_dialog_apply_filter(ed)
}

@(private="file")
symbols_dialog_activate :: proc(ed: ^Editor) {
	n := len(ed.symbols_dialog.filtered_idx)
	if n == 0 { return }
	if ed.symbols_dialog.selected < 0 || ed.symbols_dialog.selected >= n { return }

	v := pane_as_editor(&ed.panes[ed.symbols_dialog.source_pane])
	if v == nil { return }

	sym_idx := ed.symbols_dialog.filtered_idx[ed.symbols_dialog.selected]
	if sym_idx < 0 || sym_idx >= len(v.symbols) { return }
	sym := v.symbols[sym_idx]

	// Focus the source pane and place the cursor on the symbol's name.
	ed.active = ed.symbols_dialog.source_pane

	doc_lines := document.document_line_count(&v.doc)
	target_line := sym.line
	if target_line >= doc_lines { target_line = doc_lines - 1 }

	line_start  := document.document_line_start(&v.doc, target_line)
	line_text   := document.document_get_line(&v.doc, target_line, context.temp_allocator)
	target_col  := sym.column
	if int(target_col) > len(line_text) { target_col = u32(len(line_text)) }

	v.cursor_line   = target_line
	v.cursor_col    = target_col
	v.cursor_offset = line_start + target_col
	v.sel_active    = false

	ed.cursor_visible = true
	ed.cursor_timer = 0

	// Position the target line at the top of the pane's text area instead of
	// just making it visible. `scroll_y` is clamped at 0 so we never scroll
	// "above" the first line. The end of the document is intentionally not
	// clamped — when jumping near EOF we accept some empty space below so
	// the symbol stays anchored at the top, matching "scroll up as much as
	// possible" semantics. In diff mode the layout is row-indexed and
	// shared between panes, so we defer to the existing scroll-into-view
	// behaviour there.
	if ed.diff_state.active || ed.line_height <= 0 {
		sync_cursor_from_offset(ed)
	} else {
		target_scroll_y := f32(target_line) * f32(ed.line_height)
		if target_scroll_y < 0 { target_scroll_y = 0 }
		v.scroll_y        = target_scroll_y
		v.scroll_y_target = target_scroll_y
		v.scroll_line     = target_line
	}

	symbols_dialog_close(ed)
}

// --- Input ---------------------------------------------------------------

@(private)
symbols_dialog_handle_event :: proc(ed: ^Editor, event: ^sdl3.Event) {
	#partial switch event.type {
	case .TEXT_INPUT:
		input_text := string(event.text.text)
		if len(input_text) > 0 { symbols_dialog_filter_append(ed, input_text) }

	case .KEY_DOWN:
		key := event.key.key
		switch key {
		case sdl3.K_ESCAPE, sdl3.K_F6:
			symbols_dialog_close(ed)
		case sdl3.K_UP:
			symbols_dialog_move_selection(ed, -1)
		case sdl3.K_DOWN:
			symbols_dialog_move_selection(ed, 1)
		case sdl3.K_PAGEUP:
			step := ed.symbols_dialog.visible_rows
			if step < 1 { step = 1 }
			symbols_dialog_move_selection(ed, -step)
		case sdl3.K_PAGEDOWN:
			step := ed.symbols_dialog.visible_rows
			if step < 1 { step = 1 }
			symbols_dialog_move_selection(ed, step)
		case sdl3.K_HOME:
			symbols_dialog_move_selection(ed, -len(ed.symbols_dialog.filtered_idx))
		case sdl3.K_END:
			symbols_dialog_move_selection(ed, len(ed.symbols_dialog.filtered_idx))
		case sdl3.K_RETURN:
			symbols_dialog_activate(ed)
		case sdl3.K_BACKSPACE:
			symbols_dialog_filter_backspace(ed)
		}
	}
}

// --- Rendering ------------------------------------------------------------

@(private="file")
symbol_kind_tag :: proc(k: syntax.SymbolKind) -> string {
	switch k {
	case .Function: return "fn "
	case .Type:     return "T  "
	case .Variable: return "var"
	case .Module:   return "mod"
	case .Other:    return "   "
	}
	return "   "
}

@(private)
symbols_dialog_render :: proc(ed: ^Editor, renderer: ^sdl3.Renderer, width, height: i32) {
	ctx := ui.Context{
		renderer    = renderer,
		font        = ed.font,
		engine      = ed.engine,
		char_width  = ed.char_width,
		line_height = ed.line_height,
	}
	theme := ui.default_theme()

	ui.draw_dim_overlay(&ctx, width, height, theme.overlay)

	want_cols: i32 = 64
	want_rows: i32 = 26
	dialog_w := min(want_cols * ed.char_width + 32, width  - 40)
	dialog_h := min(want_rows * ed.line_height + 40, height - 40)
	if dialog_w < 240 { dialog_w = min(width  - 16, 240) }
	if dialog_h < 200 { dialog_h = min(height - 16, 200) }
	dialog_x := (width  - dialog_w) / 2
	dialog_y := (height - dialog_h) / 2
	dialog_rect := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_w), f32(dialog_h)}

	// Title — derive from the source pane's file name if any.
	title: string
	if v := pane_as_editor(&ed.panes[ed.symbols_dialog.source_pane]); v != nil {
		fname := v.file_path != "" ? filepath_base_in_dialog(v.file_path) : "untitled"
		title = fmt.tprintf("Symbols — %s", fname)
	} else {
		title = "Symbols"
	}
	content := ui.draw_window(&ctx, dialog_rect, title, theme)

	line_step := ed.line_height
	x := i32(content.x)
	y := i32(content.y)
	w := i32(content.w)

	// Filter field
	filter_str := string(ed.symbols_dialog.filter[:])
	ui.draw_input_field(&ctx, x, y, w, "Filter: ", filter_str, theme)
	y += line_step + 8

	// Footer reservation
	footer_height: i32 = line_step + 12
	list_top    := y
	list_bottom := i32(dialog_rect.y + dialog_rect.h) - footer_height - 12
	list_h      := list_bottom - list_top
	visible_rows := int(list_h / line_step)
	if visible_rows < 1 { visible_rows = 1 }
	ed.symbols_dialog.visible_rows = visible_rows

	// Adjust scroll so the selected row is in view.
	if ed.symbols_dialog.selected < ed.symbols_dialog.scroll {
		ed.symbols_dialog.scroll = ed.symbols_dialog.selected
	} else if ed.symbols_dialog.selected >= ed.symbols_dialog.scroll + visible_rows {
		ed.symbols_dialog.scroll = ed.symbols_dialog.selected - visible_rows + 1
	}
	if ed.symbols_dialog.scroll < 0 { ed.symbols_dialog.scroll = 0 }

	v := pane_as_editor(&ed.panes[ed.symbols_dialog.source_pane])
	if v == nil {
		ui.draw_text(&ctx, "(no source pane)", x + 8, list_top, theme.dim_fg)
	} else if len(ed.symbols_dialog.filtered_idx) == 0 {
		msg := len(v.symbols) == 0 ? "(no symbols in this file)" : "(no matches)"
		ui.draw_text(&ctx, msg, x + 8, list_top, theme.dim_fg)
	} else {
		// Precompute parent indices for every symbol, plus a "last visible
		// child" flag keyed by original symbol index. These drive the
		// box-drawing tree prefix in front of each row: the flag for the
		// row itself decides between `├─` and `└─`, while the flag of each
		// ancestor in the chain decides between `│ ` (more siblings to come)
		// and `  ` (subtree is done).
		filtered    := ed.symbols_dialog.filtered_idx[:]
		n_syms      := len(v.symbols)
		parent_idx  := make([]int, n_syms, context.temp_allocator)
		for j in 0..<n_syms {
			parent_idx[j] = -1
			d := v.symbols[j].depth
			if d > 0 {
				for k := j - 1; k >= 0; k -= 1 {
					if v.symbols[k].depth < d { parent_idx[j] = k; break }
				}
			}
		}

		is_last_by_orig := make(map[int]bool, 0, context.temp_allocator)
		seen_parents    := make(map[int]bool, 0, context.temp_allocator)
		for ri := len(filtered) - 1; ri >= 0; ri -= 1 {
			sym_idx := filtered[ri]
			p := parent_idx[sym_idx]
			if _, exists := seen_parents[p]; !exists {
				is_last_by_orig[sym_idx] = true
				seen_parents[p] = true
			}
		}

		end := min(ed.symbols_dialog.scroll + visible_rows, len(filtered))
		for i := ed.symbols_dialog.scroll; i < end; i += 1 {
			sym_idx := filtered[i]
			sym := v.symbols[sym_idx]
			row_y := list_top + i32(i - ed.symbols_dialog.scroll) * line_step
			tag := symbol_kind_tag(sym.kind)

			// Walk the ancestor chain (deepest first), then emit one
			// segment per depth level. For depth D the row produces D
			// segments — the last is the tee (├─/└─), the rest are
			// trunks (│ /  ).
			D := int(sym.depth)
			sb: strings.Builder
			strings.builder_init(&sb, context.temp_allocator)
			if D > 0 {
				chain := make([]int, D, context.temp_allocator)
				cur := sym_idx
				for d := D - 1; d >= 0; d -= 1 {
					cur = parent_idx[cur]
					chain[d] = cur
				}
				for c in 0..<D {
					entity_idx := sym_idx
					if c != D - 1 { entity_idx = chain[c+1] }
					last := false
					if val, ok := is_last_by_orig[entity_idx]; ok { last = val }
					if c == D - 1 {
						strings.write_string(&sb, last ? "└─ " : "├─ ")
					} else {
						strings.write_string(&sb, last ? "   " : "│  ")
					}
				}
			}
			prefix := strings.to_string(sb)

			// Pad by display cells (rune count) so the box-drawing chars —
			// which are 3 UTF-8 bytes each but a single cell wide — don't
			// throw off Ln-column alignment the way %-Ns (byte-padded)
			// would.
			name_cells := utf8.rune_count_in_string(prefix) + utf8.rune_count_in_string(sym.name)
			target_cells := 32
			pad_n := target_cells - name_cells
			if pad_n < 1 { pad_n = 1 }
			pad := strings.repeat(" ", pad_n, context.temp_allocator)
			label := fmt.tprintf("%s  %s%s%s  Ln %d", tag, prefix, sym.name, pad, sym.line + 1)

			is_sel := i == ed.symbols_dialog.selected
			ui.draw_list_row(&ctx, x, row_y, w, label, is_sel, theme)
		}
	}

	hint := "↑/↓ navigate    Enter jump    Type to filter    Esc close"
	fw, _ := ui.text_size(&ctx, hint)
	foot_x := i32(dialog_rect.x + (dialog_rect.w - f32(fw)) / 2)
	foot_y := i32(dialog_rect.y + dialog_rect.h) - line_step - 10
	ui.draw_text(&ctx, hint, foot_x, foot_y, theme.dim_fg)
}

// Small basename helper, duplicate of the one in render.odin to avoid a
// dependency on filepath at this site.
@(private="file")
filepath_base_in_dialog :: proc(path: string) -> string {
	if len(path) == 0 { return path }
	i := len(path) - 1
	for i >= 0 {
		c := path[i]
		if c == '/' || c == '\\' { return path[i+1:] }
		i -= 1
	}
	return path
}

package editor

import "core:fmt"
import "core:strings"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "../document"
import "../syntax"
import "../terminal"
import "../ui"

TAB_WIDTH :: 4

@(private="file")
build_line_display :: proc(line: string, allocator := context.temp_allocator) -> (display: string, byte_to_col: []int) {
	sb: strings.Builder
	strings.builder_init(&sb, 0, len(line) + 4, allocator)

	cols := make([]int, len(line) + 1, allocator)
	col := 0
	current_character_index := 0
	for current_character_index < len(line) {
		current_character := line[current_character_index]

		rune_len := 1
		if current_character >= 0xC0 {
			switch {
			case current_character < 0xE0: rune_len = 2
			case current_character < 0xF0: rune_len = 3
			case:          rune_len = 4
			}
			if current_character_index + rune_len > len(line) { rune_len = len(line) - current_character_index }
		}

		for k in 0..<rune_len {
			cols[current_character_index + k] = col
		}

		if rune_len == 1 {
			switch {
			case current_character == '\t':
				spaces := TAB_WIDTH - (col % TAB_WIDTH)
				for _ in 0..<spaces { strings.write_byte(&sb, ' ') }
				col += spaces
			case current_character == '\r':
			case current_character < 0x20 || current_character == 0x7F:
				strings.write_byte(&sb, '?')
				col += 1
			case:
				strings.write_byte(&sb, current_character)
				col += 1
			}
		} else {
			for k in 0..<rune_len {
				strings.write_byte(&sb, line[current_character_index + k])
			}
			col += 1
		}

		current_character_index += rune_len
	}
	cols[len(line)] = col
	return strings.to_string(sb), cols
}

editor_update :: proc(ed: ^Editor, dt: f64) {
	ed.clock += dt

	if ed.diff_state.active {
		// Animate the shared diff scroll.
		if ed.diff_state.scroll_y != ed.diff_state.scroll_y_target {
			factor := f32(dt * SCROLL_SMOOTHNESS)
			if factor > 1.0 { factor = 1.0 }
			ed.diff_state.scroll_y += (ed.diff_state.scroll_y_target - ed.diff_state.scroll_y) * factor
			if abs(ed.diff_state.scroll_y_target - ed.diff_state.scroll_y) < 0.5 {
				ed.diff_state.scroll_y = ed.diff_state.scroll_y_target
			}
		}
	} else {
		// Per-pane content updates (smooth-scroll for editor panes, byte
		// drain + cursor blink for terminal panes).
		for i in 0..<len(ed.panes) {
			#partial switch &c in ed.panes[i].content {
			case EditorPane:
				editor_pane_update(ed, &c, dt)
			case TerminalPane:
				if c.term != nil {
					title_h := editor_title_bar_height(ed)
					body := sdl3.Rect{
						ed.panes[i].rect.x,
						ed.panes[i].rect.y + title_h,
						ed.panes[i].rect.w,
						ed.panes[i].rect.h - title_h,
					}
					terminal.terminal_set_geometry(c.term, body, ed.char_width, ed.line_height)
					terminal.terminal_update(c.term, dt)
				}
			}
		}
	}

	ed.cursor_timer += dt
	if ed.cursor_timer >= CURSOR_BLINK_RATE {
		ed.cursor_timer -= CURSOR_BLINK_RATE
		ed.cursor_visible = !ed.cursor_visible
	}

	// Auto-reanalyze symbols once the user has paused. All three gates must
	// hold: the pane's doc has been mutated, at least 2 s have passed since
	// its last rebuild, and at least 1 s has passed since the most recent
	// keystroke anywhere in the editor. F6 is skipped — opening it already
	// forces a fresh rebuild, and rebuilding while its filtered_idx slice
	// is live would invalidate the dialog's indices.
	if !ed.show_symbols {
		for i in 0..<len(ed.panes) {
			#partial switch &c in ed.panes[i].content {
			case EditorPane:
				if !c.symbols_dirty                                { continue }
				if ed.clock - c.last_analysis_time   < 2.0         { continue }
				if ed.clock - ed.last_keystroke_time < 1.0         { continue }
				pane_rebuild_symbols(&c)
				c.symbols_dirty      = false
				c.last_analysis_time = ed.clock
			}
		}
	}
}

@(private="file")
editor_pane_update :: proc(ed: ^Editor, v: ^EditorPane, dt: f64) {
	if v.scroll_y == v.scroll_y_target { return }
	factor := f32(dt * SCROLL_SMOOTHNESS)
	if factor > 1.0 { factor = 1.0 }
	v.scroll_y += (v.scroll_y_target - v.scroll_y) * factor
	if abs(v.scroll_y_target - v.scroll_y) < 0.5 {
		v.scroll_y = v.scroll_y_target
	}
	if ed.line_height > 0 {
		v.scroll_line = u32(v.scroll_y / f32(ed.line_height))
	}
}

editor_render :: proc(ed: ^Editor, renderer: ^sdl3.Renderer, width: i32, height: i32) {
	status_height: i32 = ed.line_height + 4
	text_area_height := height - status_height

	// Full-window background
	sdl3.SetRenderDrawColorFloat(renderer, ed.bg_color.r, ed.bg_color.g, ed.bg_color.b, ed.bg_color.a)
	sdl3.RenderFillRect(renderer, &sdl3.FRect{0, 0, f32(width), f32(height)})

	// Compute per-pane rectangles. The divider sits at `split_ratio` of the
	// total width and is clamped so neither pane can drop below a usable
	// minimum (~10 character cells, falling back to 80 px if the font hasn't
	// been measured yet).
	visible := editor_visible_pane_count(ed)
	if visible == 1 {
		ed.panes[0].rect = sdl3.Rect{0, 0, width, text_area_height}
	} else {
		divider_w: i32 = 2
		usable := width - divider_w

		min_pane: i32 = 80
		if ed.char_width > 0 { min_pane = ed.char_width * 10 }
		if min_pane > usable/2 { min_pane = usable / 2 }

		ratio := ed.split_ratio
		if ratio < 0.05 { ratio = 0.05 }
		if ratio > 0.95 { ratio = 0.95 }
		left := i32(f32(usable) * ratio)
		if left < min_pane              { left = min_pane }
		if left > usable - min_pane     { left = usable - min_pane }

		ed.panes[0].rect = sdl3.Rect{0,                0, left,                 text_area_height}
		ed.panes[1].rect = sdl3.Rect{left + divider_w, 0, usable - left,        text_area_height}
	}

	// Render each visible pane by dispatching on its content type.
	for i in 0..<visible {
		pane := &ed.panes[i]
		is_active := i == ed.active
		#partial switch &c in pane.content {
		case EditorPane:
			render_editor_pane(ed, renderer, pane, &c, is_active, i)
		case TerminalPane:
			if c.term != nil {
				title_h := editor_title_bar_height(ed)
				render_pane_title_strip(ed, renderer, pane.rect.x, pane.rect.y, pane.rect.w, title_h, "Terminal", is_active)
				body := sdl3.Rect{
					pane.rect.x,
					pane.rect.y + title_h,
					pane.rect.w,
					pane.rect.h - title_h,
				}
				terminal.terminal_set_geometry(c.term, body, ed.char_width, ed.line_height)
				terminal.terminal_render(c.term, renderer, ed.font, ed.engine)
			}
		}
	}

	// Divider between panes.
	if visible == 2 {
		div_x := ed.panes[1].rect.x - 2
		div_rect := sdl3.FRect{f32(div_x), 0, 2, f32(text_area_height)}
		sdl3.SetRenderDrawColorFloat(renderer, ed.divider_color.r, ed.divider_color.g, ed.divider_color.b, ed.divider_color.a)
		sdl3.RenderFillRect(renderer, &div_rect)
	}

	// Status bar — content depends on the active pane's type.
	status_y := height - status_height
	sdl3.SetRenderDrawColorFloat(renderer, ed.status_bg.r, ed.status_bg.g, ed.status_bg.b, ed.status_bg.a)
	sdl3.RenderFillRect(renderer, &sdl3.FRect{0, f32(status_y), f32(width), f32(status_height)})

	status_text: string
	#partial switch &c in editor_active_pane(ed).content {
	case EditorPane:
		dirty_indicator := document.document_is_dirty(&c.doc) ? "[+] " : ""
		view_tag := ed.split_active ? fmt.tprintf("[Pane %d] ", ed.active + 1) : ""
		diff_tag := ed.diff_state.active ? "[DIFF] " : ""
		hint := ed.diff_state.active ? "(F8 exit diff, F1 help)" : "(F1 help, F2 browse, Ctrl+Tab swap panes, F8 diff)"
		status_text = fmt.tprintf("%s%s%sLn %d, Col %d | %d lines | %d bytes  %s",
			diff_tag,
			view_tag,
			dirty_indicator,
			c.cursor_line + 1,
			c.cursor_col + 1,
			document.document_line_count(&c.doc),
			document.document_length(&c.doc),
			hint,
		)
	}
	if len(status_text) > 0 {
		render_string(ed, renderer, status_text, ed.padding_x, status_y + 2, ed.status_fg)
	}

	// Modal overlays render on top of everything else.
	if ed.show_browse {
		browse_render(ed, renderer, width, height)
	}
	if ed.show_symbols {
		symbols_dialog_render(ed, renderer, width, height)
	}
	if ed.show_help {
		help_render(ed, renderer, width, height)
	}
	if ed.show_terminal_close_confirm {
		terminal_close_confirm_render(ed, renderer, width, height)
	}
}

// --- Per-content renderers ------------------------------------------------

@(private="file")
render_editor_pane :: proc(ed: ^Editor, renderer: ^sdl3.Renderer, pane: ^Pane, v: ^EditorPane, is_active: bool, pane_idx: int) {
	view_w := pane.rect.w
	view_h := pane.rect.h
	view_x := pane.rect.x
	view_y := pane.rect.y

	// Title bar (tinted strip with filename + dirty marker) at the top of the
	// pane. Text-area math below is in terms of `text_y` / `text_h` so the
	// title bar stays anchored above the visible content.
	title_h := editor_title_bar_height(ed)
	render_pane_title_bar(ed, renderer, v, view_x, view_y, view_w, title_h, is_active)

	text_y := view_y + title_h
	text_h := view_h - title_h

	v.visible_lines = u32(text_h / ed.line_height)
	if v.visible_lines == 0 { v.visible_lines = 1 }

	line_count := document.document_line_count(&v.doc)
	gutter_chars := max(digit_count(line_count), 3)
	gutter_width := i32(gutter_chars + 1) * ed.char_width
	v.gutter_width = gutter_width

	view_clip := sdl3.Rect{view_x, text_y, view_w, text_h}
	sdl3.SetRenderClipRect(renderer, &view_clip)

	if ed.diff_state.active {
		render_editor_pane_diff(ed, renderer, v, view_x, text_y, view_w, is_active, pane_idx, gutter_chars, gutter_width)
	} else {
		render_editor_pane_normal(ed, renderer, v, view_x, text_y, is_active, gutter_chars, gutter_width)
	}

	sdl3.SetRenderClipRect(renderer, nil)

	// Scrollbar — content range and scroll value differ between modes.
	{
		ui_ctx := ui.Context{
			renderer    = renderer,
			font        = ed.font,
			engine      = ed.engine,
			char_width  = ed.char_width,
			line_height = ed.line_height,
		}
		theme := ui.default_theme()
		sb_x := view_x + view_w - 8

		content_h, scroll_v: f32
		if ed.diff_state.active {
			content_h = f32(len(ed.diff_state.rows)) * f32(ed.line_height)
			scroll_v  = ed.diff_state.scroll_y
		} else {
			content_h = f32(line_count) * f32(ed.line_height)
			scroll_v  = v.scroll_y
		}
		ui.draw_scrollbar(&ui_ctx, sb_x, text_y, text_h, content_h, f32(text_h), scroll_v, theme)
	}
}

// Tinted strip at the top of an editor pane showing the document's file name
// (basename), or "untitled" for an unsaved buffer, with a trailing `*` when
// dirty. The active pane gets a brighter text color; the inactive pane is
// muted so focus is unambiguous at a glance.
@(private="file")
render_pane_title_bar :: proc(ed: ^Editor, renderer: ^sdl3.Renderer, v: ^EditorPane, x, y, w, h: i32, is_active: bool) {
	name := v.file_path != "" ? filepath_base(v.file_path) : "untitled"
	dirty := document.document_is_dirty(&v.doc) ? " *" : ""
	label := fmt.tprintf("%s%s", name, dirty)
	render_pane_title_strip(ed, renderer, x, y, w, h, label, is_active)
}

// Generic pane title strip: tinted bar, active-pane accent stripe along the
// bottom, label on the left. Shared by editor panes (filename + dirty flag)
// and terminal panes (static "Terminal" label) so the visual treatment stays
// consistent.
@(private)
render_pane_title_strip :: proc(ed: ^Editor, renderer: ^sdl3.Renderer, x, y, w, h: i32, label: string, is_active: bool) {
	bar := sdl3.FRect{f32(x), f32(y), f32(w), f32(h)}
	sdl3.SetRenderDrawColorFloat(renderer, ed.status_bg.r, ed.status_bg.g, ed.status_bg.b, ed.status_bg.a)
	sdl3.RenderFillRect(renderer, &bar)

	if is_active {
		stripe := sdl3.FRect{f32(x), f32(y + h - 1), f32(w), 1}
		sdl3.SetRenderDrawColorFloat(renderer, ed.cursor_color.r, ed.cursor_color.g, ed.cursor_color.b, 1.0)
		sdl3.RenderFillRect(renderer, &stripe)
	}

	text_color := is_active ? ed.status_fg : ed.line_num_color
	render_string(ed, renderer, label, x + ed.padding_x, y + 3, text_color)
}

// Local wrapper so the renderer doesn't need to import core:path/filepath.
@(private="file")
filepath_base :: proc(path: string) -> string {
	if len(path) == 0 { return path }
	// Walk back to the last separator (works for both / and \ to keep things
	// platform-agnostic without dragging filepath in).
	i := len(path) - 1
	for i >= 0 {
		c := path[i]
		if c == '/' || c == '\\' {
			return path[i+1:]
		}
		i -= 1
	}
	return path
}

@(private="file")
render_editor_pane_normal :: proc(ed: ^Editor, renderer: ^sdl3.Renderer, v: ^EditorPane, view_x, view_y: i32, is_active: bool, gutter_chars: u32, gutter_width: i32) {
	line_count := document.document_line_count(&v.doc)

	end_line := min(v.scroll_line + v.visible_lines + 2, line_count)
	sel_lo, sel_hi, has_sel := editor_pane_selection_range(v)
	scroll_y_px := i32(v.scroll_y)

	for line_idx := v.scroll_line; line_idx < end_line; line_idx += 1 {
		screen_y := view_y + ed.padding_y + i32(line_idx) * ed.line_height - scroll_y_px
		render_doc_line_into(ed, renderer, v, view_x, screen_y, gutter_chars, gutter_width,
			i32(line_idx), has_sel, sel_lo, sel_hi, is_active, i32(line_idx) == i32(v.cursor_line))
	}
}

@(private="file")
render_editor_pane_diff :: proc(ed: ^Editor, renderer: ^sdl3.Renderer, v: ^EditorPane, view_x, view_y, view_w: i32, is_active: bool, pane_idx: int, gutter_chars: u32, gutter_width: i32) {
	scroll_y_px := i32(ed.diff_state.scroll_y)
	visible_rows := v.visible_lines + 2

	start_row: u32 = 0
	if ed.line_height > 0 {
		start_row = u32(ed.diff_state.scroll_y / f32(ed.line_height))
	}
	total_rows := u32(len(ed.diff_state.rows))
	end_row := min(start_row + visible_rows, total_rows)

	for row_idx := start_row; row_idx < end_row; row_idx += 1 {
		row := ed.diff_state.rows[row_idx]
		screen_y := view_y + ed.padding_y + i32(row_idx) * ed.line_height - scroll_y_px

		// Determine which doc line this row shows on this side, and the
		// background color for the row.
		doc_line: i32 = -1
		bg: ^sdl3.FColor

		if pane_idx == 0 {
			doc_line = row.left_line
			switch row.kind {
			case .Equal:
				// no bg tint
			case .Delete:
				bg = &ed.diff_delete_bg
			case .Insert:
				bg = &ed.diff_gap_bg
			}
		} else {
			doc_line = row.right_line
			switch row.kind {
			case .Equal:
			case .Insert:
				bg = &ed.diff_insert_bg
			case .Delete:
				bg = &ed.diff_gap_bg
			}
		}

		// Fill row background tint for non-equal rows.
		if bg != nil {
			rect := sdl3.FRect{f32(view_x), f32(screen_y), f32(view_w), f32(ed.line_height)}
			sdl3.SetRenderDrawColorFloat(renderer, bg.r, bg.g, bg.b, bg.a)
			sdl3.RenderFillRect(renderer, &rect)
		}

		if doc_line < 0 { continue } // gap — nothing to draw beyond background

		is_cursor_row := is_active && doc_line == i32(v.cursor_line)
		render_doc_line_into(ed, renderer, v, view_x, screen_y, gutter_chars, gutter_width,
			doc_line, false, 0, 0, is_active, is_cursor_row)
	}
}

// Common path for laying out a single document line into a pane at the given
// screen_y. Used by both the normal and diff renderers.
@(private="file")
render_doc_line_into :: proc(
	ed: ^Editor, renderer: ^sdl3.Renderer, v: ^EditorPane,
	view_x: i32, screen_y: i32,
	gutter_chars: u32, gutter_width: i32,
	doc_line: i32,
	has_sel: bool, sel_lo, sel_hi: u32,
	is_active: bool, cursor_on_this_line: bool,
) {
	line_idx := u32(doc_line)
	line_num_str := fmt.tprintf("%*d", gutter_chars, line_idx + 1)
	render_string(ed, renderer, line_num_str, view_x + ed.padding_x, screen_y, ed.line_num_color)

	line_text := document.document_get_line(&v.doc, line_idx)
	text_x := view_x + ed.padding_x + gutter_width

	display, byte_to_col := build_line_display(line_text)

	if has_sel {
		line_byte_start := document.document_line_start(&v.doc, line_idx)
		line_byte_end := line_byte_start + u32(len(line_text))
		if sel_hi > line_byte_start && sel_lo <= line_byte_end {
			lo_byte := sel_lo > line_byte_start ? int(sel_lo - line_byte_start) : 0
			lo_col := i32(byte_to_col[lo_byte])

			hi_col: i32
			if sel_hi > line_byte_end {
				hi_col = i32(byte_to_col[len(line_text)]) + 1
			} else {
				hi_byte := int(sel_hi - line_byte_start)
				hi_col = i32(byte_to_col[hi_byte])
			}

			if hi_col > lo_col {
				rect := sdl3.FRect{
					f32(text_x + lo_col * ed.char_width),
					f32(screen_y),
					f32((hi_col - lo_col) * ed.char_width),
					f32(ed.line_height),
				}
				sdl3.SetRenderDrawColorFloat(renderer, ed.sel_color.r, ed.sel_color.g, ed.sel_color.b, ed.sel_color.a)
				sdl3.RenderFillRect(renderer, &rect)
			}
		}
	}

	if len(display) > 0 {
		render_line_with_syntax(ed, renderer, v, display, text_x, screen_y)
	}

	if is_active && cursor_on_this_line && ed.cursor_visible {
		cursor_col_byte := int(v.cursor_col)
		cursor_visual_col := byte_to_col[clamp(cursor_col_byte, 0, len(line_text))]
		cursor_x := text_x + i32(cursor_visual_col) * ed.char_width

		cursor_rect := sdl3.FRect{
			f32(cursor_x), f32(screen_y),
			f32(ed.char_width), f32(ed.line_height),
		}
		sdl3.SetRenderDrawColorFloat(renderer, ed.cursor_color.r, ed.cursor_color.g, ed.cursor_color.b, 1.0)
		sdl3.RenderFillRect(renderer, &cursor_rect)

		if cursor_col_byte < len(line_text) {
			c := line_text[cursor_col_byte]
			if c >= 0x20 && c != 0x7F {
				char_end := cursor_col_byte + 1
				if c >= 0xC0 {
					switch {
					case c < 0xE0: char_end = cursor_col_byte + 2
					case c < 0xF0: char_end = cursor_col_byte + 3
					case:          char_end = cursor_col_byte + 4
					}
				}
				char_end = min(char_end, len(line_text))
				render_string(ed, renderer, line_text[cursor_col_byte:char_end], cursor_x, screen_y, ed.bg_color)
			}
		}
	}
}

// Render one display-line, optionally colored by `language`'s tokenizer.
// `display` is the already-expanded line (tabs → spaces, CR hidden, control
// chars → '?'). When language is nil, we render in a single pass with the
// default foreground.
@(private="file")
render_line_with_syntax :: proc(ed: ^Editor, renderer: ^sdl3.Renderer, v: ^EditorPane, display: string, text_x, screen_y: i32) {
	if v.language == nil {
		render_string(ed, renderer, display, text_x, screen_y, ed.fg_color)
		return
	}

	// Per-frame token buffer in the temp arena.
	tokens := make([dynamic]syntax.Token, 0, 16, context.temp_allocator)
	syntax.tokenize_line(v.language, display, &tokens, v.symbol_names)

	for tok in tokens {
		if tok.end <= tok.start { continue }
		substr := display[tok.start:tok.end]
		color := syntax_color_for(ed, tok.kind)
		x := text_x + i32(tok.start) * ed.char_width
		render_string(ed, renderer, substr, x, screen_y, color)
	}
}

@(private="file")
syntax_color_for :: proc(ed: ^Editor, kind: syntax.TokenKind) -> sdl3.FColor {
	switch kind {
	case .Keyword:      return ed.syntax_keyword_fg
	case .Type:         return ed.syntax_type_fg
	case .String:       return ed.syntax_string_fg
	case .Number:       return ed.syntax_number_fg
	case .Comment:      return ed.syntax_comment_fg
	case .Preprocessor: return ed.syntax_preprocessor_fg
	case .Symbol:       return ed.syntax_symbol_fg
	case .Punctuation:  return ed.fg_color
	case .Default:      return ed.fg_color
	}
	return ed.fg_color
}

@(private="file")
render_string :: proc(ed: ^Editor, renderer: ^sdl3.Renderer, str: string, x: i32, y: i32, color: sdl3.FColor) {
	if len(str) == 0 { return }

	cstr := strings.clone_to_cstring(str, context.temp_allocator)

	text_obj := ttf.CreateText(ed.engine, ed.font, cstr, 0)
	if text_obj == nil { return }
	defer ttf.DestroyText(text_obj)

	_ = ttf.SetTextColorFloat(text_obj, color.r, color.g, color.b, color.a)
	_ = ttf.DrawRendererText(text_obj, f32(x), f32(y))
}

@(private="file")
digit_count :: proc(n: u32) -> u32 {
	if n == 0 { return 1 }
	count: u32 = 0
	val := n
	for val > 0 {
		count += 1
		val /= 10
	}
	return count
}

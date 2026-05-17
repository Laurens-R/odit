package editor

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "../document"

// Terminal-style editor state
Editor :: struct {
	doc:            document.Document,

	// Cursor position (in document coordinates)
	cursor_line:    u32,
	cursor_col:     u32, // byte offset within the line
	cursor_offset:  u32, // absolute byte offset in document

	// Viewport (which portion of the document is visible)
	scroll_line:    u32, // first visible line
	visible_lines:  u32, // how many lines fit on screen

	// Rendering
	font:           ^ttf.Font,
	engine:         ^ttf.TextEngine,
	font_size:      f32,
	char_width:     i32, // monospace character width in pixels
	line_height:    i32, // line height in pixels
	padding_x:      i32, // left padding
	padding_y:      i32, // top padding
	gutter_width:   i32, // line-number gutter width in pixels (set during render)

	// Blink
	cursor_visible: bool,
	cursor_timer:   f64, // seconds accumulator

	// Selection
	sel_active:     bool,
	sel_anchor:     u32, // byte offset of selection anchor (other end is cursor_offset)
	mouse_dragging: bool, // left mouse button held; motion extends selection

	// Colors (terminal palette)
	bg_color:       sdl3.FColor,
	fg_color:       sdl3.FColor,
	cursor_color:   sdl3.FColor,
	line_num_color: sdl3.FColor,
	sel_color:      sdl3.FColor,
	status_bg:      sdl3.FColor,
	status_fg:      sdl3.FColor,
}

CURSOR_BLINK_RATE :: 0.53 // seconds

editor_init :: proc(ed: ^Editor, engine: ^ttf.TextEngine, font: ^ttf.Font, font_size: f32) {
	document.document_init(&ed.doc)

	ed.font = font
	ed.engine = engine
	ed.font_size = font_size
	ed.cursor_line = 0
	ed.cursor_col = 0
	ed.cursor_offset = 0
	ed.scroll_line = 0
	ed.visible_lines = 0
	ed.cursor_visible = true
	ed.cursor_timer = 0
	ed.sel_active = false
	ed.sel_anchor = 0

	ed.padding_x = 8
	ed.padding_y = 4

	// Measure monospace character dimensions
	ed.line_height = i32(ttf.GetFontLineSkip(font))
	// Approximate char width from a reference character
	w: i32
	ttf.GetStringSize(font, "M", 1, &w, nil)
	ed.char_width = w

	// Terminal dark theme
	ed.bg_color       = sdl3.FColor{0.11, 0.11, 0.14, 1.0}
	ed.fg_color       = sdl3.FColor{0.85, 0.85, 0.85, 1.0}
	ed.cursor_color   = sdl3.FColor{0.9, 0.9, 0.9, 1.0}
	ed.line_num_color = sdl3.FColor{0.4, 0.45, 0.5, 1.0}
	ed.sel_color      = sdl3.FColor{0.22, 0.36, 0.60, 1.0}
	ed.status_bg      = sdl3.FColor{0.18, 0.20, 0.25, 1.0}
	ed.status_fg      = sdl3.FColor{0.7, 0.75, 0.8, 1.0}
}

editor_destroy :: proc(ed: ^Editor) {
	document.document_destroy(&ed.doc)
}

editor_open_string :: proc(ed: ^Editor, content: string) {
	document.document_destroy(&ed.doc)
	document.document_init(&ed.doc, content)
	ed.cursor_line = 0
	ed.cursor_col = 0
	ed.cursor_offset = 0
	ed.scroll_line = 0
	ed.sel_active = false
}

// --- Input handling ---

editor_handle_event :: proc(ed: ^Editor, event: ^sdl3.Event) {
	#partial switch event.type {
	case .TEXT_INPUT:
		input_text := string(event.text.text)
		if len(input_text) > 0 {
			editor_insert_text(ed, input_text)
		}

	case .KEY_DOWN:
		editor_handle_key(ed, event)

	case .MOUSE_WHEEL:
		mod := sdl3.GetModState()
		ctrl := .LCTRL in mod || .RCTRL in mod
		if ctrl {
			editor_zoom(ed, event.wheel.y)
		} else {
			editor_scroll(ed, -i32(event.wheel.y * 3))
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button == sdl3.BUTTON_LEFT {
			mod := sdl3.GetModState()
			shift := .LSHIFT in mod || .RSHIFT in mod
			editor_mouse_down(ed, event.button.x, event.button.y, shift)
		}

	case .MOUSE_BUTTON_UP:
		if event.button.button == sdl3.BUTTON_LEFT {
			ed.mouse_dragging = false
		}

	case .MOUSE_MOTION:
		if ed.mouse_dragging {
			editor_mouse_drag(ed, event.motion.x, event.motion.y)
		}
	}
}

@(private="file")
editor_handle_key :: proc(ed: ^Editor, event: ^sdl3.Event) {
	key := event.key.key
	mod := event.key.mod

	ctrl  := .LCTRL  in mod || .RCTRL  in mod
	shift := .LSHIFT in mod || .RSHIFT in mod

	// Reset cursor blink on any keypress
	ed.cursor_visible = true
	ed.cursor_timer = 0

	if ctrl {
		switch key {
		case sdl3.K_Z:
			if shift {
				if new_offset, ok := document.document_redo(&ed.doc); ok {
					ed.cursor_offset = new_offset
				}
			} else {
				if new_offset, ok := document.document_undo(&ed.doc); ok {
					ed.cursor_offset = new_offset
				}
			}
			ed.sel_active = false
			sync_cursor_from_offset(ed)
			return
		case sdl3.K_Y:
			if new_offset, ok := document.document_redo(&ed.doc); ok {
				ed.cursor_offset = new_offset
			}
			ed.sel_active = false
			sync_cursor_from_offset(ed)
			return
		case sdl3.K_A:
			// Select all (future)
			return
		case sdl3.K_C:
			clipboard_copy(ed)
			return
		case sdl3.K_V:
			clipboard_paste(ed)
			return
		}
	}

	switch key {
	case sdl3.K_RETURN:
		editor_insert_text(ed, "\n")

	case sdl3.K_TAB:
		editor_insert_text(ed, "    ") // 4 spaces, terminal style

	case sdl3.K_BACKSPACE:
		if delete_selection(ed) { return }
		if ed.cursor_offset > 0 {
			// Delete one character (handle UTF-8 backwards)
			del_len := prev_char_len(ed)
			document.document_delete(&ed.doc, ed.cursor_offset - del_len, del_len)
			ed.cursor_offset -= del_len
			sync_cursor_from_offset(ed)
		}

	case sdl3.K_DELETE:
		if delete_selection(ed) { return }
		doc_len := document.document_length(&ed.doc)
		if ed.cursor_offset < doc_len {
			del_len := next_char_len(ed)
			document.document_delete(&ed.doc, ed.cursor_offset, del_len)
			sync_cursor_from_offset(ed)
		}

	case sdl3.K_LEFT:
		if !shift && collapse_selection(ed, false) { return }
		update_selection_for_nav(ed, shift)
		if ed.cursor_offset > 0 {
			ed.cursor_offset -= prev_char_len(ed)
			sync_cursor_from_offset(ed)
		}

	case sdl3.K_RIGHT:
		if !shift && collapse_selection(ed, true) { return }
		update_selection_for_nav(ed, shift)
		doc_len := document.document_length(&ed.doc)
		if ed.cursor_offset < doc_len {
			ed.cursor_offset += next_char_len(ed)
			sync_cursor_from_offset(ed)
		}

	case sdl3.K_UP:
		update_selection_for_nav(ed, shift)
		if ed.cursor_line > 0 {
			move_cursor_vertical(ed, -1)
		}

	case sdl3.K_DOWN:
		update_selection_for_nav(ed, shift)
		line_count := document.document_line_count(&ed.doc)
		if ed.cursor_line < line_count - 1 {
			move_cursor_vertical(ed, 1)
		}

	case sdl3.K_HOME:
		update_selection_for_nav(ed, shift)
		if ctrl {
			ed.cursor_offset = 0
		} else {
			ed.cursor_offset = document.document_line_start(&ed.doc, ed.cursor_line)
		}
		sync_cursor_from_offset(ed)

	case sdl3.K_END:
		update_selection_for_nav(ed, shift)
		if ctrl {
			ed.cursor_offset = document.document_length(&ed.doc)
		} else {
			line_start := document.document_line_start(&ed.doc, ed.cursor_line)
			line_text := document.document_get_line(&ed.doc, ed.cursor_line)
			ed.cursor_offset = line_start + u32(len(line_text))
		}
		sync_cursor_from_offset(ed)

	case sdl3.K_PAGEUP:
		update_selection_for_nav(ed, shift)
		lines_to_move := ed.visible_lines > 1 ? ed.visible_lines - 1 : 1
		if ed.cursor_line >= lines_to_move {
			move_cursor_vertical(ed, -i32(lines_to_move))
		} else {
			move_cursor_vertical(ed, -i32(ed.cursor_line))
		}

	case sdl3.K_PAGEDOWN:
		update_selection_for_nav(ed, shift)
		line_count := document.document_line_count(&ed.doc)
		lines_to_move := ed.visible_lines > 1 ? ed.visible_lines - 1 : 1
		remaining := line_count - 1 - ed.cursor_line
		if remaining >= lines_to_move {
			move_cursor_vertical(ed, i32(lines_to_move))
		} else {
			move_cursor_vertical(ed, i32(remaining))
		}
	}
}

@(private="file")
editor_scroll :: proc(ed: ^Editor, delta_lines: i32) {
	if delta_lines == 0 { return }
	line_count := i32(document.document_line_count(&ed.doc))
	visible := i32(ed.visible_lines)
	if visible == 0 { visible = 1 }
	max_scroll := max(i32(0), line_count - visible)
	new_scroll := i32(ed.scroll_line) + delta_lines
	new_scroll = clamp(new_scroll, 0, max_scroll)
	ed.scroll_line = u32(new_scroll)
}

@(private="file")
screen_to_offset :: proc(ed: ^Editor, x: f32, y: f32) -> u32 {
	// Y → line
	rel_y := i32(y) - ed.padding_y
	row: i32 = 0
	if rel_y > 0 && ed.line_height > 0 {
		row = rel_y / ed.line_height
	}
	line_count := document.document_line_count(&ed.doc)
	target_line := ed.scroll_line + u32(max(i32(0), row))
	if target_line >= line_count { target_line = line_count - 1 }

	// X → byte column within the line
	rel_x := i32(x) - ed.padding_x - ed.gutter_width
	col: i32 = 0
	if rel_x > 0 && ed.char_width > 0 {
		// Round to nearest char boundary for natural click feel
		col = (rel_x + ed.char_width / 2) / ed.char_width
	}
	line_start := document.document_line_start(&ed.doc, target_line)
	line_text := document.document_get_line(&ed.doc, target_line)
	line_len := i32(len(line_text))
	if col > line_len { col = line_len }
	if col < 0 { col = 0 }

	return line_start + u32(col)
}

@(private="file")
editor_mouse_down :: proc(ed: ^Editor, x: f32, y: f32, shift: bool) {
	offset := screen_to_offset(ed, x, y)

	if shift {
		if !ed.sel_active {
			ed.sel_anchor = ed.cursor_offset
			ed.sel_active = true
		}
	} else {
		ed.sel_anchor = offset
		ed.sel_active = true // empty range; promoted to a real selection on drag
	}
	ed.cursor_offset = offset
	ed.mouse_dragging = true
	ed.cursor_visible = true
	ed.cursor_timer = 0
	sync_cursor_from_offset(ed)
}

@(private="file")
editor_mouse_drag :: proc(ed: ^Editor, x: f32, y: f32) {
	offset := screen_to_offset(ed, x, y)
	if offset == ed.cursor_offset { return }
	ed.cursor_offset = offset
	ed.sel_active = true
	ed.cursor_visible = true
	ed.cursor_timer = 0
	sync_cursor_from_offset(ed)
}

@(private="file")
editor_zoom :: proc(ed: ^Editor, direction: f32) {
	FONT_SIZE_MIN :: 8.0
	FONT_SIZE_MAX :: 72.0
	step: f32 = 2.0

	new_size := ed.font_size + (direction > 0 ? step : -step)
	new_size = clamp(new_size, FONT_SIZE_MIN, FONT_SIZE_MAX)
	if new_size == ed.font_size { return }

	ed.font_size = new_size
	_ = ttf.SetFontSize(ed.font, new_size)

	// Recalculate metrics
	ed.line_height = i32(ttf.GetFontLineSkip(ed.font))
	w: i32
	ttf.GetStringSize(ed.font, "M", 1, &w, nil)
	ed.char_width = w
}

@(private="file")
editor_insert_text :: proc(ed: ^Editor, text: string) {
	delete_selection(ed)
	document.document_insert(&ed.doc, ed.cursor_offset, text)
	ed.cursor_offset += u32(len(text))
	sync_cursor_from_offset(ed)
}

// --- Selection helpers ---

@(private="file")
selection_range :: proc(ed: ^Editor) -> (lo: u32, hi: u32, has: bool) {
	if !ed.sel_active { return 0, 0, false }
	lo = min(ed.sel_anchor, ed.cursor_offset)
	hi = max(ed.sel_anchor, ed.cursor_offset)
	has = lo != hi
	return
}

// Delete the active selection (if any) and place cursor at its start.
// Returns true if a non-empty selection was deleted.
@(private="file")
delete_selection :: proc(ed: ^Editor) -> bool {
	lo, hi, has := selection_range(ed)
	ed.sel_active = false
	if !has { return false }
	document.document_delete(&ed.doc, lo, hi - lo)
	ed.cursor_offset = lo
	sync_cursor_from_offset(ed)
	return true
}

// Collapse selection to one side without further movement.
// Returns true if a non-empty selection was collapsed.
@(private="file")
collapse_selection :: proc(ed: ^Editor, to_end: bool) -> bool {
	lo, hi, has := selection_range(ed)
	ed.sel_active = false
	if !has { return false }
	ed.cursor_offset = to_end ? hi : lo
	sync_cursor_from_offset(ed)
	return true
}

// On shift+nav: start (or keep) a selection anchored at the current cursor.
// On plain nav: clear any existing selection.
@(private="file")
update_selection_for_nav :: proc(ed: ^Editor, shift: bool) {
	if shift {
		if !ed.sel_active {
			ed.sel_anchor = ed.cursor_offset
			ed.sel_active = true
		}
	} else {
		ed.sel_active = false
	}
}

// --- Clipboard ---

@(private="file")
clipboard_copy :: proc(ed: ^Editor) {
	lo, hi, has := selection_range(ed)
	if !has { return }
	text := document.document_get_slice(&ed.doc, lo, hi - lo, context.temp_allocator)
	cstr := strings.clone_to_cstring(text, context.temp_allocator)
	_ = sdl3.SetClipboardText(cstr)
}

@(private="file")
clipboard_paste :: proc(ed: ^Editor) {
	raw := sdl3.GetClipboardText()
	if raw == nil { return }
	defer sdl3.free(rawptr(raw))
	text := string(cstring(raw))
	if len(text) == 0 { return }
	editor_insert_text(ed, text)
}

// --- Cursor management ---

@(private="file")
sync_cursor_from_offset :: proc(ed: ^Editor) {
	ed.cursor_line = document.document_offset_to_line(&ed.doc, ed.cursor_offset)
	line_start := document.document_line_start(&ed.doc, ed.cursor_line)
	ed.cursor_col = ed.cursor_offset - line_start
	ensure_cursor_visible(ed)
}

@(private="file")
move_cursor_vertical :: proc(ed: ^Editor, delta: i32) {
	new_line := i32(ed.cursor_line) + delta
	line_count := i32(document.document_line_count(&ed.doc))
	new_line = clamp(new_line, 0, line_count - 1)

	target_line := u32(new_line)
	line_start := document.document_line_start(&ed.doc, target_line)
	line_text := document.document_get_line(&ed.doc, target_line)
	line_len := u32(len(line_text))

	// Preserve column position, clamp to line length
	col := min(ed.cursor_col, line_len)

	ed.cursor_line = target_line
	ed.cursor_col = col
	ed.cursor_offset = line_start + col
	ensure_cursor_visible(ed)
}

@(private="file")
ensure_cursor_visible :: proc(ed: ^Editor) {
	if ed.visible_lines == 0 { return }

	if ed.cursor_line < ed.scroll_line {
		ed.scroll_line = ed.cursor_line
	} else if ed.cursor_line >= ed.scroll_line + ed.visible_lines {
		ed.scroll_line = ed.cursor_line - ed.visible_lines + 1
	}
}

@(private="file")
prev_char_len :: proc(ed: ^Editor) -> u32 {
	if ed.cursor_offset == 0 { return 0 }
	// Read up to 4 bytes before cursor to find UTF-8 char boundary
	look_back := min(ed.cursor_offset, 4)
	slice := document.document_get_slice(&ed.doc, ed.cursor_offset - look_back, look_back)
	if len(slice) == 0 { return 1 }

	// Walk backwards to find the start of the last rune
	i := len(slice) - 1
	for i > 0 && (slice[i] & 0xC0) == 0x80 {
		i -= 1
	}
	return u32(len(slice) - i)
}

@(private="file")
next_char_len :: proc(ed: ^Editor) -> u32 {
	doc_len := document.document_length(&ed.doc)
	if ed.cursor_offset >= doc_len { return 0 }
	look_ahead := min(doc_len - ed.cursor_offset, 4)
	slice := document.document_get_slice(&ed.doc, ed.cursor_offset, look_ahead)
	if len(slice) == 0 { return 1 }

	// First byte tells us the rune length
	b := slice[0]
	if b < 0x80      { return 1 }
	else if b < 0xE0 { return 2 }
	else if b < 0xF0 { return 3 }
	else             { return 4 }
}

// --- Rendering ---

editor_update :: proc(ed: ^Editor, dt: f64) {
	ed.cursor_timer += dt
	if ed.cursor_timer >= CURSOR_BLINK_RATE {
		ed.cursor_timer -= CURSOR_BLINK_RATE
		ed.cursor_visible = !ed.cursor_visible
	}
}

editor_render :: proc(ed: ^Editor, renderer: ^sdl3.Renderer, width: i32, height: i32) {
	// Calculate visible area
	status_height: i32 = ed.line_height + 4
	text_area_height := height - status_height
	ed.visible_lines = u32(text_area_height / ed.line_height)
	if ed.visible_lines == 0 { ed.visible_lines = 1 }

	// Line number gutter width (enough for 4+ digit line numbers)
	line_count := document.document_line_count(&ed.doc)
	gutter_chars := max(digit_count(line_count), 3)
	gutter_width := i32(gutter_chars + 1) * ed.char_width
	ed.gutter_width = gutter_width

	// Draw background
	sdl3.SetRenderDrawColorFloat(renderer, ed.bg_color.r, ed.bg_color.g, ed.bg_color.b, ed.bg_color.a)
	sdl3.RenderFillRect(renderer, &sdl3.FRect{0, 0, f32(width), f32(height)})

	// Render visible lines
	end_line := min(ed.scroll_line + ed.visible_lines, line_count)

	sel_lo, sel_hi, has_sel := selection_range(ed)

	for line_idx := ed.scroll_line; line_idx < end_line; line_idx += 1 {
		screen_y := ed.padding_y + i32(line_idx - ed.scroll_line) * ed.line_height

		// Draw line number
		line_num_str := fmt.tprintf("%*d", gutter_chars, line_idx + 1)
		render_string(ed, renderer, line_num_str, ed.padding_x, screen_y, ed.line_num_color)

		// Draw line content
		line_text := document.document_get_line(&ed.doc, line_idx)
		text_x := ed.padding_x + gutter_width

		// Draw selection highlight for this line (behind text/cursor)
		if has_sel {
			line_byte_start := document.document_line_start(&ed.doc, line_idx)
			line_byte_end := line_byte_start + u32(len(line_text)) // position of newline (or EOF)
			if sel_hi > line_byte_start && sel_lo <= line_byte_end {
				lo_col := i32(sel_lo > line_byte_start ? sel_lo - line_byte_start : 0)
				hi_col: i32
				if sel_hi > line_byte_end {
					// Selection continues past EOL — extend one char to indicate newline included
					hi_col = i32(len(line_text)) + 1
				} else {
					hi_col = i32(sel_hi - line_byte_start)
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

		is_cursor_line := line_idx == ed.cursor_line && ed.cursor_visible
		cursor_col_byte := int(ed.cursor_col)

		if len(line_text) > 0 {
			if is_cursor_line && cursor_col_byte < len(line_text) {
				// Render text before cursor
				if cursor_col_byte > 0 {
					render_string(ed, renderer, line_text[:cursor_col_byte], text_x, screen_y, ed.fg_color)
				}
				// Render text after cursor char
				char_end := cursor_col_byte + 1
				// Handle UTF-8: find the end of the rune
				if line_text[cursor_col_byte] >= 0xC0 {
					if line_text[cursor_col_byte] < 0xE0 { char_end = cursor_col_byte + 2 }
					else if line_text[cursor_col_byte] < 0xF0 { char_end = cursor_col_byte + 3 }
					else { char_end = cursor_col_byte + 4 }
				}
				char_end = min(char_end, len(line_text))

				if char_end < len(line_text) {
					after_x := text_x + i32(char_end) * ed.char_width
					render_string(ed, renderer, line_text[char_end:], after_x, screen_y, ed.fg_color)
				}

				// Draw block cursor
				cursor_x := text_x + i32(cursor_col_byte) * ed.char_width
				cursor_rect := sdl3.FRect{
					f32(cursor_x), f32(screen_y),
					f32(ed.char_width), f32(ed.line_height),
				}
				sdl3.SetRenderDrawColorFloat(renderer, ed.cursor_color.r, ed.cursor_color.g, ed.cursor_color.b, 1.0)
				sdl3.RenderFillRect(renderer, &cursor_rect)

				// Draw the character under cursor with inverted color (background color)
				render_string(ed, renderer, line_text[cursor_col_byte:char_end], i32(cursor_x), screen_y, ed.bg_color)
			} else {
				render_string(ed, renderer, line_text, text_x, screen_y, ed.fg_color)
				if is_cursor_line {
					// Cursor is past end of line
					cursor_x := text_x + i32(cursor_col_byte) * ed.char_width
					cursor_rect := sdl3.FRect{
						f32(cursor_x), f32(screen_y),
						f32(ed.char_width), f32(ed.line_height),
					}
					sdl3.SetRenderDrawColorFloat(renderer, ed.cursor_color.r, ed.cursor_color.g, ed.cursor_color.b, 1.0)
					sdl3.RenderFillRect(renderer, &cursor_rect)
				}
			}
		} else if is_cursor_line {
			// Empty line, just draw block cursor
			cursor_x := text_x
			cursor_rect := sdl3.FRect{
				f32(cursor_x), f32(screen_y),
				f32(ed.char_width), f32(ed.line_height),
			}
			sdl3.SetRenderDrawColorFloat(renderer, ed.cursor_color.r, ed.cursor_color.g, ed.cursor_color.b, 1.0)
			sdl3.RenderFillRect(renderer, &cursor_rect)
		}
	}

	// Draw status bar
	status_y := height - status_height
	sdl3.SetRenderDrawColorFloat(renderer, ed.status_bg.r, ed.status_bg.g, ed.status_bg.b, ed.status_bg.a)
	sdl3.RenderFillRect(renderer, &sdl3.FRect{0, f32(status_y), f32(width), f32(status_height)})

	dirty_indicator := document.document_is_dirty(&ed.doc) ? "[+] " : ""
	status_text := fmt.tprintf("%sLn %d, Col %d | %d lines | %d bytes",
		dirty_indicator,
		ed.cursor_line + 1,
		ed.cursor_col + 1,
		line_count,
		document.document_length(&ed.doc),
	)
	render_string(ed, renderer, status_text, ed.padding_x, status_y + 2, ed.status_fg)
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

// --- Helpers ---

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

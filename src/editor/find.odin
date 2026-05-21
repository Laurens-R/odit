package editor

import "core:fmt"
import "vendor:sdl3"

import "../document"
import "../ui"

// --- Types -----------------------------------------------------------------

// One occurrence of the current find query in the active pane's document.
// Stored as line + byte range within the line so the renderer doesn't have to
// translate absolute offsets back to (line, column) every frame. Matches are
// constrained to a single line (the matcher refuses to cross '\n'), so this
// always represents a single contiguous span on a single visual row.
@(private)
FindMatch :: struct {
	line:       u32, // 0-based document line index
	start_byte: u32, // byte offset within the line
	end_byte:   u32, // exclusive byte offset within the line
}

// Per-editor find-mode state. The bar attaches to a single pane at a time
// (`pane_index`); it closes on Esc, on a mouse click outside the bar, or when
// the active pane changes. `bar_rectangle` is rewritten every frame by the
// renderer so the mouse hit-test in mouse.odin can decide whether a click
// landed on the bar or on the underlying text.
@(private)
FindState :: struct {
	active:        bool,
	pane_index:    int,
	query_buffer:  [dynamic]u8,
	matches:       [dynamic]FindMatch,
	current_match: int, // -1 when no matches
	bar_rectangle: sdl3.FRect,
}

// Hard cap on matches collected per recompute. Past this we just stop scanning
// so a wildcard like "*" on a huge doc can't lock the UI up.
@(private)
FIND_MAX_MATCHES :: 10000

// --- Lifecycle -------------------------------------------------------------

@(private)
find_state_destroy :: proc(find: ^FindState) {
	delete(find.query_buffer)
	delete(find.matches)
	find^ = FindState{}
}

@(private)
find_active :: proc(editor: ^Editor) -> bool {
	return editor.find.active
}

// Open the find bar on the active pane. No-op if the active pane isn't an
// editor pane. Pre-seeds the query from the current selection so the common
// "select word, Ctrl+F" flow works without re-typing.
@(private)
find_open :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }

	// Only one bottom-bar at a time. Cancel any in-progress replace before
	// taking over, so the replace preview is rolled back cleanly.
	replace_close(editor, false)

	editor.find.active     = true
	editor.find.pane_index = editor.active_pane_index

	// Seed query from the current selection when it's a short single-line span.
	if editor_pane.selection_active {
		low_offset, high_offset, has_selection := editor_pane_selection_range(editor_pane)
		if has_selection && high_offset - low_offset <= 256 {
			selection_text := document.document_get_slice(&editor_pane.document, low_offset, high_offset - low_offset, context.temp_allocator)
			contains_newline := false
			for byte_value in transmute([]u8)selection_text {
				if byte_value == '\n' { contains_newline = true; break }
			}
			if !contains_newline {
				clear(&editor.find.query_buffer)
				for byte_value in transmute([]u8)selection_text { append(&editor.find.query_buffer, byte_value) }
			}
		}
		editor_pane.selection_active = false
	}

	find_recompute(editor)
}

@(private)
find_close :: proc(editor: ^Editor) {
	if !editor.find.active { return }
	editor.find.active = false
	clear(&editor.find.matches)
	editor.find.current_match = -1
	editor.find.bar_rectangle = sdl3.FRect{}
}

// --- Query mutation --------------------------------------------------------

@(private="file")
find_query_append :: proc(editor: ^Editor, text_to_append: string) {
	for byte_value in transmute([]u8)text_to_append {
		if byte_value == '\n' || byte_value == '\r' { continue }
		append(&editor.find.query_buffer, byte_value)
	}
	find_recompute(editor)
}

@(private="file")
find_query_backspace :: proc(editor: ^Editor) {
	query_length := len(editor.find.query_buffer)
	if query_length == 0 { return }
	// Strip one UTF-8 code point.
	new_end_index := query_length - 1
	for new_end_index > 0 && (editor.find.query_buffer[new_end_index] & 0xC0) == 0x80 { new_end_index -= 1 }
	resize(&editor.find.query_buffer, new_end_index)
	find_recompute(editor)
}

// --- Search ----------------------------------------------------------------

// Rebuild the match list against the current pane's document. Called whenever
// the query changes (and once on open). Picks an initial `current_match` near
// the document cursor so the user lands on something sensible.
@(private)
find_recompute :: proc(editor: ^Editor) {
	clear(&editor.find.matches)
	editor.find.current_match = -1

	if !editor.find.active                           { return }
	if len(editor.find.query_buffer) == 0            { return }
	if editor.find.pane_index < 0 || editor.find.pane_index >= len(editor.panes) { return }

	editor_pane := pane_as_editor(&editor.panes[editor.find.pane_index])
	if editor_pane == nil { return }

	query_bytes := editor.find.query_buffer[:]
	total_line_count := document.document_line_count(&editor_pane.document)

	for line_index: u32 = 0; line_index < total_line_count; line_index += 1 {
		if len(editor.find.matches) >= FIND_MAX_MATCHES { break }
		line_text := document.document_get_line(&editor_pane.document, line_index, context.temp_allocator)
		line_bytes := transmute([]u8)line_text
		search_position := 0
		for search_position <= len(line_bytes) {
			if len(editor.find.matches) >= FIND_MAX_MATCHES { break }
			consumed_byte_count, matched := glob_match_at(line_bytes[search_position:], query_bytes)
			if !matched {
				search_position += 1
				continue
			}
			append(&editor.find.matches, FindMatch{
				line       = line_index,
				start_byte = u32(search_position),
				end_byte   = u32(search_position + consumed_byte_count),
			})
			// Always advance at least one byte so a zero-length match (e.g.
			// query "*") doesn't spin forever on the same offset.
			advance_step := consumed_byte_count
			if advance_step < 1 { advance_step = 1 }
			search_position += advance_step
		}
	}

	if len(editor.find.matches) == 0 { return }

	// Pick the first match at or after the cursor; fall back to 0.
	cursor_offset := editor_pane.cursor_offset
	editor.find.current_match = 0
	for found_match, found_match_index in editor.find.matches {
		match_offset := document.document_line_start(&editor_pane.document, found_match.line) + found_match.start_byte
		if match_offset >= cursor_offset {
			editor.find.current_match = found_match_index
			break
		}
	}

	find_jump_to_current(editor)
}

// Shortest-prefix glob matcher. Returns the number of bytes consumed at the
// start of `text` and whether a match was found. `*` matches any byte sequence
// (not crossing '\n') and `?` matches a single non-'\n' byte.
//
// Since we only ever call this on a single line of text (no '\n' present), the
// newline guard is defensive; the matcher won't synthesize a '\n' on its own.
//
// Shared with the Replace bar in replace.odin — keep package-private.
@(private)
glob_match_at :: proc(text: []byte, pattern: []byte) -> (consumed: int, matched: bool) {
	text_index    := 0
	pattern_index := 0
	star_text_index    := -1
	star_pattern_index := -1

	for text_index < len(text) {
		if pattern_index < len(pattern) && pattern[pattern_index] == '*' {
			star_text_index    = text_index
			star_pattern_index = pattern_index
			pattern_index += 1
			if pattern_index == len(pattern) {
				// Trailing '*' — shortest match consumes nothing past here.
				return text_index, true
			}
			continue
		}
		if pattern_index < len(pattern) {
			pattern_byte := pattern[pattern_index]
			text_byte    := text[text_index]
			if text_byte == '\n' {
				// Match must stay on a single line — neither '?' nor a literal
				// in the query is allowed to consume a newline.
				if star_pattern_index == -1 { return 0, false }
				return 0, false
			}
			if pattern_byte == '?' || pattern_byte == text_byte {
				text_index += 1
				pattern_index += 1
				if pattern_index == len(pattern) { return text_index, true }
				continue
			}
		}
		if star_pattern_index != -1 {
			star_text_index += 1
			if star_text_index > len(text) { return 0, false }
			text_index    = star_text_index
			pattern_index = star_pattern_index + 1
			if pattern_index == len(pattern) { return text_index, true }
			continue
		}
		return 0, false
	}

	// Text exhausted — only matches if remaining pattern is all '*'s.
	for pattern_index < len(pattern) && pattern[pattern_index] == '*' { pattern_index += 1 }
	if pattern_index == len(pattern) { return text_index, true }
	return 0, false
}

// --- Navigation ------------------------------------------------------------

// Move current_match by +1 / -1 (wrapping). Caller handles bounds; no-op when
// the match list is empty.
@(private)
find_navigate :: proc(editor: ^Editor, direction: int) {
	if !editor.find.active                  { return }
	if len(editor.find.matches) == 0        { return }
	if direction == 0                       { return }

	match_count := len(editor.find.matches)
	new_index := editor.find.current_match + direction
	// Modular wrap (Odin's % can return negative for negative operands).
	new_index = ((new_index % match_count) + match_count) % match_count
	editor.find.current_match = new_index
	find_jump_to_current(editor)
}

// Move the active pane's cursor to the current match and scroll it into view.
// We move the cursor (rather than just scrolling) so that Esc leaves the user
// at the match they navigated to — same as VS Code / Sublime / etc.
@(private="file")
find_jump_to_current :: proc(editor: ^Editor) {
	if editor.find.current_match < 0                                       { return }
	if editor.find.current_match >= len(editor.find.matches)               { return }
	if editor.find.pane_index != editor.active_pane_index                  { return }
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }

	match := editor.find.matches[editor.find.current_match]
	line_start_offset := document.document_line_start(&editor_pane.document, match.line)
	editor_pane.cursor_line    = match.line
	editor_pane.cursor_column  = match.start_byte
	editor_pane.cursor_offset  = line_start_offset + match.start_byte
	editor_pane.selection_active = false
	editor.cursor_visible = true
	editor.cursor_timer   = 0
	ensure_cursor_visible(editor)
}

// --- Event handling --------------------------------------------------------

// Returns true if `event` was fully consumed by find mode. The caller falls
// back to normal dispatch otherwise (so mouse wheel keeps scrolling the doc,
// and clicks outside the bar can close find AND place the cursor in one go).
@(private)
find_handle_event :: proc(editor: ^Editor, event: ^sdl3.Event) -> bool {
	#partial switch event.type {
	case .TEXT_INPUT:
		input_text := string(event.text.text)
		if len(input_text) > 0 { find_query_append(editor, input_text) }
		return true

	case .KEY_DOWN:
		pressed_key   := event.key.key
		key_modifiers := event.key.mod
		ctrl_held     := .LCTRL  in key_modifiers || .RCTRL  in key_modifiers
		shift_held    := .LSHIFT in key_modifiers || .RSHIFT in key_modifiers

		switch pressed_key {
		case sdl3.K_ESCAPE:
			find_close(editor)
			return true
		case sdl3.K_UP:
			find_navigate(editor, -1)
			return true
		case sdl3.K_DOWN:
			find_navigate(editor, +1)
			return true
		case sdl3.K_RETURN:
			find_navigate(editor, shift_held ? -1 : +1)
			return true
		case sdl3.K_BACKSPACE:
			find_query_backspace(editor)
			return true
		case sdl3.K_F:
			if ctrl_held {
				find_close(editor)
				return true
			}
		}
		// Swallow any other key while find is active so accidental edits don't
		// leak through to the document.
		return true
	}
	return false
}

// --- Rendering -------------------------------------------------------------

// Find's highlight pass — delegates to the shared match-highlight renderer.
@(private)
find_render_highlights :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, editor_pane: ^EditorPane, view_x, text_y, gutter_width: i32, pane_index: int) {
	if !editor.find.active                       { return }
	if editor.find.pane_index != pane_index      { return }
	render_match_highlights(editor, renderer, editor_pane, view_x, text_y, gutter_width, pane_index,
		editor.find.matches[:], editor.find.current_match)
}

// Paint highlight rectangles for every match in `matches` that lands inside the
// visible viewport of `editor_pane`. Called from the editor's normal renderer
// before the glyph layer (the alpha-blended fill tints both background and text
// without obscuring the characters). Shared by Find and Replace; pass
// `current_match = -1` if there is no distinguished match to brighten.
//
// `view_x`/`text_y` is the top-left of the pane's text area (i.e. past the
// title bar). Text inside that area starts at view_x + padding + gutter — this
// proc applies that offset itself.
@(private)
render_match_highlights :: proc(
	editor: ^Editor, renderer: ^sdl3.Renderer, editor_pane: ^EditorPane,
	view_x, text_y, gutter_width: i32, pane_index: int,
	matches: []FindMatch, current_match: int,
) {
	if len(matches) == 0 { return }

	scroll_y_pixels := i32(editor_pane.scroll_y)
	scroll_x_pixels := i32(editor_pane.scroll_x)
	if editor_pane.wrap_mode { scroll_x_pixels = 0 }
	first_visible_line := editor_pane.scroll_line
	last_visible_line  := first_visible_line + editor_pane.visible_lines + 2

	sdl3.SetRenderDrawBlendMode(renderer, sdl3.BLENDMODE_BLEND)
	defer sdl3.SetRenderDrawBlendMode(renderer, sdl3.BLENDMODE_NONE)

	for match_value, match_index in matches {
		if match_value.line < first_visible_line { continue }
		if match_value.line >  last_visible_line { break }

		// Recompute the display tab-expansion for this line so we can convert
		// the match's raw byte range into visual columns. Cheap — `build_line_display`
		// runs per visible line in the regular renderer anyway.
		line_text := document.document_get_line(&editor_pane.document, match_value.line, context.temp_allocator)
		_, byte_to_visual_column := build_line_display(line_text)

		if int(match_value.start_byte) > len(line_text) || int(match_value.end_byte) > len(line_text) { continue }

		start_visual_column := i32(byte_to_visual_column[match_value.start_byte])
		end_visual_column   := i32(byte_to_visual_column[match_value.end_byte])
		if end_visual_column <= start_visual_column { continue }

		is_active_match := match_index == current_match

		// Wrap mode: emit one rect per visual row the match crosses.
		if editor_pane.wrap_mode {
			render_match_highlight_wrapped(editor, renderer, editor_pane, view_x, text_y, gutter_width, pane_index,
				match_value.line, start_visual_column, end_visual_column, is_active_match)
			continue
		}

		row_y_position := text_y + editor.padding_y + i32(match_value.line) * editor.line_height - scroll_y_pixels
		text_origin_x := view_x + editor.padding_x + gutter_width - scroll_x_pixels
		rectangle := sdl3.FRect{
			f32(text_origin_x + start_visual_column * editor.character_width),
			f32(row_y_position),
			f32((end_visual_column - start_visual_column) * editor.character_width),
			f32(editor.line_height),
		}
		highlight_color := is_active_match ? editor.find_match_active_background : editor.find_match_background
		sdl3.SetRenderDrawColorFloat(renderer, highlight_color.r, highlight_color.g, highlight_color.b, highlight_color.a)
		sdl3.RenderFillRect(renderer, &rectangle)
	}
}

// Wrap-mode highlight: the match's visual span may cross row boundaries, so
// we slice it the same way the wrap-mode text renderer slices the display
// text. Mirrors the selection-rect logic in render_wrapped_doc_line.
@(private="file")
render_match_highlight_wrapped :: proc(
	editor: ^Editor, renderer: ^sdl3.Renderer, editor_pane: ^EditorPane,
	view_x, text_y, gutter_width: i32, pane_index: int,
	line_index: u32, start_visual_column, end_visual_column: i32,
	is_active_match: bool,
) {
	pane := &editor.panes[pane_index]
	text_area_width := pane.rectangle.w - editor.padding_x - gutter_width - editor.padding_x
	columns_per_row := text_area_width / editor.character_width
	if columns_per_row < 1 { columns_per_row = 1 }

	// Need to compute the screen-y of this line in wrap mode: walk wrap rows
	// from scroll_line up to line_index. Cheaper for small visible ranges than
	// reusing the full render loop here.
	scroll_y_pixels := i32(editor_pane.scroll_y)
	current_y_position := text_y + editor.padding_y - scroll_y_pixels % editor.line_height
	for walk_line: u32 = editor_pane.scroll_line; walk_line < line_index; walk_line += 1 {
		walk_text := document.document_get_line(&editor_pane.document, walk_line, context.temp_allocator)
		walk_display, _ := build_line_display(walk_text)
		walk_columns := i32(len(walk_display))
		if walk_columns == 0 { walk_columns = 1 }
		walk_rows := (walk_columns + columns_per_row - 1) / columns_per_row
		current_y_position += walk_rows * editor.line_height
	}

	text_origin_x := view_x + editor.padding_x + gutter_width

	first_row := start_visual_column / columns_per_row
	last_row  := (end_visual_column - 1) / columns_per_row
	highlight_color := is_active_match ? editor.find_match_active_background : editor.find_match_background
	sdl3.SetRenderDrawColorFloat(renderer, highlight_color.r, highlight_color.g, highlight_color.b, highlight_color.a)
	for visual_row in first_row..=last_row {
		row_start_column := visual_row * columns_per_row
		row_end_column   := row_start_column + columns_per_row
		segment_low  := max(start_visual_column, row_start_column)
		segment_high := min(end_visual_column,   row_end_column)
		if segment_high <= segment_low { continue }
		rectangle := sdl3.FRect{
			f32(text_origin_x + (segment_low - row_start_column) * editor.character_width),
			f32(current_y_position + visual_row * editor.line_height),
			f32((segment_high - segment_low) * editor.character_width),
			f32(editor.line_height),
		}
		sdl3.RenderFillRect(renderer, &rectangle)
	}
}

// Draw the find bar at the bottom of the active pane. `pane_bottom_y` is the
// y-coordinate of the line just below the text area (i.e. where the bar's
// top edge sits). The bar takes the full pane width.
@(private)
find_render_bar :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, pane: ^Pane) {
	if !editor.find.active { return }

	bar_height := editor_find_bar_height_for_pane(editor, editor.find.pane_index)
	bar_y := pane.rectangle.y + pane.rectangle.h - bar_height
	bar_rectangle := sdl3.FRect{f32(pane.rectangle.x), f32(bar_y), f32(pane.rectangle.w), f32(bar_height)}
	editor.find.bar_rectangle = bar_rectangle

	// Background tint + accent top stripe so it reads as a distinct widget.
	sdl3.SetRenderDrawColorFloat(renderer, editor.status_bar_background.r, editor.status_bar_background.g, editor.status_bar_background.b, editor.status_bar_background.a)
	sdl3.RenderFillRect(renderer, &bar_rectangle)
	stripe_rectangle := sdl3.FRect{bar_rectangle.x, bar_rectangle.y, bar_rectangle.w, 1}
	sdl3.SetRenderDrawColorFloat(renderer, editor.cursor_color.r, editor.cursor_color.g, editor.cursor_color.b, 1.0)
	sdl3.RenderFillRect(renderer, &stripe_rectangle)

	ui_context := editor_make_ui_context(editor, renderer)
	theme := ui.default_theme()

	// Layout: prompt + input (left), match counter (right).
	text_y_position := bar_y + (bar_height - editor.line_height) / 2

	prompt_label := "Find: "
	prompt_width, _ := ui.text_size(&ui_context, prompt_label)
	input_x := pane.rectangle.x + editor.padding_x + prompt_width
	ui.draw_text(&ui_context, prompt_label, pane.rectangle.x + editor.padding_x, text_y_position, theme.dim_foreground)

	query_string := string(editor.find.query_buffer[:])
	if len(query_string) > 0 {
		ui.draw_text(&ui_context, query_string, input_x, text_y_position, theme.text_foreground)
	}

	// Blinking cursor at end of the query string.
	if editor.cursor_visible {
		query_width, _ := ui.text_size(&ui_context, query_string)
		cursor_rectangle := sdl3.FRect{
			f32(input_x + query_width),
			f32(text_y_position),
			f32(editor.character_width),
			f32(editor.line_height),
		}
		sdl3.SetRenderDrawColorFloat(renderer, theme.accent_foreground.r, theme.accent_foreground.g, theme.accent_foreground.b, theme.accent_foreground.a)
		sdl3.RenderFillRect(renderer, &cursor_rectangle)
	}

	// Right side: "N/M" indicator (or hint when no query / no matches).
	status_text: string
	switch {
	case len(editor.find.query_buffer) == 0:
		status_text = "wildcards: *  ?    ↑/↓ navigate  Esc exit"
	case len(editor.find.matches) == 0:
		status_text = "no matches"
	case len(editor.find.matches) >= FIND_MAX_MATCHES:
		status_text = fmt.tprintf("%d / %d+", editor.find.current_match + 1, len(editor.find.matches))
	case:
		status_text = fmt.tprintf("%d / %d", editor.find.current_match + 1, len(editor.find.matches))
	}
	if len(status_text) > 0 {
		status_width, _ := ui.text_size(&ui_context, status_text)
		status_x_position := pane.rectangle.x + pane.rectangle.w - editor.padding_x - status_width
		ui.draw_text(&ui_context, status_text, status_x_position, text_y_position, theme.dim_foreground)
	}
}

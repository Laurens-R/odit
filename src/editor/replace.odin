package editor

import "core:fmt"
import "vendor:sdl3"

import "../document"
import "../ui"

// --- Types -----------------------------------------------------------------

@(private)
ReplaceField :: enum {
	Search,
	Replace,
}

// Per-editor state for the Ctrl+R "find and replace" bar. Unlike Find this
// actually mutates the document on every keystroke so the user can see the
// replacement live; the in-progress preview is rolled back on Esc and
// coalesced into a single Compound undo entry on Enter (so Ctrl+Z reverts
// the whole transaction).
//
// `undo_snapshot_position` captures `doc.undo_stack.current_position` at open
// time; `replace_refresh` rolls the doc back to that point before each new
// preview. `saved_*` mirror the pre-open editor state so cancel can restore
// it exactly. `bar_rectangle` / field rects are repainted every frame so the
// mouse handler in mouse.odin can hit-test them.
@(private)
ReplaceState :: struct {
	active:                  bool,
	pane_index:              int,
	focused_field:           ReplaceField,
	search_buffer:           [dynamic]u8,
	replace_buffer:          [dynamic]u8,
	matches:                 [dynamic]FindMatch, // reuses Find's match struct

	bar_rectangle:           sdl3.FRect,
	search_field_rectangle:  sdl3.FRect,
	replace_field_rectangle: sdl3.FRect,

	undo_snapshot_position:  int,
	has_preview_applied:     bool,

	// Gates the live-preview pipeline. False until the user actually types
	// (or backspaces) inside the Replace input; until then we just paint
	// match highlights without touching the document — typing a search query
	// shouldn't make every match vanish before the user even looked at the
	// Replace field. Once true it stays true, so clearing the field back to
	// empty still applies "delete all matches" preview (the explicit
	// "replace with nothing" case).
	replace_field_touched:   bool,

	// Pre-open editor state, restored on cancel so a discarded preview is
	// invisible to the user (cursor, selection, dirty flag).
	saved_cursor_offset:     u32,
	saved_dirty_flag:        bool,
}

// --- Lifecycle -------------------------------------------------------------

@(private)
replace_state_destroy :: proc(replace: ^ReplaceState) {
	delete(replace.search_buffer)
	delete(replace.replace_buffer)
	delete(replace.matches)
	replace^ = ReplaceState{}
}

@(private)
replace_active :: proc(editor: ^Editor) -> bool {
	return editor.replace.active
}

// Pixel height of the replace bar when active on `pane_index`. Two text rows
// plus a little vertical padding above/below/between.
@(private)
replace_bar_height_for_pane :: proc(editor: ^Editor, pane_index: int) -> i32 {
	if !editor.replace.active                       { return 0 }
	if editor.replace.pane_index != pane_index      { return 0 }
	return editor.line_height * 2 + 18
}

@(private)
replace_open :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }

	// Only one bottom-bar at a time. Close find first.
	find_close(editor)

	editor.replace.active                 = true
	editor.replace.pane_index             = editor.active_pane_index
	editor.replace.focused_field          = .Search
	editor.replace.saved_cursor_offset    = editor_pane.cursor_offset
	editor.replace.saved_dirty_flag       = document.document_is_dirty(&editor_pane.document)
	editor.replace.undo_snapshot_position = document.document_begin_compound(&editor_pane.document)
	editor.replace.has_preview_applied    = false
	editor.replace.replace_field_touched  = false

	// Seed search field from a short single-line selection — same convenience
	// as Find. Clears the selection afterwards so the highlight doesn't
	// distract from the matches.
	if editor_pane.selection_active {
		low_offset, high_offset, has_selection := editor_pane_selection_range(editor_pane)
		if has_selection && high_offset - low_offset <= 256 {
			selection_text := document.document_get_slice(&editor_pane.document, low_offset, high_offset - low_offset, context.temp_allocator)
			contains_newline := false
			for byte_value in transmute([]u8)selection_text {
				if byte_value == '\n' { contains_newline = true; break }
			}
			if !contains_newline {
				clear(&editor.replace.search_buffer)
				for byte_value in transmute([]u8)selection_text { append(&editor.replace.search_buffer, byte_value) }
			}
		}
		editor_pane.selection_active = false
	}

	replace_refresh(editor)
}

// Close the replace bar. `commit == true` keeps the preview and coalesces all
// recorded edits into one Compound undo entry; `commit == false` rolls the doc
// back to its pre-open state and discards the abandoned edits.
@(private)
replace_close :: proc(editor: ^Editor, commit: bool) {
	if !editor.replace.active { return }

	editor_pane := pane_as_editor(&editor.panes[editor.replace.pane_index])
	if editor_pane != nil {
		if commit {
			if editor.replace.has_preview_applied {
				document.document_end_compound(&editor_pane.document, editor.replace.undo_snapshot_position)
				pane_mark_document_modified(editor, editor_pane)
			}
		} else {
			if editor.replace.has_preview_applied {
				document.document_pop_to_position(&editor_pane.document, editor.replace.undo_snapshot_position)
				// Restore pre-open state so a cancel is invisible.
				editor_pane.cursor_offset = editor.replace.saved_cursor_offset
				if !editor.replace.saved_dirty_flag {
					document.document_mark_saved(&editor_pane.document)
				}
				sync_cursor_from_offset(editor)
			}
		}
	}

	editor.replace.active = false
	clear(&editor.replace.search_buffer)
	clear(&editor.replace.replace_buffer)
	clear(&editor.replace.matches)
	editor.replace.has_preview_applied   = false
	editor.replace.replace_field_touched = false
	editor.replace.bar_rectangle         = sdl3.FRect{}
}

// --- Preview pipeline -----------------------------------------------------

// Roll back any prior preview, recompute matches against the now-restored
// document state, then re-apply the replacement. Called after every keystroke
// in either field — yes, it does the full O(doc) scan each time, but the doc
// is single-pane and search/replace input is human-rate, so this is fine in
// practice and keeps the data flow extremely simple.
@(private)
replace_refresh :: proc(editor: ^Editor) {
	editor_pane := pane_as_editor(&editor.panes[editor.replace.pane_index]); if editor_pane == nil { return }

	if editor.replace.has_preview_applied {
		document.document_pop_to_position(&editor_pane.document, editor.replace.undo_snapshot_position)
		editor.replace.has_preview_applied = false
	}

	replace_recompute_matches(editor, editor_pane)

	// Live preview only kicks in after the user touches the Replace field —
	// otherwise just typing a search term would yank every match out of the
	// document, which feels jarring. Highlights still draw via
	// `replace_render_highlights` so the user sees what would be replaced.
	if len(editor.replace.matches) > 0 && editor.replace.replace_field_touched {
		replace_apply_preview(editor, editor_pane)
	}
}

@(private="file")
replace_recompute_matches :: proc(editor: ^Editor, editor_pane: ^EditorPane) {
	clear(&editor.replace.matches)
	if len(editor.replace.search_buffer) == 0 { return }

	query_bytes := editor.replace.search_buffer[:]
	total_line_count := document.document_line_count(&editor_pane.document)

	for line_index: u32 = 0; line_index < total_line_count; line_index += 1 {
		if len(editor.replace.matches) >= FIND_MAX_MATCHES { break }
		line_text := document.document_get_line(&editor_pane.document, line_index, context.temp_allocator)
		line_bytes := transmute([]u8)line_text
		search_position := 0
		for search_position <= len(line_bytes) {
			if len(editor.replace.matches) >= FIND_MAX_MATCHES { break }
			consumed_byte_count, matched := glob_match_at(line_bytes[search_position:], query_bytes)
			if !matched {
				search_position += 1
				continue
			}
			append(&editor.replace.matches, FindMatch{
				line       = line_index,
				start_byte = u32(search_position),
				end_byte   = u32(search_position + consumed_byte_count),
			})
			advance_step := consumed_byte_count
			if advance_step < 1 { advance_step = 1 }
			search_position += advance_step
		}
	}
}

// Apply the current replacement at every match, last-to-first so earlier
// offsets don't shift under us as later matches change size. Each individual
// insert/delete is recorded in the doc undo stack — `replace_close(commit=true)`
// coalesces them into one Compound entry.
@(private="file")
replace_apply_preview :: proc(editor: ^Editor, editor_pane: ^EditorPane) {
	replace_text := string(editor.replace.replace_buffer[:])

	for match_index := len(editor.replace.matches) - 1; match_index >= 0; match_index -= 1 {
		match_value := editor.replace.matches[match_index]
		line_start := document.document_line_start(&editor_pane.document, match_value.line)
		absolute_offset := line_start + match_value.start_byte
		original_length := match_value.end_byte - match_value.start_byte
		if original_length > 0 {
			document.document_delete(&editor_pane.document, absolute_offset, original_length)
		}
		if len(replace_text) > 0 {
			document.document_insert(&editor_pane.document, absolute_offset, replace_text)
		}
	}

	editor.replace.has_preview_applied = true
}

// --- Event handling --------------------------------------------------------

// Active-field text buffer accessor. Returns a pointer so callers can mutate.
@(private="file")
replace_focused_buffer :: proc(editor: ^Editor) -> ^[dynamic]u8 {
	if editor.replace.focused_field == .Search { return &editor.replace.search_buffer }
	return &editor.replace.replace_buffer
}

// Returns true when the event was consumed by replace mode. Mouse wheel and
// mouse buttons fall through so the user can still scroll, and click-outside
// is handled in mouse.odin (it commits as cancel and then proceeds with the
// normal click).
@(private)
replace_handle_event :: proc(editor: ^Editor, event: ^sdl3.Event) -> bool {
	#partial switch event.type {
	case .TEXT_INPUT:
		input_text := string(event.text.text)
		if len(input_text) > 0 {
			buffer := replace_focused_buffer(editor)
			for byte_value in transmute([]u8)input_text {
				if byte_value == '\n' || byte_value == '\r' { continue }
				append(buffer, byte_value)
			}
			if editor.replace.focused_field == .Replace {
				editor.replace.replace_field_touched = true
			}
			replace_refresh(editor)
		}
		return true

	case .KEY_DOWN:
		pressed_key   := event.key.key
		key_modifiers := event.key.mod
		ctrl_held     := .LCTRL  in key_modifiers || .RCTRL  in key_modifiers

		switch pressed_key {
		case sdl3.K_ESCAPE:
			replace_close(editor, false) // cancel
			return true
		case sdl3.K_RETURN:
			// Pressing Enter while focused on Replace is an explicit "commit
			// this Replace value" — including the empty case, where it means
			// "delete all matches". Arm the preview if the user never typed
			// in the field, so the commit has something to coalesce.
			if editor.replace.focused_field == .Replace && !editor.replace.replace_field_touched {
				editor.replace.replace_field_touched = true
				replace_refresh(editor)
			}
			replace_close(editor, true) // commit
			return true
		case sdl3.K_TAB:
			editor.replace.focused_field = editor.replace.focused_field == .Search ? .Replace : .Search
			return true
		case sdl3.K_BACKSPACE:
			buffer := replace_focused_buffer(editor)
			buffer_length := len(buffer^)
			if buffer_length > 0 {
				new_end := buffer_length - 1
				for new_end > 0 && ((buffer^)[new_end] & 0xC0) == 0x80 { new_end -= 1 }
				resize(buffer, new_end)
				if editor.replace.focused_field == .Replace {
					editor.replace.replace_field_touched = true
				}
				replace_refresh(editor)
			}
			return true
		case sdl3.K_R:
			if ctrl_held {
				replace_close(editor, false)
				return true
			}
		}
		// Swallow everything else (so a stray key can't sneak edits into
		// the document while the preview is live).
		return true
	}
	return false
}

// Mouse hit-test for the search/replace input fields. Called from mouse.odin
// when a MOUSE_BUTTON_DOWN lands inside `bar_rectangle` so a click in either
// field gives that field focus.
@(private)
replace_handle_bar_click :: proc(editor: ^Editor, mouse_x, mouse_y: f32) {
	if !editor.replace.active { return }
	if ui.point_in_rect(editor.replace.search_field_rectangle, mouse_x, mouse_y) {
		editor.replace.focused_field = .Search
	} else if ui.point_in_rect(editor.replace.replace_field_rectangle, mouse_x, mouse_y) {
		editor.replace.focused_field = .Replace
	}
}

// --- Rendering -------------------------------------------------------------

@(private)
replace_render_highlights :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, editor_pane: ^EditorPane, view_x, text_y, gutter_width: i32, pane_index: int) {
	if !editor.replace.active                       { return }
	if editor.replace.pane_index != pane_index      { return }
	// `current_match = -1` — every match in Replace is equally interesting
	// (the cursor's not navigating between them like in Find).
	render_match_highlights(editor, renderer, editor_pane, view_x, text_y, gutter_width, pane_index,
		editor.replace.matches[:], -1)
}

// Draw the two-row replace bar at the bottom of the pane.
@(private)
replace_render_bar :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, pane: ^Pane) {
	if !editor.replace.active { return }

	bar_height := replace_bar_height_for_pane(editor, editor.replace.pane_index)
	bar_y := pane.rectangle.y + pane.rectangle.h - bar_height
	bar_rectangle := sdl3.FRect{f32(pane.rectangle.x), f32(bar_y), f32(pane.rectangle.w), f32(bar_height)}
	editor.replace.bar_rectangle = bar_rectangle

	// Background tint + accent top stripe (matches the Find bar treatment).
	sdl3.SetRenderDrawColorFloat(renderer, editor.status_bar_background.r, editor.status_bar_background.g, editor.status_bar_background.b, editor.status_bar_background.a)
	sdl3.RenderFillRect(renderer, &bar_rectangle)
	stripe_rectangle := sdl3.FRect{bar_rectangle.x, bar_rectangle.y, bar_rectangle.w, 1}
	sdl3.SetRenderDrawColorFloat(renderer, editor.cursor_color.r, editor.cursor_color.g, editor.cursor_color.b, 1.0)
	sdl3.RenderFillRect(renderer, &stripe_rectangle)

	ui_context := editor_make_ui_context(editor, renderer)
	theme := ui.default_theme()

	// Two rows: Search on top, Replace under it. Use the wider of the two
	// labels as the input-field origin so the inputs line up.
	search_label  := "Find:    "
	replace_label := "Replace: "
	label_width, _ := ui.text_size(&ui_context, replace_label)

	row_padding: i32 = 5
	row_one_y := bar_y + row_padding
	row_two_y := row_one_y + editor.line_height + 4

	input_x := pane.rectangle.x + editor.padding_x + label_width
	right_text_max_width: i32 = 30 * editor.character_width
	input_width := pane.rectangle.w - editor.padding_x - label_width - right_text_max_width - editor.padding_x
	if input_width < editor.character_width * 8 { input_width = editor.character_width * 8 }

	editor.replace.search_field_rectangle  = sdl3.FRect{f32(input_x), f32(row_one_y), f32(input_width), f32(editor.line_height)}
	editor.replace.replace_field_rectangle = sdl3.FRect{f32(input_x), f32(row_two_y), f32(input_width), f32(editor.line_height)}

	// Row 1 — Search
	ui.draw_text(&ui_context, search_label, pane.rectangle.x + editor.padding_x, row_one_y, theme.dim_foreground)
	search_string := string(editor.replace.search_buffer[:])
	if len(search_string) > 0 {
		ui.draw_text(&ui_context, search_string, input_x, row_one_y, theme.text_foreground)
	}
	if editor.replace.focused_field == .Search && editor.cursor_visible {
		query_width, _ := ui.text_size(&ui_context, search_string)
		cursor_rectangle := sdl3.FRect{f32(input_x + query_width), f32(row_one_y), f32(editor.character_width), f32(editor.line_height)}
		sdl3.SetRenderDrawColorFloat(renderer, theme.accent_foreground.r, theme.accent_foreground.g, theme.accent_foreground.b, theme.accent_foreground.a)
		sdl3.RenderFillRect(renderer, &cursor_rectangle)
	}

	// Row 2 — Replace
	ui.draw_text(&ui_context, replace_label, pane.rectangle.x + editor.padding_x, row_two_y, theme.dim_foreground)
	replace_string := string(editor.replace.replace_buffer[:])
	if len(replace_string) > 0 {
		ui.draw_text(&ui_context, replace_string, input_x, row_two_y, theme.text_foreground)
	}
	if editor.replace.focused_field == .Replace && editor.cursor_visible {
		query_width, _ := ui.text_size(&ui_context, replace_string)
		cursor_rectangle := sdl3.FRect{f32(input_x + query_width), f32(row_two_y), f32(editor.character_width), f32(editor.line_height)}
		sdl3.SetRenderDrawColorFloat(renderer, theme.accent_foreground.r, theme.accent_foreground.g, theme.accent_foreground.b, theme.accent_foreground.a)
		sdl3.RenderFillRect(renderer, &cursor_rectangle)
	}

	// Right column: match count + commit/cancel hint. The count label
	// flips to "replacements" once the preview is armed so the user can tell
	// at a glance whether what they're seeing is a live preview or just
	// highlighted matches waiting to be touched.
	count_text: string
	noun := editor.replace.replace_field_touched ? "replacements" : "matches"
	switch {
	case len(editor.replace.search_buffer) == 0:
		count_text = "wildcards: *  ?"
	case len(editor.replace.matches) == 0:
		count_text = "no matches"
	case len(editor.replace.matches) >= FIND_MAX_MATCHES:
		count_text = fmt.tprintf("%d+ %s", len(editor.replace.matches), noun)
	case:
		count_text = fmt.tprintf("%d %s", len(editor.replace.matches), noun)
	}
	hint_text: string
	if editor.replace.replace_field_touched {
		hint_text = "Enter commit  Esc cancel  Tab swap"
	} else {
		hint_text = "Type in Replace to preview  Esc cancel"
	}

	count_width, _ := ui.text_size(&ui_context, count_text)
	hint_width,  _ := ui.text_size(&ui_context, hint_text)
	count_x := pane.rectangle.x + pane.rectangle.w - editor.padding_x - count_width
	hint_x  := pane.rectangle.x + pane.rectangle.w - editor.padding_x - hint_width
	ui.draw_text(&ui_context, count_text, count_x, row_one_y, theme.dim_foreground)
	ui.draw_text(&ui_context, hint_text,  hint_x,  row_two_y, theme.dim_foreground)
}

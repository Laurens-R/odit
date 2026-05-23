package editor

import "core:slice"

import "../document"

// Multi-cursor support is layered on top of the existing single-cursor
// fields on `EditorPane` (cursor_offset / cursor_line / cursor_column /
// selection_active / selection_anchor). Those continue to act as the
// "primary" cursor — the one LSP / hover / completion / find / replace
// always speak to. Any additional carets live in `additional_cursors`
// and are folded in by the multi-cursor edit primitives below.
//
// The primary-only contract is deliberate: LSP requests target a single
// (line, column), and forking them N-ways would surface a UX no one
// asked for. Multi-cursor work happens in `multicursor.odin`
// (gather / scatter / replay) and the few edit / motion sites in
// `cursor.odin`, `selection.odin`, and `input.odin` that route through
// it; the rest of the editor stays single-cursor.

@(private)
Cursor :: struct {
	offset:           u32,
	line:             u32,
	column:           u32,
	selection_active: bool,
	selection_anchor: u32,
}

// --- Gather / scatter / dedupe ------------------------------------------
//
// "Gather" copies the primary + additionals into a flat slice we can
// shuffle, edit, and sort; "scatter" writes the result back, restoring
// the primary as cursors[0]. Edit primitives only ever touch the
// gathered slice — no in-place mutation of `pane.additional_cursors`
// inside an edit loop, which would surprise any concurrent iterator.

@(private)
pane_gather_cursors :: proc(pane: ^EditorPane, allocator := context.temp_allocator) -> [dynamic]Cursor {
	gathered := make([dynamic]Cursor, 0, 1 + len(pane.additional_cursors), allocator)
	append(&gathered, Cursor{
		offset           = pane.cursor_offset,
		line             = pane.cursor_line,
		column           = pane.cursor_column,
		selection_active = pane.selection_active,
		selection_anchor = pane.selection_anchor,
	})
	for additional_cursor in pane.additional_cursors {
		append(&gathered, additional_cursor)
	}
	return gathered
}

@(private)
pane_scatter_cursors :: proc(pane: ^EditorPane, cursors: []Cursor) {
	if len(cursors) == 0 { return }
	primary := cursors[0]
	pane.cursor_offset     = primary.offset
	pane.cursor_line       = primary.line
	pane.cursor_column     = primary.column
	pane.selection_active  = primary.selection_active
	pane.selection_anchor  = primary.selection_anchor
	clear(&pane.additional_cursors)
	for cursor_index in 1..<len(cursors) {
		append(&pane.additional_cursors, cursors[cursor_index])
	}
}

// Drop additional cursors whose `offset` matches the primary or another
// additional — happens naturally after edits when two carets walk into
// the same byte. The primary is always retained.
@(private)
pane_dedupe_cursors :: proc(pane: ^EditorPane) {
	if len(pane.additional_cursors) == 0 { return }
	deduped := make([dynamic]Cursor, 0, len(pane.additional_cursors), context.temp_allocator)
	for candidate in pane.additional_cursors {
		duplicate := candidate.offset == pane.cursor_offset
		if !duplicate {
			for already_kept in deduped {
				if already_kept.offset == candidate.offset {
					duplicate = true
					break
				}
			}
		}
		if !duplicate { append(&deduped, candidate) }
	}
	clear(&pane.additional_cursors)
	for kept in deduped { append(&pane.additional_cursors, kept) }
}

// Drop every additional cursor so only the primary remains. Used by
// Escape and by single-cursor navigation paths (LSP go-to,
// find/replace, F6 symbol jump, …) that don't want stale carets left
// behind.
@(private)
pane_collapse_to_primary :: proc(pane: ^EditorPane) {
	if len(pane.additional_cursors) > 0 {
		clear(&pane.additional_cursors)
	}
}

// True when the pane has more than one cursor active right now.
@(private)
pane_has_multiple_cursors :: proc(pane: ^EditorPane) -> bool {
	return len(pane.additional_cursors) > 0
}

// --- Per-cursor edit replay ---------------------------------------------
//
// Every per-cursor edit boils down to "delete a (possibly empty) range,
// then insert some (possibly empty) text" at that cursor's pre-edit
// offset. We collect one plan per cursor, sort descending by offset,
// then apply them in that order so no plan's offsets are invalidated
// by a sibling edit at a lower offset. After applying we recompute
// each cursor's final offset by walking the cumulative shift from all
// strictly-lower-offset edits.

@(private)
EditPlan :: struct {
	delete_at:    u32,
	delete_len:   u32,
	insert_text:  string, // borrowed for the lifetime of the apply call
	cursor_index: int,    // back-reference into the gathered cursor slice
}

// Build a plan from a cursor for the "insert text (replacing selection)"
// case. If `text_to_insert` is empty this models a pure delete-selection.
@(private)
plan_replace_selection_with_text :: proc(cursor: Cursor, text_to_insert: string, cursor_index: int) -> EditPlan {
	delete_at := cursor.offset
	delete_len: u32 = 0
	if cursor.selection_active {
		low_offset  := min(cursor.offset, cursor.selection_anchor)
		high_offset := max(cursor.offset, cursor.selection_anchor)
		delete_at  = low_offset
		delete_len = high_offset - low_offset
	}
	return EditPlan{
		delete_at    = delete_at,
		delete_len   = delete_len,
		insert_text  = text_to_insert,
		cursor_index = cursor_index,
	}
}

// Apply a per-cursor set of edits and update each cursor's offset to
// land just after its inserted text (cumulative shifts included).
// Wraps the whole batch in one compound undo so Ctrl+Z reverts every
// caret's edit as one step.
@(private)
apply_edit_plans :: proc(editor: ^Editor, pane: ^EditorPane, cursors: []Cursor, plans: []EditPlan) {
	if len(plans) == 0 { return }

	// Sort plans in-place by delete_at descending so applying in this
	// order keeps lower offsets stable. We rely on cursor_index to
	// remember which gathered cursor each plan came from.
	slice.sort_by(plans, proc(left, right: EditPlan) -> bool { return left.delete_at > right.delete_at })

	snapshot_position := document.document_begin_compound(&pane.document)
	for plan in plans {
		if plan.delete_len > 0 {
			document.document_delete(&pane.document, plan.delete_at, plan.delete_len)
		}
		if len(plan.insert_text) > 0 {
			document.document_insert(&pane.document, plan.delete_at, plan.insert_text)
		}
	}
	document.document_end_compound(&pane.document, snapshot_position)

	// Recompute each cursor's final offset. The "self" plan moves the
	// cursor to (delete_at + insert_len); other plans at strictly-lower
	// offsets shift it by (their_insert_len - their_delete_len).
	for plan in plans {
		cumulative_shift: i64 = 0
		for other_plan in plans {
			if other_plan.cursor_index == plan.cursor_index { continue }
			if other_plan.delete_at < plan.delete_at {
				cumulative_shift += i64(len(other_plan.insert_text)) - i64(other_plan.delete_len)
			}
		}
		final_offset := i64(plan.delete_at) + i64(len(plan.insert_text)) + cumulative_shift
		if final_offset < 0 { final_offset = 0 }

		cursor_at_index := &cursors[plan.cursor_index]
		cursor_at_index.offset           = u32(final_offset)
		cursor_at_index.selection_active = false
		cursor_at_index.selection_anchor = 0
	}

	pane_scatter_cursors(pane, cursors)
	pane_resync_all_cursors(pane)
	pane_dedupe_cursors(pane)
	pane_mark_document_modified(editor, pane)
}

// Refresh every cursor's `line` / `column` from its `offset` after a
// document mutation. Walks both primary and additionals.
@(private)
pane_resync_all_cursors :: proc(pane: ^EditorPane) {
	pane.cursor_line   = document.document_offset_to_line(&pane.document, pane.cursor_offset)
	primary_line_start := document.document_line_start(&pane.document, pane.cursor_line)
	pane.cursor_column = pane.cursor_offset - primary_line_start
	for &additional_cursor in pane.additional_cursors {
		additional_cursor.line   = document.document_offset_to_line(&pane.document, additional_cursor.offset)
		additional_line_start   := document.document_line_start(&pane.document, additional_cursor.line)
		additional_cursor.column = additional_cursor.offset - additional_line_start
	}
}

// --- Common operations driven through the replay primitive -------------

// Replace every cursor's selection (or insert at every caret) with
// `text_to_insert`. This is the multi-cursor-aware replacement for
// `editor_insert_text` — when only the primary cursor is present it
// behaves identically.
@(private)
multi_insert_text :: proc(editor: ^Editor, text_to_insert: string) {
	pane := editor_active_editor_pane(editor); if pane == nil { return }
	cursors := pane_gather_cursors(pane)
	plans := make([dynamic]EditPlan, 0, len(cursors), context.temp_allocator)
	for cursor_value, cursor_index in cursors {
		append(&plans, plan_replace_selection_with_text(cursor_value, text_to_insert, cursor_index))
	}
	apply_edit_plans(editor, pane, cursors[:], plans[:])
	ensure_cursor_visible(editor)
}

// Backspace at every cursor: deletes the current selection if any,
// otherwise the previous character.
@(private)
multi_backspace :: proc(editor: ^Editor) {
	pane := editor_active_editor_pane(editor); if pane == nil { return }
	cursors := pane_gather_cursors(pane)
	plans := make([dynamic]EditPlan, 0, len(cursors), context.temp_allocator)
	for cursor_value, cursor_index in cursors {
		if cursor_value.selection_active && cursor_value.offset != cursor_value.selection_anchor {
			append(&plans, plan_replace_selection_with_text(cursor_value, "", cursor_index))
			continue
		}
		if cursor_value.offset == 0 { continue }
		previous_char_length := cursor_prev_char_len(pane, cursor_value.offset)
		append(&plans, EditPlan{
			delete_at    = cursor_value.offset - previous_char_length,
			delete_len   = previous_char_length,
			insert_text  = "",
			cursor_index = cursor_index,
		})
	}
	apply_edit_plans(editor, pane, cursors[:], plans[:])
	ensure_cursor_visible(editor)
}

// Forward-delete at every cursor: deletes the current selection if any,
// otherwise the character to the right of the caret.
@(private)
multi_delete_forward :: proc(editor: ^Editor) {
	pane := editor_active_editor_pane(editor); if pane == nil { return }
	document_length := document.document_length(&pane.document)
	cursors := pane_gather_cursors(pane)
	plans := make([dynamic]EditPlan, 0, len(cursors), context.temp_allocator)
	for cursor_value, cursor_index in cursors {
		if cursor_value.selection_active && cursor_value.offset != cursor_value.selection_anchor {
			append(&plans, plan_replace_selection_with_text(cursor_value, "", cursor_index))
			continue
		}
		if cursor_value.offset >= document_length { continue }
		next_char_length := cursor_next_char_len(pane, cursor_value.offset)
		append(&plans, EditPlan{
			delete_at    = cursor_value.offset,
			delete_len   = next_char_length,
			insert_text  = "",
			cursor_index = cursor_index,
		})
	}
	apply_edit_plans(editor, pane, cursors[:], plans[:])
	ensure_cursor_visible(editor)
}

// --- Indent / outdent on the line(s) covered by every cursor ----------

// Indent every line covered by every cursor's selection by
// `TAB_WIDTH` spaces. With no selection on any cursor, falls through
// to plain "insert 4 spaces at every caret" — the conventional
// Tab-as-typing behavior.
@(private)
multi_indent_selection :: proc(editor: ^Editor) {
	pane := editor_active_editor_pane(editor); if pane == nil { return }
	cursors := pane_gather_cursors(pane)

	any_selection := false
	for cursor_value in cursors {
		if cursor_value.selection_active && cursor_value.offset != cursor_value.selection_anchor {
			any_selection = true
			break
		}
	}
	if !any_selection {
		multi_insert_text(editor, "    ")
		return
	}

	lines_to_indent := make(map[u32]bool, allocator = context.temp_allocator)
	for cursor_value in cursors {
		low_line, high_line := cursor_line_span(pane, cursor_value)
		for line in low_line..=high_line { lines_to_indent[line] = true }
	}

	indent_text := "    "
	plans := make([dynamic]EditPlan, 0, len(lines_to_indent), context.temp_allocator)
	for line in lines_to_indent {
		line_start_offset := document.document_line_start(&pane.document, line)
		append(&plans, EditPlan{
			delete_at    = line_start_offset,
			delete_len   = 0,
			insert_text  = indent_text,
			cursor_index = -1,
		})
	}

	apply_edit_plans_with_passive_cursors(editor, pane, cursors[:], plans[:])
	ensure_cursor_visible(editor)
}

// Span of lines a cursor "covers" for line-level operations. With no
// selection that's just the caret's line; with a selection that's
// [low_line, high_line], excluding the trailing line when the
// selection ends at a line boundary (VSCode/Sublime convention).
@(private)
cursor_line_span :: proc(pane: ^EditorPane, cursor: Cursor) -> (low_line, high_line: u32) {
	if !cursor.selection_active || cursor.offset == cursor.selection_anchor {
		return cursor.line, cursor.line
	}
	low_offset  := min(cursor.offset, cursor.selection_anchor)
	high_offset := max(cursor.offset, cursor.selection_anchor)
	low_line  = document.document_offset_to_line(&pane.document, low_offset)
	high_line = document.document_offset_to_line(&pane.document, high_offset)
	if high_line > low_line {
		high_line_start := document.document_line_start(&pane.document, high_line)
		if high_offset == high_line_start { high_line -= 1 }
	}
	return
}

// Outdent every line covered by every cursor by up to `TAB_WIDTH` spaces
// (or one leading tab). Cursors without a multi-line selection still
// outdent their own line — matching the Shift+Tab convention.
@(private)
multi_outdent_selection :: proc(editor: ^Editor) {
	pane := editor_active_editor_pane(editor); if pane == nil { return }
	cursors := pane_gather_cursors(pane)

	lines_to_outdent := make(map[u32]bool, allocator = context.temp_allocator)
	for cursor_value in cursors {
		low_line, high_line := cursor_line_span(pane, cursor_value)
		for line in low_line..=high_line { lines_to_outdent[line] = true }
	}

	plans := make([dynamic]EditPlan, 0, len(lines_to_outdent), context.temp_allocator)
	for line in lines_to_outdent {
		line_start_offset := document.document_line_start(&pane.document, line)
		line_text         := document.document_get_line(&pane.document, line, context.temp_allocator)
		if len(line_text) == 0 { continue }
		bytes_to_remove: u32 = 0
		switch line_text[0] {
		case '\t':
			bytes_to_remove = 1
		case ' ':
			for int(bytes_to_remove) < len(line_text) && bytes_to_remove < u32(TAB_WIDTH) && line_text[bytes_to_remove] == ' ' {
				bytes_to_remove += 1
			}
		}
		if bytes_to_remove == 0 { continue }
		append(&plans, EditPlan{
			delete_at    = line_start_offset,
			delete_len   = bytes_to_remove,
			insert_text  = "",
			cursor_index = -1,
		})
	}

	apply_edit_plans_with_passive_cursors(editor, pane, cursors[:], plans[:])
	ensure_cursor_visible(editor)
}

// Variant of apply_edit_plans for line-level operations whose plans
// don't correspond 1:1 with cursors. Each plan still mutates the
// document; cursor offsets are recomputed purely from cumulative
// shifts (no "self" plan moves the cursor to a new offset). Selection
// anchors are shifted alongside cursor offsets so a selected range
// stays anchored to the same text after the indent.
@(private)
apply_edit_plans_with_passive_cursors :: proc(editor: ^Editor, pane: ^EditorPane, cursors: []Cursor, plans: []EditPlan) {
	if len(plans) == 0 { return }

	slice.sort_by(plans, proc(left, right: EditPlan) -> bool { return left.delete_at > right.delete_at })

	snapshot_position := document.document_begin_compound(&pane.document)
	for plan in plans {
		if plan.delete_len > 0 {
			document.document_delete(&pane.document, plan.delete_at, plan.delete_len)
		}
		if len(plan.insert_text) > 0 {
			document.document_insert(&pane.document, plan.delete_at, plan.insert_text)
		}
	}
	document.document_end_compound(&pane.document, snapshot_position)

	shift_offset :: proc(offset: u32, plans: []EditPlan) -> u32 {
		// Net delta of all plans whose delete_at is strictly less than
		// `offset`. An insert at exactly `offset` doesn't push the
		// cursor forward — that's how indent leaves a caret-at-line-
		// start where it was relative to the leading whitespace.
		cumulative_shift: i64 = 0
		for plan in plans {
			if plan.delete_at < offset {
				// The deletion bites into `offset` only if it overlaps;
				// for line-indent plans the deletion is always
				// contained in leading whitespace so this clamp is the
				// safe-conservative shape.
				effective_delete_end := plan.delete_at + plan.delete_len
				if effective_delete_end > offset { effective_delete_end = offset }
				cumulative_shift -= i64(effective_delete_end - plan.delete_at)
				cumulative_shift += i64(len(plan.insert_text))
			}
		}
		shifted := i64(offset) + cumulative_shift
		if shifted < 0 { shifted = 0 }
		return u32(shifted)
	}

	for cursor_index in 0..<len(cursors) {
		cursor_at_index := &cursors[cursor_index]
		cursor_at_index.offset = shift_offset(cursor_at_index.offset, plans)
		if cursor_at_index.selection_active {
			cursor_at_index.selection_anchor = shift_offset(cursor_at_index.selection_anchor, plans)
		}
	}

	pane_scatter_cursors(pane, cursors)
	pane_resync_all_cursors(pane)
	pane_dedupe_cursors(pane)
	pane_mark_document_modified(editor, pane)
}

// --- Per-cursor char-length helpers ------------------------------------
//
// Mirrors `prev_char_len` / `next_char_len` in cursor.odin but takes a
// concrete offset instead of reading the pane's primary cursor.

@(private)
cursor_prev_char_len :: proc(pane: ^EditorPane, cursor_offset: u32) -> u32 {
	if cursor_offset == 0 { return 0 }
	look_back_bytes := min(cursor_offset, 4)
	look_back_slice := document.document_get_slice(&pane.document, cursor_offset - look_back_bytes, look_back_bytes)
	if len(look_back_slice) == 0 { return 1 }
	last_byte_index := len(look_back_slice) - 1
	for last_byte_index > 0 && (look_back_slice[last_byte_index] & 0xC0) == 0x80 {
		last_byte_index -= 1
	}
	return u32(len(look_back_slice) - last_byte_index)
}

@(private)
cursor_next_char_len :: proc(pane: ^EditorPane, cursor_offset: u32) -> u32 {
	document_length := document.document_length(&pane.document)
	if cursor_offset >= document_length { return 0 }
	look_ahead_bytes := min(document_length - cursor_offset, 4)
	look_ahead_slice := document.document_get_slice(&pane.document, cursor_offset, look_ahead_bytes)
	if len(look_ahead_slice) == 0 { return 1 }
	first_byte := look_ahead_slice[0]
	switch {
	case first_byte < 0x80: return 1
	case first_byte < 0xE0: return 2
	case first_byte < 0xF0: return 3
	}
	return 4
}

// --- Per-cursor motion --------------------------------------------------

@(private)
move_all_cursors_horizontal :: proc(editor: ^Editor, direction: i32, shift_held: bool) {
	pane := editor_active_editor_pane(editor); if pane == nil { return }
	document_length := document.document_length(&pane.document)

	apply_to_cursor :: proc(cursor: ^Cursor, pane: ^EditorPane, document_length: u32, direction: i32, shift_held: bool) {
		// Plain horizontal motion with a live selection collapses to the
		// boundary on that side rather than nudging by one byte.
		if !shift_held && cursor.selection_active {
			low_offset  := min(cursor.offset, cursor.selection_anchor)
			high_offset := max(cursor.offset, cursor.selection_anchor)
			cursor.selection_active = false
			cursor.offset = direction < 0 ? low_offset : high_offset
			return
		}
		if shift_held && !cursor.selection_active {
			cursor.selection_anchor = cursor.offset
			cursor.selection_active = true
		}
		if !shift_held { cursor.selection_active = false }
		if direction < 0 {
			if cursor.offset > 0 { cursor.offset -= cursor_prev_char_len(pane, cursor.offset) }
		} else {
			if cursor.offset < document_length { cursor.offset += cursor_next_char_len(pane, cursor.offset) }
		}
	}

	primary_cursor := Cursor{
		offset           = pane.cursor_offset,
		line             = pane.cursor_line,
		column           = pane.cursor_column,
		selection_active = pane.selection_active,
		selection_anchor = pane.selection_anchor,
	}
	apply_to_cursor(&primary_cursor, pane, document_length, direction, shift_held)
	pane.cursor_offset    = primary_cursor.offset
	pane.selection_active = primary_cursor.selection_active
	pane.selection_anchor = primary_cursor.selection_anchor

	for &additional_cursor in pane.additional_cursors {
		apply_to_cursor(&additional_cursor, pane, document_length, direction, shift_held)
	}

	pane_resync_all_cursors(pane)
	pane_dedupe_cursors(pane)
	ensure_cursor_visible(editor)
}

@(private)
move_all_cursors_vertical :: proc(editor: ^Editor, line_delta: i32, shift_held: bool) {
	pane := editor_active_editor_pane(editor); if pane == nil { return }
	total_line_count := i32(document.document_line_count(&pane.document))

	apply_to_cursor :: proc(cursor: ^Cursor, pane: ^EditorPane, total_line_count: i32, line_delta: i32, shift_held: bool) {
		if shift_held && !cursor.selection_active {
			cursor.selection_anchor = cursor.offset
			cursor.selection_active = true
		}
		if !shift_held { cursor.selection_active = false }
		new_line_signed := i32(cursor.line) + line_delta
		new_line_signed = clamp(new_line_signed, 0, total_line_count - 1)
		target_line := u32(new_line_signed)
		line_start_offset := document.document_line_start(&pane.document, target_line)
		target_line_text  := document.document_get_line(&pane.document, target_line, context.temp_allocator)
		clamped_column := min(cursor.column, u32(len(target_line_text)))
		cursor.line   = target_line
		cursor.offset = line_start_offset + clamped_column
		// `column` itself is preserved across vertical motion so a long
		// run of Up/Down through short lines snaps back to the original
		// column on the first long line again.
	}

	primary_cursor := Cursor{
		offset           = pane.cursor_offset,
		line             = pane.cursor_line,
		column           = pane.cursor_column,
		selection_active = pane.selection_active,
		selection_anchor = pane.selection_anchor,
	}
	apply_to_cursor(&primary_cursor, pane, total_line_count, line_delta, shift_held)
	pane.cursor_offset    = primary_cursor.offset
	pane.cursor_line      = primary_cursor.line
	pane.selection_active = primary_cursor.selection_active
	pane.selection_anchor = primary_cursor.selection_anchor

	for &additional_cursor in pane.additional_cursors {
		apply_to_cursor(&additional_cursor, pane, total_line_count, line_delta, shift_held)
	}

	pane_dedupe_cursors(pane)
	ensure_cursor_visible(editor)
}

// --- Add / collapse cursors --------------------------------------------

@(private)
editor_add_cursor_above :: proc(editor: ^Editor) {
	editor_add_cursor_on_adjacent_line(editor, -1)
}

@(private)
editor_add_cursor_below :: proc(editor: ^Editor) {
	editor_add_cursor_on_adjacent_line(editor, +1)
}

@(private)
editor_add_cursor_on_adjacent_line :: proc(editor: ^Editor, line_delta: i32) {
	pane := editor_active_editor_pane(editor); if pane == nil { return }

	// Anchor the column we're stacking on. With existing additional
	// cursors we extend from the one furthest in the direction of motion
	// — so a chain of Ctrl+Shift+Down clicks keeps growing downward
	// instead of toggling around the primary.
	anchor_line   := pane.cursor_line
	anchor_column := pane.cursor_column
	for additional_cursor in pane.additional_cursors {
		if line_delta < 0 && additional_cursor.line < anchor_line {
			anchor_line = additional_cursor.line
			anchor_column = additional_cursor.column
		} else if line_delta > 0 && additional_cursor.line > anchor_line {
			anchor_line = additional_cursor.line
			anchor_column = additional_cursor.column
		}
	}

	total_line_count := i32(document.document_line_count(&pane.document))
	new_line_signed  := i32(anchor_line) + line_delta
	if new_line_signed < 0 || new_line_signed >= total_line_count { return }
	new_line := u32(new_line_signed)

	line_start_offset := document.document_line_start(&pane.document, new_line)
	line_text         := document.document_get_line(&pane.document, new_line, context.temp_allocator)
	clamped_column    := min(anchor_column, u32(len(line_text)))

	new_cursor := Cursor{
		offset           = line_start_offset + clamped_column,
		line             = new_line,
		column           = anchor_column, // preserve preferred column
		selection_active = false,
	}

	// If the new cursor would land exactly on the primary, skip — Escape
	// is the way to collapse, not Ctrl+Shift+motion.
	if new_cursor.offset == pane.cursor_offset { return }
	for additional_cursor in pane.additional_cursors {
		if additional_cursor.offset == new_cursor.offset { return }
	}
	append(&pane.additional_cursors, new_cursor)
	ensure_cursor_visible(editor)
}

// Add a cursor at the next document occurrence of the primary cursor's
// selected text. The new cursor's selection covers that next match so a
// subsequent edit replaces every match together. With no current
// selection the primary cursor's word under the caret is selected first
// (Sublime/VSCode behavior).
@(private)
editor_add_cursor_at_next_match :: proc(editor: ^Editor) {
	pane := editor_active_editor_pane(editor); if pane == nil { return }

	if !pane.selection_active || pane.cursor_offset == pane.selection_anchor {
		// No selection yet — promote the word under the primary caret to
		// a selection. The next Ctrl+D press will then find the next
		// occurrence.
		line_text     := document.document_get_line(&pane.document, pane.cursor_line, context.temp_allocator)
		cursor_column := int(pane.cursor_column)
		word_start := cursor_column
		word_end   := cursor_column
		for word_start > 0           && is_word_byte(line_text[word_start - 1]) { word_start -= 1 }
		for word_end   < len(line_text) && is_word_byte(line_text[word_end])    { word_end   += 1 }
		if word_end <= word_start { return }
		line_start_offset := document.document_line_start(&pane.document, pane.cursor_line)
		pane.selection_anchor = line_start_offset + u32(word_start)
		pane.cursor_offset    = line_start_offset + u32(word_end)
		pane.selection_active = true
		pane_resync_all_cursors(pane)
		ensure_cursor_visible(editor)
		return
	}

	primary_low  := min(pane.cursor_offset, pane.selection_anchor)
	primary_high := max(pane.cursor_offset, pane.selection_anchor)
	needle       := document.document_get_slice(&pane.document, primary_low, primary_high - primary_low, context.temp_allocator)
	if len(needle) == 0 { return }

	// Search from after the furthest existing cursor's selection. That
	// way repeated Ctrl+D picks up the next-next-next match instead of
	// re-finding ones we already grabbed.
	search_start := primary_high
	for additional_cursor in pane.additional_cursors {
		if !additional_cursor.selection_active { continue }
		additional_high := max(additional_cursor.offset, additional_cursor.selection_anchor)
		if additional_high > search_start { search_start = additional_high }
	}

	document_length := document.document_length(&pane.document)
	match_offset, found_after := find_substring_in_document(pane, needle, search_start, document_length)
	if !found_after {
		// Wrap to the top so a long file with the needle only above the
		// caret still grows the selection set.
		match_offset, found_after = find_substring_in_document(pane, needle, 0, primary_low)
	}
	if !found_after { return }

	// Don't re-add a cursor that overlaps an existing one.
	for additional_cursor in pane.additional_cursors {
		if additional_cursor.offset == match_offset + u32(len(needle)) { return }
	}

	new_cursor_offset := match_offset + u32(len(needle))
	new_line          := document.document_offset_to_line(&pane.document, new_cursor_offset)
	new_line_start    := document.document_line_start(&pane.document, new_line)
	append(&pane.additional_cursors, Cursor{
		offset           = new_cursor_offset,
		line             = new_line,
		column           = new_cursor_offset - new_line_start,
		selection_active = true,
		selection_anchor = match_offset,
	})
	ensure_cursor_visible(editor)
}

// Substring search over the piece-tree, returning the first occurrence
// in [start, end). Slow path — we read up to one chunk at a time and do
// a naive scan. Good enough for Ctrl+D on selections that are usually
// shorter than a line.
@(private)
find_substring_in_document :: proc(pane: ^EditorPane, needle: string, search_start, search_end: u32) -> (match_offset: u32, found: bool) {
	if len(needle) == 0 || search_end <= search_start { return 0, false }
	region_length := search_end - search_start
	if u32(len(needle)) > region_length { return 0, false }
	haystack := document.document_get_slice(&pane.document, search_start, region_length, context.temp_allocator)
	for scan_index in 0..=len(haystack) - len(needle) {
		matches := true
		for needle_index in 0..<len(needle) {
			if haystack[scan_index + needle_index] != needle[needle_index] {
				matches = false
				break
			}
		}
		if matches { return search_start + u32(scan_index), true }
	}
	return 0, false
}

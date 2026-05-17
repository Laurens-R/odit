package editor

import "../document"

@(private)
selection_range :: proc(ed: ^Editor) -> (lo: u32, hi: u32, has: bool) {
	if !ed.sel_active { return 0, 0, false }
	lo = min(ed.sel_anchor, ed.cursor_offset)
	hi = max(ed.sel_anchor, ed.cursor_offset)
	has = lo != hi
	return
}

// Delete the active selection (if any) and place cursor at its start.
// Returns true if a non-empty selection was deleted.
@(private)
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
@(private)
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
@(private)
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

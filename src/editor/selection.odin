package editor

import "../document"

@(private)
selection_range :: proc(ed: ^Editor) -> (lo: u32, hi: u32, has: bool) {
	v := editor_active_editor_pane(ed); if v == nil { return }
	if !v.sel_active { return 0, 0, false }
	lo = min(v.sel_anchor, v.cursor_offset)
	hi = max(v.sel_anchor, v.cursor_offset)
	has = lo != hi
	return
}

@(private)
editor_pane_selection_range :: proc(ep: ^EditorPane) -> (lo: u32, hi: u32, has: bool) {
	if !ep.sel_active { return 0, 0, false }
	lo = min(ep.sel_anchor, ep.cursor_offset)
	hi = max(ep.sel_anchor, ep.cursor_offset)
	has = lo != hi
	return
}

@(private)
delete_selection :: proc(ed: ^Editor) -> bool {
	v := editor_active_editor_pane(ed); if v == nil { return false }
	lo, hi, has := selection_range(ed)
	v.sel_active = false
	if !has { return false }
	document.document_delete(&v.doc, lo, hi - lo)
	v.cursor_offset = lo
	sync_cursor_from_offset(ed)
	return true
}

@(private)
collapse_selection :: proc(ed: ^Editor, to_end: bool) -> bool {
	v := editor_active_editor_pane(ed); if v == nil { return false }
	lo, hi, has := selection_range(ed)
	v.sel_active = false
	if !has { return false }
	v.cursor_offset = to_end ? hi : lo
	sync_cursor_from_offset(ed)
	return true
}

@(private)
update_selection_for_nav :: proc(ed: ^Editor, shift: bool) {
	v := editor_active_editor_pane(ed); if v == nil { return }
	if shift {
		if !v.sel_active {
			v.sel_anchor = v.cursor_offset
			v.sel_active = true
		}
	} else {
		v.sel_active = false
	}
}

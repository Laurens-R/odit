package editor

import "../document"

@(private)
selection_range :: proc(editor: ^Editor) -> (low_offset: u32, high_offset: u32, has_selection: bool) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	if !editor_pane.selection_active { return 0, 0, false }
	low_offset  = min(editor_pane.selection_anchor, editor_pane.cursor_offset)
	high_offset = max(editor_pane.selection_anchor, editor_pane.cursor_offset)
	has_selection = low_offset != high_offset
	return
}

@(private)
editor_pane_selection_range :: proc(editor_pane: ^EditorPane) -> (low_offset: u32, high_offset: u32, has_selection: bool) {
	if !editor_pane.selection_active { return 0, 0, false }
	low_offset  = min(editor_pane.selection_anchor, editor_pane.cursor_offset)
	high_offset = max(editor_pane.selection_anchor, editor_pane.cursor_offset)
	has_selection = low_offset != high_offset
	return
}

@(private)
delete_selection :: proc(editor: ^Editor) -> bool {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return false }
	low_offset, high_offset, has_selection := selection_range(editor)
	editor_pane.selection_active = false
	if !has_selection { return false }
	document.document_delete(&editor_pane.document, low_offset, high_offset - low_offset)
	pane_mark_document_modified(editor_pane)
	editor_pane.cursor_offset = low_offset
	sync_cursor_from_offset(editor)
	return true
}

@(private)
collapse_selection :: proc(editor: ^Editor, collapse_to_end: bool) -> bool {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return false }
	low_offset, high_offset, has_selection := selection_range(editor)
	editor_pane.selection_active = false
	if !has_selection { return false }
	editor_pane.cursor_offset = collapse_to_end ? high_offset : low_offset
	sync_cursor_from_offset(editor)
	return true
}

@(private)
update_selection_for_nav :: proc(editor: ^Editor, shift_held: bool) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	if shift_held {
		if !editor_pane.selection_active {
			editor_pane.selection_anchor = editor_pane.cursor_offset
			editor_pane.selection_active = true
		}
	} else {
		editor_pane.selection_active = false
	}
}

package editor

import "../document"
import "../syntax"

// Generic pane management: destruction, accessors, focus / move,
// open-string entry points, background-document stash + dedupe.
// Per-pane-type code lives next door (`terminal.odin`,
// `markdown_preview.odin`, `output_pane.odin`, `pane_symbols.odin`).

// --- Destruction --------------------------------------------------------

@(private)
pane_destroy :: proc(pane: ^Pane) {
	pane_content_destroy(&pane.content)
	if pane.has_saved_content {
		pane_content_destroy(&pane.saved_content)
		pane.has_saved_content = false
	}
}

// Tear down a single PaneContent without touching the surrounding
// Pane. Factored so the terminal stash/restore dance can release
// whatever the pane's previous content held.
@(private)
pane_content_destroy :: proc(pane_content: ^PaneContent) {
	#partial switch &content_value in pane_content {
	case EditorPane:
		editor_pane_destroy_in_place(&content_value)
	case TerminalPane:
		// Terminal lifetimes are owned by `Editor.terminals`, not by
		// the pane — the pane just holds a borrowed pointer.
		// Clearing it here (instead of calling terminal_destroy) lets
		// the pane be replaced or torn down without killing a session
		// the user only meant to hide. `editor_destroy` is the one
		// place that actually destroys.
		content_value.terminal = nil
	case MarkdownPreviewPane:
		markdown_preview_pane_destroy(&content_value)
	case OutputPane:
		// Log buffer is owned by Editor.debug_output_lines, not the
		// pane — pane teardown just drops the scroll state struct.
		_ = content_value
	}
}

// Release every owned resource on an EditorPane in place. Shared by
// `pane_content_destroy` (for live panes) and `editor_destroy` (for
// EditorPanes parked in `background_documents`).
@(private)
editor_pane_destroy_in_place :: proc(editor_pane: ^EditorPane) {
	document.document_destroy(&editor_pane.document)
	if len(editor_pane.file_path) > 0 {
		delete(editor_pane.file_path)
		editor_pane.file_path = ""
	}
	if len(editor_pane.display_title_override) > 0 {
		delete(editor_pane.display_title_override)
		editor_pane.display_title_override = ""
	}
	for symbol in editor_pane.symbols { delete(symbol.name) }
	delete(editor_pane.symbols)
	delete(editor_pane.symbol_names)
	delete(editor_pane.additional_cursors)
}

// --- Per-pane geometry helpers -----------------------------------------

// Height of the title strip at the top of every pane (filename area).
// Used by both render and mouse-coordinate translation.
@(private)
editor_title_bar_height :: proc(editor: ^Editor) -> i32 {
	return editor.line_height + 6
}

// Pixel height reserved for the find bar at the bottom of a pane
// when find mode is active on that pane. Returns 0 when find isn't
// active for this pane.
@(private)
editor_find_bar_height_for_pane :: proc(editor: ^Editor, pane_index: int) -> i32 {
	if !editor.find.active                       { return 0 }
	if editor.find.pane_index != pane_index      { return 0 }
	return editor.line_height + 10
}

// Total pixel height reserved at the bottom of a pane for any
// active overlay bar (find OR replace — only one can be active at
// a time). Used by the renderer to shrink the text-area height.
@(private)
editor_bottom_bar_height_for_pane :: proc(editor: ^Editor, pane_index: int) -> i32 {
	return editor_find_bar_height_for_pane(editor, pane_index) + replace_bar_height_for_pane(editor, pane_index)
}

// --- Accessors / focus / move ------------------------------------------

@(private)
editor_active_pane :: proc(editor: ^Editor) -> ^Pane {
	return &editor.panes[editor.active_pane_index]
}

// Single sink for "this pane's document just changed". Flips every
// dirty flag that gates an idle/debounced rebuild so future flags
// (next time we add another debounced consumer) get picked up by
// every existing mutation site for free. Stamps `editor.clock` on
// the LSP edit timer so the didChange debounce in
// `editor_lsp_update` measures from the latest edit.
@(private)
pane_mark_document_modified :: proc(editor: ^Editor, editor_pane: ^EditorPane) {
	editor_pane.symbols_dirty       = true
	editor_pane.markdown_dirty      = true
	editor_pane.lsp_dirty           = true
	editor_pane.lsp_last_edit_time  = editor.clock
}

// Returns the active pane's `EditorPane`, or nil if the active pane
// is not an editor pane. Most cursor/selection/clipboard procs
// short-circuit on nil so they're safe to call regardless of what
// kind of pane is currently focused.
@(private)
editor_active_editor_pane :: proc(editor: ^Editor) -> ^EditorPane {
	return pane_as_editor(&editor.panes[editor.active_pane_index])
}

@(private)
pane_as_editor :: proc(pane: ^Pane) -> ^EditorPane {
	editor_pane_value, is_editor_pane := &pane.content.(EditorPane)
	return editor_pane_value if is_editor_pane else nil
}

// Returns 2 when a split is showing both panes; 1 otherwise.
@(private)
editor_visible_pane_count :: proc(editor: ^Editor) -> int {
	return 2 if editor.split_active else 1
}

// Hit-test: which pane is the given pixel position over? Returns
// -1 if none.
@(private)
editor_pane_at :: proc(editor: ^Editor, pixel_x, pixel_y: f32) -> int {
	for pane_index in 0..<editor_visible_pane_count(editor) {
		pane_rectangle := editor.panes[pane_index].rectangle
		if pixel_x >= f32(pane_rectangle.x) && pixel_x < f32(pane_rectangle.x + pane_rectangle.w) &&
		   pixel_y >= f32(pane_rectangle.y) && pixel_y < f32(pane_rectangle.y + pane_rectangle.h) {
			return pane_index
		}
	}
	return -1
}

// Toggle focus to the other pane (no-op when no split is active).
@(private)
editor_focus_other_pane :: proc(editor: ^Editor) {
	if !editor.split_active { return }
	editor.active_pane_index = 1 - editor.active_pane_index
	editor.cursor_visible = true
	editor.cursor_timer = 0
}

// Move focus to a specific pane by index. When the user asks for
// pane[1] but split isn't currently active, we open the split —
// the right pane is always populated (editor_init seeds it with an
// empty editor), so revealing it is enough; no new content gets
// created.
@(private)
editor_focus_pane :: proc(editor: ^Editor, target_pane_index: int) {
	if target_pane_index < 0 || target_pane_index >= len(editor.panes) { return }
	if target_pane_index == 1 && !editor.split_active {
		editor.split_active = true
	}
	if editor.active_pane_index == target_pane_index { return }
	editor.active_pane_index = target_pane_index
	editor.cursor_visible = true
	editor.cursor_timer = 0
	editor_mark_dirty(editor)
}

// Move the active pane's content to `target_pane_index`. If both
// panes have content we swap (so neither doc gets lost); if the
// destination is the empty initial editor pane, the source's
// content effectively shifts over and the source is left with the
// destination's old empty slot. When targeting the right pane while
// split is inactive, the split opens — the right pane is then
// revealed with the moved content.
//
// Focus follows the moved content so the user can keep typing
// without an extra Ctrl+Tab.
@(private)
editor_move_active_to_pane :: proc(editor: ^Editor, target_pane_index: int) {
	if target_pane_index < 0 || target_pane_index >= len(editor.panes) { return }
	if editor.active_pane_index == target_pane_index { return }

	if target_pane_index == 1 && !editor.split_active {
		editor.split_active = true
	}

	source_index := editor.active_pane_index
	// Swap the two contents wholesale. PaneContent is a union —
	// both fields own their payload (EditorPane.document, etc.) so
	// the swap doesn't alias any state. Borrowed-pointer panes
	// (TerminalPane, OutputPane) just shuffle the pointer, fine.
	source_content      := editor.panes[source_index].content
	destination_content := editor.panes[target_pane_index].content
	editor.panes[source_index].content      = destination_content
	editor.panes[target_pane_index].content = source_content

	// Close any Find / Replace bars pinned to the panes whose
	// content just shifted out from under them — the bar's
	// `pane_index` would otherwise point at a doc that's now
	// somewhere else.
	if find_active(editor)    && (editor.find.pane_index    == source_index || editor.find.pane_index    == target_pane_index) { find_close(editor) }
	if replace_active(editor) && (editor.replace.pane_index == source_index || editor.replace.pane_index == target_pane_index) { replace_close(editor, false) }

	editor.active_pane_index = target_pane_index
	editor.cursor_visible = true
	editor.cursor_timer = 0
	editor_mark_dirty(editor)
}

// --- Public open-string entry points -----------------------------------

editor_open_string :: proc(editor: ^Editor, content_text: string) {
	editor_open_string_in_pane(editor, editor.active_pane_index, content_text)
}

// Load a string into a specific pane. If a `file_path` is supplied
// and the document is already open (in any pane or in
// `background_documents`), this switches to the existing copy
// rather than reloading — the user's cursor, scroll, undo history
// and unsaved edits are preserved. Otherwise the target pane's
// current EditorPane is moved into `background_documents` (if it's
// worth keeping — has a path, override, or unsaved changes) and a
// fresh editor pane is installed in its place.
editor_open_string_in_pane :: proc(editor: ^Editor, pane_index: int, content_text: string, file_path: string = "") {
	if pane_index < 0 || pane_index >= len(editor.panes) { return }

	// Dedupe: if this path is already loaded, switch to it instead
	// of doing a fresh load. Avoids two EditorPanes diverging from
	// the same on-disk file and discards the (already-read)
	// `content_text` argument — that read is the caller's choice,
	// not something we can undo here.
	if len(file_path) > 0 {
		existing_pane_index, existing_background_index := editor_find_open_document(editor, file_path)
		if existing_pane_index == pane_index { return }
		if existing_pane_index >= 0 {
			editor.active_pane_index = existing_pane_index
			return
		}
		if existing_background_index >= 0 {
			editor_swap_background_into_pane(editor, pane_index, existing_background_index)
			return
		}
	}

	// Stash whatever was in the target pane so it can be reached
	// again from the F4 picker. Untitled-and-clean panes are not
	// worth stashing and are just destroyed by `pane_destroy` below.
	pane_stash_editor(editor, pane_index)

	safe_content := content_text
	if len(safe_content) < 0 || len(safe_content) > EDITOR_MAX_DOCUMENT_BYTES {
		safe_content = ""
	}

	// Tear down whatever remains in the pane and install a fresh
	// editor.
	pane_destroy(&editor.panes[pane_index])

	new_editor_pane: EditorPane
	document.document_init(&new_editor_pane.document, safe_content)
	if len(file_path) > 0 {
		// Normalize the on-disk path so display / comparison stays
		// consistent regardless of whether the OS handed us back
		// slashes or our own code joined with forward slashes.
		new_editor_pane.file_path = path_normalize(file_path)
		new_editor_pane.language  = syntax.get_definition_for_path(file_path)
	}
	editor.panes[pane_index].content = new_editor_pane

	// Build the per-pane symbol index now that the doc + language
	// are wired up.
	if new_editor_pane.language != nil {
		if editor_pane := pane_as_editor(&editor.panes[pane_index]); editor_pane != nil {
			pane_rebuild_symbols(editor_pane)
		}
	}

	// Notify the LSP layer that a new document is open in this pane
	// (if its language has an LSP entry configured). Safe to call
	// when no LSP is available — the proc short-circuits.
	if editor_pane := pane_as_editor(&editor.panes[pane_index]); editor_pane != nil {
		editor_lsp_pane_opened(editor, editor_pane)
	}
}

// Drop a fresh untitled EditorPane into the given pane, destroying
// whatever was there. Use this on the Ctrl+F4 close path —
// `editor_open_string_in_pane` would stash the doc the user is
// asking to close, which is wrong.
@(private)
editor_replace_pane_with_empty_editor :: proc(editor: ^Editor, pane_index: int) {
	if pane_index < 0 || pane_index >= len(editor.panes) { return }
	if editor_pane := pane_as_editor(&editor.panes[pane_index]); editor_pane != nil {
		editor_lsp_pane_closing(editor, editor_pane)
	}
	pane_destroy(&editor.panes[pane_index])

	new_editor_pane: EditorPane
	document.document_init(&new_editor_pane.document, "")
	editor.panes[pane_index].content = new_editor_pane
}

// --- Background-document stash + dedupe --------------------------------

// Move the target pane's EditorPane into `background_documents` if
// it's worth keeping (has a path, has a display-title override, or
// is dirty). On success the pane is left with an empty
// `PaneContent{}` — the caller is expected to install new content
// right after. Returns true when a stash actually happened.
@(private)
pane_stash_editor :: proc(editor: ^Editor, pane_index: int) -> bool {
	if pane_index < 0 || pane_index >= len(editor.panes) { return false }
	pane := &editor.panes[pane_index]
	editor_pane_ptr, is_editor := &pane.content.(EditorPane)
	if !is_editor { return false }

	is_worth_keeping := len(editor_pane_ptr.file_path) > 0 ||
	                    len(editor_pane_ptr.display_title_override) > 0 ||
	                    document.document_is_dirty(&editor_pane_ptr.document)
	if !is_worth_keeping { return false }

	// Find/Replace bars are pinned to a specific pane index; the
	// doc we are moving away is the one the bar was bound to, so
	// close the bar before the pane content changes underneath it.
	if find_active(editor)    && editor.find.pane_index    == pane_index { find_close(editor) }
	if replace_active(editor) && editor.replace.pane_index == pane_index { replace_close(editor, false) }

	// Append a value-copy; ownership of the heap-allocated fields
	// transfers to the new slot. We then *both* zero out the
	// EditorPane fields in the union storage AND set the union to
	// its nil variant. The belt-and-suspenders matters: if a later
	// destroy path somehow still observes the union as an
	// EditorPane variant, every heap-pointer field is now nil/empty
	// so `editor_pane_destroy_in_place` short-circuits on each one
	// instead of double-freeing what we just transferred to the
	// background.
	append(&editor.background_documents, editor_pane_ptr^)
	editor_pane_ptr^ = EditorPane{}
	pane.content = PaneContent{}
	return true
}

// Pull a background document into the target pane, stashing the
// pane's current content (if worth keeping) on the way out. Used
// both by `editor_open_string_in_pane` when a requested path is
// found in the stash and by the F4 picker when the user clicks a
// row.
@(private)
editor_swap_background_into_pane :: proc(editor: ^Editor, pane_index, background_index: int) {
	if pane_index       < 0 || pane_index       >= len(editor.panes)               { return }
	if background_index < 0 || background_index >= len(editor.background_documents) { return }

	// Lift the target out of the list first. Subsequent mutations
	// to `background_documents` (the stash that follows) can then
	// freely append without shifting the index we already captured.
	restored_editor_pane := editor.background_documents[background_index]
	ordered_remove(&editor.background_documents, background_index)

	// Move the pane's existing editor into the background, OR — if
	// it isn't stash-worthy — destroy it directly. Either way the
	// pane is empty afterwards and ready to receive the restored
	// content.
	if !pane_stash_editor(editor, pane_index) {
		pane_destroy(&editor.panes[pane_index])
		editor.panes[pane_index].content = PaneContent{}
	}

	editor.panes[pane_index].content = restored_editor_pane
}

// Find an open EditorPane whose `file_path` matches
// (case-insensitively). Returns `(pane_index, -1)` when the doc is
// in a visible pane, `(-1, background_index)` when it's stashed,
// and `(-1, -1)` when not open.
@(private)
editor_find_open_document :: proc(editor: ^Editor, file_path: string) -> (pane_index: int, background_index: int) {
	pane_index, background_index = -1, -1
	if len(file_path) == 0 { return }

	for visible_pane_index in 0..<len(editor.panes) {
		visible_editor_pane := pane_as_editor(&editor.panes[visible_pane_index])
		if visible_editor_pane == nil                                                  { continue }
		if len(visible_editor_pane.file_path) == 0                                     { continue }
		if path_equals_ignore_case(visible_editor_pane.file_path, file_path) {
			pane_index = visible_pane_index
			return
		}
	}
	for background_editor_pane, idx in editor.background_documents {
		if len(background_editor_pane.file_path) == 0                                  { continue }
		if path_equals_ignore_case(background_editor_pane.file_path, file_path) {
			background_index = idx
			return
		}
	}
	return
}

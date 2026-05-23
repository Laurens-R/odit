package editor

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import close_confirm_pkg "./close_confirm"
import diff_pkg "./diff"
import "../document"
import save_as_pkg "./save_as"
import "../syntax"

// Editor-side glue for the Save-As / Close-Confirm dialog pair. State +
// render live in the `save_as` and `close_confirm` subpackages; this
// file owns the actual filesystem write, the pane retargeting after a
// successful Save-As, the chained "save then close" flow from the
// close-confirm dialog, and the multi-pane teardown that runs when a
// file actually closes.

// --- Save-As open / commit / error flow ----------------------------------

// Open the Save-As modal. Internal convenience so the close-confirm
// chain + hotkey handlers don't repeat the active-pane check and the
// host-pointer plumbing on every call.
@(private="file")
save_as_dialog_open :: proc(editor: ^Editor, close_after_save: bool) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	save_as_pkg.open_with_hooks(&editor.save_as_dialog, editor.save_as_hooks, editor.active_pane_index, close_after_save)
}

// --- Save-As host trampolines --------------------------------------------

// Pre-fill heuristic for the path input. If the doc already has a
// path we keep it (Save-As on an existing file is a "save a copy"
// gesture; user edits the filename). For untitled docs we synthesize
// <project-root|cwd>/untitled.txt.
@(private)
save_as_host_default_path :: proc(user_data: rawptr, pane_index: int, allocator: runtime.Allocator) -> string {
	editor := cast(^Editor)user_data
	if pane_index < 0 || pane_index >= len(editor.panes) { return "" }
	editor_pane := pane_as_editor(&editor.panes[pane_index]); if editor_pane == nil { return "" }

	if len(editor_pane.file_path) > 0 {
		return strings.clone(editor_pane.file_path, allocator)
	}
	parent_directory: string
	if len(editor.project_root) > 0 {
		parent_directory = editor.project_root
	} else {
		cwd, err := os.get_working_directory(context.temp_allocator)
		parent_directory = err == nil ? cwd : "."
	}
	joined := path_join({parent_directory, "untitled.txt"}, context.temp_allocator)
	return strings.clone(joined, allocator)
}

// Perform the file write and retarget the pane. Returns "" on success
// (dispatcher closes the popup, plus chains into
// `editor_close_active_pane_content` when `close_after_save` is set)
// or an error message that keeps the popup open with the message
// displayed.
@(private)
save_as_host_commit :: proc(user_data: rawptr, pane_index: int, path: string, close_after_save: bool) -> (error_message: string) {
	editor := cast(^Editor)user_data
	if pane_index < 0 || pane_index >= len(editor.panes) { return "" }
	editor_pane := pane_as_editor(&editor.panes[pane_index]); if editor_pane == nil { return "" }

	cleaned_path, _ := filepath.clean(path, context.temp_allocator)

	content_text := document.document_get_text(&editor_pane.document, context.temp_allocator)
	write_error  := os.write_entire_file(cleaned_path, transmute([]byte)content_text)
	if write_error != nil {
		return fmt.tprintf("Cannot write %s: %v", cleaned_path, write_error)
	}

	// Retarget the pane at the new on-disk path: free the prior owned
	// string, clone the new one, redetect the language for the new
	// extension, mark the doc clean, and rebuild the per-pane symbol
	// index.
	if len(editor_pane.file_path) > 0 { delete(editor_pane.file_path) }
	editor_pane.file_path = path_normalize(cleaned_path)
	editor_pane.language  = syntax.get_definition_for_path(cleaned_path)
	document.document_mark_saved(&editor_pane.document)
	pane_rebuild_symbols(editor_pane)
	editor_pane.symbols_dirty      = false
	editor_pane.last_analysis_time = editor.clock

	if close_after_save { editor_close_active_pane_content(editor) }
	return ""
}

// --- Close-confirm host trampolines --------------------------------------

@(private)
close_confirm_host_subject_name :: proc(user_data: rawptr, pane_index: int) -> string {
	editor := cast(^Editor)user_data
	if pane_index < 0 || pane_index >= len(editor.panes) { return "this file" }
	editor_pane := pane_as_editor(&editor.panes[pane_index])
	if editor_pane == nil { return "this file" }
	if len(editor_pane.file_path) > 0 { return filepath_base_for_close(editor_pane.file_path) }
	return "this untitled file"
}

@(private)
close_confirm_host_save_and_close :: proc(user_data: rawptr, pane_index: int) {
	editor := cast(^Editor)user_data
	close_confirm_save_and_close(editor, pane_index)
}

@(private)
close_confirm_host_discard_and_close :: proc(user_data: rawptr, pane_index: int) {
	editor := cast(^Editor)user_data
	close_confirm_discard_and_close(editor, pane_index)
}

// Yes branch: save then close. If the file has a known path we write
// to it directly and close immediately; otherwise we hand off to the
// Save-As modal with `close_after_save = true` so the close fires on a
// successful write.
@(private="file")
close_confirm_save_and_close :: proc(editor: ^Editor, pane_index: int) {
	if pane_index < 0 || pane_index >= len(editor.panes) { return }
	editor_pane := pane_as_editor(&editor.panes[pane_index]); if editor_pane == nil { return }

	if len(editor_pane.file_path) == 0 {
		save_as_dialog_open(editor, close_after_save = true)
		return
	}

	if save_pane_to_existing_path(editor, editor_pane) {
		editor_close_active_pane_content(editor)
	} else {
		// Direct save failed — fall back to Save-As so the user can
		// pick a different path and still complete the close they
		// asked for.
		save_as_dialog_open(editor, close_after_save = true)
		save_as_pkg.set_error(&editor.save_as_dialog, fmt.tprintf("Could not write %s — choose a different path", editor_pane.file_path))
	}
}

// No branch: discard pending edits and close.
@(private="file")
close_confirm_discard_and_close :: proc(editor: ^Editor, pane_index: int) {
	_ = pane_index // editor_close_active_pane_content uses active_pane_index
	editor_close_active_pane_content(editor)
}

// Local basename helper — render.odin's copy is `@(private="file")`, so
// it's not visible from here.
@(private="file")
filepath_base_for_close :: proc(file_path: string) -> string {
	if len(file_path) == 0 { return file_path }
	for character_index := len(file_path) - 1; character_index >= 0; character_index -= 1 {
		current_character := file_path[character_index]
		if current_character == '/' || current_character == '\\' { return file_path[character_index+1:] }
	}
	return file_path
}

// --- Public actions wired to the hotkeys --------------------------------

// Ctrl+S — direct save when the active pane already has a path,
// otherwise fall through to the Save-As modal. If the direct write
// fails we open Save-As so the user gets a usable retry surface (and
// sees the error).
@(private)
editor_save_active_file :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	if len(editor_pane.file_path) == 0 {
		save_as_dialog_open(editor, close_after_save = false)
		return
	}
	if !save_pane_to_existing_path(editor, editor_pane) {
		save_as_dialog_open(editor, close_after_save = false)
		save_as_pkg.set_error(&editor.save_as_dialog, fmt.tprintf("Could not write %s — choose a different path", editor_pane.file_path))
	}
}

// Ctrl+Shift+S — always pop the modal even when the file already has
// a path, so the user can save a copy under a new name.
@(private)
editor_save_as_active_file :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	save_as_dialog_open(editor, close_after_save = false)
}

// Ctrl+F4 — close the active file. Dirty docs route through the
// confirm dialog; clean docs close immediately.
@(private)
editor_close_active_file :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	if document.document_is_dirty(&editor_pane.document) {
		close_confirm_pkg.open(&editor.close_confirm_dialog, editor.active_pane_index)
		return
	}
	editor_close_active_pane_content(editor)
}

// Close the active pane's file. Behaviour depends on the surrounding
// panes:
//
//   * Single-pane mode (split off): replace the active pane's content
//     with a fresh untitled doc — there's nowhere else to fall back to.
//   * Split with both sides editors: collapse the split so the
//     surviving editor goes full-screen in pane[0] (the canonical home
//     for single-pane mode). The closed file's pane is torn down.
//   * Split with the other side a terminal (or anything non-editor):
//     keep the split, replace the active pane's content with untitled.
//     We don't drop the terminal out from under the user.
//
// Refuses to act when the active pane isn't an editor pane (Ctrl+F4
// over a terminal is a no-op).
@(private)
editor_close_active_pane_content :: proc(editor: ^Editor) {
	if editor.active_pane_index < 0 || editor.active_pane_index >= len(editor.panes) { return }
	active_pane := &editor.panes[editor.active_pane_index]
	if _, active_is_editor := active_pane.content.(EditorPane); !active_is_editor { return }

	// Find/Replace bars are pinned to a specific pane index. Closing
	// or moving panes around invalidates those associations; tearing
	// them down up-front avoids the renderer painting them in the
	// wrong place next frame.
	if find_active(editor) {
		find_close(editor)
	}
	if replace_active(editor) {
		replace_close(editor, false)
	}

	// Notify the LSP layer that the active document is going away.
	// Safe to call when the doc wasn't LSP-tracked — short-circuits
	// inside.
	if editor_pane := pane_as_editor(active_pane); editor_pane != nil {
		editor_lsp_pane_closing(editor, editor_pane)
	}

	// Easy case: no split. Just blank the file we were on. We DON'T
	// route through `editor_open_string_in_pane` here because that
	// would stash the doc into background_documents — but the user
	// explicitly asked to close it, not switch away from it.
	if !editor.split_active {
		editor_replace_pane_with_empty_editor(editor, editor.active_pane_index)
		return
	}

	other_pane_index := 1 - editor.active_pane_index
	other_pane := &editor.panes[other_pane_index]
	_, other_is_editor := other_pane.content.(EditorPane)

	if !other_is_editor {
		// The other side is a terminal (only other content kind
		// today). We don't want closing a file to also kill an
		// in-flight shell, so just blank the active pane and keep the
		// split going.
		editor_replace_pane_with_empty_editor(editor, editor.active_pane_index)
		return
	}

	// Both panes are editors — collapse. Diff mode is a two-pane-only
	// feature so it dies with the split.
	if editor.diff_state.active {
		diff_pkg.destroy(&editor.diff_state)
	}

	if editor.active_pane_index == 0 {
		// Closing pane[0]: free its content, then move pane[1] into
		// pane[0] via a shallow PaneContent copy. Zero out pane[1]
		// without destroying the union (the data is now owned by
		// pane[0]).
		pane_content_destroy(&editor.panes[0].content)
		editor.panes[0].content = editor.panes[1].content
		editor.panes[1].content = PaneContent{}
		if editor.panes[1].has_saved_content {
			pane_content_destroy(&editor.panes[1].saved_content)
			editor.panes[1].saved_content = PaneContent{}
			editor.panes[1].has_saved_content = false
		}
	} else {
		// Closing pane[1]: pane[0] is already in its single-pane
		// position; just destroy the pane we're closing.
		pane_destroy(&editor.panes[1])
	}

	editor.split_active      = false
	editor.active_pane_index = 0
}

// Write the pane's document to its known on-disk path. Returns false
// on any IO failure; callers that care about the error message should
// look at the dialog they then surface (Save-As, in practice).
@(private="file")
save_pane_to_existing_path :: proc(editor: ^Editor, editor_pane: ^EditorPane) -> bool {
	if len(editor_pane.file_path) == 0 { return false }
	content_text := document.document_get_text(&editor_pane.document, context.temp_allocator)
	write_error  := os.write_entire_file(editor_pane.file_path, transmute([]byte)content_text)
	if write_error != nil { return false }
	document.document_mark_saved(&editor_pane.document)
	return true
}

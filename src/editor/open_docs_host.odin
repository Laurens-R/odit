package editor

import "base:runtime"
import "core:fmt"
import "core:strings"

import "../document"
import open_docs_pkg "./open_docs"

// Host trampolines for the F4 open-documents picker. Enumerates the
// active pane, the other split pane, and every background-stashed
// editor pane; routes the user's pick into either a pane focus
// switch or a background-swap.

@(private)
open_docs_host_list_entries :: proc(user_data: rawptr, source_pane_index: int, allocator: runtime.Allocator) -> []open_docs_pkg.EntrySource {
	editor := cast(^Editor)user_data
	sources := make([dynamic]open_docs_pkg.EntrySource, 0, 16, allocator)

	// Source pane (active) first so the user's current doc is the top row.
	if source_pane_index >= 0 && source_pane_index < len(editor.panes) {
		if source_editor_pane := pane_as_editor(&editor.panes[source_pane_index]); source_editor_pane != nil {
			append(&sources, open_docs_pkg.EntrySource{
				location   = .ActivePane,
				pane_index = source_pane_index,
				is_dirty   = document.document_is_dirty(&source_editor_pane.document),
				label      = open_docs_format_label(source_editor_pane, source_pane_index, .ActivePane, allocator),
			})
		}
	}

	// Other-pane doc, if a split is active.
	if editor.split_active {
		for visible_pane_index in 0..<len(editor.panes) {
			if visible_pane_index == source_pane_index { continue }
			other_editor_pane := pane_as_editor(&editor.panes[visible_pane_index])
			if other_editor_pane == nil { continue }
			append(&sources, open_docs_pkg.EntrySource{
				location   = .OtherPane,
				pane_index = visible_pane_index,
				is_dirty   = document.document_is_dirty(&other_editor_pane.document),
				label      = open_docs_format_label(other_editor_pane, visible_pane_index, .OtherPane, allocator),
			})
		}
	}

	// Background documents — most-recently-stashed first.
	for reverse_index := len(editor.background_documents) - 1; reverse_index >= 0; reverse_index -= 1 {
		background_editor_pane := &editor.background_documents[reverse_index]
		append(&sources, open_docs_pkg.EntrySource{
			location         = .Background,
			background_index = reverse_index,
			is_dirty         = document.document_is_dirty(&background_editor_pane.document),
			label            = open_docs_format_label(background_editor_pane, -1, .Background, allocator),
		})
	}
	return sources[:]
}

@(private)
open_docs_host_activate :: proc(user_data: rawptr, source_pane_index: int, location: open_docs_pkg.EntryLocation, pane_index, background_index: int) {
	editor := cast(^Editor)user_data
	switch location {
	case .ActivePane:
		// Picking the currently-active doc — just close (handled by
		// the modal itself).

	case .OtherPane:
		if pane_index >= 0 && pane_index < len(editor.panes) {
			editor.active_pane_index = pane_index
		}

	case .Background:
		// Pull the stashed doc into the pane the dialog opened from.
		editor_swap_background_into_pane(editor, source_pane_index, background_index)
	}
	editor.cursor_visible = true
	editor.cursor_timer   = 0
}

@(private="file")
open_docs_format_label :: proc(editor_pane: ^EditorPane, pane_index: int, location: open_docs_pkg.EntryLocation, allocator := context.temp_allocator) -> string {
	dirty_marker := document.document_is_dirty(&editor_pane.document) ? "* " : "  "

	display_name: string
	full_path:    string
	switch {
	case len(editor_pane.display_title_override) > 0:
		display_name = editor_pane.display_title_override
	case len(editor_pane.file_path) > 0:
		display_name = open_docs_filepath_base(editor_pane.file_path)
		full_path    = editor_pane.file_path
	case:
		display_name = "untitled"
	}

	location_tag: string
	switch location {
	case .ActivePane: location_tag = "[active]"
	case .OtherPane:  location_tag = fmt.tprintf("[Pane %d]", pane_index + 1)
	case .Background: location_tag = ""
	}

	if len(full_path) > 0 && len(location_tag) > 0 {
		return strings.clone(fmt.tprintf("%s%s — %s    %s", dirty_marker, display_name, full_path, location_tag), allocator)
	}
	if len(full_path) > 0 {
		return strings.clone(fmt.tprintf("%s%s — %s", dirty_marker, display_name, full_path), allocator)
	}
	if len(location_tag) > 0 {
		return strings.clone(fmt.tprintf("%s%s    %s", dirty_marker, display_name, location_tag), allocator)
	}
	return strings.clone(fmt.tprintf("%s%s", dirty_marker, display_name), allocator)
}

@(private="file")
open_docs_filepath_base :: proc(file_path: string) -> string {
	if len(file_path) == 0 { return file_path }
	for character_index := len(file_path) - 1; character_index >= 0; character_index -= 1 {
		current_character := file_path[character_index]
		if current_character == '/' || current_character == '\\' { return file_path[character_index+1:] }
	}
	return file_path
}

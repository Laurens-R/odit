package editor

import "base:runtime"
import "core:fmt"
import "core:path/filepath"
import "core:strings"

import "../document"
import "../syntax"
import symbols_pkg "./symbols"

// Per-EditorPane symbol cache + F6 Symbols-dialog host trampolines.
// `pane_rebuild_symbols` lives here rather than in the symbols
// subpackage because `EditorPane.symbol_names` is also consumed by
// the per-line syntax tokenizer.

// Walk every line of the pane's doc through the language's symbol
// patterns and rebuild `symbols` + `symbol_names`. Called on file
// load, when symbols_dialog opens (so the dialog sees fresh data),
// and on the background reanalyze tick.
@(private)
pane_rebuild_symbols :: proc(editor_pane: ^EditorPane) {
	for existing_symbol in editor_pane.symbols { delete(existing_symbol.name) }
	clear(&editor_pane.symbols)
	clear(&editor_pane.symbol_names)

	if editor_pane.language == nil { return }

	total_line_count := document.document_line_count(&editor_pane.document)

	// Materialize every line into a slice once — the syntax matcher
	// works on a whole-file lexeme stream so patterns like
	// `template ... class {NAME} {` can span newlines.
	all_lines := make([]string, total_line_count, context.temp_allocator)
	for line_index in 0..<total_line_count {
		all_lines[line_index] = document.document_get_line(&editor_pane.document, line_index, context.temp_allocator)
	}

	// Pass 1: discover user-declared type names so the `{TYPE}`
	// placeholder can resolve references regardless of declaration
	// order.
	known_type_names := make(map[string]bool, 0, context.temp_allocator)
	{
		scratch_symbols: [dynamic]syntax.Symbol
		scratch_symbols.allocator = context.temp_allocator
		syntax.extract_symbols_from_lines(editor_pane.language, all_lines, &scratch_symbols, nil, context.temp_allocator)
		for scratch_symbol in scratch_symbols {
			if scratch_symbol.kind == .Type { known_type_names[scratch_symbol.name] = true }
		}
	}

	// Pass 2: full extraction (names cloned with the long-lived
	// allocator).
	syntax.extract_symbols_from_lines(editor_pane.language, all_lines, &editor_pane.symbols, &known_type_names)

	for extracted_symbol in editor_pane.symbols {
		editor_pane.symbol_names[extracted_symbol.name] = extracted_symbol.kind
	}
}

// Refresh the active pane's symbol cache and open the picker.
@(private)
symbols_open :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor)
	if editor_pane == nil { return }

	// Always refresh on open so the user sees the latest declarations.
	pane_rebuild_symbols(editor_pane)
	editor_pane.symbols_dirty      = false
	editor_pane.last_analysis_time = editor.clock

	symbols_pkg.open(&editor.symbols_dialog, editor.active_pane_index, editor_pane.symbols[:])
}

// --- Symbols dialog host trampolines ----------------------------------

@(private="file")
symbols_host_source_pane :: proc(editor: ^Editor) -> ^EditorPane {
	source_pane_index := editor.symbols_dialog.source_pane_index
	if source_pane_index < 0 || source_pane_index >= len(editor.panes) { return nil }
	return pane_as_editor(&editor.panes[source_pane_index])
}

@(private)
symbols_host_source_symbols :: proc(user_data: rawptr) -> []syntax.Symbol {
	editor := cast(^Editor)user_data
	source_editor_pane := symbols_host_source_pane(editor)
	if source_editor_pane == nil { return nil }
	return source_editor_pane.symbols[:]
}

@(private)
symbols_host_dialog_title :: proc(user_data: rawptr, allocator: runtime.Allocator) -> string {
	editor := cast(^Editor)user_data
	source_editor_pane := symbols_host_source_pane(editor)
	if source_editor_pane == nil { return strings.clone("Symbols", allocator) }
	display_filename := source_editor_pane.file_path != "" ? filepath.base(source_editor_pane.file_path) : "untitled"
	return fmt.aprintf("Symbols — %s", display_filename, allocator = allocator)
}

@(private)
symbols_host_apply_activate :: proc(user_data: rawptr, symbol_index: int) {
	editor := cast(^Editor)user_data
	source_editor_pane := symbols_host_source_pane(editor)
	if source_editor_pane == nil { return }
	if symbol_index < 0 || symbol_index >= len(source_editor_pane.symbols) { return }

	selected_symbol := source_editor_pane.symbols[symbol_index]

	// Focus the source pane and place the cursor on the symbol's name.
	editor.active_pane_index = editor.symbols_dialog.source_pane_index

	document_line_count := document.document_line_count(&source_editor_pane.document)
	target_line := selected_symbol.line
	if target_line >= document_line_count { target_line = document_line_count - 1 }

	line_start_offset := document.document_line_start(&source_editor_pane.document, target_line)
	line_text         := document.document_get_line(&source_editor_pane.document, target_line, context.temp_allocator)
	target_column     := selected_symbol.column
	if int(target_column) > len(line_text) { target_column = u32(len(line_text)) }

	source_editor_pane.cursor_line      = target_line
	source_editor_pane.cursor_column    = target_column
	source_editor_pane.cursor_offset    = line_start_offset + target_column
	source_editor_pane.selection_active = false

	editor.cursor_visible = true
	editor.cursor_timer = 0

	// Position the target line at the top of the pane's text area
	// instead of just making it visible. In diff mode the layout is
	// row-indexed and shared between panes, so we defer to the
	// existing scroll-into-view behaviour there.
	if editor.diff_state.active || editor.line_height <= 0 {
		sync_cursor_from_offset(editor)
	} else {
		target_scroll_y := f32(target_line) * f32(editor.line_height)
		if target_scroll_y < 0 { target_scroll_y = 0 }
		source_editor_pane.scroll_y        = target_scroll_y
		source_editor_pane.scroll_y_target = target_scroll_y
		source_editor_pane.scroll_line     = target_line
	}
}

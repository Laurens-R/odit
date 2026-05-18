package editor

import "core:strings"
import "vendor:sdl3"

import "../document"

@(private)
clipboard_copy :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	low_offset, high_offset, has_selection := selection_range(editor)
	if !has_selection { return }
	selected_text := document.document_get_slice(&editor_pane.document, low_offset, high_offset - low_offset, context.temp_allocator)
	c_string_text := strings.clone_to_cstring(selected_text, context.temp_allocator)
	_ = sdl3.SetClipboardText(c_string_text)
}

@(private)
clipboard_paste :: proc(editor: ^Editor) {
	raw_clipboard_pointer := sdl3.GetClipboardText()
	if raw_clipboard_pointer == nil { return }
	defer sdl3.free(rawptr(raw_clipboard_pointer))
	clipboard_text := string(cstring(raw_clipboard_pointer))
	if len(clipboard_text) == 0 { return }
	editor_insert_text(editor, clipboard_text)
}

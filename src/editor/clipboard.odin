package editor

import "core:strings"
import "vendor:sdl3"

import "../document"

@(private)
clipboard_copy :: proc(ed: ^Editor) {
	lo, hi, has := selection_range(ed)
	if !has { return }
	text := document.document_get_slice(&ed.doc, lo, hi - lo, context.temp_allocator)
	cstr := strings.clone_to_cstring(text, context.temp_allocator)
	_ = sdl3.SetClipboardText(cstr)
}

@(private)
clipboard_paste :: proc(ed: ^Editor) {
	raw := sdl3.GetClipboardText()
	if raw == nil { return }
	defer sdl3.free(rawptr(raw))
	text := string(cstring(raw))
	if len(text) == 0 { return }
	editor_insert_text(ed, text)
}

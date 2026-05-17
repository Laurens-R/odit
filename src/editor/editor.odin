package editor

import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "../document"

// Terminal-style editor state
Editor :: struct {
	doc:            document.Document,

	// Cursor position (in document coordinates)
	cursor_line:    u32,
	cursor_col:     u32, // byte offset within the line
	cursor_offset:  u32, // absolute byte offset in document

	// Viewport (which portion of the document is visible)
	scroll_line:     u32, // first visible line (derived from scroll_y)
	visible_lines:   u32, // how many lines fully fit on screen
	scroll_y:        f32, // current vertical scroll, in pixels (animated)
	scroll_y_target: f32, // target vertical scroll, in pixels

	// Rendering
	font:           ^ttf.Font,
	engine:         ^ttf.TextEngine,
	font_size:      f32,
	char_width:     i32, // monospace character width in pixels
	line_height:    i32, // line height in pixels
	padding_x:      i32, // left padding
	padding_y:      i32, // top padding
	gutter_width:   i32, // line-number gutter width in pixels (set during render)

	// Blink
	cursor_visible: bool,
	cursor_timer:   f64, // seconds accumulator

	// Selection
	sel_active:     bool,
	sel_anchor:     u32, // byte offset of selection anchor (other end is cursor_offset)
	mouse_dragging: bool, // left mouse button held; motion extends selection

	// Modal UI
	show_help:      bool, // F1 help dialog open
	show_browse:    bool, // F2 file browser open
	browse:         BrowseState,

	// Colors (terminal palette)
	bg_color:       sdl3.FColor,
	fg_color:       sdl3.FColor,
	cursor_color:   sdl3.FColor,
	line_num_color: sdl3.FColor,
	sel_color:      sdl3.FColor,
	status_bg:      sdl3.FColor,
	status_fg:      sdl3.FColor,
}

CURSOR_BLINK_RATE :: 0.53 // seconds
SCROLL_SMOOTHNESS :: 18.0 // higher = snappier; lower = floatier

editor_init :: proc(ed: ^Editor, engine: ^ttf.TextEngine, font: ^ttf.Font, font_size: f32) {
	document.document_init(&ed.doc, "")

	ed.font = font
	ed.engine = engine
	ed.font_size = font_size
	ed.cursor_line = 0
	ed.cursor_col = 0
	ed.cursor_offset = 0
	ed.scroll_line = 0
	ed.visible_lines = 0
	ed.scroll_y = 0
	ed.scroll_y_target = 0
	ed.cursor_visible = true
	ed.cursor_timer = 0
	ed.sel_active = false
	ed.sel_anchor = 0

	ed.padding_x = 8
	ed.padding_y = 4

	// Measure monospace character dimensions
	ed.line_height = i32(ttf.GetFontLineSkip(font))
	// Approximate char width from a reference character
	w: i32
	ttf.GetStringSize(font, "M", 1, &w, nil)
	ed.char_width = w

	// Terminal dark theme
	ed.bg_color       = sdl3.FColor{0.11, 0.11, 0.14, 1.0}
	ed.fg_color       = sdl3.FColor{0.85, 0.85, 0.85, 1.0}
	ed.cursor_color   = sdl3.FColor{0.9, 0.9, 0.9, 1.0}
	ed.line_num_color = sdl3.FColor{0.4, 0.45, 0.5, 1.0}
	ed.sel_color      = sdl3.FColor{0.22, 0.36, 0.60, 1.0}
	ed.status_bg      = sdl3.FColor{0.18, 0.20, 0.25, 1.0}
	ed.status_fg      = sdl3.FColor{0.7, 0.75, 0.8, 1.0}
}

editor_destroy :: proc(ed: ^Editor) {
	document.document_destroy(&ed.doc)
	browse_state_destroy(ed)
}

// Hard upper bound for a single document load. Anything beyond this is treated
// as a corrupt input rather than being passed to the piece tree.
EDITOR_MAX_DOCUMENT_BYTES :: 1024 * 1024 * 1024 // 1 GiB

editor_open_string :: proc(ed: ^Editor, content: string) {
	// Defensive: if `content` has been clobbered between the caller's compose
	// and our entry (corrupt ptr or absurd len), fall back to an empty doc.
	// Without this guard a bad len reaches bytes.buffer_init_string, which
	// reinterprets it as size_t and trips the Windows heap allocator.
	safe := content
	if len(safe) < 0 || len(safe) > EDITOR_MAX_DOCUMENT_BYTES {
		safe = ""
	}

	document.document_destroy(&ed.doc)
	document.document_init(&ed.doc, safe)
	ed.cursor_line = 0
	ed.cursor_col = 0
	ed.cursor_offset = 0
	ed.scroll_line = 0
	ed.scroll_y = 0
	ed.scroll_y_target = 0
	ed.sel_active = false
}

// True when a modal dialog (help, browse, future popups) currently owns input.
// main.odin uses this to decide whether Escape should quit the app.
editor_is_modal_open :: proc(ed: ^Editor) -> bool {
	return ed.show_help || ed.show_browse
}

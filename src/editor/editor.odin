package editor

import "core:strings"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "../document"
import "../syntax"

// --- Pane types -----------------------------------------------------------
//
// A `Pane` is a generic container that occupies a rectangle in the window.
// Each pane holds exactly one piece of `PaneContent` — currently only an
// editor, but the union is the place to add browser panes, terminal panes,
// settings panes, etc. without touching the rest of the codebase. Routing
// of input/render based on content type happens at well-defined dispatch
// points in `input.odin` and `render.odin`.

// `EditorPane` is the per-document state for a pane displaying a text buffer:
// its document, cursor, scroll position, and selection. Multiple editor panes
// can coexist (each is independent), and a pane's content can be swapped to a
// different content type later without disturbing this struct.
EditorPane :: struct {
	doc:             document.Document,
	file_path:       string, // owned absolute path; "" for an untitled doc
	language:        ^syntax.Definition, // nil → plain text rendering
	symbols:         [dynamic]syntax.Symbol,           // declarations found in this doc (owned names)
	symbol_names:    map[string]syntax.SymbolKind,     // set view of `symbols` for fast highlighter lookup

	// Cursor position (in document coordinates)
	cursor_line:     u32,
	cursor_col:      u32, // byte offset within the line
	cursor_offset:   u32, // absolute byte offset in document

	// Viewport (which portion of the document is visible)
	scroll_line:     u32, // first visible line (derived from scroll_y)
	visible_lines:   u32, // how many lines fully fit on screen
	scroll_y:        f32, // current vertical scroll, in pixels (animated)
	scroll_y_target: f32, // target vertical scroll, in pixels

	// Selection
	sel_active:      bool,
	sel_anchor:      u32, // byte offset of selection anchor (other end is cursor_offset)
	mouse_dragging:  bool, // left mouse button held; motion extends selection

	gutter_width:    i32, // line-number gutter width in pixels (set during render)

	// Symbol re-analysis bookkeeping. `symbols_dirty` flips true whenever the
	// pane's document is mutated; `last_analysis_time` is `ed.clock` at the
	// last rebuild. Together with `Editor.last_keystroke_time` they gate the
	// auto-reanalyze pass in `editor_update`.
	symbols_dirty:        bool,
	last_analysis_time:   f64,
}

// Tagged union of all pane content kinds. Add variants here as new pane types
// are introduced.
PaneContent :: union {
	EditorPane,
}

// A pane is a generic container that owns a screen rectangle and one piece of
// content. The renderer/input dispatcher type-switches on `content`.
Pane :: struct {
	rect:    sdl3.Rect, // pixel rectangle this pane was last drawn into
	content: PaneContent,
}

// Top-level editor state. Shared resources (font, modals, palette) live here;
// per-pane state lives in `panes`. `active` selects which pane receives
// keyboard input and is shown with the visible cursor (when its content is an
// editor pane).
Editor :: struct {
	panes:           [2]Pane,
	active:          int,  // 0 or 1
	split_active:    bool, // when false, only panes[0] is rendered (full width)

	// Rendering (shared between panes)
	font:            ^ttf.Font,
	engine:          ^ttf.TextEngine,
	font_size:       f32,
	char_width:      i32,
	line_height:     i32,
	padding_x:       i32,
	padding_y:       i32,

	// Blink (shared rhythm; cursor only drawn in the active pane's editor)
	cursor_visible:  bool,
	cursor_timer:    f64,

	// Monotonic clock (seconds) accumulated from `editor_update`'s dt. Used
	// as the time base for auto-reanalysis debouncing.
	clock:                f64,
	last_keystroke_time:  f64,

	// Modal UI
	show_help:       bool,
	help_scroll:     i32,
	show_browse:     bool,
	browse:          BrowseState,

	// Diff mode (compares views[0]'s doc against views[1]'s doc)
	diff_state:      DiffState,

	// Colors (terminal palette)
	bg_color:        sdl3.FColor,
	fg_color:        sdl3.FColor,
	cursor_color:    sdl3.FColor,
	line_num_color:  sdl3.FColor,
	sel_color:       sdl3.FColor,
	status_bg:       sdl3.FColor,
	status_fg:       sdl3.FColor,
	divider_color:   sdl3.FColor,

	// Diff-mode row backgrounds
	diff_delete_bg:  sdl3.FColor, // line only on the left (red-tinted)
	diff_insert_bg:  sdl3.FColor, // line only on the right (green-tinted)
	diff_gap_bg:     sdl3.FColor, // gap on this side aligning the other pane

	// File-browser git status tints
	git_modified_fg:  sdl3.FColor,
	git_added_fg:     sdl3.FColor,
	git_untracked_fg: sdl3.FColor,
	git_renamed_fg:   sdl3.FColor,
	git_deleted_fg:   sdl3.FColor,

	// Syntax-highlighting palette (used by render when a pane has a language)
	syntax_keyword_fg:      sdl3.FColor,
	syntax_type_fg:         sdl3.FColor,
	syntax_string_fg:       sdl3.FColor,
	syntax_number_fg:       sdl3.FColor,
	syntax_comment_fg:      sdl3.FColor,
	syntax_preprocessor_fg: sdl3.FColor,
	syntax_symbol_fg:       sdl3.FColor,

	// Symbol-jump (F6) dialog state
	show_symbols:   bool,
	symbols_dialog: SymbolsDialog,
}

CURSOR_BLINK_RATE :: 0.53 // seconds
SCROLL_SMOOTHNESS :: 18.0 // higher = snappier; lower = floatier

// Hard upper bound for a single document load. Anything beyond this is treated
// as a corrupt input rather than being passed to the piece tree.
EDITOR_MAX_DOCUMENT_BYTES :: 1024 * 1024 * 1024 // 1 GiB

editor_init :: proc(ed: ^Editor, engine: ^ttf.TextEngine, font: ^ttf.Font, font_size: f32) {
	// Initialize both panes as empty editor panes. Future code paths can
	// reassign `panes[i].content` to a different content type when the user
	// opens a non-editor view.
	for i in 0..<len(ed.panes) {
		ep: EditorPane
		document.document_init(&ep.doc, "")
		ed.panes[i].content = ep
	}
	ed.active = 0
	ed.split_active = false

	ed.font = font
	ed.engine = engine
	ed.font_size = font_size
	ed.cursor_visible = true
	ed.cursor_timer = 0

	ed.padding_x = 8
	ed.padding_y = 4

	// Measure monospace character dimensions
	ed.line_height = i32(ttf.GetFontLineSkip(font))
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
	ed.divider_color  = sdl3.FColor{0.30, 0.34, 0.42, 1.0}
	ed.diff_delete_bg = sdl3.FColor{0.28, 0.10, 0.12, 1.0}
	ed.diff_insert_bg = sdl3.FColor{0.10, 0.28, 0.14, 1.0}
	ed.diff_gap_bg    = sdl3.FColor{0.07, 0.08, 0.11, 1.0}

	ed.git_modified_fg  = sdl3.FColor{0.95, 0.78, 0.42, 1.0} // amber
	ed.git_added_fg     = sdl3.FColor{0.45, 0.85, 0.50, 1.0} // green
	ed.git_untracked_fg = sdl3.FColor{0.50, 0.78, 0.95, 1.0} // light blue
	ed.git_renamed_fg   = sdl3.FColor{0.78, 0.62, 0.95, 1.0} // purple
	ed.git_deleted_fg   = sdl3.FColor{0.92, 0.45, 0.45, 1.0} // red

	ed.syntax_keyword_fg      = sdl3.FColor{0.55, 0.70, 0.95, 1.0} // soft blue
	ed.syntax_type_fg         = sdl3.FColor{0.48, 0.82, 0.85, 1.0} // teal
	ed.syntax_string_fg       = sdl3.FColor{0.65, 0.85, 0.55, 1.0} // soft green
	ed.syntax_number_fg       = sdl3.FColor{0.92, 0.70, 0.45, 1.0} // orange
	ed.syntax_comment_fg      = sdl3.FColor{0.45, 0.50, 0.58, 1.0} // dim grey
	ed.syntax_preprocessor_fg = sdl3.FColor{0.88, 0.55, 0.78, 1.0} // magenta
	ed.syntax_symbol_fg       = sdl3.FColor{0.95, 0.90, 0.55, 1.0} // pale yellow

	syntax.init()
}

editor_destroy :: proc(ed: ^Editor) {
	for i in 0..<len(ed.panes) {
		pane_destroy(&ed.panes[i])
	}
	browse_state_destroy(ed)
	diff_state_destroy(&ed.diff_state)
	symbols_dialog_destroy(&ed.symbols_dialog)
	syntax.destroy()
}

// Per-content cleanup. Add cases here as new content types are introduced.
@(private)
pane_destroy :: proc(p: ^Pane) {
	#partial switch &c in p.content {
	case EditorPane:
		document.document_destroy(&c.doc)
		if len(c.file_path) > 0 {
			delete(c.file_path)
			c.file_path = ""
		}
		for s in c.symbols { delete(s.name) }
		delete(c.symbols)
		delete(c.symbol_names)
	}
}

// Height of the title strip at the top of every editor pane (filename area).
// Used by both render and mouse-coordinate translation.
@(private)
editor_title_bar_height :: proc(ed: ^Editor) -> i32 {
	return ed.line_height + 6
}

// --- Pane accessors -------------------------------------------------------

@(private)
editor_active_pane :: proc(ed: ^Editor) -> ^Pane {
	return &ed.panes[ed.active]
}

// Returns the active pane's `EditorPane`, or nil if the active pane is not an
// editor pane. Most cursor/selection/clipboard procs short-circuit on nil so
// they're safe to call regardless of what kind of pane is currently focused.
@(private)
editor_active_editor_pane :: proc(ed: ^Editor) -> ^EditorPane {
	return pane_as_editor(&ed.panes[ed.active])
}

@(private)
pane_as_editor :: proc(p: ^Pane) -> ^EditorPane {
	ep, ok := &p.content.(EditorPane)
	return ep if ok else nil
}

// Returns 2 when a split is showing both panes; 1 otherwise.
@(private)
editor_visible_pane_count :: proc(ed: ^Editor) -> int {
	return 2 if ed.split_active else 1
}

// Hit-test: which pane is the given pixel position over? Returns -1 if none.
@(private)
editor_pane_at :: proc(ed: ^Editor, x, y: f32) -> int {
	for i in 0..<editor_visible_pane_count(ed) {
		r := ed.panes[i].rect
		if x >= f32(r.x) && x < f32(r.x + r.w) &&
		   y >= f32(r.y) && y < f32(r.y + r.h) {
			return i
		}
	}
	return -1
}

// Toggle focus to the other pane (no-op when no split is active).
@(private)
editor_focus_other_pane :: proc(ed: ^Editor) {
	if !ed.split_active { return }
	ed.active = 1 - ed.active
	ed.cursor_visible = true
	ed.cursor_timer = 0
}

// --- Public open-string entry points --------------------------------------

editor_open_string :: proc(ed: ^Editor, content: string) {
	editor_open_string_in_pane(ed, ed.active, content)
}

// Load a string into a specific pane, replacing its content with a fresh
// editor pane regardless of the previous content type. `file_path` is stored
// on the pane for display in the title bar; pass "" for an untitled doc.
editor_open_string_in_pane :: proc(ed: ^Editor, pane_idx: int, content: string, file_path: string = "") {
	if pane_idx < 0 || pane_idx >= len(ed.panes) { return }

	safe := content
	if len(safe) < 0 || len(safe) > EDITOR_MAX_DOCUMENT_BYTES {
		safe = ""
	}

	// Tear down whatever was in the pane and replace with a fresh editor.
	pane_destroy(&ed.panes[pane_idx])

	ep: EditorPane
	document.document_init(&ep.doc, safe)
	if len(file_path) > 0 {
		ep.file_path = strings.clone(file_path)
		ep.language  = syntax.get_definition_for_path(file_path)
	}
	ed.panes[pane_idx].content = ep

	// Build the per-pane symbol index now that the doc + language are wired
	// up. `pane_rebuild_symbols` is defined in symbols.odin.
	if ep.language != nil {
		if v := pane_as_editor(&ed.panes[pane_idx]); v != nil {
			pane_rebuild_symbols(v)
		}
	}
}

// True when a modal dialog (help, browse, future popups) currently owns input.
editor_is_modal_open :: proc(ed: ^Editor) -> bool {
	return ed.show_help || ed.show_browse || ed.show_symbols
}

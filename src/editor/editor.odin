package editor

import "core:strings"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "../document"
import "../syntax"
import "../terminal"
import "../ui"

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
	document:        document.Document,
	file_path:       string, // owned absolute path; "" for an untitled doc
	// Optional title-bar override; when non-empty the pane shows this label
	// instead of `filepath_base(file_path)`. Used by F3's git-history viewer
	// to surface "filename @ short-hash" without retargeting the pane at a
	// fake on-disk path that Ctrl+S would then happily overwrite.
	display_title_override: string, // owned, "" when not overridden
	language:        ^syntax.Definition, // nil → plain text rendering
	symbols:         [dynamic]syntax.Symbol,           // declarations found in this doc (owned names)
	symbol_names:    map[string]syntax.SymbolKind,     // set view of `symbols` for fast highlighter lookup

	// Cursor position (in document coordinates)
	cursor_line:     u32,
	cursor_column:   u32, // byte offset within the line
	cursor_offset:   u32, // absolute byte offset in document

	// Viewport (which portion of the document is visible)
	scroll_line:     u32, // first visible line (derived from scroll_y)
	visible_lines:   u32, // how many lines fully fit on screen
	scroll_y:        f32, // current vertical scroll, in pixels (animated)
	scroll_y_target: f32, // target vertical scroll, in pixels

	// Horizontal scroll, in pixels. Used only when `wrap_mode == false`;
	// flipping to wrap clears `scroll_x_target` to 0. Animated identically
	// to scroll_y for parity.
	scroll_x:        f32,
	scroll_x_target: f32,

	// When true, lines that exceed the pane's available text width are
	// broken into multiple visual rows that fit the pane. When false,
	// long lines remain on a single row and the user pans horizontally
	// with scroll_x. Toggled by Ctrl+W.
	wrap_mode:       bool,

	// Interactive scrollbar state. The renderer writes the current
	// `track_rectangle` / `thumb_rectangle` here every frame; mouse
	// handlers in `mouse.odin` read those rects to hit-test hover and
	// drag. `is_hovered` widens the next paint; `is_dragging` locks scroll
	// updates onto the thumb under the cursor.
	scrollbar:       ScrollbarState,

	// Selection
	selection_active:  bool,
	selection_anchor:  u32, // byte offset of selection anchor (other end is cursor_offset)
	mouse_dragging:    bool, // left mouse button held; motion extends selection

	gutter_width:    i32, // line-number gutter width in pixels (set during render)

	// Symbol re-analysis bookkeeping. `symbols_dirty` flips true whenever the
	// pane's document is mutated; `last_analysis_time` is `editor.clock` at the
	// last rebuild. Together with `Editor.last_keystroke_time` they gate the
	// auto-reanalyze pass in `editor_update`.
	symbols_dirty:        bool,
	last_analysis_time:   f64,
}

// Per-pane scrollbar interaction state. Track + thumb rects are rewritten
// every frame by the renderer; the rest persists between frames so hover /
// drag survive across event ticks.
ScrollbarState :: struct {
	track_rectangle: sdl3.FRect,
	thumb_rectangle: sdl3.FRect,
	is_hovered:      bool,
	is_dragging:     bool,
	drag_delta_y:    f32, // y-offset within the thumb at drag start
}

// A pane that hosts an embedded terminal emulator instead of a document.
// The terminal owns a child shell process, a read thread, and a cell-grid
// screen — see the `terminal` package. We store a pointer rather than the
// terminal by value so the union variant stays a single word and the
// terminal's internal pointers (mutex, thread handle) are address-stable.
TerminalPane :: struct {
	terminal: ^terminal.Terminal,
}

// Tagged union of all pane content kinds. Add variants here as new pane types
// are introduced.
PaneContent :: union {
	EditorPane,
	TerminalPane,
	MarkdownPreviewPane,
}

// A pane is a generic container that owns a screen rectangle and one piece of
// content. The renderer/input dispatcher type-switches on `content`.
//
// `saved_content` is a stash slot. When F9 turns a pane into a terminal we
// move the previous content (typically an EditorPane) into `saved_content`
// so the original document is preserved untouched while the terminal runs.
// `saved_split_active` remembers `Editor.split_active` at the same moment so
// F9-close can put the editor back into single- vs split-pane mode exactly
// the way the user left it.
Pane :: struct {
	rectangle:           sdl3.Rect,
	content:             PaneContent,
	saved_content:       PaneContent, // zero-value when nothing stashed
	saved_split_active:  bool,
	has_saved_content:   bool,
}

// Top-level editor state. Shared resources (font, modals, palette) live here;
// per-pane state lives in `panes`. `active_pane_index` selects which pane
// receives keyboard input and is shown with the visible cursor (when its
// content is an editor pane).
Editor :: struct {
	panes:             [2]Pane,
	active_pane_index: int,  // 0 or 1
	split_active:      bool, // when false, only panes[0] is rendered (full width)

	// Split divider position when `split_active`. Stored as a fraction of
	// the full window width (left pane share), so the layout adapts to
	// window resizes for free. Initialized in `editor_init`; updated by the
	// drag handler in `mouse.odin`.
	split_ratio:      f32,
	divider_dragging: bool,

	// System cursors cached at startup so we can swap shapes on hover /
	// drag of the pane divider without paying the per-frame cost of
	// CreateSystemCursor. `current_cursor` lets us avoid redundant
	// SetCursor calls each frame.
	cursor_default:   ^sdl3.Cursor,
	cursor_resize_ew: ^sdl3.Cursor,
	current_cursor:   ^sdl3.Cursor,

	// Per-render TTF text cache. The editor renders many short strings
	// (one per syntax token) every frame, most of which repeat from one
	// frame to the next; caching avoids the GPU-texture churn that comes
	// from `ttf.CreateText` + `ttf.DestroyText` round-trips.
	text_cache: ui.TextCache,

	// Frame-skip flag. The main loop calls `editor_render` + `RenderPresent`
	// only when this is set, then clears it via `editor_mark_clean`. Setters
	// are scattered: every input handler, the cursor-blink toggle, terminal
	// output drains, smooth-scroll animation, window resize. When nothing's
	// happening, the entire render path is skipped and we just `Sleep(16)`.
	needs_redraw: bool,

	// Rendering (shared between panes)
	font:             ^ttf.Font,
	text_engine:      ^ttf.TextEngine,
	font_size:        f32,
	character_width:  i32,
	line_height:      i32,
	padding_x:        i32,
	padding_y:        i32,

	// Blink (shared rhythm; cursor only drawn in the active pane's editor)
	cursor_visible:  bool,
	cursor_timer:    f64,

	// Monotonic clock (seconds) accumulated from `editor_update`'s delta_time.
	// Used as the time base for auto-reanalysis debouncing.
	clock:                f64,
	last_keystroke_time:  f64,

	// Modal UI
	show_help:       bool,
	help_scroll:     i32,
	show_browse:     bool,
	browse_state:    BrowseState,

	// Diff mode (compares views[0]'s doc against views[1]'s doc)
	diff_state:      DiffState,

	// Colors (terminal palette)
	background_color:  sdl3.FColor,
	foreground_color:  sdl3.FColor,
	cursor_color:      sdl3.FColor,
	line_number_color: sdl3.FColor,
	selection_color:   sdl3.FColor,
	status_bar_background: sdl3.FColor,
	status_bar_foreground: sdl3.FColor,
	divider_color:     sdl3.FColor,

	// Diff-mode row backgrounds
	diff_delete_background:  sdl3.FColor, // line only on the left (red-tinted)
	diff_insert_background:  sdl3.FColor, // line only on the right (green-tinted)
	diff_gap_background:     sdl3.FColor, // gap on this side aligning the other pane
	diff_change_background:  sdl3.FColor, // line content differs but line exists on both sides
	diff_change_inline_highlight: sdl3.FColor, // alpha-blended overlay on the differing bytes only

	// File-browser git status tints
	git_modified_foreground:  sdl3.FColor,
	git_added_foreground:     sdl3.FColor,
	git_untracked_foreground: sdl3.FColor,
	git_renamed_foreground:   sdl3.FColor,
	git_deleted_foreground:   sdl3.FColor,

	// Syntax-highlighting palette (used by render when a pane has a language)
	syntax_keyword_foreground:      sdl3.FColor,
	syntax_type_foreground:         sdl3.FColor,
	syntax_string_foreground:       sdl3.FColor,
	syntax_number_foreground:       sdl3.FColor,
	syntax_comment_foreground:      sdl3.FColor,
	syntax_preprocessor_foreground: sdl3.FColor,
	syntax_symbol_foreground:       sdl3.FColor,

	// Symbol-jump (F6) dialog state
	show_symbols:   bool,
	symbols_dialog: SymbolsDialog,

	// Confirm-close dialog for the embedded terminal (F9). When the user
	// hits F9 while a terminal is running we show this modal instead of
	// killing the shell immediately.
	show_terminal_close_confirm: bool,
	terminal_close_confirm:      TerminalCloseConfirm,

	// Find mode (Ctrl+F). Attached to a single pane at a time; closes on
	// click outside the bar, on Esc, or on pane switch.
	find:                       FindState,
	find_match_background:      sdl3.FColor, // all matches
	find_match_active_background: sdl3.FColor, // currently selected match

	// Find-and-replace mode (Ctrl+R). Lives at the same bottom-of-pane spot
	// as Find; opening one closes the other. Live preview is rolled back on
	// Esc and coalesced into one Compound undo entry on Enter.
	replace:                    ReplaceState,

	// Find-in-files dialog (Ctrl+Shift+F). Modal: takes over input while
	// `show_find_in_files` is true.
	show_find_in_files:         bool,
	find_in_files:              FindInFilesState,

	// Replace-in-files dialog (Ctrl+Shift+R). Modal companion to the find
	// dialog — does destructive on-disk writes when the user commits.
	show_replace_in_files:      bool,
	replace_in_files:           ReplaceInFilesState,

	// Save-As path-input modal. Opens directly via Ctrl+Shift+S, indirectly
	// via Ctrl+S on an untitled doc, and from the Yes branch of the close
	// confirmation when the file has no path yet.
	show_save_as:               bool,
	save_as_dialog:             SaveAsDialog,

	// Yes/No/Cancel prompt fired by Ctrl+F4 on a dirty document.
	show_close_confirm:         bool,
	close_confirm_dialog:       CloseConfirmDialog,

	// Git history viewer (F3). Lists past revisions of the active pane's
	// file; activating one opens that revision in the opposite pane.
	show_git_history:           bool,
	git_history_dialog:         GitHistoryDialog,

	// Fonts loaded lazily for the markdown preview pane. Proportional (Arial-
	// like) for body / headings; monospace for inline code and code blocks.
	// Loaded on the first F5 press, freed in `editor_destroy`.
	markdown_fonts:             MarkdownFonts,

	// Project root, set by Ctrl+P in the file browser. Owned absolute path;
	// "" when unset. When set:
	//   - The F2 browser defaults to it on next open if the cached cwd has
	//     wandered outside the root.
	//   - The F9 terminal spawns with it as the working directory.
	//   - The status bar shows it at all times.
	project_root:               string,
}

CURSOR_BLINK_RATE :: 0.53 // seconds
SCROLL_SMOOTHNESS :: 18.0 // higher = snappier; lower = floatier

// Hard upper bound for a single document load. Anything beyond this is treated
// as a corrupt input rather than being passed to the piece tree.
EDITOR_MAX_DOCUMENT_BYTES :: 1024 * 1024 * 1024 // 1 GiB

editor_init :: proc(editor: ^Editor, text_engine: ^ttf.TextEngine, font: ^ttf.Font, font_size: f32) {
	// Initialize both panes as empty editor panes. Future code paths can
	// reassign `panes[i].content` to a different content type when the user
	// opens a non-editor view.
	for pane_index in 0..<len(editor.panes) {
		editor_pane: EditorPane
		document.document_init(&editor_pane.document, "")
		editor.panes[pane_index].content = editor_pane
	}
	editor.active_pane_index = 0
	editor.split_active = false
	editor.split_ratio  = 0.5 // default 50/50 when the split is opened

	// Cache the two cursors we ever swap between. `EW_RESIZE` is the
	// closest system cursor to a "grab the column divider" indicator; SDL3
	// doesn't expose a dedicated grab/grabbing shape, and on Windows it
	// renders as the familiar double-headed left/right arrow.
	editor.cursor_default   = sdl3.CreateSystemCursor(.DEFAULT)
	editor.cursor_resize_ew = sdl3.CreateSystemCursor(.EW_RESIZE)
	editor.current_cursor   = editor.cursor_default
	if editor.cursor_default != nil { _ = sdl3.SetCursor(editor.cursor_default) }

	ui.text_cache_init(&editor.text_cache, text_engine, font, 1024)

	// Force an initial render so the first frame paints, then keep the
	// flag accurate via the various setters below.
	editor.needs_redraw = true

	editor.font = font
	editor.text_engine = text_engine
	editor.font_size = font_size
	editor.cursor_visible = true
	editor.cursor_timer = 0

	editor.padding_x = 8
	editor.padding_y = 4

	// Measure monospace character dimensions
	editor.line_height = i32(ttf.GetFontLineSkip(font))
	measured_width: i32
	ttf.GetStringSize(font, "M", 1, &measured_width, nil)
	editor.character_width = measured_width

	// Terminal dark theme
	editor.background_color       = sdl3.FColor{0.11, 0.11, 0.14, 1.0}
	editor.foreground_color       = sdl3.FColor{0.85, 0.85, 0.85, 1.0}
	editor.cursor_color           = sdl3.FColor{0.9, 0.9, 0.9, 1.0}
	editor.line_number_color      = sdl3.FColor{0.4, 0.45, 0.5, 1.0}
	editor.selection_color        = sdl3.FColor{0.22, 0.36, 0.60, 1.0}
	editor.status_bar_background  = sdl3.FColor{0.18, 0.20, 0.25, 1.0}
	editor.status_bar_foreground  = sdl3.FColor{0.7, 0.75, 0.8, 1.0}
	editor.divider_color          = sdl3.FColor{0.30, 0.34, 0.42, 1.0}
	editor.diff_delete_background = sdl3.FColor{0.28, 0.10, 0.12, 1.0}
	editor.diff_insert_background = sdl3.FColor{0.10, 0.28, 0.14, 1.0}
	editor.diff_gap_background    = sdl3.FColor{0.07, 0.08, 0.11, 1.0}
	editor.diff_change_background        = sdl3.FColor{0.24, 0.20, 0.08, 1.0}  // dim amber tint over the whole row
	editor.diff_change_inline_highlight  = sdl3.FColor{0.78, 0.60, 0.18, 0.55} // brighter amber on the differing bytes

	editor.git_modified_foreground  = sdl3.FColor{0.95, 0.78, 0.42, 1.0} // amber
	editor.git_added_foreground     = sdl3.FColor{0.45, 0.85, 0.50, 1.0} // green
	editor.git_untracked_foreground = sdl3.FColor{0.50, 0.78, 0.95, 1.0} // light blue
	editor.git_renamed_foreground   = sdl3.FColor{0.78, 0.62, 0.95, 1.0} // purple
	editor.git_deleted_foreground   = sdl3.FColor{0.92, 0.45, 0.45, 1.0} // red

	editor.find_match_background          = sdl3.FColor{0.55, 0.50, 0.15, 0.55} // muted yellow
	editor.find_match_active_background   = sdl3.FColor{0.95, 0.78, 0.20, 0.85} // bright amber

	editor.syntax_keyword_foreground      = sdl3.FColor{0.55, 0.70, 0.95, 1.0} // soft blue
	editor.syntax_type_foreground         = sdl3.FColor{0.48, 0.82, 0.85, 1.0} // teal
	editor.syntax_string_foreground       = sdl3.FColor{0.65, 0.85, 0.55, 1.0} // soft green
	editor.syntax_number_foreground       = sdl3.FColor{0.92, 0.70, 0.45, 1.0} // orange
	editor.syntax_comment_foreground      = sdl3.FColor{0.45, 0.50, 0.58, 1.0} // dim grey
	editor.syntax_preprocessor_foreground = sdl3.FColor{0.88, 0.55, 0.78, 1.0} // magenta
	editor.syntax_symbol_foreground       = sdl3.FColor{0.95, 0.90, 0.55, 1.0} // pale yellow

	syntax.init()
}

editor_destroy :: proc(editor: ^Editor) {
	for pane_index in 0..<len(editor.panes) {
		pane_destroy(&editor.panes[pane_index])
	}
	browse_state_destroy(editor)
	diff_state_destroy(&editor.diff_state)
	symbols_dialog_destroy(&editor.symbols_dialog)
	find_state_destroy(&editor.find)
	replace_state_destroy(&editor.replace)
	find_in_files_destroy(&editor.find_in_files)
	replace_in_files_destroy(&editor.replace_in_files)
	save_as_dialog_destroy(&editor.save_as_dialog)
	git_history_dialog_destroy(&editor.git_history_dialog)
	markdown_fonts_destroy(&editor.markdown_fonts)
	if len(editor.project_root) > 0 {
		delete(editor.project_root)
		editor.project_root = ""
	}
	syntax.destroy()
	if editor.cursor_default   != nil { sdl3.DestroyCursor(editor.cursor_default)   }
	if editor.cursor_resize_ew != nil { sdl3.DestroyCursor(editor.cursor_resize_ew) }
	ui.text_cache_destroy(&editor.text_cache)
}

// Per-content cleanup. Add cases here as new content types are introduced.
@(private)
pane_destroy :: proc(pane: ^Pane) {
	pane_content_destroy(&pane.content)
	if pane.has_saved_content {
		pane_content_destroy(&pane.saved_content)
		pane.has_saved_content = false
	}
}

// Tear down a single PaneContent without touching the surrounding Pane.
// Factored so the terminal stash/restore dance can release whatever the
// pane's previous content held.
@(private)
pane_content_destroy :: proc(pane_content: ^PaneContent) {
	#partial switch &content_value in pane_content {
	case EditorPane:
		document.document_destroy(&content_value.document)
		if len(content_value.file_path) > 0 {
			delete(content_value.file_path)
			content_value.file_path = ""
		}
		if len(content_value.display_title_override) > 0 {
			delete(content_value.display_title_override)
			content_value.display_title_override = ""
		}
		for symbol in content_value.symbols { delete(symbol.name) }
		delete(content_value.symbols)
		delete(content_value.symbol_names)
	case TerminalPane:
		if content_value.terminal != nil {
			terminal.terminal_destroy(content_value.terminal)
			content_value.terminal = nil
		}
	case MarkdownPreviewPane:
		markdown_preview_pane_destroy(&content_value)
	}
}

// Height of the title strip at the top of every editor pane (filename area).
// Used by both render and mouse-coordinate translation.
@(private)
editor_title_bar_height :: proc(editor: ^Editor) -> i32 {
	return editor.line_height + 6
}

// Pixel height reserved for the find bar at the bottom of a pane when find
// mode is active on that pane. Returns 0 when find isn't active for this pane.
@(private)
editor_find_bar_height_for_pane :: proc(editor: ^Editor, pane_index: int) -> i32 {
	if !editor.find.active                       { return 0 }
	if editor.find.pane_index != pane_index      { return 0 }
	return editor.line_height + 10
}

// Total pixel height reserved at the bottom of a pane for any active overlay
// bar (find OR replace — only one can be active at a time). Used by the
// renderer to shrink the text-area height.
@(private)
editor_bottom_bar_height_for_pane :: proc(editor: ^Editor, pane_index: int) -> i32 {
	return editor_find_bar_height_for_pane(editor, pane_index) + replace_bar_height_for_pane(editor, pane_index)
}

// --- Pane accessors -------------------------------------------------------

@(private)
editor_active_pane :: proc(editor: ^Editor) -> ^Pane {
	return &editor.panes[editor.active_pane_index]
}

// Returns the active pane's `EditorPane`, or nil if the active pane is not an
// editor pane. Most cursor/selection/clipboard procs short-circuit on nil so
// they're safe to call regardless of what kind of pane is currently focused.
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

// Hit-test: which pane is the given pixel position over? Returns -1 if none.
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

// --- Terminal pane toggle (F9) --------------------------------------------

// Open the embedded terminal in the right pane. If a document is already
// there it gets stashed (untouched) and restored on the next toggle. If a
// terminal is already running this is a no-op so a stray F9 press doesn't
// kill a working shell.
@(private)
editor_open_terminal :: proc(editor: ^Editor) {
	terminal_pane_index := 1
	pane := &editor.panes[terminal_pane_index]

	// Already a terminal — nothing to do.
	if _, is_terminal_pane := pane.content.(TerminalPane); is_terminal_pane { return }

	pane_rectangle := pane.rectangle
	if pane_rectangle.w == 0 || pane_rectangle.h == 0 {
		// Pane hasn't been laid out yet; conjure something reasonable so
		// the shell gets a sane initial size and the renderer adjusts on
		// the next frame.
		pane_rectangle = sdl3.Rect{ x = 0, y = 0, w = 720, h = 480 }
	}
	character_width := editor.character_width;  if character_width <= 0 { character_width = 8 }
	line_height     := editor.line_height;      if line_height     <= 0 { line_height     = 16 }

	row_count    := max(i32(4),  (pane_rectangle.h - editor_title_bar_height(editor)) / line_height)
	column_count := max(i32(10), pane_rectangle.w / character_width)

	// Match the terminal's default colors to the editor palette so plain
	// shell output blends with the surrounding UI instead of sitting on a
	// black slab.
	default_foreground := terminal.Color{ editor.foreground_color.r, editor.foreground_color.g, editor.foreground_color.b, editor.foreground_color.a }
	default_background := terminal.Color{ editor.background_color.r, editor.background_color.g, editor.background_color.b, editor.background_color.a }

	// When a project root is set, anchor the shell there so terminal commands
	// run relative to the project regardless of where the editor was launched
	// from. Otherwise inherit the editor's own cwd ("" = pass nil to spawn).
	new_terminal := terminal.terminal_new(row_count, column_count, default_foreground, default_background, editor.project_root)
	if new_terminal == nil { return }

	// Stash both the previous content AND the previous split state so
	// closing the terminal puts the editor back exactly as it was — single
	// pane if it started single, split with the original right-side doc if
	// it started split. Drop any prior stash defensively.
	if pane.has_saved_content {
		pane_content_destroy(&pane.saved_content)
		pane.has_saved_content = false
	}
	pane.saved_content      = pane.content
	pane.saved_split_active = editor.split_active
	pane.has_saved_content  = true

	pane.content              = TerminalPane{ terminal = new_terminal }
	editor.split_active       = true
	editor.active_pane_index  = terminal_pane_index
}

// F9-again: shut the terminal down and restore both the document that was
// stashed when it opened AND the split state that was in effect then.
@(private)
editor_close_terminal :: proc(editor: ^Editor) {
	terminal_pane_index := 1
	pane := &editor.panes[terminal_pane_index]

	terminal_pane, is_terminal_pane := &pane.content.(TerminalPane)
	if !is_terminal_pane { return }

	if terminal_pane.terminal != nil {
		terminal.terminal_destroy(terminal_pane.terminal)
		terminal_pane.terminal = nil
	}

	if pane.has_saved_content {
		pane.content            = pane.saved_content
		editor.split_active     = pane.saved_split_active
		pane.saved_content      = PaneContent{}
		pane.saved_split_active = false
		pane.has_saved_content  = false
	} else {
		// No stash recorded — defensively reset to single-pane mode.
		pane.content        = PaneContent{}
		editor.split_active = false
	}

	// If we ended up single-pane, focus has to be on pane 0.
	if !editor.split_active { editor.active_pane_index = 0 }
}

// Single entry point bound to F9. Opening a fresh terminal is fire-and-
// forget; closing one prompts with a Yes/No dialog so an accidental press
// doesn't nuke a running shell.
@(private)
editor_toggle_terminal :: proc(editor: ^Editor) {
	if _, is_terminal_pane := editor.panes[1].content.(TerminalPane); is_terminal_pane {
		terminal_close_confirm_open(editor)
	} else {
		editor_open_terminal(editor)
	}
}

// --- Public open-string entry points --------------------------------------

editor_open_string :: proc(editor: ^Editor, content_text: string) {
	editor_open_string_in_pane(editor, editor.active_pane_index, content_text)
}

// Load a string into a specific pane, replacing its content with a fresh
// editor pane regardless of the previous content type. `file_path` is stored
// on the pane for display in the title bar; pass "" for an untitled doc.
editor_open_string_in_pane :: proc(editor: ^Editor, pane_index: int, content_text: string, file_path: string = "") {
	if pane_index < 0 || pane_index >= len(editor.panes) { return }

	safe_content := content_text
	if len(safe_content) < 0 || len(safe_content) > EDITOR_MAX_DOCUMENT_BYTES {
		safe_content = ""
	}

	// Tear down whatever was in the pane and replace with a fresh editor.
	pane_destroy(&editor.panes[pane_index])

	new_editor_pane: EditorPane
	document.document_init(&new_editor_pane.document, safe_content)
	if len(file_path) > 0 {
		new_editor_pane.file_path = strings.clone(file_path)
		new_editor_pane.language  = syntax.get_definition_for_path(file_path)
	}
	editor.panes[pane_index].content = new_editor_pane

	// Build the per-pane symbol index now that the doc + language are wired
	// up. `pane_rebuild_symbols` is defined in symbols.odin.
	if new_editor_pane.language != nil {
		if editor_pane := pane_as_editor(&editor.panes[pane_index]); editor_pane != nil {
			pane_rebuild_symbols(editor_pane)
		}
	}
}

// Mark the editor as needing a fresh render. Cheap; safe to call from any
// path that mutates visible state. Setters that flip user-visible bits
// (key/text/mouse events, cursor blink, scroll animation, terminal output)
// all funnel through here so the main loop can skip render+present on
// frames where nothing has actually changed.
editor_mark_dirty :: proc(editor: ^Editor) {
	editor.needs_redraw = true
}

// Drop the dirty flag — called by the main loop right after `editor_render`.
editor_mark_clean :: proc(editor: ^Editor) {
	editor.needs_redraw = false
}

// True when this frame must be drawn. Wraps the flag so the main loop never
// reads internal state directly.
editor_needs_render :: proc(editor: ^Editor) -> bool {
	return editor.needs_redraw
}

// True when a modal dialog (help, browse, future popups) currently owns input.
editor_is_modal_open :: proc(editor: ^Editor) -> bool {
	return editor.show_help || editor.show_browse || editor.show_symbols || editor.show_terminal_close_confirm || editor.show_find_in_files || editor.show_replace_in_files || editor.show_save_as || editor.show_close_confirm || editor.show_git_history
}

// --- Project root ---------------------------------------------------------

// Replace the current project root. Pass "" to clear it. `path` is copied —
// the caller retains ownership of the buffer they pass in. Idempotent / safe
// to call repeatedly.
@(private)
editor_set_project_root :: proc(editor: ^Editor, path: string) {
	if len(editor.project_root) > 0 {
		delete(editor.project_root)
		editor.project_root = ""
	}
	if len(path) > 0 {
		editor.project_root = strings.clone(path)
	}
}

// True when `path` is the project root or sits inside it. Caller passes
// already-normalized absolute paths; we just do a case-insensitive prefix
// check with a separator boundary so `C:/foo` is not treated as inside
// `C:/foobar`. Returns false if no project root is set.
@(private)
editor_path_inside_project_root :: proc(editor: ^Editor, path: string) -> bool {
	if len(editor.project_root) == 0 { return false }
	if len(path) == 0                { return false }
	if path_equals_ignore_case(path, editor.project_root) { return true }

	root_length := len(editor.project_root)
	if len(path) <= root_length { return false }
	if !path_has_prefix_ignore_case(path, editor.project_root) { return false }
	// Boundary check — refuse a hit where `editor.project_root` is just a
	// prefix of a longer sibling name.
	boundary_byte := path[root_length]
	return boundary_byte == '/' || boundary_byte == '\\'
}

// Case-insensitive path equality. ASCII-only fold; full Unicode case folding
// would need a real table and we don't need it for path matching on the
// platforms we target.
@(private="file")
path_equals_ignore_case :: proc(a, b: string) -> bool {
	if len(a) != len(b) { return false }
	for byte_index in 0..<len(a) {
		if ascii_fold_lower(a[byte_index]) != ascii_fold_lower(b[byte_index]) { return false }
	}
	return true
}

@(private="file")
path_has_prefix_ignore_case :: proc(path, prefix: string) -> bool {
	if len(prefix) > len(path) { return false }
	for byte_index in 0..<len(prefix) {
		if ascii_fold_lower(path[byte_index]) != ascii_fold_lower(prefix[byte_index]) { return false }
	}
	return true
}

// ASCII case-fold AND separator-fold. We want both `\` and `/` to compare as
// equal so paths from different sources (filepath.clean output, raw cwd, etc.)
// compare correctly. Full Unicode folding isn't needed for path matching on
// the platforms we target.
@(private="file")
ascii_fold_lower :: proc(byte_value: u8) -> u8 {
	if byte_value >= 'A' && byte_value <= 'Z' { return byte_value + ('a' - 'A') }
	if byte_value == '\\' { return '/' }
	return byte_value
}

package editor

import "core:strings"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "../dap"
import "../document"
import "../lsp"
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
	scrollbar:       ui.Scrollbar,

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

	// Same idea as `symbols_dirty` but for the markdown preview's idle
	// auto-refresh. Set on every document mutation; cleared once the preview
	// re-parses the source (or eagerly when no preview is open).
	markdown_dirty:       bool,

	// LSP sync bookkeeping. `lsp_did_open_sent` flips true once a didOpen
	// notification has been issued for the pane's current file path; the
	// close path uses it to know whether a matching didClose is required.
	// `lsp_dirty` + `lsp_last_edit_time` debounce didChange so the editor
	// doesn't spam the server on every keystroke.
	lsp_did_open_sent:    bool,
	lsp_dirty:            bool,
	lsp_last_edit_time:   f64,
}

// A pane that hosts an embedded terminal emulator instead of a document.
// The terminal owns a child shell process, a read thread, and a cell-grid
// screen — see the `terminal` package. We store a pointer rather than the
// terminal by value so the union variant stays a single word and the
// terminal's internal pointers (mutex, thread handle) are address-stable.
//
// The pointer here aliases the active entry in `Editor.terminals` — the
// editor owns the terminal lifetime; the pane just holds a borrowed
// pointer for rendering/input dispatch.
TerminalPane :: struct {
	terminal:  ^terminal.Terminal,
	scrollbar: ui.Scrollbar,
}

// One entry in the editor's multi-terminal list. `display_number` is a
// stable monotonically-assigned 1-based label used in the title strip and
// the picker — when a terminal is destroyed, the others keep their numbers
// instead of shifting, so the user's mental map ("Terminal 3") stays valid.
@(private)
TerminalEntry :: struct {
	terminal:       ^terminal.Terminal,
	display_number: int,
	// Task-runner bookkeeping. `is_build_job=true` marks a one-shot session
	// spawned by the Tasks dialog so the per-frame poll knows to watch its
	// child's exit code (rather than treating it as an interactive shell
	// that lives until the user closes it). When a build-job terminal exits
	// with code 0 *and* `pending_debug_profile_index >= 0`, the editor
	// auto-starts the queued debug session.
	is_build_job:                bool,
	build_profile_name:          string, // owned; "" for interactive shells
	pending_debug_profile_index: int,    // -1 = standalone build
	build_exit_observed:         bool,   // set once exit has been handled — guards against double-firing
}

// Tagged union of all pane content kinds. Add variants here as new pane types
// are introduced.
PaneContent :: union {
	EditorPane,
	TerminalPane,
	MarkdownPreviewPane,
	OutputPane,
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
	cursor_resize_ns: ^sdl3.Cursor,
	current_cursor:   ^sdl3.Cursor,

	// Last-seen mouse position from the SDL event stream. Threaded into
	// every `ui.Context` (via `editor_make_ui_context`) so generic UI
	// primitives — buttons, list rows — can auto-detect hover without
	// callers having to track it themselves.
	last_mouse_x:    f32,
	last_mouse_y:    f32,

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
	help_scrollbar:  ui.Scrollbar,
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

	// All open terminal sessions. F9 toggles visibility of the active
	// entry (and creates the first one when the list is empty); Ctrl+F9
	// always creates a fresh session; Ctrl+Shift+F9 opens a picker over
	// `terminals` so the user can switch between them. Ctrl+F4 in a
	// terminal pane destroys the active entry — when the last one goes
	// away the terminal slot collapses back to whatever was in pane[1]
	// before the first show. Whether a terminal is currently visible is
	// derived from `editor.panes[1].content` (see `editor_is_terminal_visible`),
	// so we don't carry a separate boolean that could go out of sync.
	terminals:                   [dynamic]TerminalEntry,
	active_terminal_index:       int,  // index into `terminals`; 0 when the list is empty
	next_terminal_display_number: int, // monotonically incremented; assigned at create-time

	// Ctrl+Shift+F9 picker. Lists open terminal sessions so the user can
	// jump between them.
	show_terminal_picker:        bool,
	terminal_picker:             TerminalPicker,

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

	// Open-documents picker (F4). Lists every EditorPane that's open but
	// not currently displayed — selecting one swaps it into the active
	// pane (stashing whatever was there first via the same mechanism).
	show_open_docs:             bool,
	open_docs_dialog:           OpenDocsDialog,

	// Documents that are open but not currently displayed in any pane.
	// Populated whenever an EditorPane is replaced via
	// `editor_open_string_in_pane` (the "switch" path); drained when the
	// user picks one back via F4 or opens the same file from the browser.
	// EditorPane values are stored by value — the slot owns its document,
	// file_path, display_title_override, symbols, and symbol_names.
	background_documents:       [dynamic]EditorPane,

	// Fonts loaded lazily for the markdown preview pane. Proportional (Arial-
	// like) for body / headings; monospace for inline code and code blocks.
	// Loaded on the first F5 press, freed in `editor_destroy`.
	markdown_fonts:             MarkdownFonts,

	// Top-of-window menu bar. Always visible; clicking a title opens the
	// dropdown, clicking outside or pressing Esc closes it. While a menu is
	// open, `menu_bar.open_menu_index >= 0` — this also counts as a modal
	// for the purpose of `editor_is_modal_open` so global hotkeys are
	// suppressed.
	menu_bar:                    MenuBarState,

	// Set by the File > Quit menu entry. main.odin polls this each frame
	// and exits the main loop when it flips true. Mirrors the existing
	// Ctrl+Q-in-main-loop path without needing the menu to reach into SDL.
	quit_requested:              bool,

	// User config loaded from settings.json at init. Currently holds the
	// per-language LSP command lookup; expected to grow.
	settings:                    EditorSettings,

	// Running LSP clients, keyed by lowercase language id ("odin"). Lazily
	// spawned the first time a file with that language is opened; torn
	// down on editor_destroy. Pointers are owned by this map.
	lsp_clients:                 map[string]^lsp.Client,

	// Hover popup state. Set by Ctrl+K → editor sends the LSP hover
	// request → next frame's poll surfaces a result → we copy it here for
	// rendering. Cleared on Esc / next keystroke / cursor move.
	hover_popup:                 HoverPopup,
	hover_popup_request_pending: bool,

	// Completion popup state — see `completion.odin` for the lifecycle.
	completion_popup:            CompletionPopup,

	// Signature-help popup — fires on `(`, refreshes on `,` while inside
	// the same argument list, auto-closes on `)` / Esc / cursor row change.
	signature_popup:             SignaturePopup,

	// Project root, set by Ctrl+P in the file browser. Owned absolute path;
	// "" when unset. When set:
	//   - The F2 browser defaults to it on next open if the cached cwd has
	//     wandered outside the root.
	//   - The F9 terminal spawns with it as the working directory.
	//   - The status bar shows it at all times.
	project_root:               string,

	// Right-side debug panel (F7). Owns the breakpoint list and the DAP
	// session snapshot. See debug.odin and dap_integration.odin.
	debug_state:                DebugState,
	breakpoint_color:           sdl3.FColor,
	breakpoint_disabled_color:  sdl3.FColor,
	debug_current_line_color:   sdl3.FColor, // background tint on the line where execution is paused

	// Running DAP adapter processes, keyed by adapter id ("lldb", ...).
	// `active_dap_client` aliases whichever entry is the one a session is
	// running against (or `nil` when no session is active). Owned by this
	// map; pointers freed in `editor_destroy`.
	dap_clients:                map[string]^dap.Client,
	active_dap_client:          ^dap.Client,

	// Per-project build + debug profiles (loaded from
	// `<project_root>/.odit/project.json`). Reloaded any time the project
	// root changes — empty when there's no project root or no file.
	project_config:              ProjectConfig,

	// F7 tasks dialog. Build profiles run inside a fresh terminal session
	// (see `editor_terminal_create_for_build`); the terminal entry is
	// tagged as a build job so the per-frame poll knows to watch its child
	// process and chain a queued debug launch when a build-then-debug
	// pairing completes successfully.
	show_tasks_dialog:           bool,
	tasks_dialog:                TasksDialog,

	// Selected index into `project_config.debug_profiles`. -1 means "no
	// selection yet" — the Tasks dialog (F7) seeds it on activation.
	active_debug_configuration_index: int,

	// Conditional-breakpoint editor — opened by Shift+clicking the gutter.
	// The dialog targets a frozen (file, line) tuple captured at open time
	// so a pane swap mid-edit can't retarget the write.
	show_breakpoint_condition:   bool,
	breakpoint_condition_dialog: BreakpointConditionDialog,

	// Shared scrolling log for the debug-output pane. Owned line strings;
	// trimmed at DEBUG_OUTPUT_MAX_LINES. The OutputPane in pane[1] reads
	// from this buffer, so opening / closing the pane never loses history.
	debug_output_lines:          [dynamic]string,
}

CURSOR_BLINK_RATE :: 0.53 // seconds
SCROLL_SMOOTHNESS :: 18.0 // higher = snappier; lower = floatier

// Hard upper bound for a single document load. Anything beyond this is treated
// as a corrupt input rather than being passed to the piece tree.
EDITOR_MAX_DOCUMENT_BYTES :: 1024 * 1024 * 1024 // 1 GiB

editor_init :: proc(editor: ^Editor, text_engine: ^ttf.TextEngine, font: ^ttf.Font, font_size: f32) {
	// Both panes start as empty, untitled editor panes — the user lands on
	// a blank document they can immediately type into, no welcome text, no
	// pre-loaded buffer. `editor_open_string_in_pane` later swaps these
	// out (or stashes them into `background_documents`) when a real file
	// is opened.
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
	editor.cursor_resize_ns = sdl3.CreateSystemCursor(.NS_RESIZE)
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

	menu_bar_init(&editor.menu_bar)
	editor_settings_init(&editor.settings)

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

	editor.breakpoint_color           = sdl3.FColor{0.92, 0.35, 0.35, 1.0} // saturated red
	editor.breakpoint_disabled_color  = sdl3.FColor{0.55, 0.40, 0.40, 1.0} // muted red
	editor.debug_current_line_color   = sdl3.FColor{0.28, 0.22, 0.12, 1.0} // dim amber

	debug_state_init(&editor.debug_state)
	editor.dap_clients = make(map[string]^dap.Client)
	// Sentinel — start_session asks the user to pick via F7 the first time
	// when more than one debug profile is loaded.
	editor.active_debug_configuration_index = -1

	project_config_init(&editor.project_config)

	syntax.init()

	// Restore the last-used project root (if any) so reopening the editor
	// drops the user straight back into the project they were working in.
	editor_persistence_load(editor)
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
	open_docs_dialog_destroy(&editor.open_docs_dialog)
	terminal_picker_destroy(&editor.terminal_picker)
	tasks_dialog_destroy(&editor.tasks_dialog)
	project_config_destroy(&editor.project_config)
	breakpoint_condition_dialog_destroy(&editor.breakpoint_condition_dialog)
	hover_popup_destroy(&editor.hover_popup)
	completion_popup_destroy(&editor.completion_popup)
	signature_popup_destroy(&editor.signature_popup)
	editor_lsp_destroy_all(editor)
	editor_settings_destroy(&editor.settings)
	for background_index in 0..<len(editor.background_documents) {
		editor_pane_destroy_in_place(&editor.background_documents[background_index])
	}
	if cap(editor.background_documents) > 0 { delete(editor.background_documents) }

	// Tear down every open terminal session. The pane teardown above only
	// cleared borrowed pointers — actual ownership lives here. After my
	// pane_content_destroy change the TerminalPane case is a no-op on the
	// terminal pointer, so this loop is the *only* call to terminal_destroy
	// and double-free is structurally impossible.
	for &entry in editor.terminals {
		if entry.terminal != nil {
			terminal.terminal_destroy(entry.terminal)
			entry.terminal = nil
		}
		if len(entry.build_profile_name) > 0 {
			delete(entry.build_profile_name)
			entry.build_profile_name = ""
		}
	}
	if cap(editor.terminals) > 0 { delete(editor.terminals) }
	markdown_fonts_destroy(&editor.markdown_fonts)
	editor_dap_destroy_all(editor)
	debug_state_destroy(&editor.debug_state)
	debug_output_destroy(editor)
	if len(editor.project_root) > 0 {
		delete(editor.project_root)
		editor.project_root = ""
	}
	syntax.destroy()
	if editor.cursor_default   != nil { sdl3.DestroyCursor(editor.cursor_default)   }
	if editor.cursor_resize_ew != nil { sdl3.DestroyCursor(editor.cursor_resize_ew) }
	if editor.cursor_resize_ns != nil { sdl3.DestroyCursor(editor.cursor_resize_ns) }
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
		editor_pane_destroy_in_place(&content_value)
	case TerminalPane:
		// Terminal lifetimes are owned by `Editor.terminals`, not by the
		// pane — the pane just holds a borrowed pointer. Clearing it here
		// (instead of calling terminal_destroy) lets the pane be replaced
		// or torn down without killing a session the user only meant to
		// hide. `editor_destroy` is the one place that actually destroys.
		content_value.terminal = nil
	case MarkdownPreviewPane:
		markdown_preview_pane_destroy(&content_value)
	case OutputPane:
		// Log buffer is owned by Editor.debug_output_lines, not the pane —
		// pane teardown just drops the scroll state struct.
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
}

// Height of the title strip at the top of every editor pane (filename area).
// Used by both render and mouse-coordinate translation.
@(private)
editor_title_bar_height :: proc(editor: ^Editor) -> i32 {
	return editor.line_height + 6
}

// Build a `ui.Context` populated with the editor's font metrics + the last
// known mouse position. Every place that used to construct the same struct
// literal inline now goes through this helper so the mouse fields are
// always present (otherwise hover-aware widgets would silently no-op).
@(private)
editor_make_ui_context :: proc(editor: ^Editor, renderer: ^sdl3.Renderer) -> ui.Context {
	return ui.Context{
		renderer        = renderer,
		font            = editor.font,
		engine          = editor.text_engine,
		character_width = editor.character_width,
		line_height     = editor.line_height,
		mouse_x         = editor.last_mouse_x,
		mouse_y         = editor.last_mouse_y,
	}
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

// Single sink for "this pane's document just changed". Flips every dirty flag
// that gates an idle/debounced rebuild so future flags (next time we add
// another debounced consumer) get picked up by every existing mutation site
// for free. Stamps `editor.clock` on the LSP edit timer so the didChange
// debounce in `editor_lsp_update` measures from the latest edit.
@(private)
pane_mark_document_modified :: proc(editor: ^Editor, editor_pane: ^EditorPane) {
	editor_pane.symbols_dirty       = true
	editor_pane.markdown_dirty      = true
	editor_pane.lsp_dirty           = true
	editor_pane.lsp_last_edit_time  = editor.clock
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

// Move focus to a specific pane by index. When the user asks for pane[1]
// (the right pane) but split isn't currently active, we open the split —
// the right pane is always populated (editor_init seeds it with an empty
// editor), so revealing it is enough; no new content gets created.
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

// Move the active pane's content to `target_pane_index`. If both panes
// have content we swap (so neither doc gets lost); if the destination is
// the empty initial editor pane, the source's content effectively shifts
// over and the source is left with the destination's old empty slot. When
// targeting the right pane while split is inactive, the split opens — the
// right pane is then revealed with the moved content.
//
// Focus follows the moved content so the user can keep typing without an
// extra Ctrl+Tab.
@(private)
editor_move_active_to_pane :: proc(editor: ^Editor, target_pane_index: int) {
	if target_pane_index < 0 || target_pane_index >= len(editor.panes) { return }
	if editor.active_pane_index == target_pane_index { return }

	if target_pane_index == 1 && !editor.split_active {
		editor.split_active = true
	}

	source_index := editor.active_pane_index
	// Swap the two contents wholesale. PaneContent is a union — both fields
	// own their payload (EditorPane.document, etc.) so the swap doesn't
	// alias any state. Borrowed-pointer panes (TerminalPane, OutputPane)
	// just shuffle the pointer, which is fine.
	source_content      := editor.panes[source_index].content
	destination_content := editor.panes[target_pane_index].content
	editor.panes[source_index].content      = destination_content
	editor.panes[target_pane_index].content = source_content

	// Close any Find / Replace bars pinned to the panes whose content just
	// shifted out from under them — the bar's `pane_index` would otherwise
	// point at a doc that's now somewhere else.
	if find_active(editor)    && (editor.find.pane_index    == source_index || editor.find.pane_index    == target_pane_index) { find_close(editor) }
	if replace_active(editor) && (editor.replace.pane_index == source_index || editor.replace.pane_index == target_pane_index) { replace_close(editor, false) }

	editor.active_pane_index = target_pane_index
	editor.cursor_visible = true
	editor.cursor_timer = 0
	editor_mark_dirty(editor)
}

// --- Multi-terminal session model -----------------------------------------
//
// Terminals live in `editor.terminals` and are independent of pane state.
// pane[1] is the "terminal slot" — when a terminal is being shown it holds
// a `TerminalPane` whose `terminal` field is a *borrowed* pointer aliasing
// the active entry. The terminal itself stays alive even when pane[1] is
// showing something else.
//
// F9               toggle visibility of the active terminal (creates the
//                  first one when the list is empty)
// Ctrl+F9          always create a new session and make it the active one
// Ctrl+Shift+F9    open a picker over `editor.terminals`
// Ctrl+F4          (in a terminal pane) destroy the active session

@(private)
TERMINAL_PANE_INDEX :: 1

@(private)
editor_is_terminal_visible :: proc(editor: ^Editor) -> bool {
	_, is_terminal := editor.panes[TERMINAL_PANE_INDEX].content.(TerminalPane)
	return is_terminal
}

@(private)
editor_active_terminal :: proc(editor: ^Editor) -> ^terminal.Terminal {
	if len(editor.terminals) == 0 { return nil }
	if editor.active_terminal_index < 0 || editor.active_terminal_index >= len(editor.terminals) { return nil }
	return editor.terminals[editor.active_terminal_index].terminal
}

// Display number of the active terminal entry, or 0 when nothing's open.
// Used by the title strip and the picker so the user sees the same stable
// "Terminal #N" label regardless of where it appears.
@(private)
editor_active_terminal_display_number :: proc(editor: ^Editor) -> int {
	if len(editor.terminals) == 0 { return 0 }
	if editor.active_terminal_index < 0 || editor.active_terminal_index >= len(editor.terminals) { return 0 }
	return editor.terminals[editor.active_terminal_index].display_number
}

// Show the active terminal in pane[1], stashing whatever was there into the
// pane's `saved_content` slot. No-op when no terminals exist or one is
// already visible — the caller is expected to handle those.
@(private)
editor_terminal_show :: proc(editor: ^Editor) {
	if editor_is_terminal_visible(editor) { return }
	active_terminal := editor_active_terminal(editor); if active_terminal == nil { return }

	pane := &editor.panes[TERMINAL_PANE_INDEX]
	// Drop any prior saved_content defensively — a stale stash would leak
	// the doc we'd be overwriting.
	if pane.has_saved_content {
		pane_content_destroy(&pane.saved_content)
		pane.has_saved_content = false
	}
	pane.saved_content      = pane.content
	pane.saved_split_active = editor.split_active
	pane.has_saved_content  = true

	pane.content             = TerminalPane{ terminal = active_terminal }
	editor.split_active      = true
	editor.active_pane_index = TERMINAL_PANE_INDEX
}

// Hide the currently-visible terminal: restore pane[1] from `saved_content`
// (and the matching `split_active` snapshot) without destroying anything in
// `editor.terminals`. The session keeps running in the background.
@(private)
editor_terminal_hide :: proc(editor: ^Editor) {
	if !editor_is_terminal_visible(editor) { return }
	pane := &editor.panes[TERMINAL_PANE_INDEX]

	// Clear the borrowed pointer before swapping content out — keeps the
	// pane_content_destroy fallthrough below from doing anything to a
	// terminal that's still owned by `editor.terminals`.
	if terminal_pane, is_terminal := &pane.content.(TerminalPane); is_terminal {
		terminal_pane.terminal = nil
	}

	if pane.has_saved_content {
		pane.content            = pane.saved_content
		editor.split_active     = pane.saved_split_active
		pane.saved_content      = PaneContent{}
		pane.saved_split_active = false
		pane.has_saved_content  = false
	} else {
		pane.content        = PaneContent{}
		editor.split_active = false
	}

	if !editor.split_active { editor.active_pane_index = 0 }
}

// Spawn a new shell session and make it the active terminal. If the slot is
// already visible the borrowed pointer in pane[1] swaps to the new one; if
// hidden, this also makes the slot visible.
@(private)
editor_terminal_create_new :: proc(editor: ^Editor) {
	pane := &editor.panes[TERMINAL_PANE_INDEX]
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

	default_foreground := terminal.Color{ editor.foreground_color.r, editor.foreground_color.g, editor.foreground_color.b, editor.foreground_color.a }
	default_background := terminal.Color{ editor.background_color.r, editor.background_color.g, editor.background_color.b, editor.background_color.a }

	// When a project root is set, anchor the shell there so terminal commands
	// run relative to the project regardless of where the editor was launched
	// from. Otherwise inherit the editor's own cwd ("" = pass nil to spawn).
	new_terminal := terminal.terminal_new(row_count, column_count, default_foreground, default_background, editor.project_root)
	if new_terminal == nil { return }

	editor.next_terminal_display_number += 1
	append(&editor.terminals, TerminalEntry{
		terminal       = new_terminal,
		display_number = editor.next_terminal_display_number,
	})
	editor.active_terminal_index = len(editor.terminals) - 1

	if editor_is_terminal_visible(editor) {
		// Already showing a different session — swap the borrowed pointer
		// in place rather than re-stashing pane[1].
		if terminal_pane, is_terminal := &editor.panes[TERMINAL_PANE_INDEX].content.(TerminalPane); is_terminal {
			terminal_pane.terminal = new_terminal
		}
		editor.active_pane_index = TERMINAL_PANE_INDEX
	} else {
		editor_terminal_show(editor)
	}
}

// Spawn a one-shot terminal session running `command_line` instead of the
// default interactive shell. Tagged as a build job so the per-frame poll in
// `editor_dap_update` can watch its exit code and (when the build belongs
// to a build-then-debug chain) auto-start the queued debug session on
// success. Returns the new terminal pointer or nil on failure.
@(private)
editor_terminal_create_for_build :: proc(editor: ^Editor, command_line: string, working_directory: string, build_profile_name: string, pending_debug_profile_index: int) -> ^terminal.Terminal {
	pane := &editor.panes[TERMINAL_PANE_INDEX]
	pane_rectangle := pane.rectangle
	if pane_rectangle.w == 0 || pane_rectangle.h == 0 {
		pane_rectangle = sdl3.Rect{ x = 0, y = 0, w = 720, h = 480 }
	}
	character_width := editor.character_width;  if character_width <= 0 { character_width = 8 }
	line_height     := editor.line_height;      if line_height     <= 0 { line_height     = 16 }

	row_count    := max(i32(4),  (pane_rectangle.h - editor_title_bar_height(editor)) / line_height)
	column_count := max(i32(10), pane_rectangle.w / character_width)

	default_foreground := terminal.Color{ editor.foreground_color.r, editor.foreground_color.g, editor.foreground_color.b, editor.foreground_color.a }
	default_background := terminal.Color{ editor.background_color.r, editor.background_color.g, editor.background_color.b, editor.background_color.a }

	cwd := working_directory
	if len(cwd) == 0 { cwd = editor.project_root }

	new_terminal := terminal.terminal_new(row_count, column_count, default_foreground, default_background, cwd, command_line)
	if new_terminal == nil { return nil }

	editor.next_terminal_display_number += 1
	append(&editor.terminals, TerminalEntry{
		terminal                    = new_terminal,
		display_number              = editor.next_terminal_display_number,
		is_build_job                = true,
		build_profile_name          = strings.clone(build_profile_name),
		pending_debug_profile_index = pending_debug_profile_index,
	})
	editor.active_terminal_index = len(editor.terminals) - 1

	if editor_is_terminal_visible(editor) {
		if terminal_pane, is_terminal := &editor.panes[TERMINAL_PANE_INDEX].content.(TerminalPane); is_terminal {
			terminal_pane.terminal = new_terminal
		}
		editor.active_pane_index = TERMINAL_PANE_INDEX
	} else {
		editor_terminal_show(editor)
	}
	return new_terminal
}

// Kill the active terminal session. If others remain, the next one in the
// list becomes active and the visible pane (if any) swaps over to it. If the
// list empties, pane[1] is restored from saved_content.
@(private)
editor_terminal_destroy_active :: proc(editor: ^Editor) {
	if len(editor.terminals) == 0 { return }
	if editor.active_terminal_index < 0 || editor.active_terminal_index >= len(editor.terminals) { return }

	was_visible := editor_is_terminal_visible(editor)

	doomed_terminal := editor.terminals[editor.active_terminal_index].terminal
	if doomed_entry_name := editor.terminals[editor.active_terminal_index].build_profile_name; len(doomed_entry_name) > 0 {
		delete(doomed_entry_name)
	}
	ordered_remove(&editor.terminals, editor.active_terminal_index)

	// Clear the borrowed pointer in pane[1] *before* terminal_destroy so a
	// concurrent render path can't latch onto a half-freed handle.
	if was_visible {
		if terminal_pane, is_terminal := &editor.panes[TERMINAL_PANE_INDEX].content.(TerminalPane); is_terminal {
			terminal_pane.terminal = nil
		}
	}
	if doomed_terminal != nil { terminal.terminal_destroy(doomed_terminal) }

	if len(editor.terminals) == 0 {
		editor.active_terminal_index = 0
		if was_visible { editor_terminal_hide(editor) }
		return
	}

	// Clamp the active index to the new list size; the most natural fall-
	// through pick is the entry that just shifted into the removed slot
	// (same index unless we killed the last entry).
	if editor.active_terminal_index >= len(editor.terminals) {
		editor.active_terminal_index = len(editor.terminals) - 1
	}

	if was_visible {
		new_active := editor_active_terminal(editor)
		if terminal_pane, is_terminal := &editor.panes[TERMINAL_PANE_INDEX].content.(TerminalPane); is_terminal {
			terminal_pane.terminal = new_active
		}
	}
}

// F9: hide if currently visible, show the active one if hidden, or create
// the first session when none exist yet.
@(private)
editor_toggle_terminal :: proc(editor: ^Editor) {
	if editor_is_terminal_visible(editor) {
		editor_terminal_hide(editor)
		return
	}
	if len(editor.terminals) == 0 {
		editor_terminal_create_new(editor)
		return
	}
	editor_terminal_show(editor)
}

// --- Public open-string entry points --------------------------------------

editor_open_string :: proc(editor: ^Editor, content_text: string) {
	editor_open_string_in_pane(editor, editor.active_pane_index, content_text)
}

// Load a string into a specific pane. If a `file_path` is supplied and the
// document is already open (in any pane or in `background_documents`), this
// switches to the existing copy rather than reloading — the user's cursor,
// scroll, undo history and unsaved edits are preserved. Otherwise the target
// pane's current EditorPane is moved into `background_documents` (if it's
// worth keeping — has a path, override, or unsaved changes) and a fresh
// editor pane is installed in its place.
editor_open_string_in_pane :: proc(editor: ^Editor, pane_index: int, content_text: string, file_path: string = "") {
	if pane_index < 0 || pane_index >= len(editor.panes) { return }

	// Dedupe: if this path is already loaded, switch to it instead of doing a
	// fresh load. Avoids two EditorPanes diverging from the same on-disk file
	// and discards the (already-read) `content_text` argument — that read is
	// the caller's choice, not something we can undo here.
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

	// Stash whatever was in the target pane so it can be reached again from
	// the F4 picker. Untitled-and-clean panes are not worth stashing and are
	// just destroyed by `pane_destroy` below.
	pane_stash_editor(editor, pane_index)

	safe_content := content_text
	if len(safe_content) < 0 || len(safe_content) > EDITOR_MAX_DOCUMENT_BYTES {
		safe_content = ""
	}

	// Tear down whatever remains in the pane and install a fresh editor.
	pane_destroy(&editor.panes[pane_index])

	new_editor_pane: EditorPane
	document.document_init(&new_editor_pane.document, safe_content)
	if len(file_path) > 0 {
		// Normalize the on-disk path so display / comparison stays
		// consistent regardless of whether the OS handed us back slashes
		// or our own code joined with forward slashes.
		new_editor_pane.file_path = path_normalize(file_path)
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

	// Notify the LSP layer that a new document is open in this pane (if its
	// language has an LSP entry configured). Safe to call when no LSP is
	// available — the proc short-circuits.
	if editor_pane := pane_as_editor(&editor.panes[pane_index]); editor_pane != nil {
		editor_lsp_pane_opened(editor, editor_pane)
	}
}

// Drop a fresh untitled EditorPane into the given pane, destroying whatever
// was there. Use this on the Ctrl+F4 close path — `editor_open_string_in_pane`
// would stash the doc the user is asking to close, which is wrong.
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

// Move the target pane's EditorPane into `background_documents` if it's
// worth keeping (has a path, has a display-title override, or is dirty).
// On success the pane is left with an empty `PaneContent{}` — the caller is
// expected to install new content right after. Returns true when a stash
// actually happened.
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

	// Find/Replace bars are pinned to a specific pane index; the doc we are
	// moving away is the one the bar was bound to, so close the bar before
	// the pane content changes underneath it.
	if find_active(editor)    && editor.find.pane_index    == pane_index { find_close(editor) }
	if replace_active(editor) && editor.replace.pane_index == pane_index { replace_close(editor, false) }

	// Append a value-copy; ownership of the heap-allocated fields transfers
	// to the new slot. We then *both* zero out the EditorPane fields in the
	// union storage AND set the union to its nil variant. The belt-and-
	// suspenders matters: if a later destroy path somehow still observes the
	// union as an EditorPane variant, every heap-pointer field is now nil/
	// empty so `editor_pane_destroy_in_place` short-circuits on each one
	// instead of double-freeing what we just transferred to the background.
	append(&editor.background_documents, editor_pane_ptr^)
	editor_pane_ptr^ = EditorPane{}
	pane.content = PaneContent{}
	return true
}

// Pull a background document into the target pane, stashing the pane's
// current content (if worth keeping) on the way out. Used both by
// `editor_open_string_in_pane` when a requested path is found in the stash
// and by the F4 picker when the user clicks a row.
@(private)
editor_swap_background_into_pane :: proc(editor: ^Editor, pane_index, background_index: int) {
	if pane_index       < 0 || pane_index       >= len(editor.panes)               { return }
	if background_index < 0 || background_index >= len(editor.background_documents) { return }

	// Lift the target out of the list first. Subsequent mutations to
	// `background_documents` (the stash that follows) can then freely append
	// without shifting the index we already captured.
	restored_editor_pane := editor.background_documents[background_index]
	ordered_remove(&editor.background_documents, background_index)

	// Move the pane's existing editor into the background, OR — if it isn't
	// stash-worthy — destroy it directly. Either way the pane is empty
	// afterwards and ready to receive the restored content.
	if !pane_stash_editor(editor, pane_index) {
		pane_destroy(&editor.panes[pane_index])
		editor.panes[pane_index].content = PaneContent{}
	}

	editor.panes[pane_index].content = restored_editor_pane
}

// Find an open EditorPane whose `file_path` matches (case-insensitively).
// Returns `(pane_index, -1)` when the doc is in a visible pane, `(-1,
// background_index)` when it's stashed, and `(-1, -1)` when not open.
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
	return editor.show_help || editor.show_browse || editor.show_symbols || editor.show_find_in_files || editor.show_replace_in_files || editor.show_save_as || editor.show_close_confirm || editor.show_git_history || editor.show_open_docs || editor.show_terminal_picker || editor.show_tasks_dialog || editor.show_breakpoint_condition || editor.menu_bar.open_menu_index >= 0
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
		// Normalize incoming path to platform-native separators so the
		// status bar, title strips, and debug output log all show one
		// consistent form regardless of whether the caller sourced the
		// path from F2 (OS-native) or from JSON config (forward slashes).
		editor.project_root = path_normalize(path)
	}
	// Reload per-project profiles whenever the root moves — the new root
	// might have its own `.odit/project.json`, and the old one's profiles
	// shouldn't follow the user across projects.
	project_config_reload(editor)
	// Forget any prior debug selection — indices into `debug_profiles` are
	// no longer meaningful against the new project's list.
	editor.active_debug_configuration_index = -1
	// Persist the new root so the next session can resume here.
	editor_persistence_save(editor)
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
@(private)
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

// Leaf package describing the contract between the editor and each
// modal/dialog subpackage.
//
// Two vtables live here:
//
//   * `Binding` — editor → subpackage. Lifecycle + dispatch +
//     visibility for one registered subpackage. The editor holds a
//     `[dynamic]Binding`, iterates them in priority order on each
//     event / frame, and never references subpackage symbols
//     directly.
//
//   * `EditorAPI` — subpackage → editor. The editor populates this
//     once at init with every primitive any subpackage needs
//     (pane / file ops, project-root state, etc.). Subpackages
//     receive `^EditorAPI` on every dispatch / render and route
//     all editor-side work through it.
//
// This is the only package that both `editor` and the subpackages
// import. Subpackages never import `editor`; `editor` never imports
// `editor` types into subpackages. The cycle is broken.
package binding

import "base:runtime"
import "vendor:sdl3"

import "../../dap"
import "../../markdown"
import "../../ui"

// Per-subpackage vtable. State pointer is opaque to the editor —
// the subpackage knows how to interpret it.
//
// `handle_event` returns:
//   consumed     — true if the subpackage owned this event (editor
//                  should stop further dispatch).
//   needs_redraw — true if anything visible changed.
Binding :: struct {
	name:         string,
	state:        rawptr,
	// Some bindings (passive popups: hover, signature help, inline
	// completion) don't consume input but still need to render and
	// update each frame. Set `passive = true` so the editor's event
	// loop skips them when looking for the focused modal.
	passive:      bool,
	visible:      proc(state: rawptr) -> bool,
	destroy:      proc(state: rawptr),
	handle_event: proc(state: rawptr, api: ^EditorAPI, event: ^sdl3.Event) -> (consumed: bool, needs_redraw: bool),
	render:       proc(state: rawptr, api: ^EditorAPI, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, viewport_width, viewport_height: i32),
}

// Editor primitives exposed to subpackages. `editor` is always
// passed as the first argument (opaque rawptr — the editor casts it
// back internally). New entries are added here as new subpackages
// need them.
EditorAPI :: struct {
	editor: rawptr,

	// Pane / document ops.
	find_open_document:        proc(editor: rawptr, file_path: string) -> (pane_index, background_index: int),
	open_string_in_pane:       proc(editor: rawptr, pane_index: int, content: string, file_path: string),
	swap_background_into_pane: proc(editor: rawptr, pane_index, background_index: int),
	active_pane_index:         proc(editor: rawptr) -> int,
	set_active_pane_index:     proc(editor: rawptr, pane_index: int),
	set_split_active:          proc(editor: rawptr, value: bool),

	// Higher-level helpers used by activate paths. Each returns an
	// error string ("" on success) so callers can surface failures.
	//
	// `open_file_at_path` reads the file from disk (with dedupe
	// against open / background docs) and installs it in a pane.
	// `replace_active_pane` chooses the active pane; otherwise the
	// caller can pass `split_secondary = true` to land it in pane 1.
	open_file_at_path:         proc(editor: rawptr, path: string, split_secondary: bool, allocator: runtime.Allocator) -> (error_message: string),

	// Place the active pane's cursor at (line, column) and anchor
	// the line near the top of the pane. Used by symbol-jump and
	// find-in-files activate.
	jump_active_pane_to:       proc(editor: rawptr, line, column: u32),

	// Active pane's open file path ("" when untitled / non-editor pane).
	active_pane_file_path:     proc(editor: rawptr) -> string,

	// If the active pane has a short single-line selection, returns
	// it (in `allocator`) and ok=true. Used to seed the find-in-files
	// query from selection.
	active_pane_short_selection: proc(editor: rawptr, max_bytes: int, allocator: runtime.Allocator) -> (text: string, ok: bool),

	// Open `content` in the pane opposite `source_pane_index`,
	// forces split, sets language from `file_path_for_syntax`, sets
	// display title override (caller-allocated; pane takes ownership).
	// Used by git history.
	open_string_in_opposite_pane: proc(editor: rawptr, source_pane_index: int, content: string, file_path_for_syntax: string, display_title_override: string),

	// Project root.
	project_root:              proc(editor: rawptr) -> string,
	set_project_root:          proc(editor: rawptr, path: string),
	path_inside_project_root:  proc(editor: rawptr, path: string) -> bool,

	// UI metrics.
	line_height:               proc(editor: rawptr) -> i32,
	character_width:           proc(editor: rawptr) -> i32,

	// --- LSP popups (hover / signature / completion) ---------------
	// All operate against the active pane. Request* return true when
	// a request actually went out. Poll* drain the latest in-flight
	// response; ok=false when nothing is ready.

	lsp_request_hover:          proc(editor: rawptr) -> bool,
	lsp_poll_hover:             proc(editor: rawptr, allocator: runtime.Allocator) -> (text: string, ok: bool),

	lsp_request_signature_help: proc(editor: rawptr) -> bool,
	lsp_poll_signature_help:    proc(editor: rawptr, allocator: runtime.Allocator) -> (info: SignatureInfo, ok: bool),

	lsp_request_completion:     proc(editor: rawptr) -> bool,
	lsp_poll_completion:        proc(editor: rawptr, allocator: runtime.Allocator) -> (items: []CompletionItem, ok: bool),

	// Apply an accepted completion to the document at the cursor on
	// `pane_index`. Walks back over the identifier prefix and replaces
	// it with `insert_text`.
	apply_completion_at_cursor: proc(editor: rawptr, pane_index: int, insert_text: string),

	// Markdown rendering context used by hover + signature popups.
	markdown_context:           proc(editor: rawptr, renderer: ^sdl3.Renderer) -> markdown.Context,

	// Pane / cursor / anchor primitives used by popups.
	active_pane_cursor:         proc(editor: rawptr) -> ActivePaneCursor,
	pane_anchor:                proc(editor: rawptr, pane_index: int, anchor_line: u32) -> PaneAnchor,

	// Editor theme exposed for popup chrome construction.
	theme:                      proc(editor: rawptr) -> Theme,

	// --- Project-config / build+debug profiles ----------------------
	project_loaded_path:        proc(editor: rawptr) -> string,
	list_build_profiles:        proc(editor: rawptr, allocator: runtime.Allocator) -> []BuildProfileSummary,
	list_debug_profiles:        proc(editor: rawptr, allocator: runtime.Allocator) -> []DebugProfileSummary,
	run_build_profile:          proc(editor: rawptr, build_index: int),
	start_debug_profile:        proc(editor: rawptr, debug_index: int),

	// --- DAP (debugger) primitives ---------------------------------
	active_dap_client:          proc(editor: rawptr) -> ^dap.Client,
	dap_action:                 proc(editor: rawptr, action: DapAction),
	dap_flush_file_breakpoints: proc(editor: rawptr, path: string),

	// --- Menu action dispatch --------------------------------------
	// The menu subpackage emits its own ActionKind via this
	// callback; the editor's trampoline routes to the actual
	// editor proc. Typed as a rawptr (the ActionKind value cast to
	// uint) so binding/binding.odin doesn't have to import the
	// menu subpackage and avoid a cycle.
	dispatch_menu_action:       proc(editor: rawptr, action: u32),
}

DapAction :: enum {
	StartSession,
	StopSession,
	Continue,
	StepOver,
	StepInto,
	StepOut,
}

// --- Neutral payload types -----------------------------------------------

SignatureInfo :: struct {
	label:         string,
	documentation: string,
	active_start:  i32,
	active_end:    i32,
}

CompletionItem :: struct {
	label:       string,
	detail:      string,
	insert_text: string,
}

ActivePaneCursor :: struct {
	pane_index:    int,
	cursor_line:   u32,
	cursor_column: u32,
	cursor_offset: u32,
	is_editor:     bool,
}

PaneAnchor :: struct {
	cursor_screen_top_y: i32,
	cursor_line_height:  i32,
	character_width:     i32,
	pane_left_x:         i32,
	pane_top_y:          i32,
	text_left_x:         i32, // post-gutter
}

Theme :: struct {
	background_color:          sdl3.FColor,
	foreground_color:          sdl3.FColor,
	status_bar_background:     sdl3.FColor,
	status_bar_foreground:     sdl3.FColor,
	divider_color:             sdl3.FColor,
	cursor_color:              sdl3.FColor,
	selection_color:           sdl3.FColor,
	line_number_color:         sdl3.FColor,
	syntax_keyword_foreground: sdl3.FColor,
	syntax_type_foreground:    sdl3.FColor,
	breakpoint_color:          sdl3.FColor,
	breakpoint_disabled_color: sdl3.FColor,
	git_deleted_foreground:    sdl3.FColor,
}

BuildProfileSummary :: struct {
	name:        string,
	description: string,
}

DebugProfileSummary :: struct {
	name:          string,
	build_profile: string,
}

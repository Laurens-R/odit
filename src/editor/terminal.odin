package editor

import "base:runtime"
import "core:strings"
import "vendor:sdl3"

import "../terminal"
import terminal_picker_pkg "./terminal_picker"
import "../ui"

// Multi-terminal session model + the TerminalPane that surfaces them.
//
// Terminals live in `editor.terminals` and are independent of pane
// state. pane[1] is the "terminal slot" — when a terminal is being
// shown it holds a `TerminalPane` whose `terminal` field is a
// *borrowed* pointer aliasing the active entry. The terminal itself
// stays alive even when pane[1] is showing something else.
//
// F9             toggle visibility of the active terminal (creates
//                the first one when the list is empty)
// Ctrl+F9        always create a new session and make it active
// Ctrl+Shift+F9  open a picker over `editor.terminals`
// Ctrl+F4        (in a terminal pane) destroy the active session

@(private)
TERMINAL_PANE_INDEX :: 1

// One entry in `editor.terminals`. `display_number` is a stable
// 1-based label used in the title strip and picker — when a
// terminal is destroyed the others keep their numbers instead of
// shifting, so the user's mental map ("Terminal 3") stays valid.
@(private)
TerminalEntry :: struct {
	terminal:       ^terminal.Terminal,
	display_number: int,
	// Task-runner bookkeeping. `is_build_job=true` marks a one-shot
	// session spawned by the Tasks dialog so the per-frame poll knows
	// to watch its child's exit code (rather than treating it as an
	// interactive shell that lives until the user closes it). When a
	// build-job terminal exits with code 0 *and*
	// `pending_debug_profile_index >= 0`, the editor auto-starts the
	// queued debug session.
	is_build_job:                bool,
	build_profile_name:          string, // owned; "" for interactive shells
	pending_debug_profile_index: int,    // -1 = standalone build
	build_exit_observed:         bool,   // set once exit has been handled
}

// The pane content variant that displays a terminal. Borrowed
// pointer — the terminal lifetime lives on `editor.terminals`.
TerminalPane :: struct {
	terminal:  ^terminal.Terminal,
	scrollbar: ui.Scrollbar,
}

// --- Lookups -------------------------------------------------------------

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

@(private)
editor_active_terminal_display_number :: proc(editor: ^Editor) -> int {
	if len(editor.terminals) == 0 { return 0 }
	if editor.active_terminal_index < 0 || editor.active_terminal_index >= len(editor.terminals) { return 0 }
	return editor.terminals[editor.active_terminal_index].display_number
}

// --- Show / hide / create / destroy --------------------------------------

// Show the active terminal in pane[1], stashing whatever was there
// into the pane's `saved_content` slot. No-op when no terminals
// exist or one is already visible.
@(private)
editor_terminal_show :: proc(editor: ^Editor) {
	if editor_is_terminal_visible(editor) { return }
	active_terminal := editor_active_terminal(editor); if active_terminal == nil { return }

	pane := &editor.panes[TERMINAL_PANE_INDEX]
	// Drop any prior saved_content defensively — a stale stash would
	// leak the doc we'd be overwriting.
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

// Hide the visible terminal: restore pane[1] from `saved_content`
// (and the matching `split_active` snapshot) without destroying
// anything in `editor.terminals`. The session keeps running.
@(private)
editor_terminal_hide :: proc(editor: ^Editor) {
	if !editor_is_terminal_visible(editor) { return }
	pane := &editor.panes[TERMINAL_PANE_INDEX]

	// Clear the borrowed pointer before swapping content out — keeps
	// the pane_content_destroy fallthrough below from doing anything
	// to a terminal that's still owned by `editor.terminals`.
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

// Spawn a new shell session and make it the active terminal. If the
// slot is already visible the borrowed pointer swaps to the new one;
// if hidden, this also makes the slot visible.
@(private)
editor_terminal_create_new :: proc(editor: ^Editor) {
	pane := &editor.panes[TERMINAL_PANE_INDEX]
	pane_rectangle := pane.rectangle
	if pane_rectangle.w == 0 || pane_rectangle.h == 0 {
		// Pane hasn't been laid out yet; conjure something reasonable
		// so the shell gets a sane initial size.
		pane_rectangle = sdl3.Rect{ x = 0, y = 0, w = 720, h = 480 }
	}
	character_width := editor.character_width;  if character_width <= 0 { character_width = 8 }
	line_height     := editor.line_height;      if line_height     <= 0 { line_height     = 16 }

	row_count    := max(i32(4),  (pane_rectangle.h - editor_title_bar_height(editor)) / line_height)
	column_count := max(i32(10), pane_rectangle.w / character_width)

	default_foreground := terminal.Color{ editor.foreground_color.r, editor.foreground_color.g, editor.foreground_color.b, editor.foreground_color.a }
	default_background := terminal.Color{ editor.background_color.r, editor.background_color.g, editor.background_color.b, editor.background_color.a }

	// When a project root is set, anchor the shell there so terminal
	// commands run relative to the project regardless of where the
	// editor was launched from.
	new_terminal := terminal.terminal_new(row_count, column_count, default_foreground, default_background, editor.project_root)
	if new_terminal == nil { return }

	editor.next_terminal_display_number += 1
	append(&editor.terminals, TerminalEntry{
		terminal       = new_terminal,
		display_number = editor.next_terminal_display_number,
	})
	editor.active_terminal_index = len(editor.terminals) - 1

	if editor_is_terminal_visible(editor) {
		// Already showing a different session — swap the borrowed
		// pointer in place rather than re-stashing pane[1].
		if terminal_pane, is_terminal := &editor.panes[TERMINAL_PANE_INDEX].content.(TerminalPane); is_terminal {
			terminal_pane.terminal = new_terminal
		}
		editor.active_pane_index = TERMINAL_PANE_INDEX
	} else {
		editor_terminal_show(editor)
	}
}

// Spawn a one-shot terminal session running `command_line` instead
// of the default interactive shell. Tagged as a build job so the
// per-frame poll in `editor_dap_update` can watch its exit code and
// (when the build belongs to a build-then-debug chain) auto-start
// the queued debug session on success. Returns the new terminal
// pointer or nil on failure.
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

// Kill the active terminal session. If others remain, the next one
// becomes active and the visible pane (if any) swaps over to it.
// If the list empties, pane[1] is restored from saved_content.
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

	// Clear the borrowed pointer in pane[1] *before* terminal_destroy
	// so a concurrent render path can't latch onto a half-freed
	// handle.
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

	// Clamp the active index; the most natural fall-through is the
	// entry that just shifted into the removed slot.
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

// F9: hide if visible, show the active one if hidden, or create the
// first session when none exist yet.
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

// --- terminal_picker host trampolines -----------------------------------
//
// The picker calls these via its Host callbacks; they cast
// `user_data` back to `^Editor` and apply the requested mutation.
// Keeps the terminal_picker subpackage's import graph clean: it
// never depends on the editor package.

@(private)
terminal_picker_host_list_entries :: proc(user_data: rawptr, allocator: runtime.Allocator) -> []terminal_picker_pkg.Entry {
	editor := cast(^Editor)user_data
	entries := make([]terminal_picker_pkg.Entry, len(editor.terminals), allocator)
	for entry, entry_index in editor.terminals {
		entries[entry_index] = terminal_picker_pkg.Entry{
			display_number = entry.display_number,
			is_active      = entry_index == editor.active_terminal_index,
		}
	}
	return entries
}

@(private)
terminal_picker_host_initial_selection :: proc(user_data: rawptr) -> int {
	editor := cast(^Editor)user_data
	return max(0, editor.active_terminal_index)
}

// Switch the active terminal to whichever entry the picker
// activated.
@(private)
terminal_picker_host_activate :: proc(user_data: rawptr, entry_index: int) {
	editor := cast(^Editor)user_data
	if entry_index < 0 || entry_index >= len(editor.terminals) { return }
	editor.active_terminal_index = entry_index

	if editor_is_terminal_visible(editor) {
		if terminal_pane, is_terminal := &editor.panes[TERMINAL_PANE_INDEX].content.(TerminalPane); is_terminal {
			terminal_pane.terminal = editor_active_terminal(editor)
		}
		editor.active_pane_index = TERMINAL_PANE_INDEX
	} else {
		editor_terminal_show(editor)
	}
}

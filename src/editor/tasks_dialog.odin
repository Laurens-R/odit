package editor

import "core:fmt"
import "core:strings"
import "vendor:sdl3"

import "../terminal"
import "../ui"

// F7 modal — lists every build profile + debug profile from the active
// project's `.odit/project.json` and lets the user kick one off. Picking a
// build profile spawns it inside a fresh terminal session so the user can
// watch the live output. Picking a debug profile runs its linked build
// profile first (if any) in the same kind of terminal session; on exit 0
// the queued debug launch fires automatically, on a non-zero exit the
// terminal stays put so the failure can be inspected.
//
// Replaces the prior `debug_config_picker.odin`. Same modal-dialog shape as
// `terminal_picker.odin` minus the filter — task lists are short.

@(private)
TaskEntryKind :: enum {
	BuildProfile,
	DebugProfile,
}

@(private)
TaskEntry :: struct {
	kind:          TaskEntryKind,
	profile_index: int, // index into project_config.build_profiles or .debug_profiles
}

@(private)
TasksDialog :: struct {
	entries:           [dynamic]TaskEntry,
	selected_index:    int,
	scroll_offset:     int,
	visible_row_count: int,
	row_rectangles:    [dynamic]sdl3.FRect, // rebuilt every render; one per visible row
}

// --- Lifecycle -----------------------------------------------------------

@(private)
tasks_dialog_destroy :: proc(dialog: ^TasksDialog) {
	if cap(dialog.entries)        > 0 { delete(dialog.entries)        }
	if cap(dialog.row_rectangles) > 0 { delete(dialog.row_rectangles) }
	dialog^ = TasksDialog{}
}

@(private)
tasks_dialog_open :: proc(editor: ^Editor) {
	dialog := &editor.tasks_dialog
	clear(&dialog.entries)
	for _, build_index in editor.project_config.build_profiles {
		append(&dialog.entries, TaskEntry{ kind = .BuildProfile, profile_index = build_index })
	}
	for _, debug_index in editor.project_config.debug_profiles {
		append(&dialog.entries, TaskEntry{ kind = .DebugProfile, profile_index = debug_index })
	}
	dialog.selected_index = 0
	dialog.scroll_offset  = 0
	editor.show_tasks_dialog = true
}

@(private)
tasks_dialog_close :: proc(editor: ^Editor) {
	editor.show_tasks_dialog = false
}

// --- Selection / activation ---------------------------------------------

@(private="file")
tasks_dialog_move_selection :: proc(editor: ^Editor, delta: int) {
	dialog := &editor.tasks_dialog
	count := len(dialog.entries)
	if count == 0 { return }
	new_selection := dialog.selected_index + delta
	if new_selection < 0      { new_selection = 0 }
	if new_selection >= count { new_selection = count - 1 }
	dialog.selected_index = new_selection
}

// Run whatever the user picked. For builds: spawn it. For debug profiles:
// if linked to a build, run that build with the debug profile queued as a
// follow-up; otherwise launch immediately.
@(private="file")
tasks_dialog_activate :: proc(editor: ^Editor) {
	dialog := &editor.tasks_dialog
	count := len(dialog.entries)
	if dialog.selected_index < 0 || dialog.selected_index >= count { return }
	entry := dialog.entries[dialog.selected_index]
	switch entry.kind {
	case .BuildProfile:
		tasks_run_build_profile(editor, entry.profile_index, /*pending_debug_index=*/ -1)
	case .DebugProfile:
		tasks_start_debug_profile(editor, entry.profile_index)
	}
	tasks_dialog_close(editor)
}

// Spawn the build profile at `build_index` inside a fresh terminal session
// so the user can watch the output. `pending_debug_index >= 0` queues a
// debug launch to run once the build exits with code 0; the per-frame
// terminal-exit poll in `editor_dap_update` triggers it. Returns false
// when the spawn itself failed (terminal stays hidden / closed).
@(private)
tasks_run_build_profile :: proc(editor: ^Editor, build_index: int, pending_debug_index: int) -> bool {
	config := &editor.project_config
	if build_index < 0 || build_index >= len(config.build_profiles) { return false }
	profile := &config.build_profiles[build_index]
	command_tokens := build_profile_active_command(profile)
	if command_tokens == nil || len(command_tokens) == 0 {
		debug_status_set(editor, fmt.tprintf("Build '%s' has no command for this platform", profile.name))
		return false
	}

	// Expand placeholders in every command token + working_dir against the
	// build profile's own name (so it appears as {build_name}).
	command_line := tasks_format_command_line(editor, command_tokens, profile.name)
	working_dir  := project_expand_placeholders(profile.working_dir, editor, profile.name)

	new_terminal := editor_terminal_create_for_build(editor, command_line, working_dir, profile.name, pending_debug_index)
	if new_terminal == nil {
		debug_status_set(editor, fmt.tprintf("Failed to start build: %s", profile.name))
		return false
	}
	debug_status_set(editor, fmt.tprintf("Building: %s", profile.name))
	editor_mark_dirty(editor)
	return true
}

// Build the single command-line string the PTY child swallows. Quotes any
// token containing whitespace; mirrors the quoting scheme used by the
// LSP/DAP process spawn helpers so users don't get surprised by argv
// boundaries differing across paths.
@(private="file")
tasks_format_command_line :: proc(editor: ^Editor, tokens: []string, build_name: string) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, 0, 128, context.temp_allocator)
	for token, token_index in tokens {
		if token_index > 0 { strings.write_byte(&builder, ' ') }
		expanded := project_expand_placeholders(token, editor, build_name)
		needs_quotes := false
		for character in expanded {
			if character == ' ' || character == '\t' { needs_quotes = true; break }
		}
		if needs_quotes {
			strings.write_byte(&builder, '"')
			strings.write_string(&builder, expanded)
			strings.write_byte(&builder, '"')
		} else {
			strings.write_string(&builder, expanded)
		}
	}
	return strings.to_string(builder)
}

// Launch a debug profile. If the profile lists a `build_profile`, that
// build runs first and the debug launch is queued behind it. With no link
// (or with an unknown name) we launch immediately.
@(private)
tasks_start_debug_profile :: proc(editor: ^Editor, debug_index: int) {
	config := &editor.project_config
	if debug_index < 0 || debug_index >= len(config.debug_profiles) { return }
	profile := &config.debug_profiles[debug_index]

	if len(profile.build_profile) > 0 {
		build_index := find_build_profile_index(config, profile.build_profile)
		if build_index >= 0 {
			tasks_run_build_profile(editor, build_index, debug_index)
			return
		}
		debug_status_set(editor, fmt.tprintf("Build profile '%s' not found — launching anyway", profile.build_profile))
	}
	editor.active_debug_configuration_index = debug_index
	editor_dap_start_session(editor)
}

@(private="file")
find_build_profile_index :: proc(config: ^ProjectConfig, name: string) -> int {
	for profile, profile_index in config.build_profiles {
		if profile.name == name { return profile_index }
	}
	return -1
}

// Scan every terminal entry; for each build job whose child has exited
// since last frame, fire the follow-up work: surface a status line, and
// (when the build belonged to a build-then-debug pair) auto-start the
// queued debug session iff the build succeeded. Called once per frame
// from `editor_dap_update`. On a build failure we deliberately do NOT
// destroy or switch away from the terminal — the user needs to read the
// error output to figure out what went wrong.
@(private)
tasks_poll_terminal_build_exits :: proc(editor: ^Editor) {
	for &entry in editor.terminals {
		if !entry.is_build_job        { continue }
		if entry.build_exit_observed  { continue }
		if entry.terminal == nil      { continue }
		exited, exit_code := terminal.terminal_check_process_exit(entry.terminal)
		if !exited { continue }
		entry.build_exit_observed = true

		profile_name := entry.build_profile_name
		pending      := entry.pending_debug_profile_index
		if exit_code == 0 {
			debug_status_set(editor, fmt.tprintf("Build '%s' OK", profile_name))
		} else {
			debug_status_set(editor, fmt.tprintf("Build '%s' failed (exit %d) — see terminal", profile_name, exit_code))
		}
		editor_mark_dirty(editor)

		// Build-then-debug chain. Only fire on a clean exit; on failure the
		// terminal stays visible so the user can inspect the error output
		// before deciding what to do next. Swap pane[1] from the build
		// terminal to the Debug Output pane *before* the DAP spawn so the
		// adapter's first messages appear in the right place.
		if pending >= 0 && exit_code == 0 {
			editor.active_debug_configuration_index = pending
			editor.debug_state.panel_visible = true
			editor_output_pane_show(editor)
			editor_dap_start_session(editor)
		}
	}
}

// --- Input ---------------------------------------------------------------

@(private)
tasks_dialog_handle_event :: proc(editor: ^Editor, event: ^sdl3.Event) {
	#partial switch event.type {
	case .KEY_DOWN:
		pressed_key := event.key.key
		switch pressed_key {
		case sdl3.K_ESCAPE:
			tasks_dialog_close(editor)
		case sdl3.K_F7:
			tasks_dialog_close(editor)
		case sdl3.K_UP:
			tasks_dialog_move_selection(editor, -1)
		case sdl3.K_DOWN:
			tasks_dialog_move_selection(editor, 1)
		case sdl3.K_PAGEUP:
			step := editor.tasks_dialog.visible_row_count
			if step < 1 { step = 1 }
			tasks_dialog_move_selection(editor, -step)
		case sdl3.K_PAGEDOWN:
			step := editor.tasks_dialog.visible_row_count
			if step < 1 { step = 1 }
			tasks_dialog_move_selection(editor, step)
		case sdl3.K_HOME:
			tasks_dialog_move_selection(editor, -len(editor.tasks_dialog.entries))
		case sdl3.K_END:
			tasks_dialog_move_selection(editor, len(editor.tasks_dialog.entries))
		case sdl3.K_RETURN, sdl3.K_KP_ENTER:
			tasks_dialog_activate(editor)
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button != sdl3.BUTTON_LEFT { return }
		mouse_x := event.button.x
		mouse_y := event.button.y
		dialog := &editor.tasks_dialog
		for row_rect, row_index in dialog.row_rectangles {
			if ui.point_in_rect(row_rect, mouse_x, mouse_y) {
				dialog.selected_index = dialog.scroll_offset + row_index
				tasks_dialog_activate(editor)
				return
			}
		}
	}
}

// --- Render --------------------------------------------------------------

@(private)
tasks_dialog_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, viewport_width, viewport_height: i32) {
	dialog := &editor.tasks_dialog

	ui_context := editor_make_ui_context(editor, renderer)
	theme := ui.default_theme()

	ui.draw_dim_overlay(&ui_context, viewport_width, viewport_height, theme.overlay)

	desired_columns: i32 = 76
	desired_rows:    i32 = 16
	dialog_width  := min(desired_columns * editor.character_width + 32, viewport_width  - 40)
	dialog_height := min(desired_rows * editor.line_height + 60,        viewport_height - 40)
	if dialog_width  < 400 { dialog_width  = min(viewport_width  - 16, 400) }
	if dialog_height < 200 { dialog_height = min(viewport_height - 16, 200) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	title := "Tasks"
	if len(editor.project_config.loaded_from_path) == 0 {
		title = "Tasks — no project loaded"
	}
	content_rectangle := ui.draw_window(&ui_context, dialog_rectangle, title, theme)

	line_step     := editor.line_height
	content_x     := i32(content_rectangle.x)
	content_y     := i32(content_rectangle.y)
	content_width := i32(content_rectangle.w)

	footer_height: i32 = line_step + 12
	list_top_y       := content_y
	list_bottom_y    := i32(dialog_rectangle.y + dialog_rectangle.h) - footer_height - 12
	list_area_height := list_bottom_y - list_top_y
	computed_visible_rows := int(list_area_height / line_step)
	if computed_visible_rows < 1 { computed_visible_rows = 1 }
	dialog.visible_row_count = computed_visible_rows

	count := len(dialog.entries)
	if dialog.selected_index < dialog.scroll_offset {
		dialog.scroll_offset = dialog.selected_index
	} else if dialog.selected_index >= dialog.scroll_offset + computed_visible_rows {
		dialog.scroll_offset = dialog.selected_index - computed_visible_rows + 1
	}
	if dialog.scroll_offset < 0 { dialog.scroll_offset = 0 }

	clear(&dialog.row_rectangles)
	if count == 0 {
		empty_text: string
		if len(editor.project_root) == 0 {
			empty_text = "(no project — set one via Ctrl+P in the file browser)"
		} else {
			empty_text = "(no build_profiles / debug_profiles in .odit/project.json)"
		}
		ui.draw_text(&ui_context, empty_text, content_x + 8, list_top_y, theme.dim_foreground)
	} else {
		end_row_index := min(dialog.scroll_offset + computed_visible_rows, count)
		for row_index := dialog.scroll_offset; row_index < end_row_index; row_index += 1 {
			entry := dialog.entries[row_index]
			row_y_position := list_top_y + i32(row_index - dialog.scroll_offset) * line_step
			row_label := tasks_format_row_label(editor, entry)
			is_selected := row_index == dialog.selected_index
			row_rect := sdl3.FRect{ f32(content_x), f32(row_y_position), f32(content_width), f32(line_step) }
			ui.draw_list_row(&ui_context, content_x, row_y_position, content_width, row_label, is_selected, theme)
			append(&dialog.row_rectangles, row_rect)
		}
	}

	hint_text := "↑/↓ navigate    Enter run    Esc / F7 close"
	hint_width, _ := ui.text_size(&ui_context, hint_text)
	footer_x := i32(dialog_rectangle.x + (dialog_rectangle.w - f32(hint_width)) / 2)
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - line_step - 10
	ui.draw_text(&ui_context, hint_text, footer_x, footer_y, theme.dim_foreground)
}

@(private="file")
tasks_format_row_label :: proc(editor: ^Editor, entry: TaskEntry) -> string {
	switch entry.kind {
	case .BuildProfile:
		profiles := editor.project_config.build_profiles
		if entry.profile_index < 0 || entry.profile_index >= len(profiles) { return "(invalid build profile)" }
		profile := profiles[entry.profile_index]
		if len(profile.description) > 0 {
			return fmt.tprintf("[build]  %s — %s", profile.name, profile.description)
		}
		return fmt.tprintf("[build]  %s", profile.name)
	case .DebugProfile:
		profiles := editor.project_config.debug_profiles
		if entry.profile_index < 0 || entry.profile_index >= len(profiles) { return "(invalid debug profile)" }
		profile := profiles[entry.profile_index]
		if len(profile.build_profile) > 0 {
			return fmt.tprintf("[debug]  %s  (builds: %s)", profile.name, profile.build_profile)
		}
		return fmt.tprintf("[debug]  %s", profile.name)
	}
	return ""
}

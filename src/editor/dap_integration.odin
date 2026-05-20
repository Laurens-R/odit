package editor

import "core:fmt"
import "core:strings"

import "../dap"

// --- Session lifecycle ----------------------------------------------------

// Spawn the DAP adapter for the active debug configuration and kick off the
// launch sequence. Owned by `editor.dap_clients`; reused on subsequent Run
// presses if a session is already live. Returns the freshly active client (or
// the previously running one) — `nil` if no configuration is available or the
// adapter failed to spawn.
@(private)
editor_dap_start_session :: proc(editor: ^Editor) -> ^dap.Client {
	// Re-running while a session is alive: pretend the Run button means
	// Continue instead, so a quick second tap doesn't spawn a parallel
	// adapter against the same inferior.
	if editor.active_dap_client != nil && !dap.client_has_exited(editor.active_dap_client) {
		if dap.client_is_stopped(editor.active_dap_client) {
			dap.client_continue(editor.active_dap_client)
		}
		return editor.active_dap_client
	}

	profile_count := len(editor.project_config.debug_profiles)
	if profile_count == 0 {
		if len(editor.project_root) == 0 {
			debug_status_set(editor, "No project loaded — set a project root via Ctrl+P in the file browser.")
		} else {
			debug_status_set(editor, "No debug_profiles in .odit/project.json")
		}
		return nil
	}

	// Multi-profile workflow: ask the user to pick once via the F7 dialog,
	// then reuse on every subsequent Run press. A sentinel index of -1 (set
	// in `editor_init` and on every project-root change) means "not yet
	// picked" — open the dialog instead of silently launching the first
	// entry.
	if profile_count > 1 && (editor.active_debug_configuration_index < 0 || editor.active_debug_configuration_index >= profile_count) {
		tasks_dialog_open(editor)
		return nil
	}
	configuration_index := editor.active_debug_configuration_index
	if configuration_index < 0 || configuration_index >= profile_count { configuration_index = 0 }
	config := &editor.project_config.debug_profiles[configuration_index]

	command_tokens := editor_settings_dap_command(&editor.settings, config.adapter)
	if command_tokens == nil {
		debug_status_set(editor, fmt.tprintf("No DAP adapter configured for '%s' — add a `dap.%s.command` entry.", config.adapter, config.adapter))
		return nil
	}

	resolved_tokens := resolve_lsp_command_tokens(command_tokens, context.temp_allocator)
	working_directory := project_expand_placeholders(config.working_dir, editor, config.build_profile)
	if len(working_directory) == 0 { working_directory = editor.project_root }

	// Discard any exited client cached against the same adapter id so a
	// second Run press isn't reusing a dead handle (and we don't leak the
	// previous Client struct).
	for existing_key, existing_client in editor.dap_clients {
		if existing_key == config.adapter {
			dap.client_destroy(existing_client)
			delete_key(&editor.dap_clients, existing_key)
			delete(existing_key)
			break
		}
	}

	client := dap.client_new(resolved_tokens, working_directory)
	if client == nil {
		debug_status_set(editor, fmt.tprintf("Failed to spawn DAP adapter: %s", resolved_tokens[0]))
		return nil
	}

	// Same trick the LSP map uses: own a key copy independent of the
	// settings-owned adapter id, so settings reload can't pull the rug.
	editor.dap_clients[strings.clone(config.adapter)] = client
	editor.active_dap_client = client

	// Queue the launch/attach payload — the DAP layer holds it until the
	// `initialized` event fires, then ships it in spec order.
	launch_arguments_json := build_launch_arguments_json(editor, config)
	request_command := config.request_kind
	if request_command != "attach" { request_command = "launch" }
	dap.client_launch(client, launch_arguments_json, request_command)

	// Flush every breakpoint we've collected so far. lldb-dap accepts them
	// before the `initialized` event arrives and replays them at launch
	// time; if any setBreakpoints requests get reordered the editor's
	// next change-induced flush corrects the picture anyway.
	editor_dap_flush_all_breakpoints(editor)

	if request_command == "attach" {
		if config.pid > 0 {
			debug_status_set(editor, fmt.tprintf("Attaching to pid %d", config.pid))
		} else {
			debug_status_set(editor, fmt.tprintf("Attaching to: %s", config.program))
		}
	} else {
		debug_status_set(editor, fmt.tprintf("Launching: %s", config.program))
	}
	editor_mark_dirty(editor)
	return client
}

// Tear down the active session. Idempotent — safe to call when nothing is
// running. Keeps the client struct around in `dap_clients` so a subsequent
// Run press can spawn a fresh adapter cleanly.
@(private)
editor_dap_stop_session :: proc(editor: ^Editor) {
	client := editor.active_dap_client
	if client == nil { return }
	dap.client_terminate(client)
}

// Free every DAP client. Mirrors `editor_lsp_destroy_all`.
@(private)
editor_dap_destroy_all :: proc(editor: ^Editor) {
	for adapter_id, client in editor.dap_clients {
		_ = adapter_id
		dap.client_destroy(client)
	}
	for key in editor.dap_clients {
		delete(key)
	}
	delete(editor.dap_clients)
	editor.dap_clients = nil
	editor.active_dap_client = nil
}

// --- Per-frame update ------------------------------------------------------

// Called from `editor_update`. Polls each client (drains inbound messages,
// dispatches handlers) and refreshes the cached debug-panel snapshot used by
// the renderer.
@(private)
editor_dap_update :: proc(editor: ^Editor) {
	// Watch every terminal flagged as a build job first — a finished
	// pre-build is what kicks off a chained debug session.
	tasks_poll_terminal_build_exits(editor)

	if len(editor.dap_clients) == 0 { return }

	for _, client in editor.dap_clients {
		dap.client_poll(client)
	}

	client := editor.active_dap_client
	if client == nil { return }

	// Drain any output text the adapter has buffered into the debug status
	// strip. Keep just the last ~256 bytes so a chatty inferior doesn't push
	// useful text out of view.
	if output_bytes := dap.client_drain_output(client); output_bytes != nil {
		defer delete(output_bytes)
		if len(output_bytes) > 0 {
			debug_status_set(editor, string(output_bytes))
			editor_mark_dirty(editor)
		}
	}

	// If the client has terminated since last frame, sweep its session state
	// off the editor so the panel reverts to the idle placeholders.
	if dap.client_has_exited(client) {
		debug_session_clear(&editor.debug_state)
		editor.active_dap_client = nil
		debug_status_set(editor, "Debug session ended.")
		editor_mark_dirty(editor)
		return
	}

	debug_session_sync_from_client(editor, client)
}

// Refresh the cached session flags + selected-frame clamp from the live
// client. The renderer reads the rest (stack frames, scopes, variables)
// directly from the DAP client by accessor, so there's no per-frame cloning
// to do here.
@(private="file")
debug_session_sync_from_client :: proc(editor: ^Editor, client: ^dap.Client) {
	state := &editor.debug_state

	previous_session_active := state.session_active
	previous_is_stopped     := state.is_stopped
	previous_frame_count    := len(dap.client_stack_frames(client))

	state.session_active = true

	new_is_stopped := dap.client_is_stopped(client)
	// On a fresh stop, any user-expansion of compound variables from the
	// previous stop is keyed on a now-invalidated variables_reference —
	// clear the set so we don't waste hit-test capacity on dead refs.
	if new_is_stopped && !state.is_stopped {
		clear(&state.expanded_variables)
	}
	state.is_stopped = new_is_stopped

	frame_count := len(dap.client_stack_frames(client))
	if state.selected_stack_frame >= frame_count {
		state.selected_stack_frame = 0
	}

	// Repaint when anything user-visible changed. Subsequent rebuilds happen
	// inside the renderer (which now pulls fresh data from the client).
	if previous_session_active != state.session_active ||
	   previous_is_stopped     != state.is_stopped     ||
	   previous_frame_count    != frame_count {
		editor_mark_dirty(editor)
	}
}

// --- Breakpoints ----------------------------------------------------------

// Re-send the full breakpoint list for `file_path` to the active adapter.
// DAP replaces wholesale per file, so this is the only way to push add/remove
// changes. Cheap — total bp count is in the dozens.
@(private)
editor_dap_flush_file_breakpoints :: proc(editor: ^Editor, file_path: string) {
	client := editor.active_dap_client
	if client == nil { return }
	if len(file_path) == 0 { return }

	bps := breakpoints_for_file(editor, file_path)
	scratch := make([dynamic]dap.SourceBreakpoint, 0, len(bps), context.temp_allocator)
	for bp in bps {
		// Disabled breakpoints get omitted entirely — adapter has no
		// disable concept; the editor side just remembers the row.
		if !bp.enabled { continue }
		append(&scratch, dap.SourceBreakpoint{
			line      = i32(bp.line) + 1, // DAP is 1-based
			condition = bp.condition,
		})
	}
	dap.client_set_breakpoints(client, file_path, scratch[:])
}

// Flush every file with a breakpoint. Called right after the initial launch
// goes out so the adapter sees all of them before configurationDone fires.
@(private)
editor_dap_flush_all_breakpoints :: proc(editor: ^Editor) {
	for file_entry in editor.debug_state.breakpoint_files {
		editor_dap_flush_file_breakpoints(editor, file_entry.file_path)
	}
}

// --- Configuration helpers ------------------------------------------------

// Build the JSON arguments object for the launch / attach request. Honors
// `{project_root}` / `{platform}` / `{build_name}` (and the legacy
// `${workspaceFolder}`) expansion in `program`, `cwd`, and each entry of
// `args`. Different field sets per request kind — launch wants
// program/args/cwd/stopOnEntry; attach wants pid (or program+waitFor when
// pid is absent). Resulting string lives in `context.temp_allocator`.
@(private="file")
build_launch_arguments_json :: proc(editor: ^Editor, config: ^DebugProfile) -> string {
	is_attach := config.request_kind == "attach"

	program     := project_expand_placeholders(config.program,     editor, config.build_profile)
	working_dir := project_expand_placeholders(config.working_dir, editor, config.build_profile)
	if len(working_dir) == 0 { working_dir = editor.project_root }

	builder: strings.Builder
	strings.builder_init(&builder, 0, 256, context.temp_allocator)
	strings.write_string(&builder, `{"name":`)
	dap_write_json_string(&builder, config.name)
	strings.write_string(&builder, `,"type":"lldb-dap","request":`)
	dap_write_json_string(&builder, config.request_kind)

	if is_attach {
		// Two attach modes per the DAP spec / lldb-dap docs: by-pid or
		// by-program (optionally waiting for a future launch). Emit pid
		// when it's set; otherwise fall back to program (so the user can
		// say "attach to whatever `myprogram` shows up" with waitFor).
		if config.pid > 0 {
			fmt.sbprintf(&builder, `,"pid":%d`, config.pid)
		} else if len(program) > 0 {
			strings.write_string(&builder, `,"program":`)
			dap_write_json_string(&builder, program)
		}
		if config.wait_for { strings.write_string(&builder, `,"waitFor":true`) }
	} else {
		strings.write_string(&builder, `,"program":`)
		dap_write_json_string(&builder, program)
		if len(working_dir) > 0 {
			strings.write_string(&builder, `,"cwd":`)
			dap_write_json_string(&builder, working_dir)
		}
		strings.write_string(&builder, `,"args":[`)
		for argument, argument_index in config.args {
			if argument_index > 0 { strings.write_byte(&builder, ',') }
			dap_write_json_string(&builder, project_expand_placeholders(argument, editor, config.build_profile))
		}
		strings.write_string(&builder, `]`)
		if config.stop_on_entry { strings.write_string(&builder, `,"stopOnEntry":true`) }
	}
	strings.write_byte(&builder, '}')
	return strings.to_string(builder)
}

// Minimal JSON-string writer mirroring the one in the dap package. Inlined
// here so we don't have to make the dap package's helper public.
@(private="file")
dap_write_json_string :: proc(builder: ^strings.Builder, text: string) {
	strings.write_byte(builder, '"')
	for byte_index in 0..<len(text) {
		current_byte := text[byte_index]
		switch current_byte {
		case '"':  strings.write_string(builder, `\"`)
		case '\\': strings.write_string(builder, `\\`)
		case '\n': strings.write_string(builder, `\n`)
		case '\r': strings.write_string(builder, `\r`)
		case '\t': strings.write_string(builder, `\t`)
		case '\b': strings.write_string(builder, `\b`)
		case '\f': strings.write_string(builder, `\f`)
		case:
			if current_byte < 0x20 {
				strings.write_string(builder, fmt.tprintf("\\u%04x", current_byte))
			} else {
				strings.write_byte(builder, current_byte)
			}
		}
	}
	strings.write_byte(builder, '"')
}

// --- Status line ----------------------------------------------------------

// Replace the debug-panel status text. Owned by `debug_state.status_message`;
// caller hands us a non-owned string. Trimmed to a single line to fit the
// status strip.
@(private)
debug_status_set :: proc(editor: ^Editor, message: string) {
	state := &editor.debug_state
	trimmed := strings.trim_right_space(message)
	// Keep just the first line so multi-line stderr doesn't push the rest
	// of the panel down.
	if newline_index := strings.index_byte(trimmed, '\n'); newline_index >= 0 {
		trimmed = trimmed[:newline_index]
	}
	if len(state.status_message) > 0 { delete(state.status_message) }
	state.status_message = strings.clone(trimmed)
}

package editor

import "core:encoding/json"
import "core:os"
import "core:strings"

// User-tunable knobs loaded from `%APPDATA%/odit/settings.json` (or
// `./odit.json` in the cwd, checked first). Currently small — just the
// per-language LSP command — but the schema is designed to grow:
//
//   {
//     "lsp": {
//       "odin": { "command": ["ols"] },
//       "rust": { "command": ["rust-analyzer"] }
//     }
//   }
//
// Missing file / parse failure / missing keys silently fall back to baked-in
// defaults so the editor still launches against a fresh machine without any
// config.
@(private)
EditorSettings :: struct {
	// Map language id ("odin", "rust", …) → command + args. The first
	// token is the executable, the rest are CLI args. All strings owned.
	lsp_commands: map[string][]string,
}

@(private)
editor_settings_init :: proc(settings: ^EditorSettings) {
	settings.lsp_commands = make(map[string][]string)

	// Baked-in default: Odin uses ols on PATH. Other languages aren't
	// auto-wired — users opt in by adding entries to settings.json.
	// Clone the key — the rest of this module (settings load, destroy)
	// assumes every key in the map is heap-owned. Using a string literal
	// here would crash on the first `delete(existing_key)` since literals
	// live in read-only memory.
	default_odin_command := make([]string, 1)
	default_odin_command[0] = strings.clone("ols")
	settings.lsp_commands[strings.clone("odin")] = default_odin_command

	editor_settings_try_load(settings)
}

@(private)
editor_settings_destroy :: proc(settings: ^EditorSettings) {
	for language_id, command_tokens in settings.lsp_commands {
		_ = language_id
		for token in command_tokens { delete(token) }
		delete(command_tokens)
	}
	// The map's keys are owned strings too; delete them before freeing the map.
	for language_id in settings.lsp_commands {
		delete(language_id)
	}
	delete(settings.lsp_commands)
}

// Try a small list of candidate paths. First one that parses wins; everything
// else is ignored. Missing entries leave the bakedin defaults in place.
@(private="file")
editor_settings_try_load :: proc(settings: ^EditorSettings) {
	candidate_paths: [3]string

	candidate_paths[0] = "odit.json"
	if appdata := os.get_env("APPDATA", context.temp_allocator); len(appdata) > 0 {
		candidate_paths[1] = strings.concatenate({appdata, "/odit/settings.json"}, context.temp_allocator)
	}
	if home := os.get_env("HOME", context.temp_allocator); len(home) > 0 {
		candidate_paths[2] = strings.concatenate({home, "/.config/odit/settings.json"}, context.temp_allocator)
	}

	for path_candidate in candidate_paths {
		if len(path_candidate) == 0 { continue }
		if editor_settings_load_from_path(settings, path_candidate) { return }
	}
}

@(private="file")
editor_settings_load_from_path :: proc(settings: ^EditorSettings, file_path: string) -> bool {
	file_data, read_error := os.read_entire_file_from_path(file_path, context.temp_allocator)
	if read_error != nil { return false }

	parsed_value, parse_error := json.parse(file_data, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if parse_error != .None { return false }

	root_object, root_is_object := parsed_value.(json.Object); if !root_is_object { return false }

	lsp_value, has_lsp_key := root_object["lsp"]; if !has_lsp_key { return true }
	lsp_object, lsp_is_object := lsp_value.(json.Object); if !lsp_is_object { return true }

	for language_id_raw, language_value in lsp_object {
		language_object, lang_is_object := language_value.(json.Object); if !lang_is_object { continue }
		command_value, has_command_key := language_object["command"]; if !has_command_key { continue }
		command_array, command_is_array := command_value.(json.Array); if !command_is_array { continue }
		if len(command_array) == 0 { continue }

		// Convert each array entry to a string token; reject silently if
		// any entry isn't a string (mixed types in the array are user error).
		new_command_tokens := make([]string, len(command_array))
		all_strings := true
		for token_index in 0..<len(command_array) {
			token_value, token_is_string := command_array[token_index].(string)
			if !token_is_string { all_strings = false; break }
			new_command_tokens[token_index] = strings.clone(token_value)
		}
		if !all_strings {
			for token in new_command_tokens { if len(token) > 0 { delete(token) } }
			delete(new_command_tokens)
			continue
		}

		// Replace any prior entry for this language id.
		if existing_command, has_existing := settings.lsp_commands[language_id_raw]; has_existing {
			for token in existing_command { delete(token) }
			delete(existing_command)
		}
		language_id_owned := strings.clone(language_id_raw)
		// If the key was already in the map under the same string content
		// we'd leak the previous key. Delete first.
		for existing_key in settings.lsp_commands {
			if existing_key == language_id_raw {
				delete_key(&settings.lsp_commands, existing_key)
				delete(existing_key)
				break
			}
		}
		settings.lsp_commands[language_id_owned] = new_command_tokens
	}

	return true
}

// Public lookup helper: returns the configured command tokens for a given
// language id, or nil if none is registered. Caller does NOT own the slice
// or its strings — they're owned by `EditorSettings`.
@(private)
editor_settings_lsp_command :: proc(settings: ^EditorSettings, language_id: string) -> []string {
	tokens, has_entry := settings.lsp_commands[language_id]
	if !has_entry { return nil }
	return tokens
}

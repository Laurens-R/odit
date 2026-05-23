package editor

import "core:os"
import "core:path/filepath"
import "core:strings"

import completion_popup_pkg "./completion_popup"
import "../document"
import hover_pkg "./hover"
import "../lsp"
import signature_popup_pkg "./signature_popup"
import "../syntax"

// --- Language id resolution ------------------------------------------------

// Returns the canonical LSP language id ("odin", "rust", ...) for a pane's
// active syntax definition, or "" when no LSP-eligible language is set.
// Mapping is just the lowercase of `syntax.Definition.name` for now.
@(private)
lsp_language_id_for :: proc(language_definition: ^syntax.Definition) -> string {
	if language_definition == nil { return "" }
	name := language_definition.name
	if len(name) == 0 { return "" }
	// All lowercased ASCII — temp_allocator since callers use this string
	// only to look up a client in `editor.lsp_clients`.
	output_buffer := make([]u8, len(name), context.temp_allocator)
	for byte_index in 0..<len(name) {
		current := name[byte_index]
		if current >= 'A' && current <= 'Z' { current += 32 }
		output_buffer[byte_index] = current
	}
	return string(output_buffer)
}

// --- Client lifecycle ------------------------------------------------------

// Returns the running client for `language_id`, or starts one if it isn't
// already running. Returns nil when there's no command configured for this
// language or the spawn fails. Owned by `editor.lsp_clients`.
@(private)
editor_get_or_start_lsp :: proc(editor: ^Editor, language_id: string) -> ^lsp.Client {
	if len(language_id) == 0 { return nil }
	if existing_client, has_client := editor.lsp_clients[language_id]; has_client {
		return existing_client
	}

	command_tokens := editor_settings_lsp_command(&editor.settings, language_id)
	if command_tokens == nil { return nil }

	// Relative-path tokens get resolved against <exe_dir>/lsp/ first so a
	// `"command": ["ols.exe"]` config Just Works when the binary was
	// shipped via `vendor/<platform>/lsp/`. Absolute paths and bare names
	// that miss the override fall through to OS PATH lookup unchanged.
	resolved_tokens := resolve_lsp_command_tokens(command_tokens, context.temp_allocator)

	new_client := lsp.client_new(resolved_tokens, editor.project_root)
	if new_client == nil { return nil }

	// Own a key copy independent of language_id (which is temp).
	key := strings.clone(language_id)
	editor.lsp_clients[key] = new_client
	return new_client
}

// Rewrite the executable token at the head of an LSP/DAP command line so a
// relative path is checked under the editor's own lsp/ folder before being
// handed off to PATH-search. Other tokens (CLI args to the server) are
// passed through unchanged.
//
// Resolution rules for `command_tokens[0]`:
//   * absolute path           → use as-is
//   * relative, exists under
//     <exe_dir>/lsp/<token>   → rewrite to that absolute path
//   * otherwise               → use as-is (CreateProcessW / exec searches PATH)
//
// Shared with the DAP integration — both lookups land in vendor/<plat>/lsp/
// because that's where adapter binaries are staged. Despite the folder name,
// it holds any stdio JSON-RPC tool (LSPs, DAP adapters, …).
@(private)
resolve_lsp_command_tokens :: proc(command_tokens: []string, allocator := context.temp_allocator) -> []string {
	if len(command_tokens) == 0 { return command_tokens }
	executable_token := command_tokens[0]
	if len(executable_token) == 0 { return command_tokens }
	if filepath.is_abs(executable_token) { return command_tokens }

	exe_full_path, exe_path_error := os.get_executable_path(context.temp_allocator)
	if exe_path_error != nil || len(exe_full_path) == 0 { return command_tokens }
	exe_directory := filepath.dir(exe_full_path)
	if len(exe_directory) == 0 { return command_tokens }

	candidate_path, join_error := filepath.join({exe_directory, "lsp", executable_token}, context.temp_allocator)
	if join_error != nil || len(candidate_path) == 0 { return command_tokens }
	if !os.exists(candidate_path) { return command_tokens }

	rewritten := make([]string, len(command_tokens), allocator)
	rewritten[0] = candidate_path
	for token_index in 1..<len(command_tokens) { rewritten[token_index] = command_tokens[token_index] }
	return rewritten
}

// Tear down every running LSP client. Called from editor_destroy.
@(private)
editor_lsp_destroy_all :: proc(editor: ^Editor) {
	for language_id, client in editor.lsp_clients {
		_ = language_id
		lsp.client_destroy(client)
	}
	for key in editor.lsp_clients {
		delete(key)
	}
	delete(editor.lsp_clients)
	editor.lsp_clients = nil
}

// --- Per-pane hooks -------------------------------------------------------

// Called when a pane has just been (re)populated with an editor pane that
// has both a real on-disk path and a recognized language. Tries to fire
// didOpen — if the LSP client isn't initialized yet (the handshake is
// asynchronous), leaves `lsp_did_open_sent = false` so the per-frame retry
// in `editor_lsp_update` picks it up the moment the server is ready.
@(private)
editor_lsp_pane_opened :: proc(editor: ^Editor, pane: ^EditorPane) {
	if pane == nil { return }
	pane.lsp_did_open_sent = false
	if len(pane.file_path) == 0 { return }
	language_id := lsp_language_id_for(pane.language); if len(language_id) == 0 { return }
	client := editor_get_or_start_lsp(editor, language_id); if client == nil { return }
	if !client.is_initialized { return } // retry path in editor_lsp_update handles this

	content_text := document.document_get_text(&pane.document, context.temp_allocator)
	lsp.client_did_open(client, pane.file_path, language_id, content_text)
	pane.lsp_did_open_sent = true
}

// Called before a pane's content is destroyed/replaced. Sends didClose if
// the LSP was tracking the file.
@(private)
editor_lsp_pane_closing :: proc(editor: ^Editor, pane: ^EditorPane) {
	if pane == nil { return }
	if !pane.lsp_did_open_sent { return }
	language_id := lsp_language_id_for(pane.language); if len(language_id) == 0 { return }
	client, has_client := editor.lsp_clients[language_id]; if !has_client { return }
	lsp.client_did_close(client, pane.file_path)
	pane.lsp_did_open_sent = false
}

// Called on every document mutation (insert / delete / paste / undo / redo).
// Marks the pane for a debounced didChange.
@(private)
editor_lsp_pane_modified :: proc(editor: ^Editor, pane: ^EditorPane) {
	pane.lsp_dirty          = true
	pane.lsp_last_edit_time = editor.clock
}

// Force a debounced didChange to be delivered NOW. Used right before
// firing a hover / completion / signature request so the LSP sees the
// document the user is actually looking at — without this, the server
// answers based on stale content from up to 150 ms ago.
@(private)
editor_lsp_flush_pending_change :: proc(editor: ^Editor, editor_pane: ^EditorPane) {
	if !editor_pane.lsp_dirty           { return }
	if !editor_pane.lsp_did_open_sent   { return }
	language_id := lsp_language_id_for(editor_pane.language); if len(language_id) == 0 { return }
	client, has_client := editor.lsp_clients[language_id];     if !has_client          { return }
	if !client.is_initialized           { return }

	content_text := document.document_get_text(&editor_pane.document, context.temp_allocator)
	lsp.client_did_change(client, editor_pane.file_path, content_text)
	editor_pane.lsp_dirty = false
}

// --- Auto-trigger completion ----------------------------------------------

// Hook called right after `editor_insert_text` lands a TEXT_INPUT into the
// active editor pane. Looks at what was just typed; if it's one of the
// trigger characters ols cares about, fires a completion request so the
// user gets the dropdown without having to press Ctrl+Space:
//
//   * `.` anywhere → package/struct member completion
//   * `"` on a line that starts with `import` → package picker
//
// Trigger characters are hardcoded for now; reading them from the server's
// `completionProvider.triggerCharacters` capability would be the next step.
@(private)
editor_lsp_maybe_trigger_completion :: proc(editor: ^Editor, just_typed_text: string) {
	if len(just_typed_text) == 0 { return }
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }
	if len(editor_pane.file_path) == 0 { return }
	if lsp_language_id_for(editor_pane.language) == "" { return }

	last_byte := just_typed_text[len(just_typed_text) - 1]

	switch last_byte {
	case '.':
		completion_popup_pkg.trigger_at_cursor_via_api(&editor.completion_popup, &editor.editor_api)

	case '(':
		signature_popup_pkg.request_at_cursor_via_api(&editor.signature_popup, &editor.editor_api)

	case ',':
		// Refresh signature help so the active parameter underline
		// follows along as the user moves through the argument list.
		signature_popup_pkg.request_at_cursor_via_api(&editor.signature_popup, &editor.editor_api)

	case ')':
		// Closing the call expression closes the popup.
		signature_popup_pkg.close(&editor.signature_popup)

	case '"', ':', '/':
		// `"` always fires only on `import` lines so plain string literals
		// don't pop the dropdown on every opening quote. `:` and `/` are
		// Odin's package-path separators (`vendor:foo/bar`) — they're
		// useful triggers too, but ONLY inside an import context for the
		// same reason: `name : int` and division `a / b` would otherwise
		// pop the dropdown constantly.
		if line_is_import(&editor_pane.document, editor_pane.cursor_line) {
			completion_popup_pkg.trigger_at_cursor_via_api(&editor.completion_popup, &editor.editor_api)
		}
	}
}

// True when the given line, after leading whitespace, starts with the
// `import` keyword followed by whitespace/quote/EOL. Used to decide whether
// punctuation characters that double as Odin package-path separators should
// fire LSP completion.
@(private="file")
line_is_import :: proc(doc: ^document.Document, line_index: u32) -> bool {
	line_text := document.document_get_line(doc, line_index, context.temp_allocator)
	scan := 0
	for scan < len(line_text) && (line_text[scan] == ' ' || line_text[scan] == '\t') { scan += 1 }
	import_keyword := "import"
	if scan + len(import_keyword) > len(line_text) { return false }
	if line_text[scan:scan+len(import_keyword)] != import_keyword { return false }
	boundary := scan + len(import_keyword)
	if boundary == len(line_text) { return true }
	return line_text[boundary] == ' ' || line_text[boundary] == '\t' || line_text[boundary] == '"'
}

// --- Diagnostics accessor -------------------------------------------------

// Returns the latest diagnostic list for `pane`'s current file, or nil when
// there's no LSP running for the pane's language or no diagnostics have
// been published yet. The returned slice is owned by the LSP client — do
// NOT free or hold across LSP polls (a publishDiagnostics arriving will
// replace the storage).
@(private)
editor_lsp_diagnostics_for_pane :: proc(editor: ^Editor, pane: ^EditorPane) -> []lsp.Diagnostic {
	if pane == nil || len(pane.file_path) == 0 { return nil }
	language_id := lsp_language_id_for(pane.language); if len(language_id) == 0 { return nil }
	client, has_client := editor.lsp_clients[language_id]; if !has_client { return nil }
	return lsp.client_diagnostics_for(client, pane.file_path)
}

// --- Update tick ----------------------------------------------------------

// Called once per frame from editor_update. Polls every client (drains
// inbound JSON, dispatches handlers) and fires debounced didChange
// notifications for any modified pane that has been idle for >150ms.
@(private)
editor_lsp_update :: proc(editor: ^Editor) {
	if len(editor.lsp_clients) == 0 { return }

	for _, client in editor.lsp_clients {
		lsp.client_poll(client)
	}

	// Retry didOpen for any pane that hasn't been registered with the
	// server yet. Initial registration is attempted synchronously in
	// `editor_lsp_pane_opened`, but the LSP handshake is asynchronous —
	// the first attempt often races the `initialize` response and drops.
	// `client_did_open` is itself a no-op until init completes, so this
	// loop costs almost nothing on idle frames.
	for pane_index in 0..<len(editor.panes) {
		editor_pane, is_editor := &editor.panes[pane_index].content.(EditorPane); if !is_editor { continue }
		if editor_pane.lsp_did_open_sent           { continue }
		if len(editor_pane.file_path) == 0          { continue }
		language_id := lsp_language_id_for(editor_pane.language); if len(language_id) == 0 { continue }
		client, has_client := editor.lsp_clients[language_id];     if !has_client          { continue }
		if !client.is_initialized                   { continue }

		content_text := document.document_get_text(&editor_pane.document, context.temp_allocator)
		lsp.client_did_open(client, editor_pane.file_path, language_id, content_text)
		editor_pane.lsp_did_open_sent = true
	}

	// Pull any freshly-arrived hover / completion / signature result into
	// the corresponding popup.
	hover_pkg.update_via_api(&editor.hover_popup, &editor.editor_api)
	completion_popup_pkg.update_via_api(&editor.completion_popup, &editor.editor_api)
	signature_popup_pkg.update_via_api(&editor.signature_popup, &editor.editor_api)

	DIDCHANGE_DEBOUNCE_SECONDS :: 0.15
	for pane_index in 0..<len(editor.panes) {
		editor_pane, is_editor := &editor.panes[pane_index].content.(EditorPane); if !is_editor { continue }
		if !editor_pane.lsp_dirty                                         { continue }
		if editor.clock - editor_pane.lsp_last_edit_time < DIDCHANGE_DEBOUNCE_SECONDS { continue }
		if !editor_pane.lsp_did_open_sent                                 { continue }
		language_id := lsp_language_id_for(editor_pane.language); if len(language_id) == 0 { continue }
		client, has_client := editor.lsp_clients[language_id];     if !has_client          { continue }

		content_text := document.document_get_text(&editor_pane.document, context.temp_allocator)
		lsp.client_did_change(client, editor_pane.file_path, content_text)
		editor_pane.lsp_dirty = false
	}
}

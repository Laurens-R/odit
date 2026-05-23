// Git CLI invocations that populate the dialog + fetch the picked
// revision. No editor coupling — uses `core:os` + the project's
// `git` helper module directly.
package git_history

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../../git"

// Open the dialog at `file_path` and populate it with commits.
// Resolves repo root, computes the repo-relative path, runs
// `git log`. Any failure surfaces as the dialog's error message.
//
// On success the relative path + file directory are stashed on
// `state.context` for the subsequent `git show <hash>:<rel>` step.
open_for_file :: proc(state: ^State, source_pane_index: int, file_path: string) {
	open(state, source_pane_index, file_path)
	clear_error(state)

	if len(file_path) == 0 {
		set_error(state, "Save the file first — untitled documents have no git history")
		return
	}

	if !git.is_available() {
		set_error(state, "git is not on PATH")
		return
	}

	file_directory := os.dir(file_path)

	repo_root_path, repository_found := get_repo_root(file_directory)
	if !repository_found {
		set_error(state, "This file is not inside a git repository")
		return
	}

	relative_path, relative_error := filepath.rel(repo_root_path, file_path, context.temp_allocator)
	if relative_error != .None {
		set_error(state, "Could not compute repo-relative path")
		return
	}
	forward_slashed_relative, _ := strings.replace_all(relative_path, "\\", "/", context.temp_allocator)

	if len(state.context_file_directory) > 0 { delete(state.context_file_directory) }
	if len(state.context_relative_path)  > 0 { delete(state.context_relative_path) }
	state.context_file_directory = strings.clone(file_directory)
	state.context_relative_path  = strings.clone(forward_slashed_relative)

	populate(state, file_directory, file_path)
}

@(private="file")
get_repo_root :: proc(directory_path: string) -> (root: string, ok: bool) {
	command_arguments := [?]string{"git", "-C", directory_path, "rev-parse", "--show-toplevel"}
	process_description := os.Process_Desc{ command = command_arguments[:] }
	process_state, stdout_bytes, stderr_bytes, process_error := os.process_exec(process_description, context.temp_allocator)
	_ = stderr_bytes
	if process_error != nil || !process_state.exited || process_state.exit_code != 0 { return "", false }
	return strings.trim_space(string(stdout_bytes)), true
}

@(private="file")
populate :: proc(state: ^State, file_directory: string, file_path: string) {
	format_argument := "--pretty=format:%H%x1f%aI%x1f%an%x1f%s"
	command_arguments := [?]string{"git", "-C", file_directory, "log", format_argument, "--", file_path}
	process_description := os.Process_Desc{ command = command_arguments[:] }
	process_state, stdout_bytes, stderr_bytes, process_error := os.process_exec(process_description, context.temp_allocator)
	_ = stderr_bytes
	if process_error != nil || !process_state.exited || process_state.exit_code != 0 {
		set_error(state, "git log failed for this file")
		return
	}

	sources := make([dynamic]EntrySource, 0, 32, context.temp_allocator)

	log_output := string(stdout_bytes)
	for log_line in strings.split_lines_iterator(&log_output) {
		if len(log_line) == 0 { continue }
		fields := strings.split(log_line, "\x1f", context.temp_allocator)
		if len(fields) < 4 { continue }

		full_hash := fields[0]
		commit_date := fields[1]
		author_name := fields[2]
		commit_subject := fields[3]

		short_hash_length := 7
		if len(full_hash) < short_hash_length { short_hash_length = len(full_hash) }

		append(&sources, EntrySource{
			hash       = full_hash,
			short_hash = full_hash[:short_hash_length],
			date       = commit_date,
			author     = author_name,
			subject    = commit_subject,
		})
	}

	set_entries(state, sources[:])
	if len(sources) == 0 {
		set_error(state, "No commits found for this file")
	}
}

// Fetch `git show <hash>:<rel-path>` for the picked revision. The
// returned `revision_text` lives in `context.temp_allocator`. On
// failure returns an error message in `error_message`.
fetch_revision :: proc(state: ^State, full_hash, short_hash: string) -> (revision_text: string, error_message: string) {
	if len(state.context_relative_path) == 0 || len(state.context_file_directory) == 0 {
		return "", "Git history context missing"
	}

	hash_colon_path := fmt.tprintf("%s:%s", full_hash, state.context_relative_path)
	command_arguments := [?]string{"git", "-C", state.context_file_directory, "show", hash_colon_path}
	process_description := os.Process_Desc{ command = command_arguments[:] }
	process_state, stdout_bytes, stderr_bytes, process_error := os.process_exec(process_description, context.temp_allocator)
	_ = stderr_bytes
	if process_error != nil || !process_state.exited || process_state.exit_code != 0 {
		return "", fmt.tprintf("Cannot fetch revision %s", short_hash)
	}
	return string(stdout_bytes), ""
}

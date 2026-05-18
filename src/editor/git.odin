package editor

import "base:runtime"
import "core:os"
import "core:strings"

// Per-entry git state. Inferred from `git status --porcelain` output. Multiple
// hits on the same entry (a folder containing multiple changed files) are
// collapsed to the highest-priority status — see `git_priority` below.
GitStatus :: enum u8 {
	None,       // tracked & clean, or not in a git repo at all
	Untracked,  // not tracked yet (`??`)
	Added,      // staged for addition (`A `)
	Modified,   // changed or partially staged (`M`, ` M`, `MM`, etc.)
	Renamed,    // renamed (`R`)
	Deleted,    // staged or unstaged deletion (`D`)
}

// Cached "is `git` invokable on this machine?" check. We probe once on the
// first git query and remember the answer for the rest of the session so we
// don't pay the cost (and latency) of spawning a process per directory
// navigation when git isn't installed.
@(private="file")
git_available_state :: enum {
	Unchecked,
	Available,
	Missing,
}

@(private="file")
git_availability: git_available_state = .Unchecked

@(private="file")
git_is_available :: proc() -> bool {
	switch git_availability {
	case .Available: return true
	case .Missing:   return false
	case .Unchecked:
	}

	command_arguments := [?]string{"git", "--version"}
	process_description := os.Process_Desc{ command = command_arguments[:] }

	process_state, stdout_bytes, stderr_bytes, process_error := os.process_exec(process_description, context.temp_allocator)
	_ = stdout_bytes
	_ = stderr_bytes

	git_runs_successfully := process_error == nil && process_state.exited && process_state.exit_code == 0
	git_availability = git_runs_successfully ? .Available : .Missing
	return git_runs_successfully
}

// Run `git -C <dir> status --porcelain` and return a map of entry-name →
// status. The map covers entries visible directly inside `directory_path`;
// if a file deep inside a subdirectory is changed, the corresponding
// top-level directory entry gets the rolled-up status.
//
// If git isn't installed (cached after the first attempt), `directory_path`
// isn't inside a git repo, or anything else goes wrong, returns an empty
// map. Callers should treat "not in the map" as "no git status to show".
//
// The map and underlying strings are allocated from the provided allocator
// (typically `context.temp_allocator`).
// Normalize a filesystem path for prefix comparison: forward slashes, no
// trailing separator. Returns a temp-allocator-backed string.
@(private="file")
normalize_path_for_compare :: proc(path: string, allocator: runtime.Allocator) -> string {
	forward_slashed_path, _ := strings.replace_all(path, "\\", "/", allocator)
	forward_slashed_path = strings.trim_right(forward_slashed_path, "/")
	return forward_slashed_path
}

@(private)
git_query_status :: proc(directory_path: string, allocator := context.temp_allocator) -> map[string]GitStatus {
	status_map := make(map[string]GitStatus, allocator = allocator)

	// Skip the per-directory spawn entirely if we've already determined that
	// git isn't on PATH.
	if !git_is_available() { return status_map }

	// First, resolve the repo root for `directory_path`. Porcelain output is
	// always reported as paths *relative to the repo root*, regardless of
	// where `git` was invoked from. To make the path match an entry in our
	// listing we have to strip the listing-dir's prefix off each path.
	repository_root: string
	{
		command_arguments := [?]string{"git", "-C", directory_path, "rev-parse", "--show-toplevel"}
		process_description := os.Process_Desc{ command = command_arguments[:] }
		process_state, stdout_bytes, stderr_bytes, process_error := os.process_exec(process_description, allocator)
		_ = stderr_bytes
		if process_error != nil || !process_state.exited || process_state.exit_code != 0 {
			return status_map // not inside a git repo
		}
		repository_root = strings.trim_space(string(stdout_bytes))
	}

	// Compute prefix = (listing dir) relative to (repo root), with a trailing
	// slash so we can strip it off porcelain paths. Empty when listing the
	// repo root itself.
	listing_directory_prefix: string
	{
		normalized_listing_dir := normalize_path_for_compare(directory_path,   allocator)
		normalized_repo_root   := normalize_path_for_compare(repository_root,  allocator)
		if strings.has_prefix(normalized_listing_dir, normalized_repo_root) {
			relative_listing_path := normalized_listing_dir[len(normalized_repo_root):]
			relative_listing_path  = strings.trim_left(relative_listing_path, "/")
			if len(relative_listing_path) > 0 {
				listing_directory_prefix = strings.concatenate({relative_listing_path, "/"}, allocator)
			}
		}
	}

	command_arguments := [?]string{"git", "-C", directory_path, "status", "--porcelain"}
	process_description := os.Process_Desc{
		command = command_arguments[:],
	}

	process_state, stdout_bytes, stderr_bytes, process_error := os.process_exec(process_description, allocator)
	_ = stderr_bytes
	if process_error != nil || !process_state.exited || process_state.exit_code != 0 {
		return status_map
	}

	porcelain_output := string(stdout_bytes)
	for porcelain_line in strings.split_lines_iterator(&porcelain_output) {
		if len(porcelain_line) < 4 { continue }

		status_code := porcelain_line[:2]
		entry_path := porcelain_line[3:]

		// Renames are reported as "OLD -> NEW" — we only care about the NEW
		// side (that's the file in the working tree the user sees).
		if rename_arrow_index := strings.index(entry_path, " -> "); rename_arrow_index >= 0 {
			entry_path = entry_path[rename_arrow_index + 4:]
		}

		// Git quotes paths that contain "weird" bytes. Strip surrounding
		// quotes (full octal-escape decoding is overkill for our use).
		if len(entry_path) >= 2 && entry_path[0] == '"' && entry_path[len(entry_path)-1] == '"' {
			entry_path = entry_path[1:len(entry_path)-1]
		}

		// Some git versions / configurations prefix relative paths with "./".
		if strings.has_prefix(entry_path, "./") { entry_path = entry_path[2:] }

		// Porcelain paths are repo-root-relative. Convert to listing-dir-
		// relative by stripping the prefix; entries outside the listing dir
		// are not our concern.
		if len(listing_directory_prefix) > 0 {
			if !strings.has_prefix(entry_path, listing_directory_prefix) {
				continue
			}
			entry_path = entry_path[len(listing_directory_prefix):]
			if len(entry_path) == 0 { continue }
		}

		// Key the map by the *full* relative path (relative to the listing
		// directory). Callers decide whether to do exact lookup (file or
		// flat-mode entry) or prefix rollup (directory entry in tree view).
		classified_status := classify_git_code(status_code)
		if existing_status, already_exists := status_map[entry_path]; already_exists {
			if git_priority(classified_status) > git_priority(existing_status) {
				status_map[entry_path] = classified_status
			}
		} else {
			status_map[entry_path] = classified_status
		}
	}

	return status_map
}

// Look up the effective git status for a single browse entry, given the
// raw status map returned by `git_query_status`. For files (and flat-mode
// entries with embedded slashes) we look up by exact name. For directories,
// we roll up to the highest-priority status of any path inside that
// directory's subtree.
@(private)
git_status_for_entry :: proc(status_map: map[string]GitStatus, entry_name: string, entry_is_directory: bool) -> GitStatus {
	if exact_status, found_exact := status_map[entry_name]; found_exact {
		return exact_status
	}
	if !entry_is_directory { return .None }

	directory_path_prefix := strings.concatenate({entry_name, "/"}, context.temp_allocator)
	best_status := GitStatus.None
	for descendant_path, descendant_status in status_map {
		if strings.has_prefix(descendant_path, directory_path_prefix) {
			if git_priority(descendant_status) > git_priority(best_status) {
				best_status = descendant_status
			}
		}
	}
	return best_status
}

// Short text tag for the row label. Empty string for clean / unknown entries.
@(private)
git_status_tag :: proc(status: GitStatus) -> string {
	switch status {
	case .None:      return ""
	case .Untracked: return "[N]"
	case .Added:     return "[N]"
	case .Modified:  return "[M]"
	case .Renamed:   return "[R]"
	case .Deleted:   return "[D]"
	}
	return ""
}

// Map a two-character porcelain status code to our enum. Looks at both the
// staged (`status_code[0]`) and unstaged (`status_code[1]`) positions and
// returns the highest-priority interpretation.
@(private="file")
classify_git_code :: proc(status_code: string) -> GitStatus {
	if status_code == "??" { return .Untracked }

	best_status := GitStatus.None
	for code_character_index in 0..<len(status_code) {
		code_character := status_code[code_character_index]
		interpreted_status: GitStatus
		switch code_character {
		case 'A': interpreted_status = .Added
		case 'D': interpreted_status = .Deleted
		case 'M': interpreted_status = .Modified
		case 'R': interpreted_status = .Renamed
		case 'C': interpreted_status = .Added // copy — treat like add for display purposes
		case 'U': interpreted_status = .Modified // unmerged — show as modified
		case:     interpreted_status = .None
		}
		if git_priority(interpreted_status) > git_priority(best_status) {
			best_status = interpreted_status
		}
	}
	if best_status == .None { return .Modified }
	return best_status
}

// Ordering for collapsing multiple hits on the same entry. Higher = stronger
// visual signal (we want "deleted" to win over "modified" in a folder, etc.).
@(private)
git_priority :: proc(status: GitStatus) -> int {
	switch status {
	case .None:      return 0
	case .Untracked: return 1
	case .Added:     return 2
	case .Modified:  return 3
	case .Renamed:   return 4
	case .Deleted:   return 5
	}
	return 0
}

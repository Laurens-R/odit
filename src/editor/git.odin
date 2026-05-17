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

	args := [?]string{"git", "--version"}
	desc := os.Process_Desc{ command = args[:] }

	state, stdout, stderr, err := os.process_exec(desc, context.temp_allocator)
	_ = stdout
	_ = stderr

	ok := err == nil && state.exited && state.exit_code == 0
	git_availability = ok ? .Available : .Missing
	return ok
}

// Run `git -C <dir> status --porcelain` and return a map of entry-name →
// status. The map covers entries visible directly inside `dir`; if a file
// deep inside a subdirectory is changed, the corresponding top-level
// directory entry gets the rolled-up status.
//
// If git isn't installed (cached after the first attempt), `dir` isn't inside
// a git repo, or anything else goes wrong, returns an empty map. Callers
// should treat "not in the map" as "no git status to show".
//
// The map and underlying strings are allocated from the provided allocator
// (typically `context.temp_allocator`).
// Normalize a filesystem path for prefix comparison: forward slashes, no
// trailing separator. Returns a temp-allocator-backed string.
@(private="file")
normalize_path_for_compare :: proc(p: string, allocator: runtime.Allocator) -> string {
	s, _ := strings.replace_all(p, "\\", "/", allocator)
	s = strings.trim_right(s, "/")
	return s
}

@(private)
git_query_status :: proc(dir: string, allocator := context.temp_allocator) -> map[string]GitStatus {
	result := make(map[string]GitStatus, allocator = allocator)

	// Skip the per-directory spawn entirely if we've already determined that
	// git isn't on PATH.
	if !git_is_available() { return result }

	// First, resolve the repo root for `dir`. Porcelain output is always
	// reported as paths *relative to the repo root*, regardless of where
	// `git` was invoked from. To make the path match an entry in our
	// listing we have to strip the listing-dir's prefix off each path.
	repo_root: string
	{
		args := [?]string{"git", "-C", dir, "rev-parse", "--show-toplevel"}
		desc := os.Process_Desc{ command = args[:] }
		state, stdout, stderr, err := os.process_exec(desc, allocator)
		_ = stderr
		if err != nil || !state.exited || state.exit_code != 0 {
			return result // not inside a git repo
		}
		repo_root = strings.trim_space(string(stdout))
	}

	// Compute prefix = (listing dir) relative to (repo root), with a trailing
	// slash so we can strip it off porcelain paths. Empty when listing the
	// repo root itself.
	prefix: string
	{
		norm_dir  := normalize_path_for_compare(dir,       allocator)
		norm_root := normalize_path_for_compare(repo_root, allocator)
		if strings.has_prefix(norm_dir, norm_root) {
			rel := norm_dir[len(norm_root):]
			rel  = strings.trim_left(rel, "/")
			if len(rel) > 0 {
				prefix = strings.concatenate({rel, "/"}, allocator)
			}
		}
	}

	args := [?]string{"git", "-C", dir, "status", "--porcelain"}
	desc := os.Process_Desc{
		command = args[:],
	}

	state, stdout, stderr, err := os.process_exec(desc, allocator)
	_ = stderr
	if err != nil || !state.exited || state.exit_code != 0 {
		return result
	}

	output := string(stdout)
	for line in strings.split_lines_iterator(&output) {
		if len(line) < 4 { continue }

		code := line[:2]
		path := line[3:]

		// Renames are reported as "OLD -> NEW" — we only care about the NEW
		// side (that's the file in the working tree the user sees).
		if arrow := strings.index(path, " -> "); arrow >= 0 {
			path = path[arrow + 4:]
		}

		// Git quotes paths that contain "weird" bytes. Strip surrounding
		// quotes (full octal-escape decoding is overkill for our use).
		if len(path) >= 2 && path[0] == '"' && path[len(path)-1] == '"' {
			path = path[1:len(path)-1]
		}

		// Some git versions / configurations prefix relative paths with "./".
		if strings.has_prefix(path, "./") { path = path[2:] }

		// Porcelain paths are repo-root-relative. Convert to listing-dir-
		// relative by stripping the prefix; entries outside the listing dir
		// are not our concern.
		if len(prefix) > 0 {
			if !strings.has_prefix(path, prefix) {
				continue
			}
			path = path[len(prefix):]
			if len(path) == 0 { continue }
		}

		// Key the map by the *full* relative path (relative to the listing
		// directory). Callers decide whether to do exact lookup (file or
		// flat-mode entry) or prefix rollup (directory entry in tree view).
		status := classify_git_code(code)
		if existing, exists := result[path]; exists {
			if git_priority(status) > git_priority(existing) {
				result[path] = status
			}
		} else {
			result[path] = status
		}
	}

	return result
}

// Look up the effective git status for a single browse entry, given the
// raw status map returned by `git_query_status`. For files (and flat-mode
// entries with embedded slashes) we look up by exact name. For directories,
// we roll up to the highest-priority status of any path inside that
// directory's subtree.
@(private)
git_status_for_entry :: proc(status_map: map[string]GitStatus, entry_name: string, is_dir: bool) -> GitStatus {
	if s, ok := status_map[entry_name]; ok {
		return s
	}
	if !is_dir { return .None }

	prefix := strings.concatenate({entry_name, "/"}, context.temp_allocator)
	best := GitStatus.None
	for path, s in status_map {
		if strings.has_prefix(path, prefix) {
			if git_priority(s) > git_priority(best) {
				best = s
			}
		}
	}
	return best
}

// Short text tag for the row label. Empty string for clean / unknown entries.
@(private)
git_status_tag :: proc(s: GitStatus) -> string {
	switch s {
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
// staged (`code[0]`) and unstaged (`code[1]`) positions and returns the
// highest-priority interpretation.
@(private="file")
classify_git_code :: proc(code: string) -> GitStatus {
	if code == "??" { return .Untracked }

	best := GitStatus.None
	for i in 0..<len(code) {
		c := code[i]
		s: GitStatus
		switch c {
		case 'A': s = .Added
		case 'D': s = .Deleted
		case 'M': s = .Modified
		case 'R': s = .Renamed
		case 'C': s = .Added // copy — treat like add for display purposes
		case 'U': s = .Modified // unmerged — show as modified
		case:     s = .None
		}
		if git_priority(s) > git_priority(best) {
			best = s
		}
	}
	if best == .None { return .Modified }
	return best
}

// Ordering for collapsing multiple hits on the same entry. Higher = stronger
// visual signal (we want "deleted" to win over "modified" in a folder, etc.).
@(private)
git_priority :: proc(s: GitStatus) -> int {
	switch s {
	case .None:      return 0
	case .Untracked: return 1
	case .Added:     return 2
	case .Modified:  return 3
	case .Renamed:   return 4
	case .Deleted:   return 5
	}
	return 0
}

#+build !windows
package lsp

// Placeholder for non-Windows platforms. Mirrors the Windows API so the
// rest of the package compiles; actual implementation can be filled in
// later (pipe() + fork()/posix_spawn() + threading).

ProcessState :: struct {
	is_alive: bool, // dummy so the struct isn't empty
}

@(private) process_spawn       :: proc(state: ^ProcessState, command_tokens: []string, working_directory: string = "") -> bool { return false }
@(private) process_close       :: proc(state: ^ProcessState) {}
@(private) process_finalize    :: proc(state: ^ProcessState) {}
@(private) process_read        :: proc(state: ^ProcessState, buffer: []u8) -> (bytes_read: int, ok: bool) { return 0, false }
@(private) process_write       :: proc(state: ^ProcessState, data:   []u8) -> int { return 0 }
@(private) get_process_id_platform :: proc() -> int { return 0 }

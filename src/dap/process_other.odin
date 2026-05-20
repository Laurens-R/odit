#+build !windows
package dap

// Placeholder for non-Windows platforms. Mirrors the Windows API so the rest
// of the DAP package compiles; actual implementation should be filled in
// (pipe() + posix_spawn() + threading) when the editor expands beyond Windows.

ProcessState :: struct {
	is_alive: bool, // keeps the struct non-empty
}

@(private) process_spawn    :: proc(state: ^ProcessState, command_tokens: []string, working_directory: string = "") -> bool { return false }
@(private) process_close    :: proc(state: ^ProcessState) {}
@(private) process_finalize :: proc(state: ^ProcessState) {}
@(private) process_read     :: proc(state: ^ProcessState, buffer: []u8) -> (bytes_read: int, ok: bool) { return 0, false }
@(private) process_write    :: proc(state: ^ProcessState, data:   []u8) -> int { return 0 }

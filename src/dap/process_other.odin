#+build !windows
package dap

import "core:c"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

// POSIX equivalent of `process_windows.odin`. Mirrors the Windows pipe-based
// stdio plumbing, with the same two-phase shutdown so the reader thread
// notices EOF and joins cleanly.
//
// The DAP variant differs from the LSP one in two ways:
//   - `process_check_exit` is exposed publicly so the editor can detect an
//     adapter that died mid-handshake (the same way the terminal layer
//     does for build jobs).
//   - `process_read_stderr` is non-blocking-on-empty: it returns immediately
//     with zero bytes when the pipe is idle so the editor's per-frame DAP
//     update doesn't stall the UI thread on stderr.
ProcessState :: struct {
	child_pid:    posix.pid_t,
	stdin_write:  posix.FD,
	stdout_read:  posix.FD,
	stderr_read:  posix.FD,
	has_exit:     bool,
	exit_code:    i32,
}

when ODIN_OS == .Darwin {
	foreign import system_lib "system:System"
	@(default_calling_convention="c")
	foreign system_lib {
		chdir :: proc(path: cstring) -> c.int ---
		_exit :: proc(status: c.int) -> ! ---
		@(link_name="usleep") libc_usleep :: proc(microseconds: c.uint) -> c.int ---
	}
} else {
	foreign import system_lib "system:c"
	@(default_calling_convention="c")
	foreign system_lib {
		chdir :: proc(path: cstring) -> c.int ---
		_exit :: proc(status: c.int) -> ! ---
		@(link_name="usleep") libc_usleep :: proc(microseconds: c.uint) -> c.int ---
	}
}

@(private)
process_spawn :: proc(state: ^ProcessState, command_tokens: []string, working_directory: string = "") -> bool {
	state^ = ProcessState{}
	if len(command_tokens) == 0 { return false }

	stdin_pair:  [2]posix.FD
	stdout_pair: [2]posix.FD
	stderr_pair: [2]posix.FD
	if posix.pipe(&stdin_pair)  != .OK { return false }
	if posix.pipe(&stdout_pair) != .OK { posix.close(stdin_pair[0]);  posix.close(stdin_pair[1]); return false }
	if posix.pipe(&stderr_pair) != .OK {
		posix.close(stdin_pair[0]);  posix.close(stdin_pair[1])
		posix.close(stdout_pair[0]); posix.close(stdout_pair[1])
		return false
	}

	argv_cstrings := make([]cstring, len(command_tokens) + 1, context.temp_allocator)
	for token, token_index in command_tokens {
		argv_cstrings[token_index] = strings.clone_to_cstring(token, context.temp_allocator)
	}
	argv_cstrings[len(command_tokens)] = nil

	working_directory_cstring: cstring = nil
	if len(working_directory) > 0 {
		working_directory_cstring = strings.clone_to_cstring(working_directory, context.temp_allocator)
	}

	child_pid := posix.fork()
	if child_pid < 0 {
		posix.close(stdin_pair[0]);  posix.close(stdin_pair[1])
		posix.close(stdout_pair[0]); posix.close(stdout_pair[1])
		posix.close(stderr_pair[0]); posix.close(stderr_pair[1])
		return false
	}

	if child_pid == 0 {
		// --- Child ---
		posix.dup2(stdin_pair[0],  posix.FD(0))
		posix.dup2(stdout_pair[1], posix.FD(1))
		posix.dup2(stderr_pair[1], posix.FD(2))

		posix.close(stdin_pair[0]);  posix.close(stdin_pair[1])
		posix.close(stdout_pair[0]); posix.close(stdout_pair[1])
		posix.close(stderr_pair[0]); posix.close(stderr_pair[1])

		if working_directory_cstring != nil { chdir(working_directory_cstring) }

		posix.execvp(argv_cstrings[0], raw_data(argv_cstrings))
		_exit(127)
	}

	// --- Parent ---
	posix.close(stdin_pair[0])
	posix.close(stdout_pair[1])
	posix.close(stderr_pair[1])

	state.child_pid   = child_pid
	state.stdin_write = stdin_pair[1]
	state.stdout_read = stdout_pair[0]
	state.stderr_read = stderr_pair[0]

	for handle in ([?]posix.FD{ state.stdout_read, state.stderr_read }) {
		flags := posix.fcntl(handle, .GETFL)
		posix.fcntl(handle, .SETFL, flags | c.int(posix.O_NONBLOCK))
	}

	return true
}

@(private)
process_close :: proc(state: ^ProcessState) {
	if state.child_pid > 0 { posix.kill(state.child_pid, .SIGTERM) }
	if state.stdin_write != 0 { posix.close(state.stdin_write); state.stdin_write = 0 }
	if state.stdout_read != 0 { posix.close(state.stdout_read); state.stdout_read = 0 }
	if state.stderr_read != 0 { posix.close(state.stderr_read); state.stderr_read = 0 }
}

@(private)
process_finalize :: proc(state: ^ProcessState) {
	if state.child_pid > 0 {
		status: c.int
		for attempt in 0..<50 {
			result := posix.waitpid(state.child_pid, &status, { .NOHANG })
			if result == state.child_pid {
				if posix.WIFEXITED(status) { state.exit_code = i32(posix.WEXITSTATUS(status)) }
				state.has_exit = true
				break
			}
			if attempt == 10 { posix.kill(state.child_pid, .SIGKILL) }
			libc_usleep(10_000)
		}
		state.child_pid = 0
	}
}

// Blocking-when-idle stdout read used by the reader thread: yields the CPU
// briefly on EAGAIN so it doesn't peg a core, but eventually returns so
// `is_alive` gets re-checked.
@(private)
process_read :: proc(state: ^ProcessState, buffer: []u8) -> (bytes_read: int, ok: bool) {
	if state.stdout_read == 0 { return 0, false }
	result := posix.read(state.stdout_read, raw_data(buffer), c.size_t(len(buffer)))
	if result > 0 { return int(result), true }
	if result == 0 { return 0, false }
	err := posix.errno()
	if err == .EAGAIN || err == .EWOULDBLOCK || err == .EINTR {
		libc_usleep(10_000)
		return 0, true
	}
	return 0, false
}

// Non-blocking stderr drain used by the main thread's per-frame update. No
// sleep: if the pipe is empty we return immediately (with ok=true) so the
// frame loop doesn't stall.
@(private)
process_read_stderr :: proc(state: ^ProcessState, buffer: []u8) -> (bytes_read: int, ok: bool) {
	if state.stderr_read == 0 { return 0, false }
	result := posix.read(state.stderr_read, raw_data(buffer), c.size_t(len(buffer)))
	if result > 0 { return int(result), true }
	if result == 0 {
		// Peer closed and we drained everything. Treat as clean EOF, not
		// an error — matches the Windows non-blocking helper.
		return 0, true
	}
	err := posix.errno()
	if err == .EAGAIN || err == .EWOULDBLOCK || err == .EINTR { return 0, true }
	return 0, false
}

@(private)
process_write :: proc(state: ^ProcessState, data: []u8) -> int {
	if state.stdin_write == 0 || len(data) == 0 { return 0 }
	total_written := 0
	for total_written < len(data) {
		result := posix.write(state.stdin_write, raw_data(data[total_written:]), c.size_t(uint(len(data)) - uint(total_written)))
		if result <= 0 {
			err := posix.errno()
			if err == .EINTR { continue }
			break
		}
		total_written += int(result)
	}
	return total_written
}

// Non-blocking exit poll on the child process. Mirrors the Windows variant
// so the editor can detect an adapter that died before it ever spoke DAP.
@(private)
process_check_exit :: proc(state: ^ProcessState) -> (exited: bool, exit_code: i32) {
	if state.has_exit { return true, state.exit_code }
	if state.child_pid <= 0 { return false, 0 }

	status: c.int
	result := posix.waitpid(state.child_pid, &status, { .NOHANG })
	if result == 0 || result < 0 { return false, 0 }

	if posix.WIFEXITED(status) {
		state.exit_code = i32(posix.WEXITSTATUS(status))
	} else if posix.WIFSIGNALED(status) {
		state.exit_code = 128 + i32(posix.WTERMSIG(status))
	}
	state.has_exit = true
	return true, state.exit_code
}

// Resolve a bare command token to its absolute path by walking PATH, the
// same way execvp does. Returns "" when nothing on PATH matches. Result is
// owned by `allocator`. Used by the editor's DAP diagnostic output so the
// user can see *which* binary was picked.
process_resolve_executable :: proc(command_token: string, allocator := context.allocator) -> string {
	if len(command_token) == 0 { return "" }

	// Already absolute / explicit path → don't search PATH, just verify it
	// exists and is executable. This matches execvp semantics.
	if strings.contains_rune(command_token, '/') {
		if is_executable_file(command_token) {
			return strings.clone(command_token, allocator)
		}
		return ""
	}

	path_value := os.get_env("PATH", context.temp_allocator)
	if len(path_value) == 0 { return "" }

	for path_entry in strings.split(path_value, ":", context.temp_allocator) {
		if len(path_entry) == 0 { continue }
		candidate, _ := filepath.join({ path_entry, command_token }, context.temp_allocator)
		if is_executable_file(candidate) {
			return strings.clone(candidate, allocator)
		}
	}
	return ""
}

@(private="file")
is_executable_file :: proc(path: string) -> bool {
	path_cstring := strings.clone_to_cstring(path, context.temp_allocator)
	// access(path, X_OK) returns 0 when the calling process has execute
	// permission. Good enough for "would execvp succeed".
	return posix.access(path_cstring, { .X_OK }) == .OK
}

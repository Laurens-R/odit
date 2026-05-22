#+build !windows
package lsp

import "core:c"
import "core:strings"
import "core:sys/posix"

// POSIX equivalent of the Windows stdio-pipe layer in `process_windows.odin`.
// One pipe per direction (plus stderr), child runs via fork+execvp. The
// reader side (`stdout_read`) is set non-blocking so the reader thread can
// idle-tick instead of parking in a blocking read — matching the Windows
// `PeekNamedPipe` rhythm so `is_alive` gets re-checked on shutdown.
ProcessState :: struct {
	child_pid:    posix.pid_t,
	stdin_write:  posix.FD,
	stdout_read:  posix.FD,
	stderr_read:  posix.FD,
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

	// Pre-build argv as cstrings before fork — anything that allocates is
	// off-limits between fork() and execvp() because it isn't
	// async-signal-safe.
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
		// Wire pipes into stdio. Each pair's "other" end is what the
		// parent keeps; we close it post-dup2 to avoid leaking handles
		// into the language server itself.
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
	// Close child-side ends so EOF propagates correctly when the child
	// exits or closes its own stdio.
	posix.close(stdin_pair[0])
	posix.close(stdout_pair[1])
	posix.close(stderr_pair[1])

	state.child_pid   = child_pid
	state.stdin_write = stdin_pair[1]
	state.stdout_read = stdout_pair[0]
	state.stderr_read = stderr_pair[0]

	// Non-blocking reads so the reader thread can idle-tick on the
	// `is_alive` flag instead of parking forever in a blocking read.
	for handle in ([?]posix.FD{ state.stdout_read, state.stderr_read }) {
		flags := posix.fcntl(handle, .GETFL)
		posix.fcntl(handle, .SETFL, flags | c.int(posix.O_NONBLOCK))
	}

	return true
}

// Phase 1 of shutdown — kill the child and close pipes. The reader thread
// notices the EOF on stdout_read and exits; process_finalize then reaps.
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
			if result == state.child_pid { break }
			if attempt == 10 { posix.kill(state.child_pid, .SIGKILL) }
			libc_usleep(10_000)
		}
		state.child_pid = 0
	}
}

@(private)
process_read :: proc(state: ^ProcessState, buffer: []u8) -> (bytes_read: int, ok: bool) {
	if state.stdout_read == 0 { return 0, false }
	result := posix.read(state.stdout_read, raw_data(buffer), c.size_t(len(buffer)))
	if result > 0 { return int(result), true }
	if result == 0 { return 0, false } // EOF, peer closed
	err := posix.errno()
	if err == .EAGAIN || err == .EWOULDBLOCK || err == .EINTR {
		libc_usleep(10_000)
		return 0, true
	}
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

@(private)
get_process_id_platform :: proc() -> int {
	return int(posix.getpid())
}

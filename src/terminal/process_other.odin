#+build !windows
package terminal

import "core:c"
import "core:os"
import "core:strings"
import "core:sys/posix"

// POSIX PTY-flavored process state. The "master" file descriptor is what
// the host reads/writes; the slave end becomes the child's stdio. We keep
// the child pid around so we can signal/reap it and so the task runner can
// poll for exit. Mirrors the Windows ConPTY layer in `process_windows.odin`.
PtyState :: struct {
	master_fd: posix.FD,
	child_pid: posix.pid_t,
	has_exit:  bool, // set once waitpid(WNOHANG) reports the child gone
	exit_code: i32,
}

// Direct libc bindings for the bits `core:sys/posix` doesn't expose:
//   - `ioctl` for TIOCSCTTY (give child a controlling terminal) and
//     TIOCSWINSZ (push our column/row count down to the kernel pty).
//   - `chdir` for the child's pre-exec cwd switch — must be async-signal-safe.
//   - `_exit` so a failed exec in the child doesn't run atexit / flush
//     stdio that the parent shares (would corrupt our own state).
when ODIN_OS == .Darwin {
	foreign import system_lib "system:System"
	@(default_calling_convention="c")
	foreign system_lib {
		ioctl :: proc(fd: posix.FD, request: c.ulong, #c_vararg args: ..any) -> c.int ---
		chdir :: proc(path: cstring) -> c.int ---
		_exit :: proc(status: c.int) -> ! ---
		setenv :: proc(name: cstring, value: cstring, overwrite: c.int) -> c.int ---
		@(link_name="usleep") libc_usleep :: proc(microseconds: c.uint) -> c.int ---
	}
} else {
	foreign import system_lib "system:c"
	@(default_calling_convention="c")
	foreign system_lib {
		ioctl :: proc(fd: posix.FD, request: c.ulong, #c_vararg args: ..any) -> c.int ---
		chdir :: proc(path: cstring) -> c.int ---
		_exit :: proc(status: c.int) -> ! ---
		setenv :: proc(name: cstring, value: cstring, overwrite: c.int) -> c.int ---
		@(link_name="usleep") libc_usleep :: proc(microseconds: c.uint) -> c.int ---
	}
}

// TIOCSWINSZ / TIOCSCTTY request numbers. These are macros in <sys/ioctl.h>
// and differ per OS (Darwin uses BSD-style _IOW-encoded values, Linux uses
// plain small constants). Hardcoded here so we don't need a header dance.
when ODIN_OS == .Darwin {
	TIOCSWINSZ :: c.ulong(0x80087467)
	TIOCSCTTY  :: c.ulong(0x20007461)
} else when ODIN_OS == .Linux {
	TIOCSWINSZ :: c.ulong(0x5414)
	TIOCSCTTY  :: c.ulong(0x540E)
} else {
	TIOCSWINSZ :: c.ulong(0x80087467)
	TIOCSCTTY  :: c.ulong(0x20007461)
}

winsize :: struct {
	ws_row:    c.ushort,
	ws_col:    c.ushort,
	ws_xpixel: c.ushort,
	ws_ypixel: c.ushort,
}

// Spawn a process attached to a fresh pseudo-terminal sized columns x rows.
// On success, `terminal.pty_state` is populated and ready for read/write.
// On failure everything is cleaned up and the proc returns false.
//
// `command_line` empty → interactive shell (from $SHELL, falling back to
// /bin/zsh on darwin and /bin/bash elsewhere). Non-empty strings are run
// through `/bin/sh -c <command_line>` so callers can pass an
// already-assembled shell command (mirrors what build/task runners hand
// the Windows PowerShell path).
@(private)
pty_spawn :: proc(terminal: ^Terminal, columns, rows: i32, working_directory: string = "", command_line: string = "") -> bool {
	pty_state := &terminal.pty_state
	pty_state^ = PtyState{}

	master_fd := posix.posix_openpt({ .RDWR, .NOCTTY })
	if master_fd < 0 { return false }
	if posix.grantpt(master_fd)  != .OK { posix.close(master_fd); return false }
	if posix.unlockpt(master_fd) != .OK { posix.close(master_fd); return false }

	slave_path_cstring := posix.ptsname(master_fd)
	if slave_path_cstring == nil { posix.close(master_fd); return false }

	// Set the initial window size on the master before fork so the child
	// inherits a sane geometry — otherwise shells that read winsize at
	// startup get the default 80x24 and only react on the first SIGWINCH.
	initial_size := winsize{
		ws_row    = c.ushort(rows),
		ws_col    = c.ushort(columns),
		ws_xpixel = 0,
		ws_ypixel = 0,
	}
	ioctl(master_fd, TIOCSWINSZ, &initial_size)

	// Pre-build everything the child needs *before* fork. After fork we're
	// restricted to async-signal-safe functions, so no `make`,
	// `strings.clone_to_cstring`, or `context.allocator` use.
	//
	// Both branches route through the user's `$SHELL` (zsh on macOS,
	// usually bash on Linux) rather than `/bin/sh`. This matters because
	// GUI-launched editors inherit a stripped PATH from launchd / Finder
	// (just `/usr/bin:/bin:…`), so anything the user added in `.zshenv` /
	// `.zprofile` — like a manually installed `odin` toolchain — isn't
	// visible unless we hand the command to a shell that loads those files.
	//   - Interactive F9 sessions:   `$SHELL -i`   (sources .zshrc)
	//   - Build / task commands:     `$SHELL -l -c …`   (sources .zshenv +
	//     .zprofile, *not* .zshrc — non-interactive sessions skip it; users
	//     who want a PATH visible to build tasks must put it in .zshenv).
	shell_path := os.get_env("SHELL", context.temp_allocator)
	if len(shell_path) == 0 {
		when ODIN_OS == .Darwin { shell_path = "/bin/zsh"  }
		else                    { shell_path = "/bin/bash" }
	}
	shell_path_cstring := strings.clone_to_cstring(shell_path, context.temp_allocator)

	argv_cstrings: [4]cstring
	if len(command_line) > 0 {
		argv_cstrings[0] = shell_path_cstring
		argv_cstrings[1] = cstring("-lc")
		argv_cstrings[2] = strings.clone_to_cstring(command_line, context.temp_allocator)
		argv_cstrings[3] = nil
	} else {
		argv_cstrings[0] = shell_path_cstring
		argv_cstrings[1] = cstring("-i")
		argv_cstrings[2] = nil
		argv_cstrings[3] = nil
	}

	working_directory_cstring: cstring = nil
	if len(working_directory) > 0 {
		working_directory_cstring = strings.clone_to_cstring(working_directory, context.temp_allocator)
	}

	child_pid := posix.fork()
	if child_pid < 0 {
		posix.close(master_fd)
		return false
	}

	if child_pid == 0 {
		// --- Child ---
		// Detach from the parent's controlling terminal, then re-open the
		// slave end and make it our new ctty. Order matters: setsid first
		// (becomes session leader), open(slave), TIOCSCTTY second.
		posix.setsid()

		slave_fd := posix.open(slave_path_cstring, { .RDWR })
		if slave_fd < 0 { _exit(127) }

		// Best-effort: TIOCSCTTY only works on a session leader with no
		// existing ctty. Failure is acceptable on Linux where opening the
		// pty slave already assigns one.
		ioctl(slave_fd, TIOCSCTTY, uintptr(0))

		// Plumb slave into the standard fds. After dup2 we no longer need
		// the original slave handle.
		posix.dup2(slave_fd, posix.FD(0))
		posix.dup2(slave_fd, posix.FD(1))
		posix.dup2(slave_fd, posix.FD(2))
		if slave_fd > 2 { posix.close(slave_fd) }

		// Close the master end inherited from the parent — the child has no
		// business reading or writing it.
		posix.close(master_fd)

		// Optional cwd switch. Ignore failures; the shell will start in
		// the inherited cwd, which is at worst a minor UX glitch.
		if working_directory_cstring != nil { chdir(working_directory_cstring) }

		// TERM unlocks curses-style programs (vim, less) to a reasonable
		// baseline; COLORTERM=truecolor unlocks 24-bit color paths.
		// setenv isn't in core:c/libc so we bind it locally below.
		setenv(cstring("TERM"),      cstring("xterm-256color"), 1)
		setenv(cstring("COLORTERM"), cstring("truecolor"),      1)

		posix.execvp(argv_cstrings[0], raw_data(argv_cstrings[:]))
		// exec only returns on failure — bail without running parent atexit.
		_exit(127)
	}

	// --- Parent ---
	pty_state.master_fd = master_fd
	pty_state.child_pid = child_pid

	// Non-blocking master so the reader thread can wake for shutdown
	// instead of sitting in a blocking read.
	flags := posix.fcntl(master_fd, .GETFL)
	posix.fcntl(master_fd, .SETFL, flags | c.int(posix.O_NONBLOCK))

	return true
}

// Phase 1 of shutdown — terminate the child and close the master so the
// reader thread's poll() returns. Symmetric with the Windows two-phase
// shutdown; we don't waitpid() here because the reader may still be
// running and pty_finalize() does the reaping.
@(private)
pty_close :: proc(terminal: ^Terminal) {
	pty_state := &terminal.pty_state

	if pty_state.child_pid > 0 {
		// SIGTERM first so well-behaved shells get a chance to clean up;
		// pty_finalize will SIGKILL anything still alive.
		posix.kill(pty_state.child_pid, .SIGTERM)
	}
	if pty_state.master_fd > 0 {
		posix.close(pty_state.master_fd)
		pty_state.master_fd = 0
	}
}

@(private)
pty_finalize :: proc(terminal: ^Terminal) {
	pty_state := &terminal.pty_state

	if pty_state.child_pid > 0 {
		// Reap the child. If SIGTERM didn't take it down within a few
		// polls, escalate to SIGKILL so we don't sit here forever.
		status: c.int
		for attempt in 0..<50 {
			result := posix.waitpid(pty_state.child_pid, &status, { .NOHANG })
			if result == pty_state.child_pid {
				if posix.WIFEXITED(status) {
					pty_state.exit_code = i32(posix.WEXITSTATUS(status))
				}
				pty_state.has_exit = true
				break
			}
			if attempt == 10 { posix.kill(pty_state.child_pid, .SIGKILL) }
			libc_usleep(10_000) // 10 ms
		}
		pty_state.child_pid = 0
	}
}

@(private)
pty_resize :: proc(terminal: ^Terminal, columns, rows: i32) {
	if terminal.pty_state.master_fd <= 0 { return }
	size := winsize{
		ws_row    = c.ushort(rows),
		ws_col    = c.ushort(columns),
		ws_xpixel = 0,
		ws_ypixel = 0,
	}
	ioctl(terminal.pty_state.master_fd, TIOCSWINSZ, &size)
}

// Non-blocking read on the master. The master fd is in O_NONBLOCK mode so
// read() returns EAGAIN when idle — we surface that as a zero-byte
// successful read after a short sleep so the caller re-checks `is_alive`,
// matching the Windows `PeekNamedPipe` rhythm.
@(private)
pty_read :: proc(terminal: ^Terminal, read_buffer: []u8) -> (bytes_read: int, read_succeeded: bool) {
	if terminal.pty_state.master_fd <= 0 { return 0, false }

	result := posix.read(terminal.pty_state.master_fd, raw_data(read_buffer), c.size_t(len(read_buffer)))
	if result > 0 { return int(result), true }
	if result == 0 {
		// EOF — child closed all writable ends of the pty. Treat as broken
		// so the reader thread exits.
		return 0, false
	}

	// result < 0 — EAGAIN/EWOULDBLOCK is idle, EINTR is a benign retry;
	// anything else is fatal for this fd.
	err := posix.errno()
	if err == .EAGAIN || err == .EWOULDBLOCK || err == .EINTR {
		libc_usleep(10_000)
		return 0, true
	}
	return 0, false
}

@(private)
pty_write :: proc(terminal: ^Terminal, data: []u8) -> int {
	if terminal.pty_state.master_fd <= 0 || len(data) == 0 { return 0 }
	total_written := 0
	for total_written < len(data) {
		result := posix.write(terminal.pty_state.master_fd, raw_data(data[total_written:]), c.size_t(uint(len(data)) - uint(total_written)))
		if result <= 0 {
			err := posix.errno()
			if err == .EINTR { continue }
			break
		}
		total_written += int(result)
	}
	return total_written
}

// Non-blocking process-exit check. Returns `(true, exit_code)` once the
// child has terminated, `(false, 0)` while it's still running. Used by the
// task runner to drive build → debug chaining.
@(private)
pty_check_process_exit :: proc(terminal: ^Terminal) -> (exited: bool, exit_code: i32) {
	pty_state := &terminal.pty_state
	if pty_state.has_exit { return true, pty_state.exit_code }
	if pty_state.child_pid <= 0 { return false, 0 }

	status: c.int
	result := posix.waitpid(pty_state.child_pid, &status, { .NOHANG })
	if result == 0 || result < 0 { return false, 0 }

	if posix.WIFEXITED(status) {
		pty_state.exit_code = i32(posix.WEXITSTATUS(status))
	} else if posix.WIFSIGNALED(status) {
		pty_state.exit_code = 128 + i32(posix.WTERMSIG(status))
	}
	pty_state.has_exit = true
	return true, pty_state.exit_code
}

#+build !windows
package terminal

// Stub for non-Windows platforms. POSIX support would use posix_openpt /
// grantpt / unlockpt and fork+execvp; building that out is a separate PR.
PtyState :: struct {}

@(private)
pty_spawn    :: proc(terminal: ^Terminal, columns, rows: i32, working_directory: string = "") -> bool { return false }
@(private)
pty_close    :: proc(terminal: ^Terminal) {}
@(private)
pty_finalize :: proc(terminal: ^Terminal) {}
@(private)
pty_resize   :: proc(terminal: ^Terminal, columns, rows: i32) {}
@(private)
pty_read     :: proc(terminal: ^Terminal, buffer: []u8) -> (int, bool) { return 0, false }
@(private)
pty_write    :: proc(terminal: ^Terminal, data: []u8) -> int { return 0 }

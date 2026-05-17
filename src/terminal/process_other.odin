#+build !windows
package terminal

// Stub for non-Windows platforms. POSIX support would use posix_openpt /
// grantpt / unlockpt and fork+execvp; building that out is a separate PR.
PtyState :: struct {}

@(private)
pty_spawn    :: proc(t: ^Terminal, cols, rows: i32) -> bool { return false }
@(private)
pty_close    :: proc(t: ^Terminal) {}
@(private)
pty_finalize :: proc(t: ^Terminal) {}
@(private)
pty_resize   :: proc(t: ^Terminal, cols, rows: i32) {}
@(private)
pty_read     :: proc(t: ^Terminal, buf: []u8) -> (int, bool) { return 0, false }
@(private)
pty_write    :: proc(t: ^Terminal, data: []u8) -> int { return 0 }

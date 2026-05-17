#+build windows
package terminal

import win32 "core:sys/windows"

// ConPTY-flavored process state. We keep separate "host" handles (what the
// parent reads/writes) and "pty" handles (what gets handed to the child via
// CreatePseudoConsole). The pty handles get closed right after the console
// is created — they're owned by the kernel from that point on.
PtyState :: struct {
	hpcon:        HPCON,
	process:      win32.HANDLE,
	thread_h:     win32.HANDLE,
	pipe_in:      win32.HANDLE, // host writes to shell stdin
	pipe_out:     win32.HANDLE, // host reads from shell stdout/stderr
	attr_list:    rawptr,
	attr_list_size: win32.SIZE_T,
}

HPCON :: distinct rawptr

EXTENDED_STARTUPINFO_PRESENT          :: 0x00080000
PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE   :: 0x00020016

STARTUPINFOEXW :: struct {
	StartupInfo:     win32.STARTUPINFOW,
	lpAttributeList: rawptr,
}

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention="system")
foreign kernel32 {
	CreatePseudoConsole :: proc(
		size:        win32.COORD,
		h_input:     win32.HANDLE,
		h_output:    win32.HANDLE,
		dw_flags:    win32.DWORD,
		ph_pc:       ^HPCON,
	) -> win32.HRESULT ---

	ResizePseudoConsole :: proc(h_pc: HPCON, size: win32.COORD) -> win32.HRESULT ---

	ClosePseudoConsole :: proc(h_pc: HPCON) ---

	InitializeProcThreadAttributeList :: proc(
		lp_attribute_list:  rawptr,
		dw_attribute_count: win32.DWORD,
		dw_flags:           win32.DWORD,
		lp_size:            ^win32.SIZE_T,
	) -> win32.BOOL ---

	UpdateProcThreadAttribute :: proc(
		lp_attribute_list:  rawptr,
		dw_flags:           win32.DWORD,
		attribute:          uintptr,
		lp_value:           rawptr,
		cb_size:            win32.SIZE_T,
		lp_previous_value:  rawptr,
		lp_return_size:     ^win32.SIZE_T,
	) -> win32.BOOL ---

	DeleteProcThreadAttributeList :: proc(lp_attribute_list: rawptr) ---
}

// Spawn powershell.exe attached to a fresh pseudo-console sized cols x rows.
// On success, `t.pty` is fully populated and ready for read/write. On
// failure, everything is closed and the proc returns false; the caller
// typically falls back to "no terminal".
@(private)
pty_spawn :: proc(t: ^Terminal, cols, rows: i32) -> bool {
	pty := &t.pty
	pty^ = PtyState{}

	// Two pairs of anonymous pipes — one in each direction.
	pty_in_read,  pty_in_write : win32.HANDLE
	pty_out_read, pty_out_write: win32.HANDLE

	sa := win32.SECURITY_ATTRIBUTES{}
	sa.nLength = size_of(win32.SECURITY_ATTRIBUTES)
	sa.bInheritHandle = true

	if !win32.CreatePipe(&pty_in_read,  &pty_in_write,  &sa, 0) { return false }
	if !win32.CreatePipe(&pty_out_read, &pty_out_write, &sa, 0) {
		win32.CloseHandle(pty_in_read);  win32.CloseHandle(pty_in_write)
		return false
	}

	size := win32.COORD{ X = i16(cols), Y = i16(rows) }
	hr := CreatePseudoConsole(size, pty_in_read, pty_out_write, 0, &pty.hpcon)
	// CreatePseudoConsole duplicates the handles it cares about; we can
	// close the child-side pipes once the call returns.
	win32.CloseHandle(pty_in_read)
	win32.CloseHandle(pty_out_write)
	if hr != 0 {
		win32.CloseHandle(pty_in_write); win32.CloseHandle(pty_out_read)
		return false
	}

	pty.pipe_in  = pty_in_write
	pty.pipe_out = pty_out_read

	// Build the STARTUPINFOEX with one extended attribute carrying the HPCON.
	size_needed: win32.SIZE_T
	InitializeProcThreadAttributeList(nil, 1, 0, &size_needed)
	pty.attr_list      = raw_alloc(int(size_needed))
	pty.attr_list_size = size_needed
	if pty.attr_list == nil {
		pty_close(t); pty_finalize(t)
		return false
	}
	if !InitializeProcThreadAttributeList(pty.attr_list, 1, 0, &size_needed) {
		pty_close(t); pty_finalize(t)
		return false
	}
	if !UpdateProcThreadAttribute(
		pty.attr_list,
		0,
		PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
		rawptr(pty.hpcon),
		size_of(HPCON),
		nil,
		nil,
	) {
		pty_close(t); pty_finalize(t)
		return false
	}

	si := STARTUPINFOEXW{}
	si.StartupInfo.cb              = u32(size_of(STARTUPINFOEXW))
	si.lpAttributeList             = pty.attr_list

	// Build the command line in a writable wide buffer — CreateProcessW
	// requires lpCommandLine to be mutable.
	cmdline := win32.utf8_to_wstring(`powershell.exe -NoLogo`)

	pi := win32.PROCESS_INFORMATION{}
	ok := win32.CreateProcessW(
		nil,                          // lpApplicationName
		cmdline,                      // lpCommandLine (writable wstring)
		nil, nil,
		false,                        // bInheritHandles — handles flow via the attribute list
		EXTENDED_STARTUPINFO_PRESENT,
		nil, nil,
		&si.StartupInfo,
		&pi,
	)
	if !ok {
		pty_close(t); pty_finalize(t)
		return false
	}

	pty.process  = pi.hProcess
	pty.thread_h = pi.hThread
	return true
}

// Phase 1 of shutdown — terminate the child and close the host-side pipes.
// Doing the kill first means ClosePseudoConsole (called later in
// `pty_finalize`) won't sit there waiting for the shell to exit. Closing
// `pipe_out` is what releases a ReadFile that the reader thread might be
// blocked in, so this MUST run before joining that thread.
@(private)
pty_close :: proc(t: ^Terminal) {
	pty := &t.pty

	if pty.process != nil {
		win32.TerminateProcess(pty.process, 0)
	}
	if pty.pipe_in != nil {
		win32.CloseHandle(pty.pipe_in);  pty.pipe_in = nil
	}
	if pty.pipe_out != nil {
		win32.CloseHandle(pty.pipe_out); pty.pipe_out = nil
	}
}

// Phase 2 of shutdown — only safe once the reader thread is no longer
// touching anything in `t.pty`. Releases the pseudo-console, the process /
// thread handles, and the proc-thread attribute list.
@(private)
pty_finalize :: proc(t: ^Terminal) {
	pty := &t.pty

	if pty.hpcon != nil {
		ClosePseudoConsole(pty.hpcon);   pty.hpcon = nil
	}
	if pty.process != nil {
		win32.CloseHandle(pty.process);  pty.process = nil
	}
	if pty.thread_h != nil {
		win32.CloseHandle(pty.thread_h); pty.thread_h = nil
	}
	if pty.attr_list != nil {
		DeleteProcThreadAttributeList(pty.attr_list)
		raw_free(pty.attr_list)
		pty.attr_list = nil
	}
}

@(private)
pty_resize :: proc(t: ^Terminal, cols, rows: i32) {
	if t.pty.hpcon == nil { return }
	ResizePseudoConsole(t.pty.hpcon, win32.COORD{ X = i16(cols), Y = i16(rows) })
}

// Poll the output pipe instead of blocking on `ReadFile` directly.
//
// On Windows, `CloseHandle` from another thread does NOT reliably unblock a
// synchronous `ReadFile` already in progress — the reader stays parked and a
// subsequent `thread.join` hangs forever. So we use `PeekNamedPipe` first:
// it returns immediately, tells us how many bytes are queued, and surfaces
// pipe-closed errors. When nothing is available we yield with a short
// `Sleep` so `t.alive` gets reconsulted on the next loop iteration. That's
// the actual shutdown signal — the reader notices it and exits on its own.
@(private)
pty_read :: proc(t: ^Terminal, buf: []u8) -> (n: int, ok: bool) {
	if t.pty.pipe_out == nil { return 0, false }

	available: u32
	if !win32.PeekNamedPipe(t.pty.pipe_out, nil, 0, nil, &available, nil) {
		// Pipe broken / closed → tell the caller to bail out of its loop.
		return 0, false
	}
	if available == 0 {
		// Idle-wait briefly so we're not pegging a core, then surface a
		// "successful zero-byte read" so the caller can re-check `t.alive`.
		win32.Sleep(10)
		return 0, true
	}

	to_read := u32(len(buf))
	if to_read > available { to_read = available }

	read: u32
	if !win32.ReadFile(t.pty.pipe_out, raw_data(buf), to_read, &read, nil) {
		return 0, false
	}
	return int(read), true
}

@(private)
pty_write :: proc(t: ^Terminal, data: []u8) -> int {
	if t.pty.pipe_in == nil || len(data) == 0 { return 0 }
	written: u32
	if !win32.WriteFile(t.pty.pipe_in, raw_data(data), u32(len(data)), &written, nil) {
		return 0
	}
	return int(written)
}

// --- Helpers ------------------------------------------------------------

@(private="file")
raw_alloc :: proc(n: int) -> rawptr {
	heap := win32.GetProcessHeap()
	return win32.HeapAlloc(heap, 0, win32.SIZE_T(n))
}

@(private="file")
raw_free :: proc(p: rawptr) {
	if p == nil { return }
	heap := win32.GetProcessHeap()
	win32.HeapFree(heap, 0, p)
}


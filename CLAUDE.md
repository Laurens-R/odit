# Odit

Terminal-inspired text editor written in Odin, built on SDL3. Single-binary,
self-contained: language definitions, the font, and per-platform default
keybindings are embedded at compile time. Targets Windows, Linux, and macOS;
ships with an embedded shell terminal, LSP client, and DAP debugger.

## Build

Wrappers compile and stage runtime dependencies (SDL3 / SDL3_ttf, vendored
LSP/DAP binaries under `vendor/<platform>/lsp/`) alongside the binary:

```
scripts/build.ps1 -Target windows -Config debug      # PowerShell
scripts/build.sh   linux  debug                      # POSIX (positional args)
scripts/build.sh   macos  release
```

`scripts/build_self.{ps1,sh}` builds a sibling binary at
`out/<target>/<config>/odit_self(.exe)` — used when the user has the main
`odit.exe` open and the file is locked. Prefer this over hand-rolling a
sibling output path.

Direct `odin build` (skips dependency staging, useful for quick syntax checks):

```
odin build src -target:windows_amd64 -out:out/windows/debug/odit.exe -debug
```

Vendor layout: `vendor/<file>` is staged for every target; `vendor/<target>/`
is overlaid on top with the platform prefix stripped (`vendor/windows/lsp/ols.exe`
→ `out/windows/<config>/lsp/ols.exe`). `README.md` files are skipped.

The user often runs the editor while iterating, which holds a file lock on
`odit.exe`. If a build fails with `LNK1104: cannot open file`, use
`build_self` (or drop to a sibling path) for the type-check and clean up
afterwards.

## Layout

- `src/main.odin` — entry point + main loop. Frees `context.temp_allocator`
  once per frame; anything that must outlive a frame uses `context.allocator`.
- `src/editor/` — panes, modals, input dispatch, rendering. Most of the
  shared state lives on `Editor` (`editor.odin`); per-pane state on
  `EditorPane`. LSP/DAP glue lives in `lsp_integration.odin` /
  `dap_integration.odin` — the protocol clients themselves are in their
  own packages.
- `src/document/` — piece tree + per-document undo/redo stack. Compound edits
  group multiple ops into one undo step.
- `src/syntax/` — language definitions, per-line lexer/tokenizer, whole-file
  symbol extractor used by F6.
- `src/syntax/languages/*.json` — language defs. New languages: drop a JSON
  file in and append a `#load` line to `LANGUAGE_BLOBS` in `loader.odin`.
- `src/ui/` — reusable widgets (`draw_window`, `draw_button`,
  `draw_input_field`, `draw_list_row`, …). UI procs know nothing about the
  editor — they take a `ui.Context` with renderer + font metrics.
- `src/terminal/` — embedded shell emulator (F9). Platform process spawn
  split into `process_windows.odin` (ConPTY) and `process_other.odin` (pty).
- `src/lsp/` — LSP client. Protocol types in `protocol.odin`, message
  framing in `messages.odin`, per-server process management split into
  `process_windows.odin` / `process_other.odin`. Public surface is
  `lsp.odin` (request/response routing, diagnostics, hover, completion,
  signature help).
- `src/dap/` — DAP debugger client. Same split as LSP: `protocol.odin`,
  `messages.odin`, platform process files, `dap.odin` for the public API
  (launch/attach, breakpoints, stepping, stackframes, scopes/variables).
- `src/keybindings/` — `Action` enum + per-platform JSON in
  `defaults/{windows,linux,macos}.json` embedded at compile time. User
  overrides load from disk on top.
- `src/collections/` — small reusable containers (e.g. `ringbuffer.odin`
  used by the terminal scrollback and DAP output capture).

## Conventions

- **Tabs** for indentation. Verbose, descriptive identifiers (no `i`/`tmp`/`buf`).
- Comments explain **why**, not what — hidden constraints, surprising
  tradeoffs, prior incidents. If removing a comment wouldn't confuse a
  future reader, it shouldn't be there.
- `@(private)` is package-private, `@(private="file")` is file-private.
  Prefer file-private; promote only when another file in the same package
  legitimately needs the symbol.
- Use named struct literals (`Foo{kind = .Bar, x = 1}`) when the struct has
  more than ~3 fields or when adding fields is likely — positional literals
  break silently when the struct grows.
- Platform-specific code goes in `_windows.odin` / `_other.odin` (or
  similar) files using Odin's file-suffix build constraints. Don't
  `when ODIN_OS == ...` inside a shared file when a split file is cleaner.

## Modal-dialog pattern

Every modal in the editor follows the same shape — Find-in-Files,
Replace-in-Files, Save-As, Close-Confirm, Git-History, Symbols (F6), File
Browser (F2), Tasks dialog (F7), Breakpoint-condition, Terminal picker,
Open-docs. When adding a new modal, copy one of those and follow the
checklist:

1. State struct + `show_X: bool` field on `Editor` (`editor.odin`).
2. `X_open` / `X_close` / `X_destroy` lifecycle procs. Destroy is invoked
   from `editor_destroy` for owned heap state (dynamic arrays, cloned strings).
3. Add the flag to `editor_is_modal_open` so global hotkeys (F1, F2, …) get
   suppressed while the modal owns input.
4. Modal dispatch in `editor_handle_event` (`input.odin`) — early return when
   the flag is set. Order matters: more-specific modals first.
5. Render call in `editor_render` (`render.odin`), painted *after* the
   existing modal stack so it overlays correctly.
6. Field rectangles (`input_rectangle`, `ok_rectangle`, …) are rewritten by
   the renderer every frame; mouse handling hit-tests against the same
   rects so input and visuals stay in sync.

## Syntax language JSON

Schema documented at the top of `syntax.odin` (`Definition`, `PatternToken`)
and the placeholder grammar in the comments around `PatternTokenKind`:
`{NAME}`, `{TYPE}`, `{NOTHING}`, `{ANY}`, `{OPTIONAL:X}`, `{NOT:X}`,
`{OPTION:A|B|C}`, `...`.

The lexer is case-sensitive. For case-insensitive languages (VB family,
Pascal), list both casings in `keywords` and `types` (see `vb6.json`,
`delphi.json`).

`scope_start` / `scope_end` default to `["{"]` / `["}"]`; explicit lists are
needed for keyword-bracketed languages (`Sub … End Sub`, `begin … end`).

## Configuration files

Two layers, both JSON, both tolerant of missing keys / parse failures:

- **App-level** — `./odit.json` (checked first) or
  `%APPDATA%/odit/settings.json` (Windows) / `$HOME/.config/odit/settings.json`
  (POSIX). Holds only wiring that's the same across projects: which
  executable runs each LSP (`lsp.<language_id>.command`) and DAP adapter
  (`dap.<adapter_id>.command`). Schema and defaults in `settings.odin`.
  Baked-in defaults: `ols` for Odin, `lldb-dap` for the `lldb` adapter.
  Bare relative command names are rewritten to `vendor/<plat>/lsp/<name>`
  if that file exists, so a vendored binary lands without user config.
- **Project-level** — `<project_root>/.odit/project.json`. Holds
  `build_profiles` (named build commands, with optional `command_windows`
  / `command_linux` / `command_macos` overrides) and `debug_profiles`
  (DAP launch/attach configs that reference a `build_profile` for the
  pre-build step). Schema documented at the top of `project_config.odin`.
  Placeholders like `{project_root}`, `{platform}`, `{build_name}` are
  expanded at use time.

## LSP / DAP integration

LSP and DAP clients each run a worker thread per server/adapter and route
messages by request id. The editor talks to them through the
`lsp_integration.odin` / `dap_integration.odin` glue files — those are the
only places that should touch the protocol-client public API. Diagnostics,
hover popups, completion lists, signature help, breakpoints, stack frames,
variables, and the debug output pane are all driven from the integration
files.

LSP `didOpen`/`didChange` versioning is tracked per-document with
`lsp_did_open_sent` + a monotonic version counter on `DocumentState`. Stale
hover/completion responses are filtered using the `(file_path, line, column)`
fingerprint stored on each `PendingRequest`.

## Diff mode (F8)

Two-pane only. Myers' line diff in `diff.odin`. After the Myers pass we
post-process contiguous Delete + Insert runs into `Change` rows so modified
lines stay side-by-side instead of cascading the layout down. Inline byte
ranges that actually differ are precomputed via longest-common-prefix /
longest-common-suffix at diff time so the renderer can paint a highlight
cheaply per visible line.

## Save / Close (Ctrl+S / Ctrl+Shift+S / Ctrl+F4)

- Ctrl+S writes to the existing path or pops Save-As for untitled docs. On a
  write failure, falls back to Save-As pre-loaded with the OS error.
- Ctrl+Shift+S always opens Save-As (saves a copy under a new name).
- Ctrl+F4 closes the active file. Dirty docs route through a Yes/No/Cancel
  prompt; Yes can chain into Save-As with `close_after_save = true`.
- In split mode with two editor panes, Ctrl+F4 collapses the split so the
  surviving editor goes full-screen in `pane[0]`. Terminal-paired splits keep
  the split alive and just blank the editor side.

## Hotkey overview (also in F1)

User-rebindable shortcuts are listed in `keybindings/keybindings.odin`
(`Action` enum) and bound per-platform in `keybindings/defaults/*.json`.

- **F1** help · **F2** file browser · **F3** git history · **F4** switch
  open doc in pane · **F5** markdown preview · **F6** symbol jump ·
  **F7** Tasks dialog (build/debug profiles) · **Shift+F7** debugger panel
  + output pane · **F8** diff toggle · **F9** terminal · **F10** step over ·
  **F11** step into
- **Ctrl+F9** spawn new terminal · **Ctrl+Shift+F9** terminal picker
- **Ctrl+K** LSP hover · **Ctrl+Space** LSP completion
- **Ctrl+F** find · **Ctrl+R** replace · **Ctrl+Shift+F** find in files ·
  **Ctrl+Shift+R** replace in files
- **Ctrl+S** save · **Ctrl+Shift+S** save as · **Ctrl+F4** close file
- **Ctrl+Tab** swap panes · **Ctrl+Left/Right** focus pane ·
  **Ctrl+Shift+Left/Right** move doc to pane · **Ctrl+W** wrap toggle ·
  **Ctrl+P** (in browser) set project root · **Ctrl+Q** quit

## Things to avoid

- Don't add features, refactors, or new abstractions beyond what the task
  asked for. Keep diffs minimal.
- Don't introduce error handling, fallback paths, or validation for cases
  that can't happen — trust internal invariants.
- Don't write `.md` planning files or design docs unless explicitly asked.
- Don't run the editor from build commands here — the user has it open and
  will test the changes themselves.
- Don't reach into `src/lsp/` or `src/dap/` internals from the editor
  package directly — go through `lsp_integration.odin` / `dap_integration.odin`.

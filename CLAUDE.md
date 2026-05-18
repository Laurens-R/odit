# Odit

Terminal-inspired text editor written in Odin, built on SDL3. Single-binary,
self-contained: language definitions and the font are embedded at compile time.

## Build

PowerShell wrapper that compiles and stages runtime DLLs alongside the binary:

```
scripts/build.ps1 -Target windows -Config debug      # or -Config release
scripts/build.sh   --target windows --config debug   # POSIX equivalent
```

Direct `odin build` (skips dependency staging, useful for quick syntax checks):

```
odin build src -target:windows_amd64 -out:out/windows/debug/odit.exe -debug
```

The user often runs the editor while iterating, which holds a file lock on
`odit.exe`. If a build fails with `LNK1104: cannot open file`, drop the output
to a sibling path for the type-check (e.g. `odit_test.exe`) and delete it
afterwards.

## Layout

- `src/main.odin` — entry point + main loop. Frees `context.temp_allocator`
  once per frame; anything that must outlive a frame uses `context.allocator`.
- `src/editor/` — panes, modals, input dispatch, rendering. Most of the
  shared state lives on `Editor` (`editor.odin`); per-pane state on
  `EditorPane`.
- `src/document/` — piece tree + per-document undo/redo stack. Compound edits
  group multiple ops into one undo step.
- `src/syntax/` — language definitions, per-line lexer/tokenizer, whole-file
  symbol extractor used by F6.
- `src/syntax/languages/*.json` — language defs. New languages: drop a JSON
  file in and append a `#load` line to `LANGUAGE_BLOBS` in `loader.odin`.
- `src/ui/` — reusable widgets (`draw_window`, `draw_button`,
  `draw_input_field`, `draw_list_row`, …). UI procs know nothing about the
  editor — they take a `ui.Context` with renderer + font metrics.
- `src/terminal/` — embedded shell emulator (F9 toggles it into pane[1]).

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

## Modal-dialog pattern

Every modal in the editor follows the same shape — Find-in-Files,
Replace-in-Files, Save-As, Close-Confirm, Git-History, Symbols (F6), File
Browser (F2). When adding a new modal, copy one of those and follow the
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

- **F1** help · **F2** file browser · **F3** git history of the active file ·
  **F6** symbol jump · **F8** diff toggle · **F9** terminal pane
- **Ctrl+F** find · **Ctrl+R** replace · **Ctrl+Shift+F** find in files ·
  **Ctrl+Shift+R** replace in files
- **Ctrl+S** save · **Ctrl+Shift+S** save as · **Ctrl+F4** close file
- **Ctrl+Tab** swap panes · **Ctrl+W** wrap toggle · **Ctrl+P** (in browser)
  set project root

## Things to avoid

- Don't add features, refactors, or new abstractions beyond what the task
  asked for. Keep diffs minimal.
- Don't introduce error handling, fallback paths, or validation for cases
  that can't happen — trust internal invariants.
- Don't write `.md` planning files or design docs unless explicitly asked.
- Don't run the editor from build commands here — the user has it open and
  will test the changes themselves.

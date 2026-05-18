# vendor

Third-party runtime binaries the build copies next to the produced executable.

Layout:

- `windows/` — Windows DLLs (`SDL3.dll`, `SDL3_ttf.dll`)
- `linux/`   — Linux shared objects (`libSDL3.so.0`, `libSDL3_ttf.so.0`)
- `macos/`   — macOS dynamic libraries (`libSDL3.0.dylib`, `libSDL3_ttf.0.dylib`)

The font (`font.ttf`) lives next to this file and is copied to every build
output regardless of target.

Each platform subfolder's contents are copied verbatim into
`out/<platform>/<config>/` by the build tasks in `.vscode/tasks.json`.

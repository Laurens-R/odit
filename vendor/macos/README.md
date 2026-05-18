# macOS runtime dependencies

Drop the macOS SDL3 dynamic libraries here. Expected files:

- `libSDL3.0.dylib`
- `libSDL3_ttf.0.dylib`

Install via Homebrew (`brew install sdl3 sdl3_ttf`) and copy from
`/opt/homebrew/lib/` (Apple Silicon) or `/usr/local/lib/` (Intel), or build
from source (https://github.com/libsdl-org/SDL).

Every file in this folder is copied next to the macOS build output by the
`Build: macOS (debug)` / `Build: macOS (release)` tasks.

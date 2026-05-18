# Linux runtime dependencies

Drop the Linux SDL3 shared objects here. Expected files:

- `libSDL3.so.0`
- `libSDL3_ttf.so.0`

Get them from your distro's package manager (e.g. `libsdl3-0`, `libsdl3-ttf-0`)
or build from source (https://github.com/libsdl-org/SDL).

Every file in this folder is copied next to the Linux build output by the
`Build: Linux (debug)` / `Build: Linux (release)` tasks.

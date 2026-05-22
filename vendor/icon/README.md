# Application icons

Drop platform-appropriate icon files here. The build process stages this
directory into `out/<target>/<config>/icon/` so the runtime can find them
next to the binary.

## Files

| File           | Purpose                                              | Required? |
| -------------- | ---------------------------------------------------- | --------- |
| `icon.png`     | Window / taskbar icon, loaded at startup.            | Yes (all) |
| `windows.ico`  | On-disk binary icon for Explorer (Windows packaging).| Optional  |
| `macos.icns`   | `.app` bundle icon for Finder (macOS packaging).     | Optional  |
| `linux.png`    | Icon referenced by the `.desktop` file on Linux.     | Optional  |

## icon.png

A 32-bit RGBA PNG. 256×256 is a reasonable source size — SDL rescales as
needed for the window / taskbar slot. Decoded at startup via
`core:image/png`, so transparent pixels work out of the box and no
SDL_image runtime dependency is needed.

## Per-platform binary icons (optional)

The window icon above covers the *running* application. To also give the
binary itself an icon in Explorer / Finder, you need a per-platform step
that this repo doesn't automate yet:

- **Windows** (`windows.ico`): embed via a `.rc` resource compiled with
  `rc.exe` and passed to `odin build` through `-extra-linker-flags`.
- **macOS** (`macos.icns`): wrap the binary in a `.app` bundle with
  `Contents/MacOS/odit`, `Contents/Info.plist`, and
  `Contents/Resources/icon.icns`.
- **Linux** (`linux.png`): install alongside a `.desktop` file under
  `/usr/share/applications/` and the icon under
  `/usr/share/icons/hicolor/256x256/apps/`.

Files dropped here are staged into the build output regardless, so a
post-build script can pick them up without hunting through the source tree.

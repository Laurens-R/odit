#!/usr/bin/env bash
#
# Build odit for a given target/config and stage the runtime files next
# to the produced binary. Invoked from .vscode/tasks.json.
#
#     scripts/build.sh windows debug
#
# Layout produced:
#     out/<target>/<config>/odit(.exe)
#     out/<target>/<config>/<vendored runtime deps>
#     out/<target>/<config>/font.ttf

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <windows|linux|macos> <debug|release>" >&2
    exit 64
fi

target="$1"
config="$2"

case "$target" in
    windows) odin_target=windows_amd64 ; executable_name=odit.exe ;;
    linux)   odin_target=linux_amd64   ; executable_name=odit     ;;
    macos)   odin_target=darwin_arm64  ; executable_name=odit     ;;
    *)       echo "unknown target: $target" >&2; exit 64 ;;
esac

case "$config" in
    debug)   build_flags=(-debug) ;;
    release) build_flags=(-o:speed -no-bounds-check) ;;
    *)       echo "unknown config: $config" >&2; exit 64 ;;
esac

output_directory="out/$target/$config"
output_binary="$output_directory/$executable_name"

mkdir -p "$output_directory"

echo "==> odin build src -target:$odin_target ${build_flags[*]} -out:$output_binary"
odin build src "-target:$odin_target" "${build_flags[@]}" "-out:$output_binary"

copy_if_changed() {
    local source="$1"
    local destination_directory="$2"
    local destination="$destination_directory/$(basename "$source")"

    if [ -f "$destination" ] && [ ! "$source" -nt "$destination" ]; then
        local source_size destination_size
        source_size=$(wc -c < "$source")
        destination_size=$(wc -c < "$destination")
        if [ "$source_size" = "$destination_size" ]; then
            echo "    up-to-date: $(basename "$source")"
            return
        fi
    fi

    cp -f "$source" "$destination"
    echo "    staged: $(basename "$source")"
}

vendor_platform_directory="vendor/$target"
if [ -d "$vendor_platform_directory" ]; then
    while IFS= read -r -d '' vendor_file; do
        copy_if_changed "$vendor_file" "$output_directory"
    done < <(find "$vendor_platform_directory" -maxdepth 1 -type f ! -name 'README.md' -print0)
fi

if [ -f vendor/font.ttf ]; then
    copy_if_changed "vendor/font.ttf" "$output_directory"
fi

echo "==> build complete: $output_binary"

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

copy_file_if_changed() {
    local source="$1"
    local destination="$2"
    local display_name="$3"

    if [ -f "$destination" ] && [ ! "$source" -nt "$destination" ]; then
        local source_size destination_size
        source_size=$(wc -c < "$source")
        destination_size=$(wc -c < "$destination")
        if [ "$source_size" = "$destination_size" ]; then
            echo "    up-to-date: $display_name"
            return
        fi
    fi

    mkdir -p "$(dirname "$destination")"
    cp -f "$source" "$destination"
    echo "    staged: $display_name"
}

# Two-pass copy from vendor/:
#   Pass 1 — every file under vendor/ that isn't inside a platform-specific
#            subdir (linux/, macos/, windows/) gets staged. Preserves any
#            nested directory layout so vendor/shared/foo/bar.txt lands at
#            out/<target>/<config>/shared/foo/bar.txt.
#   Pass 2 — files under vendor/<target>/ are then staged on TOP of pass 1,
#            with the platform dir itself stripped from the destination
#            path. vendor/linux/lsp/ols → out/linux/debug/lsp/ols.
# README.md files at any depth are docs and skipped.

platform_subdirectory_names=(linux macos windows)

if [ -d vendor ]; then
    while IFS= read -r -d '' vendor_file; do
        relative_path="${vendor_file#vendor/}"
        skip_file=false
        for platform_name in "${platform_subdirectory_names[@]}"; do
            case "$relative_path" in
                "$platform_name"/*) skip_file=true; break ;;
            esac
        done
        if [ "$skip_file" = true ]; then continue; fi
        copy_file_if_changed "$vendor_file" "$output_directory/$relative_path" "$relative_path"
    done < <(find vendor -type f ! -name 'README.md' -print0)

    vendor_platform_directory="vendor/$target"
    if [ -d "$vendor_platform_directory" ]; then
        while IFS= read -r -d '' vendor_file; do
            relative_path="${vendor_file#$vendor_platform_directory/}"
            copy_file_if_changed "$vendor_file" "$output_directory/$relative_path" "$relative_path"
        done < <(find "$vendor_platform_directory" -type f ! -name 'README.md' -print0)
    fi
fi

echo "==> build complete: $output_binary"

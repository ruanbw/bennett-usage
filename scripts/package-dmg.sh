#!/bin/bash
# Build the release .app bundle(s) and wrap each in a drag-to-Applications DMG.
#
# Usage:
#   ./scripts/package-dmg.sh [version] [--only <variant>]...
#
#   version           marketing version stamped into Info.plist (default 1.5.0)
#   --only <variant>  build only this variant; repeatable and comma-separated.
#                     variants: arm64 | x86_64 | universal   (default: all three)
#
# Examples:
#   ./scripts/package-dmg.sh                      # all three DMGs, version 1.5.0
#   ./scripts/package-dmg.sh 1.5.0                # all three DMGs, version 1.5.0
#   ./scripts/package-dmg.sh 1.5.0 --only universal
#   ./scripts/package-dmg.sh 1.5.0 --only arm64,x86_64
#
# Outputs (dist/):
#   BennettUsage-<version>-arm64.dmg       Apple Silicon only
#   BennettUsage-<version>-x86_64.dmg      Intel only
#   BennettUsage-<version>-universal.dmg   Apple Silicon + Intel (lipo-merged)
#   SHA256SUMS.txt                         checksums for the DMGs built above
#
# Whichever Mac runs this cross-compiles both slices, so an Intel host still
# produces the arm64 and universal artifacts. Requires bash 3.2 (macOS default).
set -euo pipefail
cd "$(dirname "$0")/.."
export LC_ALL=C

APP_NAME="Bennett Usage"
DIST="dist"
STAGE_ROOT="$DIST/.staging"

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

VERSION=""
ONLY=()
ONLY_GIVEN=0
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage 0 ;;
        --only)
            shift
            [ $# -gt 0 ] || { echo "error: --only requires a value" >&2; exit 2; }
            ONLY_GIVEN=1
            IFS=',' read -r -a _parts <<< "$1"
            [ ${#_parts[@]} -gt 0 ] && ONLY+=("${_parts[@]}")
            ;;
        --only=*)
            ONLY_GIVEN=1
            IFS=',' read -r -a _parts <<< "${1#--only=}"
            [ ${#_parts[@]} -gt 0 ] && ONLY+=("${_parts[@]}")
            ;;
        -*) echo "error: unknown option: $1" >&2; usage 2 ;;
        *)
            [ -z "$VERSION" ] || { echo "error: version given more than once" >&2; exit 2; }
            VERSION="$1"
            ;;
    esac
    shift
done
VERSION="${VERSION:-1.5.0}"

VARIANTS=()
if [ "$ONLY_GIVEN" -eq 0 ]; then
    VARIANTS=(arm64 x86_64 universal)
elif [ ${#ONLY[@]} -gt 0 ]; then
    # bash 3.2 has no associative arrays and rejects "${arr[@]}" when empty.
    for v in "${ONLY[@]}"; do
        case "$v" in
            arm64|x86_64|universal) VARIANTS+=("$v") ;;
            *) echo "error: unknown variant '$v' (expected arm64, x86_64 or universal)" >&2; exit 2 ;;
        esac
    done
fi
[ ${#VARIANTS[@]} -gt 0 ] || { echo "error: no variant selected" >&2; exit 2; }

# The app icon is a checked-in build input; regenerate it with make-app-icon.swift.
[ -f packaging/AppIcon.icns ] || {
    echo "error: packaging/AppIcon.icns is missing (run: swift scripts/make-app-icon.swift)" >&2
    exit 1
}

# --- 1. Work out which slices are needed, then build each architecture once -----

needs_arch() {
    local want="$1" v
    for v in "${VARIANTS[@]}"; do
        [ "$v" = "universal" ] && return 0
        [ "$v" = "$want" ] && return 0
    done
    return 1
}

ARM64_BIN=""
X86_64_BIN=""
set_bin() {
    case "$1" in
        arm64) ARM64_BIN="$2" ;;
        x86_64) X86_64_BIN="$2" ;;
    esac
}
get_bin() {
    case "$1" in
        arm64) printf '%s' "$ARM64_BIN" ;;
        x86_64) printf '%s' "$X86_64_BIN" ;;
    esac
}
has_slice() {  # <archs-list> <arch>
    case " $1 " in *" $2 "*) return 0 ;; esac
    return 1
}

for arch in arm64 x86_64; do
    needs_arch "$arch" || continue
    echo "==> Building BennettUsageApp (release, $arch)"
    swift build -c release --arch "$arch" --product BennettUsageApp
    bin_dir="$(swift build -c release --arch "$arch" --show-bin-path)"
    bin="$bin_dir/BennettUsageApp"
    [ -f "$bin" ] || { echo "error: missing binary at $bin" >&2; exit 1; }
    set_bin "$arch" "$bin"

    # Guard against a cross-build silently emitting the host slice instead.
    built="$(lipo -archs "$bin")"
    has_slice "$built" "$arch" || {
        echo "error: expected $arch slice, got '$built' from $bin" >&2
        exit 1
    }
done

# --- 2. Assemble, sign and package one DMG per requested variant ----------------

rm -rf "$STAGE_ROOT"
mkdir -p "$DIST"
: > "$DIST/SHA256SUMS.txt"

assemble_app() {  # <variant> <binary>
    local stage="$STAGE_ROOT/$1" binary="$2"
    local app="$stage/$APP_NAME.app"
    rm -rf "$stage"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$binary" "$app/Contents/MacOS/BennettUsageApp"
    # Regenerate with: swift scripts/make-app-icon.swift
    cp packaging/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
    sed "s/__VERSION__/$VERSION/g" packaging/Info.plist > "$app/Contents/Info.plist"
    printf 'APPL????' > "$app/Contents/PkgInfo"

    # Ad-hoc signature (no Developer ID): first launch needs right-click -> Open.
    codesign --force --deep --sign - "$app"
    codesign --verify --strict "$app"
    ln -s /Applications "$stage/Applications"
}

for variant in "${VARIANTS[@]}"; do
    echo "==> Packaging $variant"
    case "$variant" in
        universal)
            mkdir -p "$STAGE_ROOT"
            binary="$STAGE_ROOT/BennettUsageApp-universal"
            lipo -create "$ARM64_BIN" "$X86_64_BIN" -output "$binary"
            ;;
        *)
            binary="$(get_bin "$variant")"
            ;;
    esac

    assemble_app "$variant" "$binary"

    # Confirm the shipped binary really carries the advertised slices.
    slices="$(lipo -archs "$STAGE_ROOT/$variant/$APP_NAME.app/Contents/MacOS/BennettUsageApp")"
    if [ "$variant" = "universal" ]; then
        # lipo reports slices in its own order, so test each one independently.
        if ! (has_slice "$slices" arm64 && has_slice "$slices" x86_64); then
            echo "error: universal bundle is missing a slice (got '$slices')" >&2
            exit 1
        fi
    else
        [ "$slices" = "$variant" ] || { echo "error: $variant bundle carries '$slices'" >&2; exit 1; }
    fi

    out="$DIST/BennettUsage-$VERSION-$variant.dmg"
    rm -f "$out"
    hdiutil create \
        -volname "$APP_NAME $VERSION ($variant)" \
        -srcfolder "$STAGE_ROOT/$variant" \
        -ov -format UDZO "$out" >/dev/null

    (cd "$DIST" && shasum -a 256 "$(basename "$out")" >> SHA256SUMS.txt)
    printf '    %-42s %-12s %s\n' "$(basename "$out")" "$slices" "$(du -h "$out" | cut -f1)"
done

# --- 3. Report -----------------------------------------------------------------

rm -rf "$STAGE_ROOT"
echo
echo "==> Artifacts in $DIST/ (version $VERSION)"
ls -lh "$DIST"/*.dmg
echo
cat "$DIST/SHA256SUMS.txt"

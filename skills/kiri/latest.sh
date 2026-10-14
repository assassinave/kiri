#!/bin/sh
# Lists kiri's captures on disk.
#   latest.sh          the live shelf (kiri/live, kept in sync while kiri runs): its PNGs (with pixel size) and kiri-notes.md
#   latest.sh --list   the live shelf, then every Copy All / Copy for Agent export folder, newest first
#   latest.sh <name>   that folder (a name from --list)
set -eu

# kiri writes to the per-user temp dir (FileManager.temporaryDirectory). Ask the system for it
# rather than trusting $TMPDIR, which a CLI sandbox may override.
root="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || printf '%s' "${TMPDIR:-/tmp/}")"
root="${root%/}/kiri"

if [ ! -d "$root" ]; then
    echo "Nothing at $root. Is kiri running? It mirrors the shelf to $root/live." >&2
    exit 1
fi

pngs() { ls -1 "$1" | grep -c '^kiri-[0-9]*\.png$' || true; }

# Export folder names are UTC timestamps (yyyy-MM-ddTHHmmss), so a reverse name sort is newest first.
folders="$(ls -1 "$root" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}$' | sort -r || true)"

case "${1:-}" in
    --list)
        for f in live $folders; do
            [ -d "$root/$f" ] || continue
            notes=""; [ -f "$root/$f/kiri-notes.md" ] && notes=" + notes"
            label="(UTC)"; [ "$f" = live ] && label="(current shelf)"
            echo "$f $label  $(pngs "$root/$f") PNG(s)$notes"
        done
        exit 0 ;;
    "") dir="$root/live"
        [ -d "$dir" ] || { echo "No live shelf at $dir. Is kiri running? (A build from before Oct 14 2026 doesn't write it.)" >&2; exit 1; } ;;
    *)  dir="$root/$1"
        [ -d "$dir" ] || { echo "No folder named $1 in $root." >&2; exit 1; } ;;
esac

# Newest file in the folder: the last time kiri wrote to it.
updated="$(ls -1t "$dir" | head -n 1)"
updated="$(stat -f '%Sm' -t '%Y-%m-%d %H:%M %Z' "$dir/${updated:-.}")"
echo "Folder: $dir"
if [ "$(basename "$dir")" = live ]; then
    echo "Live shelf, last updated $updated"
    [ "$(pngs "$dir")" -gt 0 ] || { echo; echo "The shelf is empty."; exit 0; }
else
    echo "Exported: $(basename "$dir") UTC (modified $updated)"
fi
echo
echo "Images:"
# Numeric order: kiri-2 before kiri-10.
ls -1 "$dir" | grep '^kiri-[0-9]*\.png$' | sort -t- -k2 -n | while read -r png; do
    size="$(sips -g pixelWidth -g pixelHeight "$dir/$png" 2>/dev/null \
        | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{if (w) print w "x" h}')"
    echo "  $dir/$png  ${size:-?}"
done
echo
if [ -f "$dir/kiri-notes.md" ]; then
    echo "Notes ($dir/kiri-notes.md):"
    cat "$dir/kiri-notes.md"
else
    echo "Notes: none (no kiri-notes.md in this folder)."
fi

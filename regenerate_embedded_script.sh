#!/bin/bash
# regenerate_embedded_script.sh
#
# Regenerates the embedded byte array inside sleep-unified.c from the
# current contents of sleep-unified.sh. Run this after editing
# sleep-unified.sh, before recompiling, so the two stay in sync (the
# compiled binary always runs exactly what's in sleep-unified.sh —
# nothing else keeps them synchronized automatically).
#
# Usage:
#   ./regenerate_embedded_script.sh
#
# Expects sleep-unified.sh and sleep-unified.c in the same directory as
# this script.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH_PATH="${SCRIPT_DIR}/sleep-unified.sh"
C_PATH="${SCRIPT_DIR}/sleep-unified.c"

if [ ! -f "$SH_PATH" ]; then
    echo "Error: $SH_PATH not found." >&2
    exit 1
fi
if [ ! -f "$C_PATH" ]; then
    echo "Error: $C_PATH not found." >&2
    exit 1
fi

BYTE_COUNT=$(stat -c%s "$SH_PATH")

# Build the new array block: "0x.., 0x.., ..." 12 bytes per line, matching
# the format previously produced by the Python generator.
NEW_BLOCK=$(mktemp)
{
    echo "static const unsigned char embedded_script[] = {"
    od -An -v -tx1 "$SH_PATH" | tr -s ' ' '\n' | grep -v '^$' | \
        awk '{ printf "0x%s, ", $0; if (NR % 12 == 0) printf "\n" } END { if (NR % 12 != 0) printf "\n" }' | \
        sed 's/^/  /'
    echo "};"
    echo "static const unsigned int embedded_script_len = ${BYTE_COUNT};"
} > "$NEW_BLOCK"

# Splice the new block into sleep-unified.c, replacing everything from the
# "static const unsigned char embedded_script[] = {" line through the
# "static const unsigned int embedded_script_len = ...;" line (inclusive).
START_LINE=$(grep -n '^static const unsigned char embedded_script\[\] = {$' "$C_PATH" | head -n1 | cut -d: -f1)
END_LINE=$(grep -n '^static const unsigned int embedded_script_len = [0-9]*;$' "$C_PATH" | head -n1 | cut -d: -f1)

if [ -z "$START_LINE" ] || [ -z "$END_LINE" ]; then
    echo "Error: could not find the embedded_script array markers in $C_PATH." \
         "Has the surrounding code changed?" >&2
    rm -f "$NEW_BLOCK"
    exit 1
fi

TMP_C=$(mktemp)
head -n "$((START_LINE - 1))" "$C_PATH" > "$TMP_C"
cat "$NEW_BLOCK" >> "$TMP_C"
tail -n "+$((END_LINE + 1))" "$C_PATH" >> "$TMP_C"
mv "$TMP_C" "$C_PATH"
rm -f "$NEW_BLOCK"

echo "Embedded ${BYTE_COUNT} bytes from $(basename "$SH_PATH") into $(basename "$C_PATH")."
echo "Recompile with:"
echo "  gcc -Wall -Wextra sleep-unified.c -o sleep-unified \$(pkg-config --cflags --libs gtk+-3.0)"

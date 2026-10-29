#!/bin/bash
# residual-scan.sh — re-scan a tree for 32-bit address storage after a widening pass.
#
# Usage:
#   ./residual-scan.sh [dir...]        # defaults to the current directory
#
# Exit code 0 = clean (or only comments/dead code left, which you must eyeball).
set -u

DIRS=("$@")
[ ${#DIRS[@]} -eq 0 ] && DIRS=(".")

# Address-ish identifiers that are easy to miss: only "phy" is obvious.
PAT='int *phy[a-z_0-9]*|u32 *phy[a-z_0-9]*|S32 *phy[a-z_0-9]*|U32 *phy[a-z_0-9]*'
PAT+='|int phyaddr|u32 phyaddr|int phy_addr|u32 phy_addr'
PAT+='|int buf_addr|int frame_addr|int new_frame_addr|int addr, int size'
PAT+='|int (luma|chroma|chro|bs|dpb|counts|bitstream)_addr|u32 (luma|chroma|chro|bs|dpb|counts|bitstream)_addr'
PAT+='|\(u32\)[a-zA-Z_]*[Aa]ddr|\(int\)[a-zA-Z_]*[Aa]ddr|\(S32\)[a-zA-Z_]*[Aa]ddr'

hits=0
for d in "${DIRS[@]}"; do
  [ -d "$d" ] || { echo "skip (not a directory): $d" >&2; continue; }
  out=$(grep -rnE "$PAT" "$d" \
          --include='*.c' --include='*.cc' --include='*.cpp' --include='*.h' --include='*.hpp' \
          2>/dev/null | grep -v '\.o:' || true)
  if [ -n "$out" ]; then
    echo "$out"
    hits=$((hits + $(printf '%s\n' "$out" | wc -l)))
  fi
done

echo "--- residual scan done: $hits hit(s) ---"
echo "    Remaining hits should be hardware register writes (32-bit by design),"
echo "    commented-out code, or unrelated casts — classify each, don't blind-fix."
[ "$hits" -eq 0 ] || exit 1

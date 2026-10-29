#!/usr/bin/env bash
# install.sh — copy these skills into an agent's skills directory.
#
#   ./install.sh --claude          -> ~/.claude/skills/<name>/
#   ./install.sh --hermes          -> ~/.hermes/skills/<name>/
#   ./install.sh --to DIR          -> DIR/<name>/            (any agent)
#   ./install.sh --all             -> every destination detected on this machine
#
# Re-running overwrites the skill folder (that's how you update). Nothing else is touched.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILLS_DIR="$REPO_DIR/skills"

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

DESTINATIONS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --claude)  DESTINATIONS+=("$HOME/.claude/skills") ;;
    --hermes)  DESTINATIONS+=("$HOME/.hermes/skills") ;;
    --to)      [ $# -ge 2 ] || { echo "--to needs a directory" >&2; exit 2; }
               DESTINATIONS+=("$2"); shift ;;
    --all)
      for d in "$HOME/.claude/skills" "$HOME/.hermes/skills" "$HOME/.codex/skills" "$HOME/.openclaw/skills"; do
        [ -d "$(dirname "$d")" ] && DESTINATIONS+=("$d")
      done
      [ ${#DESTINATIONS[@]} -gt 0 ] || { echo "no known agent directory found; use --to DIR" >&2; exit 1; }
      ;;
    -h|--help) usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 2 ;;
  esac
  shift
done

[ ${#DESTINATIONS[@]} -gt 0 ] || usage 2

for dest in "${DESTINATIONS[@]}"; do
  mkdir -p "$dest"
  for skill in "$SKILLS_DIR"/*/; do
    name=$(basename "$skill")
    rm -rf "$dest/$name"
    cp -R "$skill" "$dest/$name"
    echo "installed $name -> $dest/$name"
  done
done

echo
echo "Done. Ask your agent to audit a C/C++ file and it will pick the skill up."
echo "Agents without a skills directory: reference skills/<name>/SKILL.md from AGENTS.md."

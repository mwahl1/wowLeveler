#!/bin/sh
# Rebuild Data/*.lua from QuestieDB: pull -> export (QuestieDB's own Lua tooling) -> build -> validate.
# Usage: tools/update_data.sh            update QuestieDB to its latest commit first
#        tools/update_data.sh --no-pull  rebuild from the QuestieDB commit already checked out
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="${WOW_TOOLS:-$HOME/wow-tools}"
LUA="$TOOLS/lua-5.1.5/src/lua"
QDB="$TOOLS/QuestieDB"
EXPORT="$REPO/tools/.cache/forever"

[ -x "$LUA" ] || { echo "Lua 5.1 not found at $LUA"; exit 1; }
[ -d "$QDB/.git" ] || { echo "QuestieDB checkout not found at $QDB"; exit 1; }

if [ "${1:-}" != "--no-pull" ]; then
  echo "== Updating QuestieDB"
  git -C "$QDB" pull --ff-only
fi
git -C "$QDB" log -1 --format='QuestieDB %h (%cs)'

echo "== Exporting with QuestieDB's loader"
(cd "$QDB" && "$LUA" "$REPO/tools/questiedb_export.lua" "$EXPORT")

echo "== Building Data/*.lua"
(cd "$REPO" && python3 tools/build_data.py --export "$EXPORT" --questiedb "$QDB")

echo "== Validating with Lua 5.1"
(cd "$REPO" && "$LUA" tools/validate_data.lua)

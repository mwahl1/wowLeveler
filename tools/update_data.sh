#!/bin/sh
# Rebuild Data/*.lua from QuestieDB: pull -> export (QuestieDB's own Lua tooling) -> build -> validate.
# Questie (quest blacklist) is only downloaded and read as text by build_data.py; never executed.
# Usage: tools/update_data.sh            update QuestieDB and Questie to their latest commits first
#        tools/update_data.sh --no-pull  rebuild from the commits already checked out
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="${WOW_TOOLS:-$HOME/wow-tools}"
LUA="$TOOLS/lua-5.1.5/src/lua"
# python3 on Windows is often only the Microsoft Store placeholder; fall back to python
PY="${PYTHON:-python3}"
"$PY" -c "import sys" >/dev/null 2>&1 || PY=python
QDB="$TOOLS/QuestieDB"
QUESTIE="$TOOLS/Questie"
EXPORT="$REPO/tools/.cache/forever"

[ -x "$LUA" ] || { echo "Lua 5.1 not found at $LUA"; exit 1; }
[ -d "$QDB/.git" ] || { echo "QuestieDB checkout not found at $QDB"; exit 1; }
[ -d "$QUESTIE/.git" ] || { echo "Questie checkout not found at $QUESTIE (git clone --depth 1 https://github.com/Questie/Questie.git $QUESTIE)"; exit 1; }

if [ "${1:-}" != "--no-pull" ]; then
  echo "== Updating QuestieDB"
  git -C "$QDB" pull --ff-only
  echo "== Updating Questie (download only)"
  git -C "$QUESTIE" pull --ff-only
fi
git -C "$QDB" log -1 --format='QuestieDB %h (%cs)'
git -C "$QUESTIE" log -1 --format='Questie %h (%cs)'

echo "== Exporting with QuestieDB's loader"
(cd "$QDB" && "$LUA" "$REPO/tools/questiedb_export.lua" "$EXPORT")

echo "== Building Data/*.lua"
(cd "$REPO" && "$PY" tools/build_data.py --export "$EXPORT" --questiedb "$QDB" --questie "$QUESTIE")

echo "== Validating with Lua 5.1"
(cd "$REPO" && "$LUA" tools/validate_data.lua)

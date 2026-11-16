#!/bin/bash
# Le Videur — installation sur Mac.
#   curl -fsSL https://raw.githubusercontent.com/Pablitooo5/le-videur/main/install.sh | bash
# Construit l'app sur ton Mac, la range dans ~/.claude/videur et branche le hook « PreToolUse » de Claude Code.
set -euo pipefail

REPO="Pablitooo5/le-videur"
DEST="$HOME/.claude/videur"
APP="$DEST/LeVideur.app"
SETTINGS="$HOME/.claude/settings.json"

say() { printf '%s\n' "$*"; }
fail() { printf '❌ %s\n' "$*" >&2; exit 1; }

# --- Vérifications ---
[ "$(uname)" = "Darwin" ] || fail "Le Videur ne fonctionne que sur Mac."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 14 ] || fail "Il faut macOS 14 (Sonoma) ou plus récent."
xcrun --find swiftc >/dev/null 2>&1 || fail "Il manque les outils de développement d'Apple. Lance : xcode-select --install   puis relance l'installation."
[ -x /usr/bin/python3 ] || fail "python3 est introuvable. Lance : xcode-select --install"

# --- Récupérer les sources (dossier local, ou téléchargement depuis GitHub) ---
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"
if [ -z "$SRC" ] || [ ! -f "$SRC/main.swift" ] || [ ! -f "$SRC/videur.py" ]; then
  say "→ Téléchargement des sources"
  SRC="$(mktemp -d)"
  trap 'rm -rf "$SRC"' EXIT
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$SRC" --strip-components=1
fi

# --- Construire l'app ---
say "→ Construction de l'app (environ 30 secondes)"
pkill -x LeVideur 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DEST/events"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/overlay.html" "$APP/Contents/Resources/overlay.html"
/usr/bin/python3 -I "$SRC/make_sounds.py" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O "$SRC/main.swift" -o "$APP/Contents/MacOS/LeVideur" -framework Cocoa -framework WebKit
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
cp "$SRC/videur.py" "$SRC/uninstall.sh" "$DEST/"
chmod +x "$DEST/uninstall.sh"

# --- Brancher le hook de Claude Code ---
say "→ Branchement à Claude Code ($SETTINGS)"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.avant-videur.bak"
/usr/bin/python3 -I - "$SETTINGS" "$DEST/videur.py" <<'PY'
import json, os, sys
path, script = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as f:
        data = json.load(f)
hooks = data.setdefault("hooks", {})
keep = [g for g in hooks.get("PreToolUse", [])
        if not any("videur/videur.py" in (h.get("command") or "") for h in g.get("hooks", []))]
keep.append({"matcher": "Bash|Write|Edit|MultiEdit|NotebookEdit|mcp__.*",
             "hooks": [{"type": "command", "command": f'/usr/bin/python3 -I "{script}"', "timeout": 10}]})
hooks["PreToolUse"] = keep
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
os.replace(tmp, path)
PY

open -g "$APP"
say ""
say "✅ Le Videur est installé et surveille Claude."
say "   Une icône 🕶️ est apparue dans la barre des menus : clique dessus → « Lancer la démo »."
say "   Pour désinstaller : ~/.claude/videur/uninstall.sh"

#!/bin/bash
# Le Videur — désinstallation : retire le hook, ferme l'app, supprime ~/.claude/videur.
set -euo pipefail
SETTINGS="$HOME/.claude/settings.json"
pkill -x LeVideur 2>/dev/null || true
if [ -f "$SETTINGS" ]; then
  /usr/bin/python3 -I - "$SETTINGS" <<'PY'
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
hooks = data.get("hooks")
if isinstance(hooks, dict):
    for event in list(hooks):
        kept = [g for g in hooks[event]
                if not any("videur/videur.py" in (h.get("command") or "") for h in g.get("hooks", []))]
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if not hooks:
        del data["hooks"]
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
os.replace(tmp, path)
PY
fi
rm -rf "$HOME/.claude/videur"
echo "✅ Le Videur est désinstallé."

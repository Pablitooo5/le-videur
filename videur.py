"""Le Videur — appelé par le hook « PreToolUse » de Claude Code, juste avant chaque action de Claude.

Si l'action est dangereuse (suppression en masse, push forcé, base de données effacée, fichier modifié
hors du projet…), il oblige Claude Code à te demander ton accord, même en mode « Ignorer les permissions »,
et prévient l'app pour que le videur apparaisse à l'écran. Sinon, il ne dit rien.
Rien n'est envoyé sur Internet.
"""
import json
import os
import re
import shlex
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
DIR = os.path.join(HOME, ".claude", "videur")
EVENTS = os.path.join(DIR, "events")
CONFIG = os.path.join(DIR, "config.json")
APP = os.path.join(DIR, "LeVideur.app")

# Dossiers qu'on peut vider sans risque (caches, fichiers générés, temporaires)
SAFE_RM = re.compile(
    r"(^|/)(node_modules|dist|build|out|\.next|\.nuxt|\.turbo|\.cache|\.parcel-cache|coverage|__pycache__|"
    r"\.pytest_cache|\.mypy_cache|\.venv|venv|target|DerivedData|\.svelte-kit|\.expo)(/|$)"
    r"|^/tmp/|^/private/tmp/|^/private/var/folders/|^/var/folders/|^\$TMPDIR|^\$\{TMPDIR")

# Endroits hors projet où Claude écrit normalement (mémoire, plans, compétences, temporaires)
SAFE_WRITE = [
    "/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/",
    os.path.join(HOME, ".claude", "projects") + "/",
    os.path.join(HOME, ".claude", "plans") + "/",
    os.path.join(HOME, ".claude", "skills") + "/",
    os.path.join(HOME, ".claude", "todos") + "/",
]

SQL_DANGER = re.compile(
    r"\bDROP\s+(TABLE|DATABASE|SCHEMA|VIEW)\b|\bTRUNCATE\b|\bDELETE\s+FROM\s+[\w.\"`]+\s*(;|$|\"|')",
    re.IGNORECASE)
MCP_DANGER = re.compile(r"(delete|trash|drop|destroy|wipe|purge|unpublish|reset_branch)", re.IGNORECASE)


def short(path):
    path = str(path)
    return "~" + path[len(HOME):] if path.startswith(HOME) else path


def segments(command):
    """Découpe une commande en morceaux (; && || | retours à la ligne) et en mots."""
    parts = re.split(r"\|\||&&|;|\||\n", command)
    out = []
    for part in parts:
        try:
            words = shlex.split(part, posix=True)
        except ValueError:
            words = part.split()
        while words and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]):   # VAR=valeur cmd
            words = words[1:]
        if words:
            out.append(words)
    return out


def check_bash(command):
    raw = command

    # Toucher au Videur lui-même : seulement écrire, déplacer ou supprimer (lire ou lister, ça passe)
    if ".claude/videur" in raw:
        if re.search(r">>?\s*[\"']?[^|&;\s]*\.claude/videur", raw):
            return "Modifier ou désactiver le Videur lui-même"
        writers = {"rm", "mv", "cp", "tee", "sed", "chmod", "chown", "truncate", "ln", "unlink",
                   "touch", "rsync", "install", "dd", "perl", "ruby"}
        for words in segments(raw):
            if os.path.basename(words[0]) in writers and any(".claude/videur" in w for w in words[1:]):
                return "Modifier ou désactiver le Videur lui-même"
    if re.search(r"(curl|wget)\b[^|\n]*\|\s*(sudo\s+)?(ba|z)?sh\b", raw):
        return "Exécuter un script téléchargé sur Internet"
    if SQL_DANGER.search(raw):
        return "Effacer des données d'une base (DROP, TRUNCATE ou DELETE sans condition)"

    for words in segments(raw):
        cmd = os.path.basename(words[0])
        args = words[1:]
        if cmd == "sudo":
            return "Lancer une commande avec les droits administrateur (sudo)"
        if cmd == "rm":
            flags = "".join(a.lstrip("-") for a in args if a.startswith("-") and not a.startswith("--"))
            recursive = "r" in flags.lower() or "--recursive" in args
            targets = [a for a in args if not a.startswith("-")]
            risky = [t for t in targets if not SAFE_RM.search(t)]
            wildcard = any(t in ("*", ".", "..", "~", "/", "./*", "~/*") for t in targets)
            if (recursive and risky) or wildcard:
                names = ", ".join(short(t) for t in (risky or targets)[:3])
                more = " …" if len(risky or targets) > 3 else ""
                return f"Supprimer définitivement : {names}{more}"
        if cmd == "find" and ("-delete" in args or ("-exec" in args and "rm" in args)):
            return "Supprimer des fichiers en masse (find)"
        if cmd == "xargs" and "rm" in args:
            return "Supprimer des fichiers en masse (xargs rm)"
        if cmd == "git" and args:
            sub, rest = args[0], args[1:]
            if sub == "push" and any(a in ("-f", "--force") or a.startswith("--force=") for a in rest):
                return "Écraser l'historique sur GitHub (push forcé)"
            if sub == "push" and ("--delete" in rest or any(a.startswith(":") for a in rest)):
                return "Supprimer une branche sur GitHub"
            if sub == "reset" and "--hard" in rest:
                return "Effacer tes modifications non enregistrées (git reset --hard)"
            if sub == "clean" and any(a.startswith("-") and "f" in a for a in rest):
                return "Supprimer les fichiers que git ne suit pas (git clean)"
            if sub in ("checkout", "restore") and ("." in rest or "--" in rest and "." in rest):
                return "Annuler toutes tes modifications en cours"
            if sub == "branch" and any(a in ("-D", "--delete") for a in rest):
                name = next((a for a in rest if not a.startswith("-")), "")
                return f"Supprimer la branche « {name} »" if name else "Supprimer une branche"
            if sub == "stash" and rest[:1] and rest[0] in ("clear", "drop"):
                return "Jeter des modifications mises de côté (git stash)"
        if cmd in ("mkfs", "newfs_apfs") or (cmd == "diskutil" and args and args[0].lower().startswith(("erase", "partition", "zero"))):
            return "Effacer un disque"
        if cmd == "dd" and any(a.startswith("of=/dev/") for a in args):
            return "Écrire directement sur un disque (dd)"
        if cmd == "chmod" and "-R" in args and "777" in args:
            return "Ouvrir les droits de tout un dossier à tout le monde (chmod -R 777)"
        if cmd == "npm" and args[:1] == ["publish"]:
            return "Publier un paquet sur npm"
        if cmd == "gh" and args[:2] in (["repo", "delete"], ["release", "delete"]):
            return "Supprimer un dépôt ou une version sur GitHub"
        if cmd == "supabase" and args[:2] == ["db", "reset"]:
            return "Remettre la base Supabase à zéro"
    return None


def check_write(path, cwd):
    if not path:
        return None
    full = os.path.realpath(os.path.expanduser(path))
    root = os.path.realpath(cwd) if cwd else ""
    if root and (full == root or full.startswith(root.rstrip("/") + "/")):
        return None
    if any(full.startswith(os.path.realpath(p.rstrip("/")) + "/") for p in SAFE_WRITE):
        return None
    if "/.claude/videur/" in full:
        return "Modifier ou désactiver le Videur lui-même"
    return f"Modifier un fichier hors du projet : {short(full)}"


def check(data):
    tool = data.get("tool_name") or ""
    ti = data.get("tool_input") or {}
    cwd = data.get("cwd") or ""
    if tool == "Bash":
        action = check_bash(ti.get("command") or "")
        return action, (ti.get("command") or "")
    if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        path = ti.get("file_path") or ti.get("notebook_path") or ""
        return check_write(path, cwd), short(path)
    if tool.startswith("mcp__"):
        name = tool.split("__")[-1]
        dump = json.dumps(ti, ensure_ascii=False)
        if MCP_DANGER.search(name):
            return f"Action irréversible : {name.replace('_', ' ')}", dump
        if re.search(r"(sql|migration|query)", name, re.IGNORECASE) and SQL_DANGER.search(dump):
            return "Effacer des données d'une base (DROP, TRUNCATE ou DELETE sans condition)", dump
    return None, ""


def conversation_title(data):
    title = None
    try:
        with open(data.get("transcript_path") or "", encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"custom-title"' in line:
                    title = json.loads(line).get("customTitle") or title
    except Exception:
        pass
    if not title:
        name = os.path.basename((data.get("cwd") or "").rstrip("/"))
        title = name if name and not name.startswith("scratch-") else "Une conversation"
    return " ".join(str(title).split())[:60]


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    try:
        with open(CONFIG) as f:
            if json.load(f).get("paused"):
                return
    except Exception:
        pass

    action, detail = check(data)
    if not action:
        return

    # 1. Obliger Claude Code à te demander ton accord
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason": f"🕶️ Le Videur : {action}. Vérifie avant d'accepter.",
    }}, ensure_ascii=False))
    sys.stdout.flush()

    # 2. Faire apparaître le videur à l'écran
    try:
        os.makedirs(EVENTS, exist_ok=True)
        event = {"action": action, "detail": " ".join(str(detail).split())[:160], "title": conversation_title(data)}
        tmp = os.path.join(EVENTS, ".event.tmp")
        with open(tmp, "w") as f:
            json.dump(event, f, ensure_ascii=False)
        os.replace(tmp, os.path.join(EVENTS, f"{int(time.time() * 1000)}.json"))
        if subprocess.run(["pgrep", "-xq", "LeVideur"]).returncode != 0 and os.path.isdir(APP):
            subprocess.Popen(["open", "-g", APP], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)

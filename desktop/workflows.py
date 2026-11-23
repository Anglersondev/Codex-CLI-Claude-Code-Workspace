"""Environment checks, reviewed handoffs and isolated Git sessions."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import json
import os
from pathlib import Path
import re
import subprocess

import core

STRINGS = json.loads(Path(__file__).with_name("workflows.json").read_text(encoding="utf-8"))
AGENTS = ("codex", "claude")
PLUGIN = "token-optimizer@alexgreensh-token-optimizer"


def label(key):
    return STRINGS[key][("pt-BR", "en", "es").index(core.PANEL_LANGUAGE)]


def query(command, cwd=None, timeout=8):
    return subprocess.run(command, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, encoding="utf-8", errors="replace", timeout=timeout,
                          creationflags=subprocess.CREATE_NO_WINDOW if core.WINDOWS else 0)


def settings_path(agent):
    if agent == "codex":
        return Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    return Path(os.environ.get("CLAUDE_CONFIG_DIR", Path.home() / ".claude"))


def read_config(path):
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return ""


def auth_result(agent, result):
    if agent == "claude":
        try:
            signed_in = json.loads(result.stdout)["loggedIn"]
            if isinstance(signed_in, bool):
                return "auth_ok" if signed_in else "auth_claude"
        except (TypeError, KeyError, ValueError):
            pass
    if result.returncode == 0:
        return "auth_ok"
    if re.search(r"not (?:logged|signed) in|not authenticated", result.stdout, re.I):
        return "auth_" + agent
    return "auth_unknown"


def tool_report(tool):
    name = {"codex": "Codex CLI", "claude": "Claude Code", "rtk": "RTK", "npm": "npm", "git": "Git"}[tool]
    try:
        command = core.executable(tool)
    except FileNotFoundError:
        return name + "\n" + label("missing_" + tool)
    try:
        version = query([*command, "--version"])
        first = version.stdout.strip().splitlines()
        detail = first[0][:180] if version.returncode == 0 and first else label("version_error")
    except (OSError, subprocess.TimeoutExpired):
        detail = label("version_error")
    lines = [name + " · " + detail]
    if tool in AGENTS:
        try:
            args = ["login", "status"] if tool == "codex" else ["auth", "status"]
            lines.append(label(auth_result(tool, query([*command, *args]))))
        except (OSError, subprocess.TimeoutExpired):
            lines.append(label("auth_unknown"))
    if tool == "rtk":
        for agent in AGENTS:
            config = settings_path(agent) / ("hooks.json" if agent == "codex" else "settings.json")
            active = f"rtk hook {agent}" in read_config(config)
            install = "rtk init --global" + (" --codex" if agent == "codex" else "")
            lines.append(f"{agent.title()} · " + (label("hook_on") if active else label("hook_off") + " " + install))
    return "\n".join(lines)


def optimizer_report(agent):
    root = settings_path(agent)
    if agent == "codex":
        config = read_config(root / "config.toml")
        section = re.search(r'(?m)^\s*\[plugins\."' + re.escape(PLUGIN) + r'"\]\s*(?:#.*)?\n([^\[]*)', config)
        enabled = bool(section and re.search(r'(?m)^\s*enabled\s*=\s*true\s*(?:#.*)?$', section[1]))
    else:
        try:
            settings = json.loads(read_config(root / "settings.json"))
            enabled = settings.get("enabledPlugins", {}).get(PLUGIN) is True
        except (ValueError, AttributeError):
            enabled = False
    cache = root / "plugins" / "cache" / "alexgreensh-token-optimizer" / "token-optimizer"
    versions = [p.name for p in cache.glob("*") if p.is_dir() and re.fullmatch(r"\d{1,6}(?:\.\d{1,6}){1,3}", p.name)]
    latest = max(versions, key=lambda version: tuple(map(int, version.split("."))), default="")
    return "\n".join(("Token Optimizer · " + agent.title(),
                      label("cache") + " · " + latest if latest else label("no_cache"),
                      label("plugin_on" if enabled else "plugin_off")))


def diagnostics():
    with ThreadPoolExecutor(max_workers=5) as pool:
        groups = list(pool.map(tool_report, ("codex", "claude", "git", "npm", "rtk")))
    return "\n\n".join([*groups, *(optimizer_report(agent) for agent in AGENTS)])


def git(folder, *args, timeout=20):
    return query([*core.executable("git"), "--no-optional-locks", "-c", "core.quotePath=false", *args], folder, timeout)


def changed_files(folder):
    try:
        result = git(folder, "status", "--porcelain=v1", "--untracked-files=all", "--", ".")
    except (OSError, subprocess.TimeoutExpired):
        return label("no_status")
    if result.returncode:
        return label("no_status")
    lines = result.stdout.splitlines()
    if not lines:
        return label("clean")
    return "\n".join(lines[:80] + ([label("more_files")] if len(lines) > 80 else []))


def save_checkpoint(folder, source, target, changes, tests, next_step):
    if {source, target} != set(AGENTS) or not next_step.strip():
        raise ValueError(label("enter_next"))
    stamp = datetime.now().astimezone().isoformat(timespec="minutes")
    note = (f"\n\n## {label('checkpoints')} · {stamp} · {source} → {target}\n"
            f"\n### {label('files')}\n{changes.strip() or '—'}\n"
            f"\n### {label('tests')}\n{tests.strip() or label('no_tests')}\n"
            f"\n### {label('next')}\n{next_step.strip()}\n").encode("utf-8")
    if len(note) > 60000:
        raise ValueError(label("too_large"))
    path = core.managed_path(folder, "DOCS/ANDAMENTO.md")
    if path.exists() and not path.is_file():
        raise ValueError(label("unsafe_notes"))
    path.parent.mkdir(exist_ok=True)
    with path.open("ab", buffering=0) as stream:
        stream.write(note)


def worktree_paths(folder, agent, task):
    if agent not in AGENTS or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,39}", task):
        raise ValueError(label("invalid_task"))
    return folder.with_name(f"{folder.name}-{agent}-{task}"), f"assistente/{agent}-{task}"


def create_worktree(folder, agent, task):
    folder = folder.resolve(strict=True)
    target, branch = worktree_paths(folder, agent, task)
    prefix = git(folder, "rev-parse", "--show-toplevel")
    if prefix.returncode or Path(prefix.stdout.rstrip("\r\n")).resolve() != folder or git(folder, "rev-parse", "--verify", "HEAD^{commit}").returncode:
        raise ValueError(label("need_repo"))
    if os.path.lexists(target) or git(folder, "show-ref", "--verify", "--quiet", "refs/heads/" + branch).returncode == 0:
        raise FileExistsError(label("exists"))
    # An exclusive reservation prevents Git from adopting a pre-existing empty directory.
    target.mkdir()
    try:
        result = git(folder, "worktree", "add", "-b", branch, str(target), "HEAD", timeout=None)
        if result.returncode:
            raise ValueError(result.stdout.strip() or label("need_repo"))
    except (OSError, ValueError):
        try:
            target.rmdir()
        except OSError:
            pass
        raise
    return target

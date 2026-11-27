"""1.0 Professional tools for the Linux and Windows panel.

Same contract as lib/pro.sh: context audit finding ids, checkpoint compaction,
technology and command detection, worktree pruning and a diagnostic report that
leaves out personal data. Nothing here installs or runs project commands.
"""
from datetime import datetime
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

import core

CODEX_LIMIT = 32768        # Codex project_doc_max_bytes default
FILE_WARN = 12000
PROGRESS_WARN = 8000
SCAN_MAX = 1024 * 1024
IMPORT_DEPTH = 4           # Claude Code follows @ imports up to four hops
CHECKPOINT_KEEP = 3
CHECKPOINT_HEADING = re.compile(r"^## Checkpoint · ")
INSTRUCTION_MARKER = "<!-- assistente-ia: instrucoes-do-projeto -->"  # Same marker as lib/projects.sh
SECRET = re.compile("|".join(
    f"({line.strip()})" for line in (core.RESOURCES / "secret-patterns.txt").read_text(encoding="utf-8").splitlines() if line.strip()
))
IMPORT = re.compile(r"(?:^|\s)@(\S+)")
REFERENCE = re.compile(r"(?:^|[\s(`\"])([A-Za-z0-9_][A-Za-z0-9_./-]*[.]md)")


def _regular(path):
    try:
        return path.is_file() and not core.is_link(path)
    except OSError:
        return False


def _size(path):
    try:
        return path.stat().st_size
    except OSError:
        return 0


def _text(path):
    try:
        return path.read_text(encoding="utf-8-sig", errors="replace")
    except OSError:
        return ""


def context_files(folder):
    layout = core.project_layout(folder)
    names = ["AGENTS.override.md", "AGENTS.md", "CLAUDE.md", "CLAUDE.local.md", layout["instructions"], layout["progress"]]
    found = [name for name in names if _regular(folder / name)]
    prompts = folder / layout["prompts"]
    if prompts.is_dir() and not core.is_link(prompts):
        found += sorted(f"{layout['prompts']}/{path.name}" for path in prompts.glob("*.md") if _regular(path))
    return found


def imports_of(path):
    fence = False
    for line in _text(path).splitlines():
        if line.startswith(("```", "~~~")):
            fence = not fence
            continue
        if fence:
            continue
        line = re.sub(r"`[^`]*`", "", line)
        for token in IMPORT.findall(line):
            token = token.rstrip(".,;:)")
            if "/" in token or "." in token:
                yield token


def resolve_import(base, token):
    if token.startswith("~/"):
        return Path.home() / token[2:]
    return Path(token) if os.path.isabs(token) else base / token


def _meaningful_lines(path):
    for line in _text(path).splitlines():
        line = line.strip()
        if len(line) >= 25 and not line.startswith("#"):
            yield line


def duplicate_count(first, second):
    if not (_regular(first) and _regular(second)):
        return 0
    seen = set(_meaningful_lines(first))
    return len(seen & set(_meaningful_lines(second)))


def checkpoint_count(path):
    return sum(1 for line in _text(path).splitlines() if CHECKPOINT_HEADING.match(line))


def context_findings(folder):
    """Returns (id, detail) pairs; never includes the value of a suspected secret."""
    layout = core.project_layout(folder)
    instructions, progress = layout["instructions"], layout["progress"]
    findings = []
    for name in context_files(folder):
        path = folder / name
        size = _size(path)
        if size > SCAN_MAX:
            continue
        lines = [number for number, line in enumerate(_text(path).splitlines(), 1) if SECRET.search(line)]
        findings += [("secret", f"{name}:{number}") for number in lines[:5]]
        if name != progress and size > FILE_WARN:
            findings.append(("large", f"{name}:{size}"))
    entry = "AGENTS.override.md" if _regular(folder / "AGENTS.override.md") else ("AGENTS.md" if _regular(folder / "AGENTS.md") else "")
    if entry == "AGENTS.override.md" and _regular(folder / "AGENTS.md"):
        findings.append(("override", "AGENTS.override.md"))
    if entry:
        codex = _size(folder / entry)
        if codex > CODEX_LIMIT:
            findings.append(("codex_limit", f"{entry}:{codex}"))
        for token in sorted(set(REFERENCE.findall(_text(folder / entry)))):
            if not (folder / token).exists():
                findings.append(("missing_ref", f"{entry}:{token}"))
        content = _text(folder / entry)
        if (INSTRUCTION_MARKER in content or instructions in content) and _regular(folder / instructions):
            codex += _size(folder / instructions)
            count = duplicate_count(folder / entry, folder / instructions)
            if count:
                findings.append(("duplicate", f"{entry}+{instructions}:{count}"))
        findings.append(("estimate_codex", str(codex)))
    if _regular(folder / "CLAUDE.md"):
        total, visited = 0, set()

        def walk(path, depth, label):
            nonlocal total
            key = os.path.abspath(path)
            if key in visited:
                return
            visited.add(key)
            total += _size(path)
            for token in imports_of(path):
                target = resolve_import(path.parent, token)
                if not target.is_file():
                    findings.append(("missing_import", f"{label}:@{token}"))
                elif depth >= IMPORT_DEPTH:
                    findings.append(("import_depth", f"{label}:@{token}"))
                else:
                    walk(target, depth + 1, token)

        walk(folder / "CLAUDE.md", 1, "CLAUDE.md")
        count = duplicate_count(folder / "CLAUDE.md", folder / instructions)
        if count:
            findings.append(("duplicate", f"CLAUDE.md+{instructions}:{count}"))
        findings.append(("estimate_claude", str(total)))
    if _regular(folder / progress):
        size = _size(folder / progress)
        if size > PROGRESS_WARN:
            findings.append(("large_progress", f"{progress}:{size}"))
        count = checkpoint_count(folder / progress)
        if count > CHECKPOINT_KEEP + 2:
            findings.append(("checkpoints", str(count)))
    return findings


def tokens(size):
    value = int(size) // 4
    if value < 1000:
        return f"~{value} tokens"
    whole, tenth = value // 1000, (value % 1000) // 100
    return core.text(f"~{whole},{tenth} mil tokens", f"~{whole}.{tenth}k tokens", f"~{whole},{tenth} mil tokens")


def render_findings(findings):
    T = core.text
    estimate = T("bytes ÷ 4; não é medição", "bytes ÷ 4; not a measurement", "bytes ÷ 4; no es una medición")
    messages = {
        "secret": T("Possível credencial em {0}. Remova o valor e use variáveis de ambiente.",
                    "Possible credential in {0}. Remove the value and use environment variables.",
                    "Posible credencial en {0}. Elimina el valor y usa variables de entorno."),
        "missing_import": T("Import do Claude aponta para arquivo inexistente: {0}", "Claude import points to a missing file: {0}",
                            "Un import de Claude apunta a un archivo inexistente: {0}"),
        "import_depth": T("Import além de 4 níveis (o Claude Code não segue): {0}", "Import deeper than 4 levels (Claude Code does not follow it): {0}",
                          "Import a más de 4 niveles (Claude Code no lo sigue): {0}"),
        "missing_ref": T("Referência a arquivo inexistente: {0}", "Reference to a missing file: {0}", "Referencia a un archivo inexistente: {0}"),
        "codex_limit": T("Acima do limite padrão de 32 KiB do Codex (project_doc_max_bytes); o excesso é ignorado: {0}",
                         "Over the default 32 KiB Codex limit (project_doc_max_bytes); the excess is ignored: {0}",
                         "Supera el límite predeterminado de 32 KiB de Codex (project_doc_max_bytes); el exceso se ignora: {0}"),
        "duplicate": T("Linhas repetidas carregadas duas vezes: {0}", "Repeated lines loaded twice: {0}", "Líneas repetidas cargadas dos veces: {0}"),
        "override": T("AGENTS.override.md substitui AGENTS.md no Codex", "AGENTS.override.md replaces AGENTS.md in Codex",
                      "AGENTS.override.md sustituye a AGENTS.md en Codex"),
        "large": T("Arquivo de contexto grande (bytes): {0}", "Large context file (bytes): {0}", "Archivo de contexto grande (bytes): {0}"),
        "large_progress": T("Andamento grande (bytes); condense ou compacte checkpoints: {0}",
                            "Large progress notes (bytes); condense or compact checkpoints: {0}",
                            "Progreso extenso (bytes); resume o compacta los checkpoints: {0}"),
        "checkpoints": T("{0} checkpoints no andamento; compacte os antigos (mantém os 3 últimos)",
                         "{0} checkpoints in progress notes; compact old ones (keeps the last 3)",
                         "{0} checkpoints en el progreso; compacta los antiguos (conserva los 3 últimos)"),
    }
    lines = []
    for identifier, detail in findings:
        if identifier == "estimate_codex":
            lines.append("✓ " + T("Codex: contexto fixo estimado", "Codex: estimated fixed context", "Codex: contexto fijo estimado") + f" {tokens(detail)} ({estimate})")
        elif identifier == "estimate_claude":
            lines.append("✓ " + T("Claude Code: contexto fixo estimado", "Claude Code: estimated fixed context", "Claude Code: contexto fijo estimado") + f" {tokens(detail)} ({estimate})")
        else:
            lines.append("! " + messages[identifier].format(detail))
    if not any(line.startswith("!") for line in lines):
        lines.append(T("Nenhum problema de contexto encontrado.", "No context problems found.", "No se encontraron problemas de contexto."))
    return "\n".join(lines)


def checkpoint_compact(folder):
    """Moves older checkpoints to a new archive file and keeps the most recent ones.

    Returns the archive path relative to the project, or None when nothing was moved.
    """
    layout = core.project_layout(folder)
    progress = core.managed_path(folder, layout["progress"])
    if not _regular(progress):
        raise ValueError(core.text("O arquivo de andamento não existe.", "The progress file does not exist.", "El archivo de progreso no existe."))
    lines = progress.read_text(encoding="utf-8").splitlines(keepends=True)
    total = sum(1 for line in lines if CHECKPOINT_HEADING.match(line))
    if total <= CHECKPOINT_KEEP:
        return None
    archive_dir = core.managed_path(folder, layout["archive"])
    name = f"{Path(layout['progress']).stem}-checkpoints-{datetime.now():%Y%m%d-%H%M%S}.md"
    relative = f"{layout['archive']}/{name}"
    label = core.text("Checkpoints anteriores", "Earlier checkpoints", "Checkpoints anteriores")
    kept, moved, seen, inside, old, noted, blank = [], [], 0, False, False, False, False
    for line in lines:
        if line.startswith("## "):
            inside = bool(CHECKPOINT_HEADING.match(line))
            if inside:
                seen += 1
                old = seen <= total - CHECKPOINT_KEEP
            else:
                old = False
            if inside and seen == total - CHECKPOINT_KEEP + 1 and not noted:
                kept += [f"_{label}: {relative}_\n", "\n"]
                noted, blank = True, True
        if inside and old:
            moved.append(line)
        elif not line.strip():
            if not blank:
                kept.append(line)
            blank = True
        else:
            blank = False
            kept.append(line)
    archive_dir.mkdir(parents=True, exist_ok=True)
    archive = archive_dir / name
    core.write_new(archive, "".join(moved))
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", newline="", dir=progress.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write("".join(kept))
        shutil.copymode(progress, temporary)
        temporary.replace(progress)
    except BaseException:
        Path(stream.name).unlink(missing_ok=True)
        archive.unlink(missing_ok=True)
        raise
    return relative


def _has_any(directory, *patterns):
    return any(_regular(path) for pattern in patterns for path in directory.glob(pattern))


def detect(directory):
    """Returns (technologies, {kind: command}) read from known manifest files only."""
    techs, commands = [], {}
    if not directory.is_dir() or core.is_link(directory):
        return techs, commands
    runner = "npm"
    if (directory / "pnpm-lock.yaml").is_file():
        runner = "pnpm"
    if (directory / "yarn.lock").is_file():
        runner = "yarn"
    if (directory / "bun.lockb").is_file() or (directory / "bun.lock").is_file():
        runner = "bun"
    package = directory / "package.json"
    if _regular(package):
        content = _text(package)
        techs.append("Node.js")
        for name, label in (('"next"', "Next.js"), ('"react"', "React"), ('"vue"', "Vue")):
            if name in content:
                techs.append(label)
        if (directory / "tsconfig.json").is_file() or '"typescript"' in content:
            techs.append("TypeScript")
        for script in ("test", "build", "lint", "typecheck", "type-check", "dev"):
            if re.search(rf'"{re.escape(script)}"\s*:', content):
                if script == "test":
                    commands["test"] = "npm test" if runner == "npm" else f"{runner} test"
                elif script in ("typecheck", "type-check"):
                    commands["typecheck"] = f"{runner} run {script}"
                else:
                    commands[script] = f"{runner} run {script}"
    if any(_regular(directory / name) for name in ("pyproject.toml", "requirements.txt", "setup.py")):
        techs.append("Python")
        if (directory / "tests").is_dir() or _regular(directory / "pytest.ini") or "pytest" in _text(directory / "pyproject.toml"):
            commands.setdefault("test", "python3 -m pytest")
    for manifest, tech, found in (
        ("Cargo.toml", "Rust", {"test": "cargo test", "build": "cargo build", "lint": "cargo clippy"}),
        ("go.mod", "Go", {"test": "go test ./...", "build": "go build ./...", "lint": "go vet ./..."}),
        ("Package.swift", "Swift", {"test": "swift test", "build": "swift build"}),
    ):
        if _regular(directory / manifest):
            techs.append(tech)
            for kind, command in found.items():
                commands.setdefault(kind, command)
    if _has_any(directory, "*.sln", "*.csproj"):
        techs.append("C# / .NET")
        commands.setdefault("test", "dotnet test")
        commands.setdefault("build", "dotnet build")
    if _regular(directory / "composer.json"):
        techs.append("PHP")
        if re.search(r'"test"\s*:', _text(directory / "composer.json")):
            commands.setdefault("test", "composer test")
    plugin = any(re.search(r"^\s*\*\s*Plugin Name:", _text(path), re.M) for path in directory.glob("*.php") if _regular(path))
    if _regular(directory / "wp-config.php") or (directory / "wp-content").is_dir() or plugin \
            or re.search(r"^\s*Theme Name:", _text(directory / "style.css"), re.M):
        techs.append("WordPress")
    if not _regular(package) and _has_any(directory, "*.html"):
        techs.append("HTML/CSS/JavaScript")
    return techs, commands


def detect_project(folder):
    """Detects the project root first, then code folders (CODE/ and one level of subfolders)."""
    techs, commands = detect(folder)
    if techs:
        return "", techs, commands
    layout = core.project_layout(folder)
    candidates = [path for path in sorted(folder.iterdir()) if path.is_dir()]
    code = folder / layout["code"]
    if code.is_dir() and not core.is_link(code):
        candidates += [path for path in sorted(code.iterdir()) if path.is_dir()]
    for directory in candidates:
        relative = directory.relative_to(folder).as_posix()
        if core.is_link(directory) or any(part.startswith(".") or part == "node_modules" for part in relative.split("/")):
            continue
        techs, commands = detect(directory)
        if techs:
            return relative, techs, commands
    return "", [], {}


def prune_preview(folder):
    import workflows
    result = workflows.git(folder, "worktree", "prune", "--dry-run", "-v")
    if result.returncode:
        raise ValueError(result.stdout.strip() or workflows.label("need_repo"))
    return result.stdout.strip()


def prune(folder):
    import workflows
    result = workflows.git(folder, "worktree", "prune", "-v")
    if result.returncode:
        raise ValueError(result.stdout.strip())
    return result.stdout.strip()


def sanitize(report):
    home = str(Path.home())
    if home and home not in ("/", "\\"):
        report = report.replace(home, "~")
    return SECRET.sub("[oculto]", report)


def system_report():
    def version(name):
        try:
            command = core.executable(name)
            output = subprocess.run([*command, "--version"], capture_output=True, text=True, timeout=5,
                                    creationflags=subprocess.CREATE_NO_WINDOW if core.WINDOWS else 0)
            return (output.stdout or output.stderr).strip().splitlines()[0][:120]
        except (OSError, IndexError, subprocess.SubprocessError):
            return core.text("ausente", "missing", "ausente")

    terminal = "Windows Console" if core.WINDOWS else next(
        (name for name in ("gnome-terminal", "konsole", "xfce4-terminal", "mate-terminal", "x-terminal-emulator", "xterm") if shutil.which(name)),
        core.text("nenhum terminal encontrado", "no terminal found", "no se encontró ningún terminal"))
    return "\n".join((
        core.text("Sistema", "System", "Sistema"),
        f"{platform.system()} {platform.release()} · {platform.machine()}",
        f"Assistente IA {core.APP_VERSION} · build {core.APP_BUILD}",
        f"Python {platform.python_version()} · Tk {_tk_version()}",
        f"Node.js · {version('node')}",
        f"Terminal · {terminal}",
    ))


def _tk_version():
    module = sys.modules.get("tkinter")
    return getattr(module, "TkVersion", "?") if module else "?"

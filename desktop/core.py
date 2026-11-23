"""Local project files and terminal launch for the Linux and Windows panel."""

import hashlib
import json
import locale
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import urllib.request
import zipfile


APP_VERSION = "1.0"
REPOSITORY = "Anglersondev/Codex-CLI-Claude-Code-Workspace"
RELEASES = f"https://github.com/{REPOSITORY}/releases"
WINDOWS = os.name == "nt"
SUPPORTED_LANGUAGES = ("automatic", "pt-BR", "en", "es")


def effective_language(preference="automatic"):
    if preference in SUPPORTED_LANGUAGES[1:]:
        return preference
    system = next((value for value in (
        os.environ.get("ASSISTENTE_LANG"), os.environ.get("LC_ALL"), os.environ.get("LC_MESSAGES"),
        os.environ.get("LANGUAGE"), os.environ.get("LANG"), locale.getlocale()[0],
    ) if value), "")
    code = re.split(r"[-_.:@]", system.lower(), maxsplit=1)[0]
    return code if code in ("en", "es") else "pt-BR"


PANEL_LANGUAGE = effective_language()


def configure_language(preference):
    global PANEL_LANGUAGE
    PANEL_LANGUAGE = effective_language(preference)


def text(pt, en, es):
    return {"pt-BR": pt, "en": en, "es": es}[PANEL_LANGUAGE]


LAYOUTS = {}
for line in (Path(__file__).resolve().parents[1] / "lib" / "project-layouts.tsv").read_text(encoding="utf-8").splitlines():
    language, *paths = line.split("\t")
    LAYOUTS[language] = dict(zip(
        ("instructions", "progress", "continue", "close", "summary", "start", "plan",
         "attachments", "code", "archive", "backups"), paths
    ))
    for directory, role in (("rules", "instructions"), ("docs", "progress"), ("prompts", "continue")):
        LAYOUTS[language][directory] = LAYOUTS[language][role].split("/")[0]


def project_language(folder):
    roles = ("instructions", "progress", "continue", "close", "summary", "start", "plan")
    for language, layout in LAYOUTS.items():
        if any((folder / layout[role]).exists() or is_link(folder / layout[role]) for role in roles):
            return language
    for language, layout in LAYOUTS.items():
        if any((folder / layout[role]).is_dir() for role in ("rules", "attachments")):
            return language
    return PANEL_LANGUAGE


def project_layout(folder):
    return LAYOUTS[project_language(folder)]


def state_directory():
    if "ASSISTENTE_STATE_DIR" in os.environ:
        return Path(os.environ["ASSISTENTE_STATE_DIR"])
    if WINDOWS:
        return Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local")) / "Assistente IA"
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "assistente-ia"


class State:
    def __init__(self, directory):
        self.directory = directory
        self.settings = directory / "desktop.json"
        try:
            config = json.loads(self.settings.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            config = {}
        self.config = config if isinstance(config, dict) else {}

    def write(self, name, value):
        self.directory.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=self.directory, delete=False) as temporary:
            path = Path(temporary.name)
            temporary.write(value)
        try:
            path.replace(self.directory / name)
        finally:
            path.unlink(missing_ok=True)

    @property
    def parent(self):
        value = self.config.get("parent")
        if isinstance(value, str) and value and Path(value).is_dir():
            return Path(value)
        documents = Path.home() / "Documents"
        return documents if documents.is_dir() else Path.home()

    def set_parent(self, folder):
        self.set_value("parent", str(folder))

    def set_value(self, key, value):
        self.config[key] = value
        self.write(self.settings.name, json.dumps(self.config, ensure_ascii=False))

    def agent_preferences(self, folder):
        key = hashlib.sha256(str(folder.resolve()).encode("utf-8")).hexdigest()
        return State(self.directory / "projects" / key)

    def agent_for(self, folder):
        prefs = self.agent_preferences(folder)
        try:
            agent = (prefs.directory / "tool").read_text(encoding="utf-8-sig").strip()
        except (OSError, UnicodeError):
            agent = ""
        return agent if agent in ("codex", "claude") else preferred_agent(folder)

    def remember_agent(self, folder, agent):
        self.agent_preferences(folder).write("tool", agent + "\n")

    def recent(self):
        try:
            paths = (self.directory / "recents").read_text(encoding="utf-8-sig").splitlines()
        except (OSError, ValueError):
            return []
        return list(dict.fromkeys(Path(path) for path in paths if path and Path(path).is_dir()))[:20]

    def select(self, folder):
        path = folder.resolve(strict=True)
        if not path.is_dir() or "\n" in str(path) or "\r" in str(path):
            raise ValueError(text("Escolha uma pasta válida.", "Choose a valid folder.", "Elige una carpeta válida."))
        others = [other for other in self.recent() if other != path]
        self.write("recents", "".join(str(item) + "\n" for item in [path, *others[:19]]))
        self.write("current", str(path) + "\n")
        return path


def validate_name(name):
    if (not name or len(name) > 120 or name.startswith((".", "-")) or name.endswith((".", " "))
            or re.search(r'[\\/:*?"<>|\x00-\x1f]', name)
            or re.fullmatch(r"(?:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\..*)?", name, re.IGNORECASE)):
        raise ValueError(text("Use um nome de arquivo ou pasta válido, com até 120 caracteres.",
                              "Use a valid file or folder name of up to 120 characters.", "Usa un nombre de archivo o carpeta válido de hasta 120 caracteres."))


def managed_path(project, relative):
    path = project
    for component in relative.split("/"):
        path /= component
        if is_link(path):
            raise ValueError(text(f"A pasta contém um link em {relative}.", f"The folder contains a link at {relative}.", f"La carpeta contiene un enlace en {relative}."))
    return path


def is_link(path):
    try:
        stat = path.lstat()
    except FileNotFoundError:
        return False
    return path.is_symlink() or bool(getattr(stat, "st_file_attributes", 0) & 0x400)


def write_new(path, content, keep_existing=False):
    try:
        with path.open("x", encoding="utf-8", newline="\n") as stream:
            stream.write(content)
    except FileExistsError:
        if not keep_existing or not path.is_file():
            raise


def scaffold(folder, agent, goal=""):
    language = project_language(folder)
    layout = LAYOUTS[language]

    def template(pt, en, es):
        return {"pt-BR": pt, "en": en, "es": es}[language]

    rules, progress = layout["instructions"], layout["progress"]
    files = {
        "AGENTS.md": template(f"Leia {rules} antes de trabalhar neste projeto.\n",
                          f"Read {rules} before working on this project.\n", f"Lee {rules} antes de trabajar en este proyecto.\n"),
        "CLAUDE.md": f"@{rules}\n",
        layout["instructions"]: template("# Instruções do projeto\n\nObjetivo: ", "# Project instructions\n\nGoal: ", "# Instrucciones del proyecto\n\nObjetivo: ") + goal + "\n",
        layout["progress"]: template("# Andamento\n\n## O que funciona\n\n## Próximo passo\n",
                                  "# Progress\n\n## What works\n\n## Next step\n", "# Progreso\n\n## Qué funciona\n\n## Próximo paso\n"),
        layout["continue"]: template(
            f"Leia {rules} e {progress}. Confira os arquivos e continue a tarefa registrada. "
            "Se o próximo passo estiver indefinido, peça esclarecimento.\n",
            f"Read {rules} and {progress}. Check the files and continue the recorded task. "
            "If the next step is unclear, ask for clarification.\n",
            f"Lee {rules} y {progress}. Comprueba los archivos y continúa con la tarea registrada. "
            "Si el próximo paso no está claro, pide una aclaración.\n",
        ),
        layout["close"]: template(f"Atualize {progress} com as mudanças confirmadas, os testes e o próximo passo. Mantenha o resumo curto.\n",
                                          f"Update {progress} with confirmed changes, tests, and the next step. Keep it concise.\n", f"Actualiza {progress} con los cambios confirmados, las pruebas y el próximo paso. Sé breve.\n"),
        ".assistente-ia/tool": agent + "\n",
    }
    directories = {name: managed_path(folder, name) for name in (layout["rules"], layout["docs"], layout["prompts"], layout["attachments"], ".assistente-ia")}
    paths = {name: managed_path(folder, name) for name in files}
    if any(path.exists() and not path.is_file() for path in paths.values()):
        raise ValueError(template("Um caminho reservado já está em uso.", "A reserved path is already in use.", "Una ruta reservada ya está en uso."))
    for path in directories.values():
        path.mkdir(exist_ok=True)
    for name, path in paths.items():
        write_new(path, files[name], keep_existing=True)


def project_creation_root(parent):
    return parent.parent if parent.name.upper() in ("CODEX", "CLAUDE") else parent


def create_project(parent, name, agent, goal, grouped=True):
    validate_name(name)
    if agent not in ("codex", "claude"):
        raise ValueError("Unknown agent")
    root = parent.resolve(strict=True)
    groups = {}
    if grouped:
        root = project_creation_root(root)
        groups = {agent: managed_path(root, agent.upper()) for agent in ("codex", "claude")}
    project = groups.get(agent, root) / name
    if project.exists() or is_link(project):
        raise FileExistsError(project)
    for directory in groups.values():
        if directory.exists() and not directory.is_dir():
            raise NotADirectoryError(directory)
    for directory in groups.values():
        directory.mkdir(exist_ok=True)
    project.mkdir()
    scaffold(project, agent, goal)
    write_new(project / ".gitignore", ".env\n.env.*\n!.env.example\nnode_modules/\n.venv/\n__pycache__/\n")
    return project


def preferred_agent(folder):
    try:
        profile = managed_path(folder, ".assistente-ia/tool").read_text(encoding="utf-8-sig").strip()
    except (OSError, UnicodeError, ValueError):
        profile = ""
    if profile in ("codex", "claude"):
        return profile
    return "claude" if (folder / "CLAUDE.md").is_file() and not (folder / "AGENTS.md").is_file() else "codex"


def progress_available(folder):
    try:
        path = managed_path(folder, project_layout(folder)["progress"])
        with path.open(encoding="utf-8-sig", errors="replace") as stream:
            for line in stream:
                note = line.strip()
                if note and not note.startswith(("#", "Registre fatos confirmados", "Record confirmed facts")):
                    return True
    except (OSError, ValueError):
        return False
    return False


def instructions_are_long(folder, agent):
    entry = "CLAUDE.md" if agent == "claude" else "AGENTS.md"
    if agent == "codex" and (folder / "AGENTS.override.md").is_file():
        entry = "AGENTS.override.md"
    size = 0
    for name in (entry, project_layout(folder)["instructions"]):
        try:
            size += managed_path(folder, name).stat().st_size
        except (OSError, ValueError):
            continue
    return size > 12_000


def save_prompt(folder, name, prompt):
    validate_name(name)
    if not prompt.strip() or len(prompt.encode("utf-8")) > 60000:
        raise ValueError(text("O pedido deve ter texto e até 60 KB.", "The prompt must have text and be at most 60 KB.", "La solicitud debe tener texto y ocupar como máximo 60 KB."))
    target = managed_path(folder, f"{project_layout(folder)['prompts']}/{name}.md")
    target.parent.mkdir(exist_ok=True)
    write_new(target, prompt.rstrip() + "\n")
    return target


def attach_file(folder, source):
    name = source.name
    target = managed_path(folder, f"{project_layout(folder)['attachments']}/{name}")
    target.parent.mkdir(exist_ok=True)
    with source.open("rb") as original, target.open("xb") as copied:
        try:
            shutil.copyfileobj(original, copied)
        except OSError:
            copied.close()
            target.unlink()
            raise


def backup_project(folder, destination):
    if destination.resolve().is_relative_to(folder.resolve()):
        raise ValueError(text("Escolha destino fora do projeto.", "Choose a destination outside the project.", "Elige un destino fuera del proyecto."))
    with destination.open("xb") as output:
        try:
            with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
                for root, directories, files in os.walk(folder):
                    root = Path(root)
                    directories[:] = [name for name in directories if not is_link(root / name)]
                    archive.write(root, root.relative_to(folder.parent).as_posix())
                    for name in files:
                        path = root / name
                        if path.is_file() and not is_link(path):
                            archive.write(path, path.relative_to(folder.parent).as_posix())
        except (OSError, zipfile.BadZipFile):
            output.close()
            destination.unlink()
            raise


def executable(name):
    if WINDOWS:
        local = Path(os.environ.get("LOCALAPPDATA", Path.home()))
        candidates = [shutil.which(name + ".exe"), Path.home() / ".local" / "bin" / (name + ".exe")]
        if name == "codex":
            candidates.append(local / "Programs" / "OpenAI" / "Codex" / "bin" / "codex.exe")
        for candidate in candidates:
            if candidate and Path(candidate).is_file():
                return [str(candidate)]
        node = shutil.which("node.exe")
        cmd = shutil.which(name + ".cmd")
        npm_entry = {
            "codex": "@openai/codex/bin/codex.js",
            "claude": "@anthropic-ai/claude-code/cli.js",
            "npm": "npm/bin/npm-cli.js",
        }.get(name)
        if node and cmd and npm_entry:
            js = Path(cmd).parent / "node_modules" / npm_entry
            if js.is_file():
                return [node, str(js)]
    else:
        user_bin = str(Path.home() / ".local" / "bin")
        found = shutil.which(name, path=os.pathsep.join((user_bin, os.environ.get("PATH", os.defpath))))
        if found:
            return [found]
    raise FileNotFoundError(text(f"{name} não foi encontrado. Instale a ferramenta oficial.",
                                 f"{name} was not found. Install the official tool.", f"No se encontró {name}. Instala la herramienta oficial."))


def session_arguments(agent, mode, folder, plan=False, model="", prompt=""):
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_./:\[\]-]*", model) and model:
        raise ValueError(text("Nome de modelo inválido.", "Invalid model name.", "Nombre de modelo no válido."))
    if agent == "codex":
        arguments = {"new": [], "resume": ["resume", "--last"], "history": ["resume"]}[mode]
        arguments += ["--cd", str(folder), "--ask-for-approval", "on-request",
                      "--sandbox", "read-only" if plan else "workspace-write"]
    else:
        arguments = {"new": [], "resume": ["--continue"], "history": ["--resume"]}[mode]
        arguments += ["--permission-mode", "plan" if plan else "default"]
    if model:
        arguments.extend(("--model", model))
    if prompt:
        arguments.extend(("--", prompt))
    return arguments


def session_environment(agent, avoid_overlap):
    environment = os.environ.copy()
    if avoid_overlap:
        if agent == "codex":
            config = Path(environment.get("CODEX_HOME", Path.home() / ".codex")) / "hooks.json"
        else:
            config = Path(environment.get("CLAUDE_CONFIG_DIR", Path.home() / ".claude")) / "settings.json"
        try:
            configured = f"rtk hook {agent}" in config.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            configured = False
        if configured:
            environment["TOKEN_OPTIMIZER_BASH_COMPRESS"] = "0"
            environment["TOKEN_OPTIMIZER_NO_UPDATED_TOOL_OUTPUT"] = "1"
    return environment


def terminal_worker(job):
    def interrupt(_number, _frame):
        raise KeyboardInterrupt

    if not WINDOWS:
        signal.signal(signal.SIGTERM, interrupt)
        signal.signal(signal.SIGHUP, interrupt)
    folder = job.parent
    (folder / "started").touch()
    status = 1
    try:
        config = json.loads(job.read_text(encoding="utf-8"))
        configure_language(config.get("language", "automatic"))
        environment = session_environment(config["agent"], config["avoid_overlap"])
        for command in config["commands"]:
            status = subprocess.call(command, cwd=config["cwd"], env=environment)
            if status != 0:
                break
        if status not in (0, 130, -2):
            print(text(f"Comando terminou com código {status}.", f"Command exited with code {status}.", f"El comando terminó con el código {status}."))
            input(text("Enter para voltar ao Assistente. ", "Press Enter to return to Assistente. ", "Pulsa Intro para volver a Assistente. "))
    except KeyboardInterrupt:
        status = 130
    except (OSError, ValueError, EOFError) as error:
        print(error, file=sys.stderr)
    finally:
        (folder / "status").write_text(str(status), encoding="utf-8")
    return 0 if status == 0 else 1


def terminal_process(job, project):
    python = Path(sys.executable)
    if WINDOWS and python.name.lower() == "pythonw.exe":
        python = python.with_name("python.exe")
    worker = [str(python), str(Path(__file__).with_name("panel.py")), "--terminal-worker", str(job)]
    if WINDOWS:
        return subprocess.Popen(worker, cwd=project, creationflags=subprocess.CREATE_NEW_CONSOLE)
    for program, flags in (
        ("gnome-terminal", ["--wait", "--"]), ("konsole", ["--separate", "-e"]),
        ("xfce4-terminal", ["--disable-server", "-x"]), ("mate-terminal", ["--disable-factory", "-x"]),
        ("x-terminal-emulator", ["-e"]), ("xterm", ["-e"]),
    ):
        terminal = shutil.which(program)
        if terminal:
            return subprocess.Popen([terminal, *flags, *worker], cwd=project)
    raise OSError(text("Instale um terminal, como GNOME Terminal, Konsole ou xterm.",
                        "Install a terminal such as GNOME Terminal, Konsole, or xterm.", "Instala un terminal como GNOME Terminal, Konsole o xterm."))


def newer_version(tag, installed=APP_VERSION):
    def version(value):
        if not re.fullmatch(r"v?[0-9]{1,4}\.[0-9]{1,4}(?:\.[0-9]{1,4})?", value):
            raise ValueError(text("Versão publicada desconhecida.", "Unknown published version.", "Versión publicada desconocida."))
        parts = [int(part) for part in value.lstrip("v").split(".")]
        return tuple((parts + [0])[:3])

    return version(tag) > version(installed)


def check_release():
    request = urllib.request.Request(
        f"https://api.github.com/repos/{REPOSITORY}/releases/latest",
        headers={"Accept": "application/vnd.github+json", "User-Agent": "Assistente-IA"},
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        release = json.loads(response.read(1_000_000))
    tag = release.get("tag_name", "")
    return tag if newer_version(tag) else ""

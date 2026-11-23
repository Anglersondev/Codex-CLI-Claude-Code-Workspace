"""Graphical launcher for Linux and Windows. No pip dependencies."""

from datetime import datetime
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import webbrowser

from core import (
    APP_VERSION, RELEASES, SUPPORTED_LANGUAGES, WINDOWS, State, attach_file, backup_project, check_release,
    configure_language, create_project, executable, instructions_are_long, managed_path, preferred_agent,
    progress_available, project_creation_root, save_prompt, scaffold, session_arguments, state_directory,
    terminal_process, terminal_worker, text as T,
)


if len(sys.argv) == 3 and sys.argv[1] == "--terminal-worker":
    raise SystemExit(terminal_worker(Path(sys.argv[2])))


import tkinter as tk
from tkinter import filedialog, messagebox, ttk


BLUE, INK, MUTED, BACKGROUND = "#1867cf", "#172637", "#4c637a", "#edf3fa"
AGENT_NAMES = {"codex": "Codex", "claude": "Claude Code"}


class Panel:
    def __init__(self, root):
        self.root = root
        self.state = State(state_directory())
        configure_language(self.state.config.get("language", "automatic"))
        self.paths = self.state.recent()
        self.project = self.paths[0] if self.paths else None
        self.agent = tk.StringVar(value="codex")
        self.plan = tk.BooleanVar()
        self.model = tk.StringVar()
        self.overlap = tk.BooleanVar(value=self.state.config.get("avoid_overlap", True))
        self.update_notice = tk.BooleanVar(value=self.state.config.get("update_notice", False))
        self.status = tk.StringVar()
        self.prompt = None
        self.job = None
        self.messages = queue.Queue()
        self.style()
        self.build()
        self.bind_shortcuts()
        self.render(select_agent=True)
        self.root.bind("<FocusIn>", self.refresh_context)
        self.root.after(250, self.poll)
        if self.update_notice.get():
            self.root.after(2000, self.check_updates)

    def style(self):
        self.root.title(f"Assistente IA {APP_VERSION}")
        self.root.geometry("920x570")
        self.root.minsize(755, 510)
        self.root.configure(background=BACKGROUND)
        theme = ttk.Style(self.root)
        theme.theme_use("clam")
        theme.configure(".", background="white", foreground=INK, font="TkDefaultFont")
        theme.configure("TButton", padding=(9, 5))
        theme.configure("Accent.TButton", background=BLUE, foreground="white")
        theme.map("Accent.TButton", background=[("active", "#1056b2"), ("disabled", "#677d95")])
        theme.configure("TLabel", background="white")
        theme.configure("Sub.TLabel", foreground=MUTED)
        theme.configure("Title.TLabel", font=("TkDefaultFont", 18, "bold"))
        theme.configure("Section.TLabel", font=("TkDefaultFont", 11, "bold"))
        theme.configure("TLabelframe.Label", foreground=INK, background="white")

    def build(self):
        self.root.columnconfigure(1, weight=1)
        self.root.rowconfigure(0, weight=1)
        sidebar = ttk.Frame(self.root, padding=(12, 15))
        sidebar.grid(row=0, column=0, sticky="ns", padx=(10, 6), pady=10)
        ttk.Label(sidebar, text=T("Projetos recentes", "Recent projects", "Proyectos recientes"), style="Section.TLabel").pack(anchor="w")
        self.list = tk.Listbox(sidebar, width=23, borderwidth=0, highlightthickness=1, highlightcolor=BLUE,
                               selectbackground=BLUE, selectforeground="white", exportselection=False, activestyle="none")
        self.list.pack(fill="both", expand=True, pady=(8, 10))
        self.list.bind("<<ListboxSelect>>", self.selected)
        ttk.Separator(sidebar).pack(fill="x", pady=8)
        ttk.Label(sidebar, text=T("Pasta padrão", "Default folder", "Carpeta predeterminada"), style="Section.TLabel").pack(anchor="w")
        self.parent_button = ttk.Button(sidebar, command=self.choose_parent, width=23)
        self.parent_button.pack(fill="x", pady=(5, 10))
        sidebar_actions = ttk.Frame(sidebar)
        sidebar_actions.pack(fill="x")
        ttk.Button(sidebar_actions, text=T("Novo…", "New…", "Nuevo…"), command=self.create_window).pack(side="left")
        ttk.Button(sidebar_actions, text=T("Abrir…", "Open…", "Abrir…"), command=self.open_project).pack(side="right")

        main = ttk.Frame(self.root, padding=(17, 15))
        main.grid(row=0, column=1, sticky="nsew", padx=(5, 10), pady=10)
        header = ttk.Frame(main)
        header.pack(fill="x")
        self.title = ttk.Label(header, style="Title.TLabel")
        self.title.pack(side="left", anchor="w")
        ttk.Button(header, text=T("Ajustes", "Settings", "Ajustes"), command=self.settings).pack(side="right")
        self.location = ttk.Label(main, style="Sub.TLabel")
        self.location.pack(anchor="w", pady=(2, 14))

        session = ttk.LabelFrame(main, text=T("Sessão no Terminal", "Terminal session", "Sesión en Terminal"), padding=(12, 9))
        session.pack(fill="x", pady=(0, 10))
        agents = ttk.Frame(session)
        agents.pack(fill="x", pady=(0, 9))
        for key, name in AGENT_NAMES.items():
            ttk.Radiobutton(agents, text=name, variable=self.agent, value=key, command=self.refresh_context).pack(side="left", padx=(0, 15))
        actions = ttk.Frame(session)
        actions.pack(fill="x")
        self.session_controls = [
            self.button(actions, T("Nova sessão", "New session", "Nueva sesión"), lambda: self.launch("new"), True),
            self.button(actions, T("Continuar", "Resume", "Continuar"), lambda: self.launch("resume")),
            self.button(actions, T("Histórico…", "History…", "Historial…"), lambda: self.launch("history")),
            self.button(actions, T("Opções…", "Options…", "Opciones…"), self.options),
        ]
        ttk.Label(session, text=T("Ao sair do agente, volte a este painel.", "Exit the agent to return to this panel.", "Sal del agente para volver a este panel."),
                  style="Sub.TLabel").pack(anchor="w", pady=(7, 0))

        context = ttk.LabelFrame(main, text=T("Contexto e arquivos", "Context and files", "Contexto y archivos"), padding=(12, 9))
        context.pack(fill="x", pady=(0, 10))
        self.context = ttk.Label(context, style="Sub.TLabel")
        self.context.pack(anchor="w", pady=(0, 7))
        self.context_hint = ttk.Label(context, style="Sub.TLabel", wraplength=450)
        self.context_hint.pack(anchor="w")
        files = ttk.Frame(context)
        files.pack(fill="x")
        self.file_controls = [
            self.button(files, T("Instruções", "Instructions", "Instrucciones"), self.open_instructions),
            self.button(files, T("Novo pedido…", "New prompt…", "Nueva solicitud…"), self.prompt_window),
            self.button(files, T("Adicionar anexo…", "Add attachment…", "Añadir archivo adjunto…"), self.attach),
        ]
        self.continue_control = self.button(
            files, T("Retomar pelo andamento", "Continue from notes", "Continuar desde las notas"), self.continue_notes
        )
        self.file_controls.append(self.continue_control)
        quick = ttk.Frame(context)
        quick.pack(fill="x", pady=(6, 0))
        self.file_controls += [
            self.button(quick, "Terminal", self.open_shell),
            self.button(quick, "Git", self.git_status),
            self.button(quick, T("Servidor npm…", "npm server…", "Servidor npm…"), self.dev_server),
            self.button(quick, T("Cópia ZIP…", "ZIP backup…", "Copia ZIP…"), self.backup),
        ]
        more = ttk.Frame(main)
        more.pack(fill="x")
        self.tools_menu = tk.Menu(more, tearoff=False)
        for title, command in (
            (T("Abrir pasta do projeto", "Open project folder", "Abrir carpeta del proyecto"), lambda: self.open_file(self.project)),
            (T("Preparar contexto compartilhado", "Set up shared context", "Configurar contexto compartido"), self.prepare),
            (T("Salvar andamento da sessão", "Save session progress", "Guardar progreso de la sesión"), self.wrap_up),
            (T("Copiar caminho completo", "Copy full path", "Copiar la ruta completa"), self.copy_path),
            (T("Atalhos do teclado", "Keyboard shortcuts", "Atajos de teclado"), self.show_shortcuts),
        ):
            self.tools_menu.add_command(label=title, command=lambda action=command: self.guard(action))
        self.tools = ttk.Menubutton(more, menu=self.tools_menu, text=T("Ferramentas do projeto", "Project tools", "Herramientas del proyecto"))
        self.tools.pack(side="left")
        ttk.Label(main, textvariable=self.status, style="Sub.TLabel", wraplength=450).pack(anchor="w", pady=(10, 0))

    def button(self, parent, title, command, accent=False):
        widget = ttk.Button(parent, text=title, command=lambda: self.guard(command), style="Accent.TButton" if accent else "TButton")
        widget.pack(side="left", padx=(0, 6))
        return widget

    def shortcuts(self):
        return (
            ("Ctrl+N", "<Control-n>", T("Novo projeto", "New project", "Nuevo proyecto"), self.create_window, False),
            ("Ctrl+O", "<Control-o>", T("Abrir pasta", "Open folder", "Abrir carpeta"), self.open_project, False),
            ("Ctrl+Shift+D", "<Control-Shift-D>", T("Pasta padrão", "Default folder", "Carpeta predeterminada"), self.choose_parent, False),
            ("Ctrl+Enter", "<Control-Return>", T("Nova sessão", "New session", "Nueva sesión"), lambda: self.launch("new"), True),
            ("Ctrl+Shift+P", "<Control-Shift-P>", T("Novo pedido", "New prompt", "Nueva solicitud"), self.prompt_window, True),
            ("Ctrl+Shift+A", "<Control-Shift-A>", T("Adicionar anexo", "Add attachment", "Añadir archivo adjunto"), self.attach, True),
            ("Ctrl+Shift+T", "<Control-Shift-T>", "Terminal", self.open_shell, True),
            ("Ctrl+Shift+G", "<Control-Shift-G>", "Git", self.git_status, True),
            ("Ctrl+Shift+R", "<Control-Shift-R>", T("Servidor npm", "npm server", "Servidor npm"), self.dev_server, True),
            ("Ctrl+Shift+B", "<Control-Shift-B>", T("Cópia ZIP", "ZIP backup", "Copia ZIP"), self.backup, True),
        )

    def bind_shortcuts(self):
        def activate(command, needs_project):
            if self.root.grab_current() is None and (self.project is not None or not needs_project):
                self.guard(command)
                return "break"
            return None

        for _, sequence, _, command, needs_project in self.shortcuts():
            self.root.bind(sequence, lambda _event, action=command, required=needs_project: activate(action, required))

    def show_shortcuts(self):
        rows = [f"{keys:<18} {name}" for keys, _, name, _, _ in self.shortcuts()]
        self.output(T("Atalhos do teclado", "Keyboard shortcuts", "Atajos de teclado"), "\n".join(rows))

    def render(self, select_agent=False):
        self.paths = self.state.recent()
        self.list.delete(0, "end")
        for index, path in enumerate(self.paths):
            self.list.insert("end", path.name)
            if path == self.project:
                self.list.selection_set(index)
        self.parent_button.configure(text=self.state.parent.name or str(self.state.parent))
        for control in [*self.session_controls, *self.file_controls, self.tools]:
            control.state(["!disabled"] if self.project is not None else ["disabled"])
        if self.project is None:
            self.title.configure(text=T("Escolha um projeto", "Choose a project", "Elige un proyecto"))
            self.location.configure(text=T("Crie uma pasta ou abra uma que já existe.", "Create a folder or open an existing one.", "Crea una carpeta o abre una existente."))
            return
        self.title.configure(text=self.project.name)
        self.location.configure(text="  /  ".join(self.project.parent.parts[-2:]))
        entries = [name for name in ("AGENTS.md", "CLAUDE.md") if (self.project / name).is_file()]
        self.context.configure(text="  ·  ".join(entries) if entries else T("Contexto a configurar", "Context to set up", "Contexto pendiente de configurar"))
        if select_agent:
            self.agent.set(preferred_agent(self.project))
            self.prompt = None
            self.model.set("")
        self.refresh_context()

    def refresh_context(self, event=None):
        if self.project is None or (event is not None and event.widget is not self.root):
            return
        ready = progress_available(self.project) and (self.project / "PROMPTS" / "CONTINUAR.md").is_file()
        self.continue_control.state(["!disabled"] if ready else ["disabled"])
        notes = []
        if not ready:
            notes.append(T(
                "Registre o próximo passo em DOCS/ANDAMENTO.md para retomar depois.",
                "Record the next step in DOCS/ANDAMENTO.md to continue later.",
                "Anota el próximo paso en DOCS/ANDAMENTO.md para continuar más tarde.",
            ))
        if instructions_are_long(self.project, self.agent.get()):
            notes.append(T(
                "Instruções extensas. Mova referências que usa só às vezes para DOCS.",
                "Long instructions. Move occasional references to DOCS.",
                "Instrucciones extensas. Mueve a DOCS las referencias de uso ocasional.",
            ))
        self.context_hint.configure(text="\n".join(notes))

    def selected(self, _event):
        choice = self.list.curselection()
        if choice and self.paths[choice[0]] != self.project:
            self.project = self.paths[choice[0]]
            self.status.set("")
            self.render(select_agent=True)

    def guard(self, action):
        try:
            action()
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            messagebox.showerror("Assistente IA", str(error), parent=self.root)

    def choose_parent(self):
        path = filedialog.askdirectory(parent=self.root, initialdir=self.state.parent, title=T("Pasta padrão", "Default folder", "Carpeta predeterminada"))
        if path:
            self.guard(lambda: self.state.set_parent(Path(path)))
            self.render()

    def open_project(self):
        path = filedialog.askdirectory(parent=self.root, initialdir=self.state.parent)
        if path:
            self.guard(lambda: self.select(Path(path)))

    def select(self, path):
        self.project = self.state.select(path)
        self.status.set("")
        self.render(select_agent=True)

    def dialog(self, title):
        window = tk.Toplevel(self.root, background="white")
        window.title(title)
        window.transient(self.root)
        window.grab_set()
        window.bind("<Escape>", lambda _event: window.destroy())
        body = ttk.Frame(window, padding=18)
        body.pack(fill="both", expand=True)
        return window, body

    def create_window(self):
        window, body = self.dialog(T("Novo projeto", "New project", "Nuevo proyecto"))
        parent = tk.StringVar(value=str(self.state.parent))
        remember = tk.BooleanVar()
        agent = tk.StringVar(value=self.agent.get())
        name = self.field(body, T("Nome", "Name", "Nombre"))
        goal = self.field(body, T("Objetivo (opcional)", "Goal (optional)", "Objetivo (opcional)"))
        row = ttk.Frame(body)
        row.pack(anchor="w")
        for key, label in AGENT_NAMES.items():
            ttk.Radiobutton(row, text=label, variable=agent, value=key).pack(side="left", padx=(0, 12))
        preview = ttk.Label(body, wraplength=380, style="Sub.TLabel")
        preview.pack(anchor="w", pady=4)

        def show_destination(*_args):
            root = project_creation_root(Path(parent.get()))
            preview.configure(text=str(root / agent.get().upper()))

        parent.trace_add("write", show_destination)
        agent.trace_add("write", show_destination)
        show_destination()

        def change():
            value = filedialog.askdirectory(parent=window, initialdir=parent.get())
            if value:
                parent.set(value)

        ttk.Button(body, text=T("Escolher outro local…", "Choose a different location…", "Elegir otra ubicación…"), command=change).pack(anchor="w")
        ttk.Checkbutton(body, text=T("Usar como pasta padrão", "Use as default folder", "Usar como carpeta predeterminada"), variable=remember).pack(anchor="w", pady=6)

        def create(start):
            try:
                destination = Path(parent.get())
                folder = create_project(destination, name.get().strip(), agent.get(), goal.get().strip())
                if remember.get():
                    self.state.set_parent(project_creation_root(destination))
                self.select(folder)
            except (OSError, ValueError) as error:
                messagebox.showerror("Assistente IA", str(error), parent=window)
                return
            window.destroy()
            if start:
                self.guard(lambda: self.launch("new"))

        controls = ttk.Frame(body)
        controls.pack(anchor="e", pady=(8, 0))
        ttk.Button(controls, text=T("Só criar", "Create only", "Solo crear"), command=lambda: create(False)).pack(side="left", padx=5)
        ttk.Button(controls, text=T("Criar e abrir Terminal", "Create and open Terminal", "Crear y abrir Terminal"),
                   style="Accent.TButton", command=lambda: create(True)).pack(side="left")
        name.focus_set()

    def field(self, parent, title, variable=None):
        ttk.Label(parent, text=title).pack(anchor="w")
        entry = ttk.Entry(parent, textvariable=variable, width=47)
        entry.pack(fill="x", pady=(4, 8))
        return entry

    def options(self):
        window, body = self.dialog(T("Opções da sessão", "Session options", "Opciones de sesión"))
        self.field(body, T("Modelo (vazio usa o padrão)", "Model (leave blank for default)", "Modelo (deja en blanco para usar el valor predeterminado)"), self.model)
        ttk.Checkbutton(body, text=T("Planejar · somente leitura", "Plan · read-only", "Planificar · solo lectura"), variable=self.plan).pack(anchor="w")
        selected = tk.StringVar(value=self.prompt.name if self.prompt else T("Sem pedido selecionado", "No prompt selected", "Ninguna solicitud seleccionada"))

        def choose():
            path = filedialog.askopenfilename(parent=window, initialdir=self.project / "PROMPTS",
                                               filetypes=[(T("Pedidos", "Prompts", "Solicitudes"), "*.md *.txt")])
            if path:
                self.prompt = Path(path)
                selected.set(self.prompt.name)

        ttk.Label(body, textvariable=selected, style="Sub.TLabel").pack(anchor="w", pady=(12, 4))
        ttk.Button(body, text=T("Escolher pedido…", "Choose prompt…", "Elegir solicitud…"), command=choose).pack(anchor="w")
        ttk.Button(body, text=T("Fechar", "Close", "Cerrar"), command=window.destroy).pack(anchor="e", pady=(11, 0))

    def prompt_window(self):
        window, body = self.dialog(T("Novo pedido", "New prompt", "Nueva solicitud"))
        name = self.field(body, T("Nome do pedido", "Prompt name", "Nombre de la solicitud"))
        content = tk.Text(body, width=51, height=9, wrap="word", borderwidth=1, font="TkDefaultFont")
        content.pack(fill="both", expand=True, pady=(0, 9))

        def save():
            try:
                self.prompt = save_prompt(self.project, name.get().strip(), content.get("1.0", "end-1c"))
            except (OSError, ValueError) as error:
                messagebox.showerror("Assistente IA", str(error), parent=window)
                return
            self.status.set(T("Pedido salvo e selecionado.", "Prompt saved and selected.", "Solicitud guardada y seleccionada."))
            window.destroy()

        ttk.Button(body, text=T("Salvar pedido", "Save prompt", "Guardar solicitud"), command=save).pack(anchor="e")
        name.focus_set()

    def prepare(self):
        scaffold(self.project, self.agent.get())
        self.render()
        self.status.set(T("Contexto preparado.", "Shared context is ready.", "El contexto compartido está listo."))

    def open_instructions(self):
        path = managed_path(self.project, "INSTRUCOES/PROJETO.md")
        if not path.is_file() and messagebox.askyesno("Assistente IA", T("Criar os arquivos de contexto que faltam?", "Create the missing context files?", "¿Crear los archivos de contexto que faltan?"), parent=self.root):
            self.prepare()
        if path.is_file():
            self.open_file(path)

    @staticmethod
    def open_file(path):
        if WINDOWS:
            os.startfile(str(path))
        else:
            subprocess.Popen(["xdg-open", str(path)])

    def attach(self):
        path = filedialog.askopenfilename(parent=self.root)
        if path:
            attach_file(self.project, Path(path))
            self.status.set(T("Arquivo copiado para ANEXOS.", "File copied to ANEXOS.", "Archivo copiado a ANEXOS."))

    def copy_path(self):
        self.root.clipboard_clear()
        self.root.clipboard_append(str(self.project))
        self.status.set(T("Caminho copiado.", "Path copied.", "Ruta copiada."))

    def continue_notes(self):
        self.launch("new", self.project / "PROMPTS" / "CONTINUAR.md")

    def wrap_up(self):
        self.launch("resume", self.project / "PROMPTS" / "ENCERRAR-SESSAO.md", force_work=True)

    def launch(self, mode, prompt_override=None, force_work=False):
        agent = self.agent.get()
        path = prompt_override or (self.prompt if mode == "new" else None)
        prompt = ""
        if path:
            with path.open("rb") as stream:
                data = stream.read(60001)
            if len(data) > 60000:
                raise ValueError(T("O pedido passa de 60 KB.", "The prompt exceeds 60 KB.", "La solicitud supera los 60 KB."))
            prompt = data.decode("utf-8-sig").strip()
        args = session_arguments(agent, mode, self.project, self.plan.get() and not force_work, self.model.get().strip(), prompt)
        self.run_terminal([executable(agent) + args])

    def open_shell(self):
        shell = ["powershell.exe", "-NoLogo"] if WINDOWS else [os.environ.get("SHELL", "/bin/sh"), "-i"]
        self.run_terminal([shell])

    def run_terminal(self, commands, folder=None):
        if self.job:
            raise ValueError(T("Encerre a sessão aberta antes de abrir outra.", "End the open session before starting another.", "Cierra la sesión abierta antes de iniciar otra."))
        working = folder or self.project or self.state.parent
        state = Path(tempfile.mkdtemp(prefix="assistente-"))
        job = state / "job.json"
        try:
            job.write_text(json.dumps({"cwd": str(working), "commands": commands, "agent": self.agent.get(),
                                       "avoid_overlap": self.overlap.get(), "language": self.state.config.get("language", "automatic")}),
                           encoding="utf-8")
            process = terminal_process(job, working)
        except (OSError, ValueError, subprocess.SubprocessError):
            shutil.rmtree(state)
            raise
        self.job = (state, process, time.monotonic())
        self.status.set(T("Sessão aberta no Terminal.", "Session open in Terminal.", "Sesión abierta en Terminal."))

    def poll(self):
        if self.job:
            folder, process, launched = self.job
            result = process.poll()
            started = (folder / "started").exists()
            ended = (folder / "status").exists() or (WINDOWS and started and result is not None)
            delayed = not started and (result not in (None, 0) or time.monotonic() - launched > 20)
            if ended or delayed:
                shutil.rmtree(folder, ignore_errors=True)
                self.job = None
                self.root.deiconify()
                self.root.lift()
                self.root.focus_force()
                if delayed:
                    self.status.set(T("O Terminal não iniciou. Confira o terminal instalado.", "Terminal did not start. Check the installed terminal.", "El terminal no se inició. Comprueba el terminal instalado."))
                else:
                    self.refresh_context()
                    self.status.set(T("De volta ao painel de projetos.", "Back at the project panel.", "De vuelta en el panel de proyectos."))
        while not self.messages.empty():
            self.guard(self.messages.get_nowait())
        self.root.after(250, self.poll)

    def background(self, work, success, show_error=True):
        def run():
            try:
                value = work()
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                if show_error:
                    self.messages.put(lambda message=str(error): messagebox.showerror("Assistente IA", message, parent=self.root))
            else:
                self.messages.put(lambda: success(value))
        threading.Thread(target=run, daemon=True).start()

    def output(self, title, content):
        window, body = self.dialog(title)
        display = tk.Text(body, width=70, height=17, wrap="word", font="TkFixedFont")
        display.insert("1.0", content)
        display.configure(state="disabled")
        display.pack(fill="both", expand=True)
        ttk.Button(body, text=T("Fechar", "Close", "Cerrar"), command=window.destroy).pack(anchor="e", pady=(8, 0))

    def command_output(self, command, folder):
        result = subprocess.run(command, cwd=folder, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=20, encoding="utf-8", errors="replace",
                                creationflags=subprocess.CREATE_NO_WINDOW if WINDOWS else 0)
        return result.stdout

    def git_status(self):
        command = executable("git") + ["--no-optional-locks", "status", "--short", "--branch"]
        project = self.project
        self.background(lambda: self.command_output(command, project), lambda output: self.output(T("Status do Git", "Git status", "Estado de Git"), output))

    def dev_server(self):
        project = self.project
        candidates = [project, *project.iterdir()]
        code = project / "CODIGO"
        if code.is_dir():
            candidates.extend(code.iterdir())
        packages = []
        for directory in candidates:
            if directory != project:
                relative = directory.relative_to(project).as_posix()
                if any(part.startswith(".") or part == "node_modules" for part in relative.split("/")):
                    continue
                try:
                    managed_path(project, relative)
                except ValueError:
                    continue
            package = directory / "package.json"
            if package.is_file() and not package.is_symlink():
                packages.append(directory.relative_to(project).as_posix())
        if not packages:
            raise ValueError(T("Nenhum package.json encontrado.", "No package.json was found.", "No se encontró package.json."))
        window, body = self.dialog(T("Iniciar servidor local", "Start local server", "Iniciar servidor local"))
        choice = tk.StringVar(value=packages[0])
        ttk.Label(body, text=T("Pasta que executará npm run dev", "Folder that will run npm run dev", "Carpeta donde se ejecutará npm run dev")).pack(anchor="w")
        ttk.Combobox(body, values=packages, textvariable=choice, state="readonly", width=37).pack(fill="x", pady=7)

        def run():
            command = executable("npm") + ["run", "dev"]
            target = project / choice.get()
            self.run_terminal([command], folder=target)
            window.destroy()

        ttk.Button(body, text=T("Iniciar", "Start", "Iniciar"), style="Accent.TButton",
                   command=lambda: self.guard(run)).pack(anchor="e")

    def backup(self):
        folder = self.project
        name = folder.name + datetime.now().strftime("-%Y%m%d-%H%M%S.zip")
        selected = filedialog.asksaveasfilename(parent=self.root, initialdir=folder.parent, initialfile=name,
                                               defaultextension=".zip", filetypes=[("ZIP", "*.zip")])
        if selected:
            self.status.set(T("Criando cópia ZIP…", "Creating ZIP backup…", "Creando copia ZIP…"))
            self.background(lambda: backup_project(folder, Path(selected)),
                            lambda _result: self.status.set(T("Cópia ZIP criada.", "ZIP backup created.", "Copia ZIP creada.")))

    def settings(self):
        window, body = self.dialog(T("Ajustes", "Settings", "Ajustes"))
        language_row = ttk.Frame(body)
        language_row.pack(fill="x", pady=(0, 10))
        ttk.Label(language_row, text=T("Idioma", "Language", "Idioma")).pack(side="left", padx=(0, 8))
        choices = (T("Automático", "Automatic", "Automático"), "Português (Brasil)", "English", "Español")
        choice = ttk.Combobox(language_row, values=choices, state="readonly", width=24)
        choice.pack(side="left")
        preference = self.state.config.get("language", "automatic")
        choice.current(SUPPORTED_LANGUAGES.index(preference) if preference in SUPPORTED_LANGUAGES else 0)
        choice.bind("<<ComboboxSelected>>", lambda _event: self.guard(
            lambda: self.change_language(window, SUPPORTED_LANGUAGES[choice.current()])
        ))
        ttk.Label(body, text=T("Agentes e contas", "Agents and accounts", "Agentes y cuentas"), style="Section.TLabel").pack(anchor="w")
        for agent, name in AGENT_NAMES.items():
            row = ttk.Frame(body)
            row.pack(fill="x", pady=(4, 2))
            ttk.Label(row, text=name, width=13).pack(side="left")
            self.button(row, T("Entrar", "Sign in", "Iniciar sesión"), lambda tool=agent: self.login(tool))
            self.button(row, T("Trocar conta", "Switch account", "Cambiar de cuenta"), lambda tool=agent: self.login(tool, switch=True))
            self.button(row, T("Atualizar", "Update", "Actualizar"), lambda tool=agent: self.run_terminal([executable(tool) + ["update"]]))
        ttk.Separator(body).pack(fill="x", pady=10)
        ttk.Checkbutton(body, text=T("Evitar dupla compactação com RTK", "Avoid double compression with RTK", "Evitar la doble compresión con RTK"),
                        variable=self.overlap, command=lambda: self.guard(
                            lambda: self.state.set_value("avoid_overlap", self.overlap.get()))).pack(anchor="w")
        ttk.Button(body, text=T("Economia do RTK", "RTK savings", "Ahorro de RTK"), command=lambda: self.guard(lambda: self.rtk_savings(window))).pack(anchor="w", pady=(7, 0))
        ttk.Checkbutton(body, text=T("Avisar sobre atualizações do Assistente", "Notify me about Assistente updates", "Avisarme de las actualizaciones de Assistente"),
                        variable=self.update_notice, command=self.save_updates).pack(anchor="w", pady=(8, 0))
        updates = ttk.Frame(body)
        updates.pack(fill="x", pady=(6, 0))
        self.button(updates, T("Verificar versão", "Check version", "Comprobar la versión"), lambda: self.check_updates(window))
        self.button(updates, T("Versões publicadas", "Published releases", "Versiones publicadas"), lambda: webbrowser.open(RELEASES))
        ttk.Separator(body).pack(fill="x", pady=10)
        links = ttk.Frame(body)
        links.pack(fill="x")
        self.button(links, T("Desenvolvido por Anglerson", "Developed by Anglerson", "Desarrollado por Anglerson"), lambda: webbrowser.open("https://anglerson.com.br"))
        self.button(links, T("Pague um café", "Buy me a coffee", "Invítame a un café"), lambda: webbrowser.open("https://pixgg.com/Anglerson"))
        ttk.Button(body, text=T("Fechar", "Close", "Cerrar"), command=window.destroy).pack(anchor="e", pady=(10, 0))

    def change_language(self, window, language):
        self.state.set_value("language", language)
        configure_language(language)
        window.destroy()
        for widget in self.root.winfo_children():
            widget.destroy()
        self.status.set("")
        self.build()
        self.bind_shortcuts()
        self.render()
        self.settings()

    def save_updates(self):
        def save():
            self.state.set_value("update_notice", self.update_notice.get())
            if self.update_notice.get():
                self.check_updates()
        self.guard(save)

    def check_updates(self, window=None):
        now = time.time()
        last = self.state.config.get("last_update_check", 0)
        if window is None and isinstance(last, (float, int)) and now - last < 86400:
            return
        self.state.set_value("last_update_check", now)

        def display(tag):
            if tag:
                notice = T(f"Versão {tag} publicada no GitHub.", f"Version {tag} is available on GitHub.", f"La versión {tag} está disponible en GitHub.")
                self.status.set(notice)
                if window and window.winfo_exists() and messagebox.askyesno(
                    "Assistente IA", notice + "\n" + T("Abrir as versões publicadas?", "Open published releases?", "¿Abrir las versiones publicadas?"), parent=window
                ):
                    webbrowser.open(RELEASES)
            elif window and window.winfo_exists():
                messagebox.showinfo("Assistente IA", T("Assistente atualizado.", "Assistente is up to date.", "Assistente está actualizado."), parent=window)

        self.background(check_release, display, show_error=window is not None)

    def rtk_savings(self, settings):
        command = executable("rtk") + ["gain"]
        settings.destroy()
        self.background(lambda: self.command_output(command, self.state.parent),
                        lambda result: self.output(T("Economia do RTK", "RTK savings", "Ahorro de RTK"), result))

    def login(self, agent, switch=False):
        if switch and not messagebox.askyesno("Assistente IA",
                T("Trocar o login global deste agente e manter a pasta selecionada?", "Switch this agent's global sign-in and keep the selected folder?", "¿Cambiar la cuenta global de este agente y conservar la carpeta seleccionada?"), parent=self.root):
            return
        command = executable(agent)
        prefix = ["auth"] if agent == "claude" else []
        commands = [command + prefix + ["logout"]] if switch else []
        self.run_terminal([*commands, command + prefix + ["login"]])


if __name__ == "__main__":
    app = tk.Tk()
    Panel(app)
    if "--smoke-test" in sys.argv:
        app.update_idletasks()
        app.destroy()
    else:
        app.mainloop()

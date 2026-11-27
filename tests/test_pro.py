#!/usr/bin/env python3
"""1.0 Professional regressions: prompt library, context audit, checkpoint compaction,
technology detection, safe backup filters, sanitized reports and worktree pruning.

The shell (lib/pro.sh, used by the terminal and the macOS app) and Python (desktop/pro.py,
used by the Linux and Windows panel) implementations must give the same answers, so most
tests run both on the same files. No network, real CLI, login or user state is used.
"""
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
MAIN = ROOT / "ASSISTENTE-IA-MAC.command"
sys.path.insert(0, str(ROOT / "desktop"))

import core  # noqa: E402
import library  # noqa: E402
import pro  # noqa: E402

POSIX = os.name != "nt"
CATEGORIES = (
    "auditoria", "bug", "seguranca", "desempenho", "refatoracao", "arquitetura", "funcionalidade", "wordpress",
    "frontend", "backend", "banco", "api", "seo", "acessibilidade", "testes", "documentacao", "revisao",
    "producao", "tokens", "continuar", "revisao-alternativa",
)
SECRET_VALUE = "sk-proj-" + "A1b2C3d4" * 4


class Base(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="assistente-pro-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.env = {key: value for key, value in os.environ.items()
                    if not any(part in key for part in ("API_KEY", "AUTH_TOKEN", "ACCESS_TOKEN"))}
        for setting in ("ASSISTENTE_LANG", "ASSISTENTE_PROJECT_LANG", "LC_ALL", "LC_MESSAGES"):
            self.env.pop(setting, None)
        self.env.update({
            "HOME": str(self.home), "ASSISTENTE_STATE_DIR": str(self.root / "state"), "ASSISTENTE_TEST_MODE": "1",
            "ASSISTENTE_PLATFORM": "Linux", "LANG": "pt_BR.UTF-8", "TERM": "dumb", "NO_COLOR": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        })

    def shell(self, body, input_text="", project=None, check=True):
        preamble = f"source {shlex.quote(str(MAIN))}\ninit_state || exit 77\n"
        if project is not None:
            preamble += f"PROJECT={shlex.quote(str(project))}\n"
        result = subprocess.run(["/bin/bash", "-c", preamble + body], input=input_text, text=True,
                                capture_output=True, env=self.env, cwd=self.root, timeout=20)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def app(self, *args, check=True):
        result = subprocess.run(["/bin/bash", str(MAIN), "--app", *args], text=True, capture_output=True,
                                env=self.env, cwd=self.root, timeout=20)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def project(self, name="projeto"):
        folder = self.root / name
        (folder / "INSTRUCOES").mkdir(parents=True)
        (folder / "DOCS").mkdir()
        (folder / "INSTRUCOES/PROJETO.md").write_text("# Projeto\n\nRegras de trabalho do projeto para todos os agentes.\n", encoding="utf-8")
        return folder


class LibraryTests(Base):
    def test_library_is_complete_in_three_languages(self):
        table = library.load()
        self.assertEqual(tuple(table), CATEGORIES)
        for key, translations in table.items():
            self.assertEqual(set(translations), {"pt-BR", "en", "es"}, key)
            for language, entry in translations.items():
                for field in ("category", "title", "text"):
                    self.assertTrue(entry[field].strip(), f"{key} {language} {field}")
                self.assertNotIn("\\n", entry["text"])
                self.assertLess(len(entry["text"].encode("utf-8")), 60000)
        for language in library.LANGUAGES:
            texts = [entry["text"] for entry in library.entries(language)]
            self.assertEqual(len(texts), len(CATEGORIES))
            self.assertEqual(len(set(texts)), len(texts), language)

    def test_search_ignores_accents_case_and_word_order(self):
        entries = library.entries("pt-BR")
        self.assertIn("seguranca", [entry["key"] for entry in library.search(entries, "SEGURANCA")])
        self.assertEqual([entry["key"] for entry in library.search(entries, "nonces wordpress")], ["wordpress"])
        self.assertEqual(library.search(entries, "   "), entries)
        self.assertEqual(library.search(entries, "nada-parecido-com-isto"), [])

    def test_malformed_lines_are_skipped_and_missing_translations_fall_back(self):
        source = self.root / "library.tsv"
        source.write_text("\n".join((
            "# comment",
            "ok\tpt-BR\tCategoria\tTítulo\tlinha 1\\nlinha 2",
            "too\tfew\tfields",
            "bad key\tpt-BR\tC\tT\tx",
            "ok\tfr\tC\tT\tunknown language",
        )) + "\n", encoding="utf-8")
        self.assertEqual(list(library.load(source)), ["ok"])
        entry, = library.entries("es", source)
        self.assertEqual(entry["text"], "linha 1\nlinha 2")
        self.assertEqual(entry["file"], "ok")

    @unittest.skipUnless(POSIX, "Bash launcher")
    def test_shell_library_matches_python(self):
        for language in library.LANGUAGES:
            body = (f"library_entries {language} | while IFS=$'\\t' read -r key category title; do "
                    f"printf '%s\\037%s\\037%s\\037' \"$key\" \"$category\" \"$title\"; library_text \"$key\" {language}; printf '\\036'; done")
            output = self.shell(body).stdout
            shell = [record.split("\x1f") for record in output.split("\x1e") if record]
            python = [[entry["key"], entry["category"], entry["title"], entry["text"]] for entry in library.entries(language)]
            self.assertEqual(shell, python, language)

    @unittest.skipUnless(POSIX, "Bash launcher")
    def test_app_bridge_lists_and_reads_prompts_safely(self):
        lines = self.app("library", "en").stdout.splitlines()
        self.assertEqual(len(lines), len(CATEGORIES))
        self.assertTrue(all(line.startswith("=") and line.count("\t") == 2 for line in lines))
        self.assertEqual(self.app("library-text", "api", "es").stdout, library.load()["api"]["es"]["text"])
        for bad in ("../../etc/passwd", "-n", "UPPER", ""):
            self.assertNotEqual(self.app("library-text", bad, check=False).returncode, 0, bad)

    @unittest.skipUnless(POSIX, "Bash launcher")
    def test_terminal_menu_uses_and_copies_library_prompts(self):
        folder = self.project()
        used = self.shell("TOOL=codex; choose_prompt || exit 9; printf '\\036%s' \"$INITIAL_PROMPT\"", "7\n2\n\n", folder)
        self.assertEqual(used.stdout.split("\x1e", 1)[1], library.load()["bug"]["pt-BR"]["text"])
        self.shell("TOOL=codex; choose_prompt; exit 0", "7\nb\nwordpress\n1\nc\n0\n", folder)
        saved = folder / "PROMPTS/wordpress.md"
        self.assertEqual(saved.read_text(encoding="utf-8"), library.load()["wordpress"]["pt-BR"]["text"] + "\n")
        again = self.shell("TOOL=codex; choose_prompt; exit 0", "7\nb\nwordpress\n1\nc\n0\n", folder)
        self.assertIn("já existe", again.stderr)
        self.assertEqual(saved.read_text(encoding="utf-8"), library.load()["wordpress"]["pt-BR"]["text"] + "\n")


@unittest.skipUnless(POSIX, "compares the Bash and Python implementations")
class ParityTests(Base):
    def findings_project(self):
        folder = self.project()
        shared = "Sempre rode os testes antes de concluir qualquer etapa do trabalho.\n"
        (folder / "INSTRUCOES/PROJETO.md").write_text("# Projeto\n\n" + shared, encoding="utf-8")
        (folder / "AGENTS.md").write_text(
            "<!-- assistente-ia: instrucoes-do-projeto -->\nLeia INSTRUCOES/PROJETO.md e docs/inexistente.md.\n" + shared,
            encoding="utf-8")
        chain = ["CLAUDE.md", "n1.md", "n2.md", "n3.md", "n4.md", "n5.md"]
        for current, following in zip(chain, chain[1:]):
            (folder / current).write_text(f"Veja @{following}\n", encoding="utf-8")
        (folder / "n5.md").write_text("fim\n", encoding="utf-8")
        with (folder / "CLAUDE.md").open("a", encoding="utf-8") as stream:
            stream.write(f"@sumiu.md\nchave de teste {SECRET_VALUE}\n```\n@dentro-de-bloco.md\n```\n" + shared)
        checkpoints = "".join(f"\n## Checkpoint · 2026-11-0{day} · codex → claude\n\n### Próximo passo\nPasso {day}\n" for day in range(1, 7))
        (folder / "DOCS/ANDAMENTO.md").write_text("# Andamento\n" + checkpoints, encoding="utf-8")
        return folder

    def test_context_findings_match_between_shell_and_python(self):
        folder = self.findings_project()
        shell = sorted(tuple(line.split("\t", 1)) for line in self.app("context-findings", str(folder)).stdout.splitlines())
        python = sorted(pro.context_findings(folder))
        self.assertEqual(shell, python)
        identifiers = {identifier for identifier, _ in python}
        self.assertTrue({"secret", "missing_ref", "missing_import", "import_depth", "duplicate", "checkpoints",
                         "estimate_codex", "estimate_claude"} <= identifiers, identifiers)
        self.assertIn(("missing_ref", "AGENTS.md:docs/inexistente.md"), python)
        self.assertIn(("missing_import", "CLAUDE.md:@sumiu.md"), python)
        self.assertNotIn("dentro-de-bloco", repr(python))

    def test_context_reports_never_show_the_secret_value(self):
        folder = self.findings_project()
        shell = self.app("context-audit", str(folder)).stdout
        with mock.patch.object(core, "PANEL_LANGUAGE", "en"):
            python = pro.render_findings(pro.context_findings(folder))
        for report in (shell, python):
            self.assertNotIn(SECRET_VALUE, report)
            self.assertIn("CLAUDE.md:", report)
        self.assertIn("not a measurement", python)

    def compaction_project(self, name):
        folder = self.project(name)
        checkpoint = "\n## Checkpoint · 2026-11-0{0} · codex → claude\n\n### Arquivos\n- a{0}.py\n\n\n### Próximo passo\nPasso {0}\n"
        text = "# Andamento\n\nNotas soltas do usuário.\n\n\n## Decisões fixas\nNão mexer no layout.\n"
        text += "".join(checkpoint.format(day) for day in range(1, 4))
        text += "\n## Ideias\nlinha com espaços   \n"
        text += "".join(checkpoint.format(day) for day in range(4, 7))
        (folder / "DOCS/ANDAMENTO.md").write_text(text, encoding="utf-8")
        (folder / "DOCS/ANDAMENTO.md").chmod(0o640)
        return folder, text

    def test_checkpoint_compaction_keeps_every_line_and_matches_shell(self):
        python_folder, original = self.compaction_project("python")
        shell_folder, _ = self.compaction_project("shell")
        relative = pro.checkpoint_compact(python_folder)
        output = self.app("checkpoint-compact", str(shell_folder)).stdout.strip()
        self.assertTrue(output.startswith("=DOCS/LEGADO/ANDAMENTO-checkpoints-"), output)
        stamp = re.compile(r"checkpoints-\d{8}-\d{6}")
        kept = {}
        for folder, archive in ((python_folder, relative), (shell_folder, output[1:])):
            progress = (folder / "DOCS/ANDAMENTO.md").read_text(encoding="utf-8")
            moved = (folder / archive).read_text(encoding="utf-8")
            self.assertEqual(oct((folder / "DOCS/ANDAMENTO.md").stat().st_mode & 0o777), "0o640")
            self.assertEqual(pro.checkpoint_count(folder / "DOCS/ANDAMENTO.md"), 3)
            self.assertEqual(moved.count("## Checkpoint · "), 3)
            note = f"_Checkpoints anteriores: {archive}_\n\n"
            self.assertIn(note, progress)
            # Nothing is lost or rewritten: kept text without the note, plus the archive, is the original.
            self.assertEqual(sorted((progress.replace(note, "", 1) + moved).splitlines()), sorted(original.splitlines()))
            self.assertIn("Notas soltas do usuário.\n\n\n## Decisões fixas", progress)
            self.assertIn("## Ideias\nlinha com espaços   \n", progress)
            kept[folder.name] = stamp.sub("checkpoints-X", progress)
        self.assertEqual(kept["python"], kept["shell"])
        self.assertIsNone(pro.checkpoint_compact(python_folder))
        self.assertEqual(self.app("checkpoint-compact", str(shell_folder)).stdout.strip(), "@nothing_to_compact")

    def test_compaction_refuses_a_linked_progress_file(self):
        folder = self.project()
        outside = self.root / "fora.md"
        outside.write_text("".join(f"## Checkpoint · {day}\n" for day in range(6)), encoding="utf-8")
        (folder / "DOCS/ANDAMENTO.md").symlink_to(outside)
        with self.assertRaises((ValueError, OSError)):
            pro.checkpoint_compact(folder)
        self.assertNotEqual(self.app("checkpoint-compact", str(folder), check=False).returncode, 0)
        self.assertEqual(outside.read_text(encoding="utf-8").count("## Checkpoint"), 6)

    def detection_cases(self):
        cases = {
            "node": {"package.json": '{"scripts": {"test": "vitest", "build": "vite build", "lint": "eslint ."}, '
                                     '"dependencies": {"react": "1"}}', "pnpm-lock.yaml": "", "tsconfig.json": "{}"},
            "python": {"pyproject.toml": "[tool.pytest.ini_options]\n", "tests/test_x.py": ""},
            "go": {"go.mod": "module x\n"},
            "plugin": {"meu-plugin.php": "<?php\n/*\n * Plugin Name: Meu plugin\n */\n"},
            "site": {"index.html": "<!doctype html>"},
            "composer": {"composer.json": '{"scripts": {"test": "phpunit"}}'},
            "empty": {},
        }
        for name, files in cases.items():
            folder = self.root / "detect" / name
            folder.mkdir(parents=True)
            for relative, content in files.items():
                (folder / relative).parent.mkdir(parents=True, exist_ok=True)
                (folder / relative).write_text(content, encoding="utf-8")
            yield name, folder

    def test_technology_detection_matches_between_shell_and_python(self):
        for name, folder in self.detection_cases():
            techs, commands = [], {}
            for line in self.shell(f"project_detect {shlex.quote(str(folder))}").stdout.splitlines():
                kind, value = line.split("\t", 1)
                if kind == "tech":
                    techs.append(value)
                else:
                    commands.setdefault(kind, value)
            self.assertEqual((techs, commands), pro.detect(folder), name)
        _, commands = pro.detect(self.root / "detect/node")
        self.assertEqual(commands, {"test": "pnpm test", "build": "pnpm run build", "lint": "pnpm run lint"})

    def test_safe_backup_filters_match_between_shell_and_python(self):
        folder = self.project("backup")
        for relative in (".env", ".env.example", ".ENV.local", "id_rsa", "certs/server.pem", "src/app.py", "src/.npmrc",
                         "node_modules/pkg/index.js", "build/out.bin", ".git/config", "DOCS/manual.md", ".aws/credentials"):
            (folder / relative).parent.mkdir(parents=True, exist_ok=True)
            (folder / relative).write_text("x", encoding="utf-8")
        (folder / "atalho").symlink_to(self.home)
        listing = self.root / "entries"
        self.shell(f"backup_entries_list {shlex.quote(str(listing))}", project=folder)
        shell = sorted(entry[len("./backup"):].lstrip("/") for entry in listing.read_text(encoding="utf-8").split("\0") if entry)
        python = sorted(path.relative_to(folder).as_posix() if path != folder else "" for path in core.backup_entries(folder))
        self.assertEqual(shell, python)
        for secret in (".env", ".ENV.local", "id_rsa", "certs/server.pem", "src/.npmrc", ".aws", ".git", "node_modules", "atalho"):
            self.assertNotIn(secret, python)
        for kept in (".env.example", "src/app.py", "DOCS/manual.md", "certs"):
            self.assertIn(kept, python)

    def test_sanitized_reports_match_between_shell_and_python(self):
        report = f"Pasta {self.home}/Projetos/app\nToken {SECRET_VALUE} e ghp_{'x' * 36}\nAKIAABCDEFGHIJKLMNOP fim\n"
        shell = self.shell(f"printf '%s' {shlex.quote(report)} | pro_sanitize").stdout
        with mock.patch.dict(os.environ, {"HOME": str(self.home)}):
            python = pro.sanitize(report)
        self.assertEqual(shell, python)
        self.assertEqual(python, "Pasta ~/Projetos/app\nToken [***] e [***]\n[***] fim\n")

    def test_efforts_are_validated_per_agent(self):
        accepted = ("codex:", "codex:low", "codex:xhigh", "codex:max", "codex:ultra", "claude:", "claude:medium", "claude:max", "claude:ultracode")
        rejected = ("codex:ultracode", "claude:ultra", "codex:minimal", "claude:-x", "codex:high;rm", "claude:MAX")
        body = "".join(f"valid_effort {shlex.quote(pair.split(':')[0])} {shlex.quote(pair.split(':', 1)[1])} && echo {shlex.quote(pair + '=yes')} || echo {shlex.quote(pair + '=no')}\n"
                       for pair in accepted + rejected)
        output = self.shell(body).stdout.split()
        self.assertEqual(output, [f"{pair}=yes" for pair in accepted] + [f"{pair}=no" for pair in rejected])

    @unittest.skipUnless(shutil.which("git"), "git")
    def test_worktree_prune_previews_then_needs_confirmation(self):
        repository = self.root / "repo"
        repository.mkdir()
        git = ["git", "-c", "user.name=Teste", "-c", "user.email=teste@example.invalid", "-c", "init.defaultBranch=main"]
        subprocess.run([*git, "init", "-q", str(repository)], check=True, env=self.env)
        (repository / "a.txt").write_text("a", encoding="utf-8")
        subprocess.run([*git, "-C", str(repository), "add", "a.txt"], check=True, env=self.env)
        subprocess.run([*git, "-C", str(repository), "commit", "-qm", "a"], check=True, env=self.env)
        worktree = self.root / "repo-codex-x"
        subprocess.run([*git, "-C", str(repository), "worktree", "add", "-q", "-b", "assistente/codex-x", str(worktree)], check=True, env=self.env)
        shutil.rmtree(worktree)
        preview = self.app("worktree-prune", str(repository)).stdout
        self.assertIn("repo-codex-x", preview)
        self.assertNotIn("@pruned", preview)
        self.assertIn("repo-codex-x", pro.prune_preview(repository))
        self.assertIn("@pruned", self.app("worktree-prune", str(repository), "confirmed").stdout)
        self.assertEqual(pro.prune_preview(repository), "")
        self.assertEqual(self.app("worktree-prune", str(repository)).stdout.strip(), "@nothing_to_prune")
        branches = subprocess.run(["git", "-C", str(repository), "branch", "--list", "assistente/*"], capture_output=True, text=True, env=self.env).stdout
        self.assertIn("assistente/codex-x", branches, "prune must never delete branches")
        self.assertNotEqual(self.app("worktree-prune", str(repository), "yes", check=False).returncode, 0)


class RestoreTests(Base):
    def zip(self, name, entries):
        import zipfile
        source = self.root / name
        with zipfile.ZipFile(source, "w") as archive:
            for entry, content in entries:
                archive.writestr(entry, content)
        return source

    def test_restore_accepts_archives_made_by_the_macos_app(self):
        source = self.zip("copia.zip", (("./projeto/", ""), ("./projeto/DOCS/ANDAMENTO.md", "andamento"), ("./projeto/.env.example", "A=1")))
        destination = self.root / "restaurado"
        destination.mkdir()
        target = core.restore_backup(source, destination)
        self.assertEqual((target / "projeto/DOCS/ANDAMENTO.md").read_text(encoding="utf-8"), "andamento")
        self.assertTrue((target / "projeto/.env.example").is_file())

    def test_restore_rejects_escape_duplicates_and_existing_targets(self):
        destination = self.root / "restaurado"
        destination.mkdir()
        for name, entries in (("fuga.zip", (("./../fora.txt", "x"),)), ("dup.zip", (("p/A.txt", "1"), ("p/a.txt", "2"))),
                              ("abs.zip", (("/etc/x", "1"),))):
            with self.assertRaises(ValueError, msg=name):
                core.restore_backup(self.zip(name, entries), destination)
        self.assertFalse((self.root / "fora.txt").exists())
        source = self.zip("ok.zip", (("p/a.txt", "1"),))
        core.restore_backup(source, destination)
        with self.assertRaises(FileExistsError):
            core.restore_backup(source, destination)


@unittest.skipUnless(os.environ.get("ASSISTENTE_TEST_WORKFLOW_UI") == "1", "requires Tk display")
class PanelTests(Base):
    """Drives the new panel windows without a person: library, command palette, context audit, compaction."""

    def panel(self, folder):
        import tkinter as tk
        import panel
        root = tk.Tk()
        self.addCleanup(root.destroy)
        with mock.patch.dict(os.environ, {"ASSISTENTE_STATE_DIR": str(self.root / "state"), "ASSISTENTE_LANG": "pt-BR"}):
            app = panel.Panel(root)
        app.select(folder)
        app.background = lambda work, success, show_error=True: success(work())
        errors = mock.patch.object(panel.messagebox, "showerror", side_effect=AssertionError)
        errors.start()
        self.addCleanup(errors.stop)
        return root, app, panel

    def widgets(self, parent, kind):
        found = []
        for child in parent.winfo_children():
            if isinstance(child, kind):
                found.append(child)
            found += self.widgets(child, kind)
        return found

    def test_library_window_searches_copies_and_starts_a_session(self):
        import tkinter as tk
        from tkinter import ttk
        folder = self.project()
        root, app, panel = self.panel(folder)
        with mock.patch.object(panel.library, "entries", return_value=library.entries("pt-BR")):
            app.prompt_library()
        window = root.grab_current()
        search = self.widgets(window, ttk.Entry)[0]
        search.insert(0, "acessibilidade wcag")
        tree = self.widgets(window, ttk.Treeview)[0]
        self.assertEqual(len(tree.get_children()), 1)
        preview = self.widgets(window, tk.Text)[0]
        self.assertIn("WCAG 2.2", preview.get("1.0", "end"))
        buttons = {button.cget("text"): button for button in self.widgets(window, ttk.Button)}
        buttons[panel.wf.label("copy_to_project")].invoke()
        saved = folder / "PROMPTS/acessibilidade.md"
        self.assertEqual(saved.read_text(encoding="utf-8"), library.load()["acessibilidade"]["pt-BR"]["text"] + "\n")
        with mock.patch.object(panel.library, "entries", return_value=library.entries("pt-BR")):
            app.prompt_library()
        window = root.grab_current()
        self.widgets(window, ttk.Entry)[0].insert(0, "WCAG")
        {button.cget("text"): button for button in self.widgets(window, ttk.Button)}[panel.wf.label("copy_to_project")].invoke()
        self.assertTrue((folder / "PROMPTS/acessibilidade-2.md").is_file(), "a second copy never overwrites the first")
        with mock.patch.object(panel.library, "entries", return_value=library.entries("pt-BR")), \
                mock.patch.object(app, "launch") as launch:
            app.prompt_library()
            window = root.grab_current()
            self.widgets(window, ttk.Entry)[0].insert(0, "revisar o trabalho do outro agente")
            {button.cget("text"): button for button in self.widgets(window, ttk.Button)}[panel.wf.label("use_now")].invoke()
        launch.assert_called_once_with("new", initial_text=library.load()["revisao-alternativa"]["pt-BR"]["text"])

    def test_palette_context_audit_and_compaction(self):
        import tkinter as tk
        from tkinter import ttk
        folder = self.project()
        checkpoints = "".join(f"\n## Checkpoint · 2026-11-0{day} · codex → claude\n\n### Próximo passo\nPasso {day}\n" for day in range(1, 7))
        (folder / "DOCS/ANDAMENTO.md").write_text("# Andamento\n" + checkpoints, encoding="utf-8")
        (folder / "CLAUDE.md").write_text(f"token {SECRET_VALUE}\n", encoding="utf-8")
        root, app, panel = self.panel(folder)
        app.command_palette()
        window = root.grab_current()
        field = self.widgets(window, ttk.Entry)[0]
        field.insert(0, "auditoria do CONTEXTO")
        listing = self.widgets(window, tk.Listbox)[0]
        self.assertEqual(listing.get(0, "end"), (panel.wf.label("context_audit"),))
        field.focus_force()
        root.update()
        field.event_generate("<Return>")
        root.update()
        report = root.grab_current()
        text = self.widgets(report, tk.Text)[0].get("1.0", "end")
        self.assertIn("checkpoints", text)
        self.assertIn("CLAUDE.md:1", text)
        self.assertNotIn(SECRET_VALUE, text)
        report.destroy()
        with mock.patch.object(panel.messagebox, "askyesno", return_value=False):
            app.compact_checkpoints()
        self.assertEqual(pro.checkpoint_count(folder / "DOCS/ANDAMENTO.md"), 6, "cancel keeps everything")
        with mock.patch.object(panel.messagebox, "askyesno", return_value=True):
            app.compact_checkpoints()
        self.assertEqual(pro.checkpoint_count(folder / "DOCS/ANDAMENTO.md"), 3)
        self.assertEqual(len(list((folder / "DOCS/LEGADO").glob("ANDAMENTO-checkpoints-*.md"))), 1)
        self.assertIn("DOCS/LEGADO/ANDAMENTO-checkpoints-", app.status.get())


class TranslationTests(unittest.TestCase):
    def test_macos_strings_have_the_same_keys_in_every_language(self):
        pattern = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=', re.M)
        keys = {language: set(pattern.findall((ROOT / f"macOS/{language}.lproj/Localizable.strings").read_text(encoding="utf-8")))
                for language in ("pt-BR", "en", "es")}
        self.assertTrue(keys["pt-BR"])
        self.assertEqual(keys["pt-BR"], keys["en"])
        self.assertEqual(keys["pt-BR"], keys["es"])

    def test_panel_labels_are_complete_triples(self):
        import json
        labels = json.loads((ROOT / "desktop/workflows.json").read_text(encoding="utf-8"))
        for key, value in labels.items():
            self.assertEqual(len(value), 3, key)
            self.assertTrue(all(isinstance(item, str) and item.strip() for item in value), key)
            placeholders = [sorted(re.findall(r"\{(\w*)\}", item)) for item in value]
            self.assertEqual(placeholders[0], placeholders[1], key)
            self.assertEqual(placeholders[0], placeholders[2], key)

    def test_build_number_is_positive_and_platform_versions_match(self):
        self.assertRegex((ROOT / "lib/build-number").read_text(encoding="utf-8").strip(), r"^[1-9][0-9]*$")
        self.assertRegex(core.APP_VERSION, r"^[0-9]{1,4}\.[0-9]{1,4}(\.[0-9]{1,4})?$")
        self.assertIn(f"VERSION='{core.APP_VERSION}'", MAIN.read_text(encoding="utf-8"))
        windows = (ROOT / "ASSISTENTE-IA-WINDOWS.ps1").read_text(encoding="utf-8")
        self.assertIn(f"$version = '{core.APP_VERSION}'", windows)


if __name__ == "__main__":
    unittest.main()

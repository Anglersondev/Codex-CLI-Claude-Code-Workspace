"""Portable graphical launcher integration checks."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import zipfile


DESKTOP = Path(__file__).resolve().parents[1] / "desktop"
sys.path.insert(0, str(DESKTOP))
import core


class PortablePanelTests(unittest.TestCase):
    def setUp(self):
        language = mock.patch.object(core, "PANEL_LANGUAGE", "pt-BR")
        language.start()
        self.addCleanup(language.stop)
        scratch = tempfile.TemporaryDirectory(prefix="assistente-desktop-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)

    def test_default_folder_and_shared_session_paths_persist(self):
        prefs = core.State(self.root / "state")
        prefs.set_parent(self.root)
        self.assertEqual(core.State(self.root / "state").parent, self.root)
        project = core.create_project(prefs.parent, "Site da Ana's café", "claude", "Publicar o site")
        self.assertEqual(project, self.root.resolve() / "CLAUDE" / project.name)
        self.assertTrue((self.root / "CODEX").is_dir())
        self.assertEqual(prefs.select(project), project.resolve())
        self.assertEqual(prefs.recent(), [project.resolve()])
        self.assertEqual(core.preferred_agent(project), "claude")
        self.assertIn("INSTRUCOES/PROJETO.md", (project / "AGENTS.md").read_text(encoding="utf-8"))
        self.assertIn("@INSTRUCOES/PROJETO.md", (project / "CLAUDE.md").read_text(encoding="utf-8"))
        with self.assertRaises(FileExistsError):
            core.create_project(prefs.parent, project.name, "claude", "Outro objetivo")
        other = core.create_project(project.parent, project.name, "codex", "Outro objetivo")
        self.assertEqual(other, self.root.resolve() / "CODEX" / project.name)

    def test_prepare_preserves_existing_context(self):
        custom = self.root / "AGENTS.md"
        custom.write_text("Regra personalizada.", encoding="utf-8")
        core.scaffold(self.root, "codex")
        self.assertEqual(custom.read_text(encoding="utf-8"), "Regra personalizada.")
        self.assertTrue((self.root / "DOCS" / "ANDAMENTO.md").is_file())

    def test_direct_projects_do_not_create_agent_folders(self):
        project = core.create_project(self.root, "Meu projeto", "claude", "", grouped=False)
        self.assertEqual(project, self.root.resolve() / "Meu projeto")
        self.assertEqual(list(self.root.resolve().iterdir()), [project])
        self.assertTrue((project / "AGENTS.md").is_file())
        self.assertTrue((project / "CLAUDE.md").is_file())

    def test_prompts_attachments_and_backup_do_not_overwrite(self):
        project = self.root / "projeto"
        project.mkdir()
        prompt = core.save_prompt(project, "Revisão", "Confira os testes.")
        with self.assertRaises(FileExistsError):
            core.save_prompt(project, "Revisão", "Outro pedido.")
        attachment = self.root / "foto.bin"
        attachment.write_bytes(b"\x01\xff")
        core.attach_file(project, attachment)
        attachment.write_bytes(b"changed")
        with self.assertRaises(FileExistsError):
            core.attach_file(project, attachment)
        out = self.root / "backup.zip"
        core.backup_project(project, out)
        with zipfile.ZipFile(out) as archive:
            self.assertEqual(archive.read("projeto/ANEXOS/foto.bin"), b"\x01\xff")
            self.assertEqual(archive.read(f"projeto/PROMPTS/{prompt.name}").decode(), "Confira os testes.\n")
        with self.assertRaises(ValueError):
            core.backup_project(project, project / "backup.zip")

    def test_terminal_worker_runs_multiple_arguments_in_project(self):
        cwd = self.root / "pasta com espaços"
        cwd.mkdir()
        job = self.root / "job.json"
        literal = "Café & outro 'teste'"
        job.write_text(json.dumps({
            "agent": "codex",
            "avoid_overlap": False,
            "cwd": str(cwd),
            "commands": [[sys.executable, "-c",
                          "from pathlib import Path; import sys; Path('out.txt').write_text(sys.argv[1], encoding='utf-8')", literal]],
        }), encoding="utf-8")
        result = subprocess.run([sys.executable, str(DESKTOP / "panel.py"), "--terminal-worker", str(job)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual((cwd / "out.txt").read_text(encoding="utf-8"), literal)
        self.assertEqual((self.root / "status").read_text(), "0")

    @unittest.skipUnless(os.environ.get("ASSISTENTE_TEST_NATIVE_TERMINAL") == "1", "requires the platform console")
    def test_worker_runs_via_the_native_terminal(self):
        cwd = self.root / "workspace with spaces"
        cwd.mkdir()
        job = self.root / "job.json"
        job.write_text(json.dumps({
            "agent": "codex",
            "avoid_overlap": False,
            "cwd": str(cwd),
            "commands": [[sys.executable, "-c", "from pathlib import Path; Path('opened.txt').write_text('ready')"]],
        }), encoding="utf-8")
        if core.WINDOWS:
            process = core.terminal_process(job, cwd)
        else:
            xterm = shutil.which("xterm")
            self.assertIsNotNone(xterm)
            with mock.patch.object(core.shutil, "which", side_effect=lambda name: xterm if name == "xterm" else None):
                process = core.terminal_process(job, cwd)
        try:
            deadline = time.monotonic() + 20
            status = self.root / "status"
            while not status.is_file() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.1)
            self.assertTrue(status.is_file(), f"Terminal returned {process.poll()} without a completion marker")
            self.assertEqual(process.wait(timeout=5), 0)
            self.assertEqual(status.read_text(), "0")
            self.assertEqual((cwd / "opened.txt").read_text(), "ready")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_windows_terminal_dispatch_opens_new_console_without_shell(self):
        with mock.patch.object(core, "WINDOWS", True), mock.patch.object(core.subprocess, "CREATE_NEW_CONSOLE", 16, create=True):
            with mock.patch.object(core.subprocess, "Popen") as popen:
                core.terminal_process(self.root / "job.json", self.root)
        args, kwargs = popen.call_args
        self.assertEqual(args[0][-2:], ["--terminal-worker", str(self.root / "job.json")])
        self.assertEqual(kwargs, {"cwd": self.root, "creationflags": 16})

    def test_linux_terminal_dispatch_uses_explicit_arguments(self):
        with mock.patch.object(core, "WINDOWS", False), mock.patch.object(core.shutil, "which", return_value="/usr/bin/gnome-terminal"):
            with mock.patch.object(core.subprocess, "Popen") as popen:
                core.terminal_process(self.root / "job.json", self.root)
        args, kwargs = popen.call_args
        self.assertEqual(args[0][:3], ["/usr/bin/gnome-terminal", "--wait", "--"])
        self.assertEqual(kwargs, {"cwd": self.root})

    def test_agent_resume_uses_official_flags_and_safe_permissions(self):
        codex = core.session_arguments("codex", "resume", self.root, plan=True)
        self.assertEqual(codex[:2], ["resume", "--last"])
        self.assertEqual(codex[-2:], ["--sandbox", "read-only"])
        claude = core.session_arguments("claude", "history", self.root, plan=True)
        self.assertEqual(claude, ["--resume", "--permission-mode", "plan"])
        with self.assertRaises(ValueError):
            core.session_arguments("codex", "new", self.root, model="--config")

    def test_same_version_build_notification(self):
        installed_tag = f"v{core.APP_VERSION}"
        release = json.dumps({"tag_name": installed_tag, "assets": [
            {"name": f"Assistente-IA-Build-{core.APP_BUILD + 1}.txt"},
        ]}).encode()
        context = mock.MagicMock()
        context.__enter__.return_value.read.return_value = release
        with mock.patch.object(core.urllib.request, "urlopen", return_value=context):
            self.assertEqual(core.check_release(), f"{installed_tag} · build {core.APP_BUILD + 1}")
        context.__enter__.return_value.read.return_value = release.replace(installed_tag.encode(), b"v0.9")
        with mock.patch.object(core.urllib.request, "urlopen", return_value=context):
            self.assertEqual(core.check_release(), "")

    def test_project_profiles_separate_agents_and_folders(self):
        project = self.root / "website"
        project.mkdir()
        state = core.State(self.root / "state")
        state.save_profile(project, "codex", "gpt-example", True)
        state.save_profile(project, "claude", "sonnet", False)
        self.assertEqual(state.agent_for(project), "claude")
        self.assertEqual(state.profile(project, "claude"), ("sonnet", False))
        self.assertEqual(state.profile(project, "codex"), ("gpt-example", True))
        self.assertEqual(state.profile(self.root, "codex"), ("", False))
        state.toggle_favorite(project)
        self.assertEqual(core.State(state.directory).favorites(), [project])

    def test_backup_preview_and_restore_exclude_credentials_and_reject_traversal(self):
        project = self.root / "work"
        project.mkdir()
        (project / ".env").write_text("secret")
        (project / ".env.example").write_text("example")
        (project / "node_modules").mkdir()
        (project / "node_modules" / "dep.js").write_text("dependency")
        (project / "notas-edição.txt").write_text("local notes")
        entries = list(core.backup_entries(project))
        self.assertEqual({path.name for path in entries}, {"work", ".env.example", "notas-edição.txt"})
        output = self.root / "saved.zip"
        core.backup_project(project, output, entries)
        restored = core.restore_backup(output, self.root)
        self.assertEqual((restored / "work/.env.example").read_text(), "example")
        self.assertFalse((restored / "work/.env").exists())
        with self.assertRaises(FileExistsError):
            core.restore_backup(output, self.root)
        unsafe = self.root / "unsafe.zip"
        with zipfile.ZipFile(unsafe, "w") as archive:
            archive.writestr("../outside.txt", "invalid")
        with self.assertRaises(ValueError):
            core.restore_backup(unsafe, self.root)
        self.assertFalse((self.root / "outside.txt").exists())
        self.assertFalse((self.root / "unsafe").exists())

    def test_update_notification_compares_stable_versions(self):
        self.assertTrue(core.newer_version("v1.0.1", installed="1.0"))
        self.assertFalse(core.newer_version("v1.0.0", installed="1.0"))
        self.assertFalse(core.newer_version("v0.99.0", installed="1.0"))
        with self.assertRaises(ValueError):
            core.newer_version("v2.0.0-beta")

    def test_language_choice_is_saved_and_overrides_system_locale(self):
        storage = self.root / "state"
        core.State(storage).set_value("language", "en")
        with mock.patch.dict(core.os.environ, {"LANG": "es_MX.UTF-8"}, clear=True):
            self.assertEqual(core.effective_language(), "es")
            self.assertEqual(core.effective_language(core.State(storage).config["language"]), "en")
            self.assertEqual(core.effective_language("pt-BR"), "pt-BR")

    def test_spanish_project_templates_and_context_health(self):
        with mock.patch.object(core, "PANEL_LANGUAGE", "es"):
            project = core.create_project(self.root, "Sitio nuevo", "codex", "Publicar el sitio")
        instructions = project / "INSTRUCCIONES" / "PROYECTO.md"
        self.assertIn("# Instrucciones", instructions.read_text(encoding="utf-8"))
        self.assertFalse(core.progress_available(project))
        summary = project / "DOCUMENTOS" / "PROGRESO.md"
        summary.write_text("# Progreso\n\n- Revisar la navegación.\n", encoding="utf-8")
        self.assertTrue(core.progress_available(project))
        self.assertFalse(core.instructions_are_long(project, "codex"))
        (project / "AGENTS.override.md").write_text("x" * 12001, encoding="utf-8")
        self.assertTrue(core.instructions_are_long(project, "codex"))
        self.assertFalse(core.instructions_are_long(project, "claude"))

    def test_localized_layout_survives_panel_language_changes(self):
        for language, relative, progress, attachments in (
            ("en", "INSTRUCTIONS/PROJECT.md", "DOCS/PROGRESS.md", "ATTACHMENTS"),
            ("es", "INSTRUCCIONES/PROYECTO.md", "DOCUMENTOS/PROGRESO.md", "ADJUNTOS"),
        ):
            with mock.patch.object(core, "PANEL_LANGUAGE", language):
                project = core.create_project(self.root, language, "codex", "Fixture", grouped=False)
            with mock.patch.object(core, "PANEL_LANGUAGE", "pt-BR"):
                self.assertEqual(core.project_layout(project)["progress"], progress)
                self.assertIn("@" + relative, (project / "CLAUDE.md").read_text(encoding="utf-8"))
                self.assertIn(relative, (project / "AGENTS.md").read_text(encoding="utf-8"))
                self.assertIn(progress, (project / core.project_layout(project)["continue"]).read_text(encoding="utf-8"))
                source = self.root / "reference.txt"
                source.write_text("test")
                core.attach_file(project, source)
                core.scaffold(project, "codex")
                self.assertTrue((project / attachments / source.name).is_file())
                self.assertFalse((project / "INSTRUCOES").exists())

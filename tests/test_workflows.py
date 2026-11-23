"""Exercise the same handoff and worktree contracts used by the desktop panels."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "desktop"))
import core
import workflows as wf


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.project = self.root / "repo with spaces"
        self.project.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "test@example.invalid")
        (self.project / "tracked.txt").write_text("base")
        self.git("add", "tracked.txt")
        self.git("commit", "-qm", "base")
        (self.project / "tracked.txt").write_text("pending")
        (self.project / "new.txt").touch()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.project), *args], text=True)

    def bridge(self, *args, check=True):
        return subprocess.run(["/bin/bash", str(ROOT / "ASSISTENTE-IA-MAC.command"), "--app", *map(str, args)],
                              text=True, capture_output=True, check=check,
                              env={**os.environ, "ASSISTENTE_STATE_DIR": str(self.root / "state"), "ASSISTENTE_LANG": "pt-BR"})

    def check_isolation(self, folder, agent, task):
        self.assertEqual(folder.parent, self.root)
        self.assertTrue((folder / ".git").is_file())
        self.assertEqual(subprocess.check_output(["git", "-C", str(folder), "branch", "--show-current"], text=True).strip(),
                         f"assistente/{agent}-{task}")
        self.assertEqual((folder / "tracked.txt").read_text(), "base")
        self.assertFalse((folder / "new.txt").exists())
        (folder / "tracked.txt").write_text("isolated")
        self.assertEqual((self.project / "tracked.txt").read_text(), "pending")

    def test_two_isolated_agents_and_collision(self):
        for agent in ("codex", "claude"):
            folder = wf.create_worktree(self.project, agent, "fix")
            self.check_isolation(folder, agent, "fix")
            with self.assertRaises(FileExistsError):
                wf.create_worktree(self.project, agent, "fix")
            self.assertEqual((folder / "tracked.txt").read_text(), "isolated")

    def test_worktree_rejects_unborn_nested_folder_and_invalid_names(self):
        sub = self.project / "sub"
        sub.mkdir()
        with self.assertRaisesRegex(ValueError, wf.label("need_repo")):
            wf.create_worktree(sub, "codex", "fix")
        self.git("-C", str(sub), "init", "-q")
        with self.assertRaisesRegex(ValueError, wf.label("need_repo")):
            wf.create_worktree(sub, "codex", "fix")
        for value in ("../escape", "", "new/task", "-f"):
            with self.assertRaises(ValueError):
                wf.create_worktree(self.project, "codex", value)

    def test_reviewed_notes_preserve_old_notes_and_test_claims(self):
        with mock.patch.object(core, "PANEL_LANGUAGE", "pt-BR"):
            core.scaffold(self.project, "codex")
        path = self.project / "DOCS/ANDAMENTO.md"
        path.write_text("old notes", encoding="utf-8")
        changes = wf.changed_files(self.project)
        self.assertIn("tracked.txt", changes)
        self.assertIn("new.txt", changes)
        wf.save_checkpoint(self.project, "codex", "claude", changes, "4 passed", "Check layout")
        wf.save_checkpoint(self.project, "claude", "codex", "reviewed list", "", "Publish")
        saved = path.read_text(encoding="utf-8")
        for value in ("old notes", "4 passed", "Check layout", "reviewed list", wf.label("no_tests"), "Publish"):
            self.assertIn(value, saved)
        self.assertTrue(core.progress_available(self.project))
        with self.assertRaises(ValueError):
            wf.save_checkpoint(self.project, "codex", "claude", changes, "", " ")
        self.assertEqual(path.read_text(encoding="utf-8"), saved)

    def test_diagnostics_redact_auth_output_and_explain_failures(self):
        secret = "sensitive-account-detail"
        def run(command):
            if command[-1] == "--version":
                return subprocess.CompletedProcess(command, 0, "1.2.3")
            return subprocess.CompletedProcess(command, 1, '{"loggedIn":false,"account":"' + secret + '"}')
        with mock.patch.object(core, "executable", side_effect=lambda name: [name]), mock.patch.object(wf, "query", side_effect=run):
            self.assertIn(wf.label("auth_claude"), wf.tool_report("claude"))
            self.assertIn(wf.label("auth_unknown"), wf.tool_report("codex"))
            self.assertNotIn(secret, wf.tool_report("claude"))
        with mock.patch.object(core, "executable", side_effect=FileNotFoundError):
            self.assertIn(wf.label("missing_git"), wf.tool_report("git"))

    @unittest.skipIf(os.name == "nt", "POSIX symlink and native Mac bridge")
    def test_mac_worktree_checkpoint_and_refusal_of_links(self):
        folder = Path(self.bridge("worktree-create", self.project, "claude", "fix").stdout.strip())
        self.check_isolation(folder, "claude", "fix")
        self.assertNotEqual(self.bridge("worktree-create", self.project, "claude", "fix", check=False).returncode, 0)
        self.assertIn("tracked.txt", self.bridge("checkpoint-files", self.project).stdout)
        self.bridge("checkpoint-append", self.project, "first\n")
        self.bridge("checkpoint-append", self.project, "second\n")
        path = self.project / "DOCS/ANDAMENTO.md"
        self.assertEqual(path.read_text(), "first\nsecond\n")
        path.unlink()
        path.symlink_to(self.root / "outside")
        self.assertNotEqual(self.bridge("checkpoint-append", self.project, "unsafe", check=False).returncode, 0)
        with self.assertRaises(ValueError):
            wf.save_checkpoint(self.project, "codex", "claude", "", "", "unsafe")
        self.assertFalse((self.root / "outside").exists())

    @unittest.skipUnless(os.name == "nt", "Windows PowerShell terminal")
    def test_windows_terminal_resume_summary_and_read_notes(self):
        with mock.patch.object(core, "PANEL_LANGUAGE", "pt-BR"):
            core.scaffold(self.project, "codex")
        wf.save_checkpoint(self.project, "claude", "codex", "", "", "Check layout")
        code = r'''
. $env:WORKFLOW_LAUNCHER -Check
$script:project = $env:WORKFLOW_PROJECT
function Read-Choice { return '' }
function codex { Write-Output ("CALL " + (Get-Location).Path + " " + ($args -join '|')) }
Agent-Menu 'resume'
Agent-Menu 'select'
Agent-Menu 'summary'
Agent-Menu 'notes'
$script:lang = 'es'
$layout = Project-Layout $env:WORKFLOW_EMPTY_PROJECT
Write-Output ("SPANISH " + $layout.Progress)
'''
        run = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "RemoteSigned", "-Command", code],
                             capture_output=True, encoding="utf-8", errors="replace", check=True,
                             env={**os.environ, "ASSISTENTE_LANG": "en", "ASSISTENTE_STATE_DIR": str(self.root / "state"),
                                  "WORKFLOW_LAUNCHER": str(ROOT / "ASSISTENTE-IA-WINDOWS.ps1"), "WORKFLOW_PROJECT": str(self.project),
                                  "WORKFLOW_EMPTY_PROJECT": str(self.root)})
        calls = [line for line in run.stdout.splitlines() if line.startswith("CALL ")]
        self.assertEqual(len(calls), 4, run.stdout)
        self.assertTrue(all(str(self.project) in line for line in calls))
        self.assertIn("resume|--last", calls[0])
        self.assertNotIn("--last", calls[1])
        self.assertIn("Update DOCS/ANDAMENTO.md", calls[2])
        self.assertIn("Read DOCS/ANDAMENTO.md", calls[3])
        self.assertIn("SPANISH DOCUMENTOS/PROGRESO.md", run.stdout)

    @unittest.skipUnless(os.environ.get("ASSISTENTE_TEST_WORKFLOW_UI") == "1", "requires Tk display")
    def test_gui_switch_cancel_save_and_parallel_launch(self):
        import tkinter as tk
        from tkinter import ttk
        import panel
        root = tk.Tk()
        self.addCleanup(root.destroy)
        with mock.patch.dict(os.environ, {"ASSISTENTE_STATE_DIR": str(self.root / "state"), "ASSISTENTE_LANG": "pt-BR"}):
            app = panel.Panel(root)
        app.select(self.project)
        app.background = lambda work, success: success(work())
        def choose(target):
            app.agent.set(target)
            app.request_switch()
            return root.grab_current()
        win = choose("claude")
        win.destroy()
        self.assertEqual(app.agent.get(), "codex")
        win = choose("claude")
        body = win.winfo_children()[0]
        fields = [widget for widget in body.winfo_children() if isinstance(widget, tk.Text)]
        self.assertIn("tracked.txt", fields[0].get("1.0", "end"))
        fields[1].insert("1.0", "unit tests OK")
        fields[2].insert("1.0", "verify layout")
        with mock.patch.object(panel, "executable", side_effect=lambda name: [name]), mock.patch.object(panel, "terminal_process") as start:
            submit = body.winfo_children()[-1].winfo_children()[-1]
            submit.invoke()
            self.assertEqual(app.agent.get(), "claude")
            self.assertIn("verify layout", (self.project / "DOCS/ANDAMENTO.md").read_text(encoding="utf-8"))
            self.assertEqual(start.call_count, 1)
            with self.assertRaises(ValueError):
                app.launch("new")
            app.worktree_dialog()
            body = root.grab_current().winfo_children()[0]
            next(button for button in body.winfo_children() if isinstance(button, ttk.Button)).invoke()
            self.assertEqual(start.call_count, 2)
            self.assertEqual(app.agent.get(), "codex")
            self.assertIn(self.project, app.jobs)
            self.assertIn(app.project, app.jobs)
            self.assertNotEqual(self.project, app.project)
            for folder, _, _ in app.jobs.values():
                shutil.rmtree(folder)

"""Windows PowerShell launcher: argument quoting and filtered ZIP backups.

Runs with powershell.exe (Windows PowerShell 5.1) or pwsh when one is installed.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "ASSISTENTE-IA-WINDOWS.ps1"
SHELL = shutil.which("powershell") or shutil.which("pwsh")


@unittest.skipUnless(SHELL, "PowerShell not installed")
class WindowsLauncherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="assistente-ps-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = dict(os.environ, LOCALAPPDATA=str(self.root), ASSISTENTE_STATE_DIR=str(self.root / "state"))

    def powershell(self, body):
        prelude = f". '{SCRIPT}' -Check | Out-Null\n"
        result = subprocess.run([SHELL, "-NoProfile", "-NonInteractive", "-Command", prelude + body],
                                capture_output=True, text=True, encoding="utf-8", env=self.env, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_prompt_arguments_reach_the_program_unchanged(self):
        values = ['simples', 'com espaço', 'aspas "duplas" e \\"barras\\"', 'termina com barra\\',
                  'A & B | C % ^ < > !x!', '', 'linha 1\nlinha 2', 'ação ñ 中文']
        script = "import json,sys;print(json.dumps(sys.argv[1:]))"
        data = self.root / "values.json"
        data.write_text(json.dumps(values), encoding="utf-8")
        output = self.powershell(
            f"$values = [IO.File]::ReadAllText('{data}', [Text.Encoding]::UTF8) | ConvertFrom-Json\n"
            f"$command = @{{ File = '{sys.executable}'; Prefix = @('-X', 'utf8', '-c', '{script}') }}\n"
            "[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)\n"
            "$code = Invoke-Agent $command ([string[]]$values)\n"
            "if ($code -ne 0) { exit 3 }\n")
        self.assertEqual(json.loads(output.strip().splitlines()[-1]), values)

    def test_safe_zip_skips_credentials_dependencies_and_links(self):
        project = self.root / "Projeto ação"
        (project / "src").mkdir(parents=True)
        (project / "node_modules" / "x").mkdir(parents=True)
        (project / ".env").write_text("SECRET=1")
        (project / ".env.example").write_text("SECRET=")
        (project / "id_ed25519").write_text("key")
        (project / "src" / "app.js").write_text("ok")
        (project / "node_modules" / "x" / "i.js").write_text("dep")
        destination = self.root / "safe.zip"
        self.powershell(f"Write-ProjectZip '{project}' '{destination}' $false")
        with zipfile.ZipFile(destination) as archive:
            names = set(archive.namelist())
        self.assertIn("Projeto ação/src/app.js", names)
        self.assertIn("Projeto ação/.env.example", names)
        self.assertFalse(any(".env" == Path(n).name or "node_modules" in n or "id_ed25519" in n for n in names), names)

    def test_zip_never_overwrites_an_existing_file(self):
        project = self.root / "p"
        project.mkdir()
        destination = self.root / "exists.zip"
        destination.write_text("keep")
        prelude = f". '{SCRIPT}' -Check | Out-Null\n"
        result = subprocess.run([SHELL, "-NoProfile", "-NonInteractive", "-Command",
                                 prelude + f"Write-ProjectZip '{project}' '{destination}' $false"],
                                capture_output=True, text=True, env=self.env, timeout=60)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(destination.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()

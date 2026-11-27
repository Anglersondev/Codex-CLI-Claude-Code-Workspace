#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
  printf 'Usage: /bin/bash desktop/package.sh /path/to/existing-output-folder\n' >&2
  exit 2
fi
destination="$(cd "$1" && pwd -P)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/assistente-packages.XXXXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

package() {
  local name="Assistente-IA-App-$1" stage
  shift
  stage="$scratch/$name"
  mkdir -p "$stage/desktop"
  for file in "$@"; do cp -R "$root/$file" "$stage/"; done
  mkdir -p "$stage/lib"
  # Data files read by the Python panel (the Linux package also carries the whole lib/ folder).
  cp "$root/lib/project-layouts.tsv" "$root/lib/build-number" "$root/lib/backup-excludes.txt" \
    "$root/lib/secret-patterns.txt" "$root/lib/prompt-library.tsv" "$stage/lib/"
  cp "$root/desktop/core.py" "$root/desktop/panel.py" "$root/desktop/workflows.py" "$root/desktop/workflows.json" \
    "$root/desktop/pro.py" "$root/desktop/library.py" "$stage/desktop/"
  cp "$root/desktop/LEIA-ME.md" "$root/LICENSE" "$stage/"
  (cd "$scratch" && zip -qr "$name.zip" "$name")
  mv -f "$scratch/$name.zip" "$destination/$name.zip"
}

package Linux ASSISTENTE-IA-LINUX-GUI.sh ASSISTENTE-IA-LINUX.sh ASSISTENTE-IA-MAC.command GUIA-DE-USO.md LEIA-PRIMEIRO.txt RTK.md lib
package Windows ASSISTENTE-IA-WINDOWS-GUI.cmd ASSISTENTE-IA-WINDOWS.cmd ASSISTENTE-IA-WINDOWS.ps1

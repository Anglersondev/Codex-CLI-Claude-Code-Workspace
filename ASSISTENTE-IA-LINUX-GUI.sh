#!/bin/sh
set -eu

base=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import tkinter; import sys; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
  notice='Instale Python 3.9+ e Tkinter (ex.: python3-tk no Ubuntu/Debian). Install Python 3.9+ and Tkinter.'
  printf '%s\n' "$notice" >&2
  if command -v zenity >/dev/null 2>&1; then
    zenity --error --title='Assistente IA' --text="$notice" || true
  fi
  exit 1
fi
exec python3 "$base/desktop/panel.py" "$@"

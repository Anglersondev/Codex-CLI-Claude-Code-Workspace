@echo off
setlocal
where pyw.exe >nul 2>&1
if not errorlevel 1 (
  py.exe -3 -c "import tkinter; import sys; sys.exit(sys.version_info < (3, 9))" >nul 2>&1
  if errorlevel 1 goto missing
  start "" pyw.exe -3 "%~dp0desktop\panel.py"
  exit /b
)
where pythonw.exe >nul 2>&1
if not errorlevel 1 (
  python.exe -c "import tkinter; import sys; sys.exit(sys.version_info < (3, 9))" >nul 2>&1
  if errorlevel 1 goto missing
  start "" pythonw.exe "%~dp0desktop\panel.py"
  exit /b
)
:missing
echo Install Python 3.9+ for Windows from https://www.python.org/downloads/windows/ and include Tcl/Tk.
echo Instale Python 3.9+ para Windows e inclua Tcl/Tk.
pause
exit /b 1

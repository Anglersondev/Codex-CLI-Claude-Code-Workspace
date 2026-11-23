param([switch]$Check, [switch]$Help)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$version = '1.0'
$state = if ($env:ASSISTENTE_STATE_DIR) { $env:ASSISTENTE_STATE_DIR } else { Join-Path $env:LOCALAPPDATA 'Assistente IA' }
$langFile = Join-Path $state 'language'
$script:lang = if ($env:ASSISTENTE_LANG -in @('en', 'es', 'pt-BR')) { $env:ASSISTENTE_LANG } elseif (Test-Path -LiteralPath $langFile) { (Get-Content -LiteralPath $langFile -TotalCount 1 -Encoding UTF8).Trim() } elseif ([Globalization.CultureInfo]::CurrentUICulture.Name -like 'en*') { 'en' } else { 'pt-BR' }
if ($script:lang -notin @('en', 'es', 'pt-BR')) { $script:lang = 'pt-BR' }
function T([string]$pt, [string]$en, [string]$es = $en) {
  switch ($script:lang) { 'en' { $en } 'es' { $es } default { $pt } }
}
function Project-Layout([string]$folder) {
  $layouts = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'lib\project-layouts.tsv') -Encoding UTF8 |
    ConvertFrom-Csv -Delimiter "`t" -Header Language, Instructions, Progress, Continue, Close, Summary, Start, Plan, Attachments, Code, Archive, Backups
  $folderMatch = $null
  foreach ($layout in $layouts) {
    $layout | Add-Member NoteProperty Rules (Split-Path -Parent $layout.Instructions)
    $layout | Add-Member NoteProperty Docs (Split-Path -Parent $layout.Progress)
    $layout | Add-Member NoteProperty Prompts (Split-Path -Parent $layout.Continue)
    foreach ($relative in @($layout.Instructions, $layout.Progress, $layout.Continue, $layout.Close, $layout.Summary, $layout.Start, $layout.Plan)) {
      if (Test-Path -LiteralPath (Join-Path $folder $relative)) { return $layout }
    }
    if (-not $folderMatch -and ((Test-Path -LiteralPath (Join-Path $folder $layout.Rules) -PathType Container) -or
        (Test-Path -LiteralPath (Join-Path $folder $layout.Attachments) -PathType Container))) {
      $folderMatch = $layout
    }
  }
  if ($folderMatch) { return $folderMatch }
  $layouts | Where-Object Language -eq $script:lang
}
function Read-Choice([string]$pt, [string]$en) { Read-Host (T $pt $en) }
function Save-Text([string]$path, [string]$value) {
  $parent = Split-Path -Parent $path
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  $temp = Join-Path $parent ([IO.Path]::GetRandomFileName())
  try { [IO.File]::WriteAllText($temp, $value + "`n", [Text.UTF8Encoding]::new($false)); Move-Item -LiteralPath $temp -Destination $path -Force }
  finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}
function Header([string]$title) { Clear-Host; Write-Host "`n  ASSISTENTE IA · WINDOWS $version" -ForegroundColor Cyan; Write-Host "  $title"; Write-Host ('  ' + ('─' * 54)) }
function Pause-Menu { [void](Read-Host (T 'Enter para voltar' 'Press Enter to go back')) }
function Existing-Directory([string]$path) {
  if ([string]::IsNullOrWhiteSpace($path)) { return $null }
  $path = [Environment]::ExpandEnvironmentVariables($path.Trim().Trim('"'))
  if ($path.StartsWith('~')) { $path = Join-Path $HOME $path.Substring(1).TrimStart('\', '/') }
  if (-not (Test-Path -LiteralPath $path -PathType Container)) { Write-Warning (T 'Pasta não encontrada.' 'Folder not found.'); return $null }
  (Resolve-Path -LiteralPath $path).ProviderPath
}
function Project-Tool([string]$path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($path))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
  $selected = Join-Path $state "projects\$key\tool"
  if (Test-Path -LiteralPath $selected -PathType Leaf) {
    $value = ([string](Get-Content -LiteralPath $selected -TotalCount 1 -Encoding UTF8)).Trim()
    if ($value -in @('codex', 'claude')) { return $value }
  }
  $profile = Join-Path $path '.assistente-ia\tool'
  if (Test-Path -LiteralPath $profile -PathType Leaf) {
    $value = (Get-Content -LiteralPath $profile -TotalCount 1 -Encoding UTF8).Trim()
    if ($value -in @('codex', 'claude')) { return $value }
  }
  return $null
}
function Select-Tool([string]$path) {
  $tool = Project-Tool $path
  if ($tool) { return $tool }
  Write-Host (T '1) Codex CLI  2) Claude Code' '1) Codex CLI  2) Claude Code')
  $choice = Read-Choice 'Ferramenta' 'Agent'
  $tool = switch ($choice) { '1' { 'codex' } '2' { 'claude' } default { $null } }
  if ($tool) { Save-Text (Join-Path $path '.assistente-ia\tool') $tool }
  return $tool
}
function Set-Project([string]$path) {
  $script:project = Existing-Directory $path
  if (-not $script:project) { return }
  Save-Text (Join-Path $state 'current') $script:project
  $recentFile = Join-Path $state 'recents'
  $recent = @($script:project)
  if (Test-Path -LiteralPath $recentFile) { $recent += @(Get-Content -LiteralPath $recentFile -Encoding UTF8 | Where-Object { $_ -and $_ -ne $script:project -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -First 19) }
  Save-Text $recentFile ($recent -join "`n")
}
function Choose-Directory {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = T 'Escolha a pasta do projeto' 'Choose the project folder'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
  } catch { return $null }
  return $null
}
function Project-Menu {
  Header (T 'Projetos' 'Projects')
  Write-Host (T '1) Criar projeto  2) Abrir pasta  3) Recentes  0) Voltar' '1) Create project  2) Open folder  3) Recent  0) Back')
  $choice = Read-Choice 'Escolha' 'Choose'
  switch ($choice) {
    '1' {
      $parent = Choose-Directory
      if (-not $parent) { $parent = Read-Choice 'Pasta onde criar' 'Parent folder' }
      $parent = Existing-Directory $parent
      if (-not $parent) { return }
      $name = Read-Choice 'Nome do projeto' 'Project name'
      if ($name -notmatch '^[^\\/:*?"<>|.][^\\/:*?"<>|]{0,119}$' -or $name -in @('.', '..')) { Write-Warning (T 'Nome inválido.' 'Invalid name.'); return }
      Write-Host (T '1) Codex CLI  2) Claude Code' '1) Codex CLI  2) Claude Code')
      $tool = switch (Read-Choice 'Ferramenta' 'Agent') { '1' { 'codex' } '2' { 'claude' } default { $null } }
      if (-not $tool) { return }
      $group = if ($tool -eq 'codex') { 'CODEX' } else { 'CLAUDE' }
      if ((Split-Path $parent -Leaf) -in @('CODEX', 'CLAUDE')) { $parent = Split-Path $parent -Parent }
      $path = Join-Path (Join-Path $parent $group) $name
      if (Test-Path -LiteralPath $path) { Write-Warning (T 'A pasta já existe.' 'Folder already exists.'); return }
      Write-Host "$path"
      if ((Read-Choice 'Enter para criar; 0 cancela' 'Enter to create; 0 cancels') -eq '0') { return }
      foreach ($bucket in @('CODEX', 'CLAUDE')) {
        $entry = Get-Item -LiteralPath (Join-Path $parent $bucket) -Force -ErrorAction SilentlyContinue
        if ($entry -and (-not $entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
          Write-Warning (T 'CODEX e CLAUDE precisam ser pastas comuns.' 'CODEX and CLAUDE must be regular folders.')
          return
        }
      }
      foreach ($bucket in @('CODEX', 'CLAUDE')) { [IO.Directory]::CreateDirectory((Join-Path $parent $bucket)) | Out-Null }
      New-Item -ItemType Directory -Path $path | Out-Null
      Save-Text (Join-Path $path '.assistente-ia\tool') $tool
      $layout = Project-Layout $path
      foreach ($folder in @($layout.Rules, $layout.Prompts, $layout.Attachments, $layout.Docs, $layout.Code)) { New-Item -ItemType Directory -Path (Join-Path $path $folder) -Force | Out-Null }
      Save-Text (Join-Path $path $layout.Instructions) (T '# Instruções do projeto' '# Project instructions' '# Instrucciones del proyecto')
      Save-Text (Join-Path $path 'CLAUDE.md') ('@' + $layout.Instructions)
      Save-Text (Join-Path $path $layout.Progress) (T '# Andamento' '# Progress' '# Progreso')
      Save-Text (Join-Path $path 'AGENTS.md') (T "Leia $($layout.Instructions) antes de trabalhar neste projeto." "Read $($layout.Instructions) before working on this project." "Lee $($layout.Instructions) antes de trabajar en este proyecto.")
      Save-Text (Join-Path $path $layout.Continue) (T "Leia $($layout.Progress) e retome pelo próximo passo." "Read $($layout.Progress) and continue from the next step." "Lee $($layout.Progress) y continúa con el próximo paso.")
      Save-Text (Join-Path $path $layout.Close) (T "Atualize $($layout.Progress) com as mudanças confirmadas, os testes e o próximo passo." "Update $($layout.Progress) with confirmed changes, tests and the next step." "Actualiza $($layout.Progress) con los cambios confirmados, las pruebas y el próximo paso.")
      Set-Project $path
    }
    '2' {
      $path = Choose-Directory
      if (-not $path) { $path = Read-Choice 'Caminho da pasta' 'Folder path' }
      if ($path) { Set-Project $path }
    }
    '3' {
      $file = Join-Path $state 'recents'
      if (-not (Test-Path -LiteralPath $file)) { Write-Host (T 'Sem projetos recentes.' 'No recent projects.'); return }
      $paths = @(Get-Content -LiteralPath $file -Encoding UTF8 | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
      for ($i = 0; $i -lt $paths.Count; $i++) { Write-Host "$($i + 1)) $($paths[$i])" }
      $pick = Read-Choice 'Número (0 cancela)' 'Number (0 cancels)'
      if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $paths.Count) { Set-Project $paths[[int]$pick - 1] }
    }
  }
}
function Agent-Menu([string]$mode) {
  if (-not $script:project) { Project-Menu; if (-not $script:project) { return } }
  $tool = Select-Tool $script:project
  if (-not $tool) { return }
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Write-Warning (T "Instale e autentique $tool primeiro." "Install and sign in to $tool first."); return }
  $workmode = if ($mode -eq 'summary') { '1' } else { Read-Choice 'Modo: 1) trabalhar  2) planejar [1]' 'Mode: 1) work  2) plan [1]' }
  $argsList = @()
  if ($tool -eq 'codex') {
    if ($mode -in @('resume', 'summary')) { $argsList += @('resume', '--last') }
    if ($mode -eq 'select') { $argsList += 'resume' }
    $argsList += @('--cd', $script:project, '--ask-for-approval', 'on-request', '--sandbox')
    $argsList += $(if ($workmode -eq '2') { 'read-only' } else { 'workspace-write' })
  } else {
    if ($mode -in @('resume', 'summary')) { $argsList += '--continue' }
    if ($mode -eq 'select') { $argsList += '--resume' }
    $argsList += @('--permission-mode', $(if ($workmode -eq '2') { 'plan' } else { 'default' }))
  }
  if ($mode -eq 'new') {
    Write-Host (T '1) Escrever pedido  2) Usar arquivo .md/.txt  3) Sem pedido' '1) Write prompt  2) Use .md/.txt file  3) No prompt')
    $promptChoice = Read-Choice 'Escolha [3]' 'Choose [3]'
    $promptText = ''
    if ($promptChoice -eq '1') { Write-Host (T 'Escreva o pedido; FIM/DONE encerra.' 'Write the prompt; FIM/DONE finishes.'); $lines = @(); while ($true) { $line = Read-Host '> '; if ($line -in @('FIM', 'DONE')) { break }; $lines += $line; if (($lines -join "`n").Length -gt 60000) { Write-Warning (T 'Pedido muito longo.' 'Prompt too long.'); return } }; $promptText = $lines -join "`n" }
    if ($promptChoice -eq '2') { $file = Read-Choice 'Caminho do arquivo' 'File path'; if ($file -notmatch '\.(md|txt)$' -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { Write-Warning (T 'Arquivo inválido.' 'Invalid file.'); return }; $promptText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $file).ProviderPath); if ($promptText.Length -gt 60000) { Write-Warning (T 'Arquivo muito longo.' 'File too long.'); return } }
    if ($promptText) { $argsList += @('--', $promptText) }
  }
  if ($mode -in @('notes', 'summary')) {
    $layout = Project-Layout $script:project
  }
  if ($mode -eq 'notes') {
    $notes = Join-Path $script:project $layout.Progress
    if (-not (Test-Path -LiteralPath $notes -PathType Leaf) -or -not (Select-String -LiteralPath $notes -Pattern '^\s*[^#\s]' -Quiet)) {
      Write-Warning (T "Registre o próximo passo em $($layout.Progress) primeiro." "First record the next step in $($layout.Progress)." "Primero, anota el próximo paso en $($layout.Progress).")
      return
    }
    $argsList += @('--', (T "Leia $($layout.Progress) e retome pelo próximo passo registrado." "Read $($layout.Progress) and continue from the recorded next step." "Lee $($layout.Progress) y continúa con el próximo paso registrado."))
  }
  if ($mode -eq 'summary') {
    $argsList += @('--', (T "Atualize $($layout.Progress) com as mudanças confirmadas, os testes e o próximo passo." "Update $($layout.Progress) with confirmed changes, tests and the next step." "Actualiza $($layout.Progress) con los cambios confirmados, las pruebas y el próximo paso."))
  }
  Write-Host "`n$tool $($argsList -join ' ')"
  if ((Read-Choice 'Enter para começar; 0 cancela' 'Enter to start; 0 cancels') -eq '0') { return }
  Push-Location -LiteralPath $script:project
  try { & $tool @argsList }
  finally { Pop-Location }
}
function Care-Menu {
  if (-not $script:project) { Project-Menu; if (-not $script:project) { return } }
  Header (T 'Cuidar do projeto' 'Project care')
  Write-Host (T '1) Abrir pasta  2) Editar instruções  3) Abrir prompts  4) Git  5) ZIP  6) Servidor npm' '1) Open folder  2) Edit instructions  3) Open prompts  4) Git  5) ZIP  6) npm server')
  $choice = Read-Choice 'Escolha' 'Choose'
  switch ($choice) {
    '1' { Start-Process -FilePath $script:project }
    '2' { $file = Join-Path $script:project (Project-Layout $script:project).Instructions; if (-not (Test-Path -LiteralPath $file)) { Save-Text $file (T '# Instruções do projeto' '# Project instructions') }; Start-Process notepad.exe -ArgumentList ('"{0}"' -f $file) }
    '3' { $path = Join-Path $script:project (Project-Layout $script:project).Prompts; New-Item -ItemType Directory -Path $path -Force | Out-Null; Start-Process -FilePath $path }
    '4' { if (Get-Command git -ErrorAction SilentlyContinue) { & git -C $script:project status --short --branch } else { Write-Warning 'Git unavailable' } }
    '5' { $parent = Choose-Directory; if (-not $parent) { return }; if ($parent -eq $script:project -or $parent.StartsWith($script:project + '\', [StringComparison]::OrdinalIgnoreCase)) { Write-Warning (T 'Escolha uma pasta fora do projeto.' 'Choose a folder outside the project.'); return }; $dest = Join-Path $parent ((Split-Path $script:project -Leaf) + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip'); if ((Read-Choice ("$dest - " + (T 'Enter para criar; 0 cancela' 'Enter to create; 0 cancels')) '') -eq '0') { return }; Add-Type -AssemblyName System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::CreateFromDirectory($script:project, $dest, [IO.Compression.CompressionLevel]::Optimal, $true); Write-Host $dest }
    '6' { if (Test-Path -LiteralPath (Join-Path $script:project 'package.json')) { Push-Location -LiteralPath $script:project; try { & npm run dev } finally { Pop-Location } } else { Write-Warning 'package.json unavailable' } }
  }
}
function Settings-Menu {
  Header (T 'Idioma e diagnóstico' 'Language and diagnostics')
  Write-Host '1) Português (Brasil)  2) English  3) Diagnóstico / Diagnostics  4) Español (proyectos)'
  switch (Read-Choice 'Escolha' 'Choose') {
    '1' { $script:lang = 'pt-BR'; Save-Text $langFile $script:lang }
    '2' { $script:lang = 'en'; Save-Text $langFile $script:lang }
    '4' { $script:lang = 'es'; Save-Text $langFile $script:lang }
    '3' { Write-Host "PowerShell $($PSVersionTable.PSVersion)"; Write-Host "State: $state"; foreach ($tool in @('codex', 'claude', 'git', 'npm')) { $cmd = Get-Command $tool -ErrorAction SilentlyContinue; Write-Host "${tool}: $(if ($cmd) { $cmd.Source } else { 'unavailable' })" } }
  }
}
if ($Help) { Write-Host "Assistente IA Windows $version`n.\ASSISTENTE-IA-WINDOWS.cmd`n-check: verify PowerShell source"; return }
if ($Check) { Write-Host "Assistente IA Windows $version - PowerShell source loaded successfully"; return }
New-Item -ItemType Directory -Path $state -Force | Out-Null
$script:project = $null
$currentFile = Join-Path $state 'current'
if (Test-Path -LiteralPath $currentFile) { $saved = (Get-Content -LiteralPath $currentFile -TotalCount 1 -Encoding UTF8).Trim(); if (Test-Path -LiteralPath $saved -PathType Container) { $script:project = $saved } }
while ($true) {
  Header (T 'Painel' 'Dashboard')
  Write-Host "  $(T 'Projeto' 'Project'): $(if ($script:project) { $script:project } else { T 'nenhum' 'none' })"
  Write-Host (T ' 1) Continuar  2) Nova conversa  3) Escolher conversa antiga' ' 1) Resume  2) New conversation  3) Choose older conversation')
  Write-Host (T ' 4) Projetos  5) Cuidar do projeto  6) Idioma e diagnóstico  0) Sair' ' 4) Projects  5) Project care  6) Language and diagnostics  0) Exit')
  Write-Host (T ' 7) Salvar andamento da sessão  8) Retomar pelo andamento' ' 7) Save session progress  8) Continue from progress notes')
  switch (Read-Choice 'Escolha' 'Choose') {
    '7' { Agent-Menu 'summary'; Pause-Menu }
    '8' { Agent-Menu 'notes'; Pause-Menu }
    '1' { Agent-Menu 'resume'; Pause-Menu }
    '2' { Agent-Menu 'new'; Pause-Menu }
    '3' { Agent-Menu 'select'; Pause-Menu }
    '4' { Project-Menu; Pause-Menu }
    '5' { Care-Menu; Pause-Menu }
    '6' { Settings-Menu; Pause-Menu }
    '0' { return }
  }
}

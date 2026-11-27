#!/bin/bash
# Ferramentas da 1.0 Professional (Bash 3.2): auditoria de contexto, tecnologias e comandos
# detectados, compactação de checkpoints, worktrees removidos por fora e diagnóstico sem dados
# sensíveis. Só leitura, exceto quando a função diz o contrário e pede confirmação.
# Contrato com desktop/pro.py: os mesmos identificadores de achados e as mesmas regras.

CONTEXT_CODEX_LIMIT=32768   # project_doc_max_bytes padrão do Codex
CONTEXT_FILE_WARN=12000
CONTEXT_PROGRESS_WARN=8000
CONTEXT_SCAN_MAX=1048576
CONTEXT_IMPORT_DEPTH=4      # Claude Code segue imports @ até 4 níveis
CHECKPOINT_KEEP=3

pro_secret_pattern() {
  local line pattern=''
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [ -n "$line" ] || continue
    pattern="${pattern:+$pattern|}($line)"
  done < "$BASE_DIR/lib/secret-patterns.txt"
  printf '%s' "$pattern"
}

pro_regular_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]; }
pro_any() { local item; for item in "$@"; do pro_regular_file "$item" && return 0; done; return 1; }

# Arquivos de contexto do projeto, um caminho relativo por linha.
pro_context_files() {
  local file
  for file in AGENTS.override.md AGENTS.md CLAUDE.md CLAUDE.local.md "$CTX_INSTRUCTIONS" "$CTX_PROGRESS"; do
    pro_regular_file "$PROJECT/$file" && printf '%s\n' "$file"
  done
  if [ -d "$PROJECT/$CTX_PROMPTS" ] && [ ! -L "$PROJECT/$CTX_PROMPTS" ]; then
    for file in "$PROJECT/$CTX_PROMPTS"/*.md; do
      pro_regular_file "$file" && printf '%s\n' "${file#"$PROJECT"/}"
    done
  fi
  return 0
}

# Caminhos importados com @ numa linha de CLAUDE.md, fora de blocos e trechos de código.
pro_imports_of() {
  local file="$1" line token fence=0 rest
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '```'*|'~~~'*) fence=$((1-fence)); continue ;; esac
    [ "$fence" -eq 0 ] || continue
    while [[ "$line" == *'`'*'`'* ]]; do
      rest="${line#*\`}"
      line="${line%%\`*}${rest#*\`}"
    done
    while [[ "$line" =~ (^|[[:space:]])@([^[:space:]]+) ]]; do
      token="${BASH_REMATCH[2]}"
      line="${line#*"@$token"}"
      token="${token%[.,;:)]}"
      case "$token" in */*|*.*) printf '%s\n' "$token" ;; esac
    done
  done < "$file"
}

pro_resolve_import() {
  local base="$1" token="$2"
  case "$token" in
    '~/'*) printf '%s/%s' "$HOME" "${token#\~/}" ;;
    /*) printf '%s' "$token" ;;
    *) printf '%s/%s' "$base" "$token" ;;
  esac
}

# Soma os bytes de CLAUDE.md e dos imports (até 4 níveis); registra imports ausentes.
PRO_CLAUDE_BYTES=0 PRO_VISITED=''
pro_walk_imports() {
  local file="$1" depth="$2" label="$3" token target bytes
  case "$PRO_VISITED" in *"|$file|"*) return 0 ;; esac
  PRO_VISITED="$PRO_VISITED|$file|"
  bytes="$(file_bytes "$file")" || bytes=0
  PRO_CLAUDE_BYTES=$((PRO_CLAUDE_BYTES + bytes))
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    target="$(pro_resolve_import "$(dirname "$file")" "$token")"
    if [ ! -f "$target" ]; then
      printf 'missing_import\t%s:@%s\n' "$label" "$token"
    elif [ "$depth" -ge "$CONTEXT_IMPORT_DEPTH" ]; then
      printf 'import_depth\t%s:@%s\n' "$label" "$token"
    else
      pro_walk_imports "$target" $((depth+1)) "$token"
    fi
  done <<EOF
$(pro_imports_of "$file")
EOF
}

# Caminhos relativos terminados em .md citados no texto (sem URLs).
pro_markdown_refs() {
  LC_ALL=C /usr/bin/grep -oE '(^|[[:space:](`"])[A-Za-z0-9_][A-Za-z0-9_./-]*[.]md' "$1" 2>/dev/null |
    LC_ALL=C sed -E 's/^[[:space:](`"]+//' | LC_ALL=C sort -u
}

# Linhas significativas (25+ caracteres, sem títulos) repetidas entre dois arquivos.
pro_duplicate_count() {
  local a="$1" b="$2" lines
  pro_regular_file "$a" && pro_regular_file "$b" || { printf 0; return 0; }
  lines="$(LC_ALL=C awk 'NR==FNR { sub(/^[ \t]+/, ""); sub(/[ \t\r]+$/, ""); if (length($0) >= 25 && $0 !~ /^#/) seen[$0]=1; next }
    { sub(/^[ \t]+/, ""); sub(/[ \t\r]+$/, ""); if (($0 in seen) && !($0 in counted)) { counted[$0]=1; n++ } }
    END { print n+0 }' "$a" "$b")"
  printf '%s' "${lines:-0}"
}

# Achados em formato id<TAB>detalhe (contrato com desktop/pro.py).
context_findings() {
  project_context || return 1
  local file bytes pattern lines line count token codex_entry='' codex_bytes=0 progress refs
  pattern="$(pro_secret_pattern)"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    bytes="$(file_bytes "$PROJECT/$file")" || continue
    [ "$bytes" -le "$CONTEXT_SCAN_MAX" ] || continue
    lines="$(LC_ALL=C /usr/bin/grep -nE "$pattern" "$PROJECT/$file" 2>/dev/null | cut -d: -f1 | head -5)"
    for line in $lines; do printf 'secret\t%s:%s\n' "$file" "$line"; done
    if [ "$file" != "$CTX_PROGRESS" ] && [ "$bytes" -gt "$CONTEXT_FILE_WARN" ]; then printf 'large\t%s:%s\n' "$file" "$bytes"; fi
  done <<EOF
$(pro_context_files)
EOF
  if pro_regular_file "$PROJECT/AGENTS.override.md"; then
    codex_entry=AGENTS.override.md
    pro_regular_file "$PROJECT/AGENTS.md" && printf 'override\tAGENTS.override.md\n'
  elif pro_regular_file "$PROJECT/AGENTS.md"; then codex_entry=AGENTS.md; fi
  if [ -n "$codex_entry" ]; then
    codex_bytes="$(file_bytes "$PROJECT/$codex_entry")"
    [ "$codex_bytes" -le "$CONTEXT_CODEX_LIMIT" ] || printf 'codex_limit\t%s:%s\n' "$codex_entry" "$codex_bytes"
    refs="$(pro_markdown_refs "$PROJECT/$codex_entry")"
    while IFS= read -r token; do
      [ -n "$token" ] || continue
      [ -e "$PROJECT/$token" ] || printf 'missing_ref\t%s:%s\n' "$codex_entry" "$token"
    done <<EOF
$refs
EOF
    if entry_references_instructions "$PROJECT/$codex_entry" && pro_regular_file "$PROJECT/$CTX_INSTRUCTIONS"; then
      codex_bytes=$((codex_bytes + $(file_bytes "$PROJECT/$CTX_INSTRUCTIONS")))
      count="$(pro_duplicate_count "$PROJECT/$codex_entry" "$PROJECT/$CTX_INSTRUCTIONS")"
      [ "$count" -eq 0 ] || printf 'duplicate\t%s+%s:%s\n' "$codex_entry" "$CTX_INSTRUCTIONS" "$count"
    fi
    printf 'estimate_codex\t%s\n' "$codex_bytes"
  fi
  if pro_regular_file "$PROJECT/CLAUDE.md"; then
    PRO_CLAUDE_BYTES=0 PRO_VISITED=''
    pro_walk_imports "$PROJECT/CLAUDE.md" 1 CLAUDE.md
    count="$(pro_duplicate_count "$PROJECT/CLAUDE.md" "$PROJECT/$CTX_INSTRUCTIONS")"
    [ "$count" -eq 0 ] || printf 'duplicate\tCLAUDE.md+%s:%s\n' "$CTX_INSTRUCTIONS" "$count"
    printf 'estimate_claude\t%s\n' "$PRO_CLAUDE_BYTES"
  fi
  if pro_regular_file "$PROJECT/$CTX_PROGRESS"; then
    progress="$(file_bytes "$PROJECT/$CTX_PROGRESS")"
    [ "$progress" -le "$CONTEXT_PROGRESS_WARN" ] || printf 'large_progress\t%s:%s\n' "$CTX_PROGRESS" "$progress"
    count="$(checkpoint_count)"
    [ "$count" -le $((CHECKPOINT_KEEP + 2)) ] || printf 'checkpoints\t%s\n' "$count"
  fi
  return 0
}

pro_tokens() { weight_label "$1"; }

context_audit_report() {
  local id detail issues=0
  while IFS=$'\t' read -r id detail; do
    [ -n "$id" ] || continue
    case "$id" in
      secret) doctor_line warn "$(ui 'Possível credencial em' 'Possible credential in') $detail. $(ui 'Remova o valor e use variáveis de ambiente.' 'Remove the value and use environment variables.')"; issues=$((issues+1)) ;;
      missing_import) doctor_line warn "$(ui 'Import do Claude aponta para arquivo inexistente' 'Claude import points to a missing file'): $detail"; issues=$((issues+1)) ;;
      import_depth) doctor_line warn "$(ui 'Import além de 4 níveis (o Claude Code não segue)' 'Import deeper than 4 levels (Claude Code does not follow it)'): $detail"; issues=$((issues+1)) ;;
      missing_ref) doctor_line warn "$(ui 'Referência a arquivo inexistente' 'Reference to a missing file'): $detail"; issues=$((issues+1)) ;;
      codex_limit) doctor_line warn "$(ui 'Acima do limite padrão de 32 KiB do Codex (project_doc_max_bytes); o excesso é ignorado' 'Over the default 32 KiB Codex limit (project_doc_max_bytes); the excess is ignored'): $detail"; issues=$((issues+1)) ;;
      duplicate) doctor_line warn "$(ui 'Linhas repetidas carregadas duas vezes' 'Repeated lines loaded twice'): $detail"; issues=$((issues+1)) ;;
      override) doctor_line warn "$(ui 'AGENTS.override.md substitui AGENTS.md no Codex' 'AGENTS.override.md replaces AGENTS.md in Codex')"; issues=$((issues+1)) ;;
      large) doctor_line warn "$(ui 'Arquivo de contexto grande (bytes)' 'Large context file (bytes)'): $detail"; issues=$((issues+1)) ;;
      large_progress) doctor_line warn "$(ui 'Andamento grande (bytes); condense ou compacte checkpoints' 'Large progress notes (bytes); condense or compact checkpoints'): $detail"; issues=$((issues+1)) ;;
      checkpoints) doctor_line warn "$detail $(ui 'checkpoints no andamento; compacte os antigos (mantém os 3 últimos)' 'checkpoints in progress notes; compact old ones (keeps the last 3)')"; issues=$((issues+1)) ;;
      estimate_codex) doctor_line ok "$(ui 'Codex: contexto fixo estimado' 'Codex: estimated fixed context') $(pro_tokens "$detail") ($(ui 'bytes ÷ 4; não é medição' 'bytes ÷ 4; not a measurement'))" ;;
      estimate_claude) doctor_line ok "$(ui 'Claude Code: contexto fixo estimado' 'Claude Code: estimated fixed context') $(pro_tokens "$detail") ($(ui 'bytes ÷ 4; não é medição' 'bytes ÷ 4; not a measurement'))" ;;
    esac
  done <<EOF
$(context_findings)
EOF
  if [ "$issues" -eq 0 ]; then say_ui '  Nenhum problema de contexto encontrado.' '  No context problems found.'; fi
  return 0
}

# --- Checkpoints -----------------------------------------------------------
# Títulos gravados pelos painéis: "## Checkpoint · data · origem → destino".
checkpoint_count() {
  LC_ALL=C /usr/bin/grep -c '^## Checkpoint · ' "$PROJECT/$CTX_PROGRESS" 2>/dev/null || true
}

# Move os checkpoints antigos para um arquivo novo em DOCS/LEGADO e mantém os últimos.
# Nada é apagado: o texto movido fica no arquivo indicado, e o andamento ganha uma linha de referência.
checkpoint_compact() {
  project_context || return 1
  local file="$PROJECT/$CTX_PROGRESS" total archive name temporary stamp label
  safe_project_path "$CTX_PROGRESS" && safe_project_path "$CTX_ARCHIVE" || return 1
  pro_regular_file "$file" || { printf '@no_progress\n' >&2; return 1; }
  total="$(checkpoint_count)"
  [ "${total:-0}" -gt "$CHECKPOINT_KEEP" ] || { printf '@nothing_to_compact\n'; return 0; }
  stamp="$(date '+%Y%m%d-%H%M%S')"
  name="$(basename "$CTX_PROGRESS" .md)-checkpoints-$stamp.md"
  mkdir -p "$PROJECT/$CTX_ARCHIVE" || return 1
  archive="$PROJECT/$CTX_ARCHIVE/$name"
  [ ! -e "$archive" ] && [ ! -L "$archive" ] || return 1
  temporary="$(mktemp "$file.XXXXXXXX")" || return 1
  keep_file_mode "$file" "$temporary"
  # Seções de checkpoint vão até o próximo título "## " que não seja subtítulo.
  case "$CTX_LANGUAGE" in en) label='Earlier checkpoints' ;; *) label='Checkpoints anteriores' ;; esac
  if ! LC_ALL=C awk -v total="$total" -v keep="$CHECKPOINT_KEEP" -v moved="$archive" -v note="_${label}: $CTX_ARCHIVE/${name}_" '
      /^## / { inside = ($0 ~ /^## Checkpoint · /); if (inside) { seen++; old = (seen <= total - keep) } else old = 0
               if (inside && seen == total - keep + 1 && !noted) { print note; print ""; noted = 1; blank = 1 } }
      inside && old { print > moved; next }
      /^[[:space:]]*$/ { if (blank) next; blank = 1; print; next }
      { blank = 0; print }
    ' "$file" > "$temporary"; then rm -f "$temporary" "$archive"; return 1; fi
  [ -s "$archive" ] || { rm -f "$temporary" "$archive"; return 1; }
  mv -f "$temporary" "$file" || { rm -f "$temporary"; return 1; }
  printf '=%s\n' "$CTX_ARCHIVE/$name"
}

# --- Tecnologias e comandos ------------------------------------------------
# Só lê manifestos conhecidos; nunca instala nem executa nada. Saída: tipo<TAB>valor.
project_detect() {
  local dir="$1" runner=npm script
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  [ -f "$dir/pnpm-lock.yaml" ] && runner=pnpm
  [ -f "$dir/yarn.lock" ] && runner=yarn
  [ -f "$dir/bun.lockb" ] || [ -f "$dir/bun.lock" ] && runner=bun
  if pro_regular_file "$dir/package.json"; then
    printf 'tech\tNode.js\n'
    LC_ALL=C /usr/bin/grep -q '"next"' "$dir/package.json" && printf 'tech\tNext.js\n'
    LC_ALL=C /usr/bin/grep -q '"react"' "$dir/package.json" && printf 'tech\tReact\n'
    LC_ALL=C /usr/bin/grep -q '"vue"' "$dir/package.json" && printf 'tech\tVue\n'
    { [ -f "$dir/tsconfig.json" ] || LC_ALL=C /usr/bin/grep -q '"typescript"' "$dir/package.json"; } && printf 'tech\tTypeScript\n'
    for script in test build lint typecheck type-check dev; do
      if LC_ALL=C /usr/bin/grep -Eq "\"$script\"[[:space:]]*:" "$dir/package.json"; then
        case "$script" in
          test) printf 'test\t%s\n' "$([ "$runner" = npm ] && printf 'npm test' || printf '%s test' "$runner")" ;;
          build) printf 'build\t%s run build\n' "$runner" ;;
          lint) printf 'lint\t%s run lint\n' "$runner" ;;
          typecheck|type-check) printf 'typecheck\t%s run %s\n' "$runner" "$script" ;;
          dev) printf 'dev\t%s run dev\n' "$runner" ;;
        esac
      fi
    done
  fi
  if pro_regular_file "$dir/pyproject.toml" || pro_regular_file "$dir/requirements.txt" || pro_regular_file "$dir/setup.py"; then
    printf 'tech\tPython\n'
    if [ -d "$dir/tests" ] || pro_regular_file "$dir/pytest.ini" || LC_ALL=C /usr/bin/grep -q 'pytest' "$dir/pyproject.toml" 2>/dev/null; then
      printf 'test\tpython3 -m pytest\n'
    fi
  fi
  pro_regular_file "$dir/Cargo.toml" && printf 'tech\tRust\ntest\tcargo test\nbuild\tcargo build\nlint\tcargo clippy\n'
  pro_regular_file "$dir/go.mod" && printf 'tech\tGo\ntest\tgo test ./...\nbuild\tgo build ./...\nlint\tgo vet ./...\n'
  pro_regular_file "$dir/Package.swift" && printf 'tech\tSwift\ntest\tswift test\nbuild\tswift build\n'
  if pro_any "$dir"/*.sln "$dir"/*.csproj; then printf 'tech\tC# / .NET\ntest\tdotnet test\nbuild\tdotnet build\n'; fi
  if pro_regular_file "$dir/composer.json"; then
    printf 'tech\tPHP\n'
    LC_ALL=C /usr/bin/grep -Eq '"test"[[:space:]]*:' "$dir/composer.json" && printf 'test\tcomposer test\n'
  fi
  if pro_regular_file "$dir/wp-config.php" || [ -d "$dir/wp-content" ] || LC_ALL=C /usr/bin/grep -qs '^[[:space:]]*\*[[:space:]]*Plugin Name:' "$dir"/*.php ||
      LC_ALL=C /usr/bin/grep -qs '^[[:space:]]*Theme Name:' "$dir/style.css"; then
    printf 'tech\tWordPress\n'
  fi
  if ! pro_regular_file "$dir/package.json" && pro_any "$dir"/*.html; then printf 'tech\tHTML/CSS/JavaScript\n'; fi
  return 0
}

# Projeto e, se não houver manifesto na raiz, as subpastas de código (CODIGO/ e um nível).
project_detect_all() {
  local dir PROJECT_CODE_DIRS=() output
  output="$(project_detect "$PROJECT")"
  if [ -z "$output" ]; then
    project_code_directories >/dev/null 2>&1 || true
    for dir in "${PROJECT_CODE_DIRS[@]}"; do
      output="$(project_detect "$dir")"
      [ -z "$output" ] || { printf 'folder\t%s\n%s\n' "${dir#"$PROJECT"/}" "$output"; return 0; }
    done
    return 0
  fi
  printf '%s\n' "$output"
}

# --- Worktrees -------------------------------------------------------------
# git worktree prune remove só registros de pastas que já não existem; nunca apaga arquivos.
worktree_prune() {
  local folder="$1" preview
  preview="$(git -C "$folder" worktree prune --dry-run -v 2>&1)" || { printf '%s\n' "$preview" >&2; return 1; }
  [ -n "$preview" ] || { printf '@nothing_to_prune\n'; return 0; }
  printf '%s\n' "$preview" | sed 's/^/=/'
  [ "${2:-}" = confirmed ] || return 0
  git -C "$folder" worktree prune -v >/dev/null 2>&1 && printf '@pruned\n'
}

# --- Diagnóstico sem dados sensíveis --------------------------------------
pro_sanitize() {
  # Troca a pasta pessoal por ~ e mascara valores com cara de token.
  local home="${HOME%/}" pattern
  pattern="$(pro_secret_pattern)"
  if [ -n "$home" ] && [ "$home" != / ]; then
    LC_ALL=C sed -E -e "s#$(printf '%s' "$home" | sed 's/[][\.*^$#]/\\&/g')#~#g" -e "s/$pattern/[oculto]/g"
  else LC_ALL=C sed -E "s/$pattern/[oculto]/g"; fi
}

app_probe_system() {
  local os arch build tool
  os="$(uname -s 2>/dev/null) $(uname -r 2>/dev/null)"
  [ "$(uname -s)" != Darwin ] || os="macOS $(sw_vers -productVersion 2>/dev/null)"
  arch="$(uname -m 2>/dev/null)"
  build="$(cat "$BASE_DIR/lib/build-number" 2>/dev/null)"
  printf '=%s · %s\n' "$os" "$arch"
  printf '=Assistente IA %s · build %s\n' "$VERSION" "${build:-?}"
  printf '=Bash %s\n' "${BASH_VERSION%%(*}"
  for tool in node python3; do
    if command -v "$tool" >/dev/null 2>&1 && bounded_capture 5 "$tool" --version; then printf '=%s\n' "${CAPTURE%%$'\n'*}"
    else printf '@missing_%s\n' "$tool"; fi
  done
  printf '=%s\n' "${TERM_PROGRAM:-${TERM:-terminal}}"
}

# Resumo legível das tecnologias e comandos sugeridos (nada é executado).
project_detect_summary() {
  local kind value techs='' commands=''
  while IFS=$'\t' read -r kind value; do
    case "$kind" in
      tech) techs="${techs:+$techs, }$value" ;;
      folder) say "  $(ui 'Código em' 'Code in'): $value" ;;
      test|build|lint|typecheck|dev) commands="${commands}    $kind: $value"$'\n' ;;
    esac
  done <<EOF2
$(project_detect_all)
EOF2
  if [ -n "$techs" ]; then doctor_line ok "$(ui 'Tecnologias detectadas' 'Detected technologies'): $techs"
  else doctor_line ok "$(ui 'Projeto genérico (nenhum manifesto conhecido)' 'Generic project (no known manifest)')"; fi
  if [ -n "$commands" ]; then
    say_ui '  Comandos sugeridos pelos manifestos (revise antes de usar; nada foi executado):' '  Commands suggested by the manifests (review before use; nothing was run):'
    printf '%s' "$commands"
  fi
}

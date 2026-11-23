#!/bin/bash
# Bridge for the macOS app. Machine-readable commands use one value per line.

. "$BASE_DIR/lib/workflows.sh"

app_list_projects() {
  local path
  [ -f "$STATE_DIR/recents" ] || return 0
  while IFS= read -r path; do
    [ -d "$path" ] && single_line "$path" && printf '%s\n' "$path"
  done < "$STATE_DIR/recents"
  return 0
}

app_project_info() {
  local file profile codex_entry=AGENTS.md weight
  PROJECT="$(normalize_path "$1")" || return 1
  project_context || return 1
  PREF_DIR="$(project_preference_dir "$PROJECT")" || return 1
  profile="$(read_value "$PREF_DIR/tool")"
  case "$profile" in codex|claude) ;; *) profile="$(project_profile)" || profile=codex ;; esac
  printf '%s\n' "$profile"
  for file in AGENTS.md CLAUDE.md; do
    if entry_connected "$file"; then printf 'shared\n'
    elif [ -f "$PROJECT/$file" ]; then printf 'custom\n'
    else printf 'missing\n'; fi
  done
  if instructions_unfilled; then printf 'template\n'
  elif [ -f "$PROJECT/${CTX_INSTRUCTIONS}" ]; then printf 'ready\n'
  else printf 'missing\n'; fi
  if [ -f "$PROJECT/AGENTS.override.md" ]; then
    printf 'override\n'
    codex_entry=AGENTS.override.md
  fi
  if has_real_progress; then printf 'progress\n'; fi
  for file in "$codex_entry" CLAUDE.md; do
    weight="$(fixed_weight_bytes "$file")"
    if [ "$weight" -gt "$FIXED_WEIGHT_WARN_BYTES" ]; then
      printf 'large-context\n'
      break
    fi
  done
  return 0
}

app_launch() {
  local folder="$1" verb="$3" prompt_file="$7" summary=0
  TOOL="$2" WORKMODE="$4" MODEL="$5" EFFORT="$6"
  case "$TOOL" in codex|claude) ;; *) return 2 ;; esac
  case "$WORKMODE" in trabalhar|planejar) ;; *) return 2 ;; esac
  [ -z "$MODEL" ] || valid_model "$MODEL" || { warn "$(ui 'Nome de modelo inválido.' 'Invalid model name.')"; return 2; }
  case "$EFFORT" in ''|low|medium|high|xhigh|max|ultra|ultracode) ;; *) return 2 ;; esac
  app_require_tool || return 1
  if [ "$verb" = novo ] && [ -n "$prompt_file" ]; then load_prompt_file "$prompt_file" || return 1; fi
  set_project "$folder" || return 1
  project_context || return 1
  case "$verb" in
    novo|recente|escolher) ;;
    handoff) INITIAL_PROMPT="$prompt_file"; verb=novo ;;
    resumo)
      [ -d "$PROJECT/${CTX_DOCS}" ] && [ ! -L "$PROJECT/${CTX_DOCS}" ] || {
        warn "$(ui 'Prepare o contexto do projeto antes de salvar o andamento.' 'Set up project context before saving progress.')"
        return 1
      }
      INITIAL_PROMPT="$(prompt_encerrar_text)"
      verb=recente summary=1 ;;
    *) return 2 ;;
  esac
  save_preferences || return 1
  if [ "$summary" = 1 ]; then WORKMODE=trabalhar; fi
  if [ "${ASSISTENTE_BASH_COMPRESSION:-avoid}" = avoid ] && rtk_hook_active "$TOOL"; then
    export TOKEN_OPTIMIZER_BASH_COMPRESS=0 TOKEN_OPTIMIZER_NO_UPDATED_TOOL_OUTPUT=1
  fi
  run_agent_session "$verb"
}

app_require_tool() {
  command -v "$TOOL" >/dev/null 2>&1 || {
    warn "$TOOL $(ui 'está ausente. Abra os Ajustes para ver como instalar.' 'is missing. Open Settings for installation options.')"
    return 1
  }
}

app_tool_status() {
  local tool version codex_hook=0 claude_hook=0 optimizer_codex=0 optimizer_claude=0
  for tool in codex claude rtk; do
    if ! command -v "$tool" >/dev/null 2>&1; then version=''
    elif bounded_capture 5 "$tool" --version; then version="${CAPTURE%%$'\n'*}"
    else version='?'; fi
    printf '%s\n' "$version"
  done
  rtk_hook_active codex && codex_hook=1
  rtk_hook_active claude && claude_hook=1
  app_optimizer_codex && optimizer_codex=1
  app_optimizer_claude && optimizer_claude=1
  printf '%s\n' "$codex_hook" "$claude_hook" "$optimizer_codex" "$optimizer_claude"
  if /usr/bin/grep -Fq 'token-optimizer' "$(rtk_hook_file codex)" 2>/dev/null; then printf '1\n'; else printf '0\n'; fi
}

APP_OPTIMIZER_MARKET='alexgreensh-token-optimizer'
APP_OPTIMIZER_ID="token-optimizer@$APP_OPTIMIZER_MARKET"
app_optimizer_codex() {
  [ -f "${CODEX_HOME:-$HOME/.codex}/config.toml" ] || return 1
  /usr/bin/awk -v section="[plugins.\"$APP_OPTIMIZER_ID\"]" '
    /^[[:space:]]*\[/ { plugin = ($0 == section) }
    plugin && /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true([[:space:]]*#.*)?[[:space:]]*$/ { found=1 }
    END { exit !found }
  ' "${CODEX_HOME:-$HOME/.codex}/config.toml"
}

app_optimizer_claude() {
  local settings
  settings="$(rtk_hook_file claude)"
  [ -f "$settings" ] &&
    [ "$(/usr/bin/plutil -extract "enabledPlugins.$APP_OPTIMIZER_ID" raw -o - "$settings" 2>/dev/null)" = true ]
}

app_optimizer_control() {
  local tool="$1" action="$2" entry tag best='' adapter='' cache args=()
  case "$action" in enable|disable) ;; *) return 2 ;; esac
  case "$tool" in
    claude)
      TOOL=claude
      app_require_tool && claude plugin "$action" "$APP_OPTIMIZER_ID" --scope user ;;
    codex)
      app_optimizer_codex || return 1
      cache="${CODEX_HOME:-$HOME/.codex}/plugins/cache/$APP_OPTIMIZER_MARKET/token-optimizer"
      for entry in "$cache"/*; do
        tag="v${entry##*/}"
        rtk_valid_tag "$tag" && [ -f "$entry/skills/token-optimizer/scripts/measure.py" ] || continue
        if [ -z "$best" ] || rtk_tag_newer "$tag" "$best"; then
          best="$tag"
          adapter="$entry/skills/token-optimizer/scripts/measure.py"
        fi
      done
      [ -n "$adapter" ] || { warn "$(ui 'Adaptador do Token Optimizer não encontrado.' 'Token Optimizer adapter not found.')"; return 1; }
      [ "$action" != disable ] || args+=(--uninstall)
      python3 "$adapter" --runtime codex codex-install "${args[@]}" ;;
    *) return 2 ;;
  esac
}

app_update_integrations() {
  local result=0
  if rtk_present; then
    mkdir -p "$STATE_DIR" && rtk_update confirmed || result=1
  fi
  if command -v codex >/dev/null 2>&1 && app_optimizer_codex; then
    codex plugin marketplace upgrade "$APP_OPTIMIZER_MARKET" || result=1
  fi
  if command -v claude >/dev/null 2>&1 && app_optimizer_claude; then
    claude plugin marketplace update "$APP_OPTIMIZER_MARKET" &&
      claude plugin update "$APP_OPTIMIZER_ID" --scope user || result=1
  fi
  return "$result"
}

app_dev_packages() {
  local dir PROJECT_CODE_DIRS=()
  PROJECT="$(normalize_path "$1")" || return 1
  if [ -f "$PROJECT/package.json" ] && [ ! -L "$PROJECT/package.json" ]; then
    printf '.\n'
    return 0
  fi
  project_code_directories || return 1
  for dir in "${PROJECT_CODE_DIRS[@]}"; do
    if [ -f "$dir/package.json" ] && [ ! -L "$dir/package.json" ]; then
      printf '%s\n' "${dir#"$PROJECT"/}"
    fi
  done
}

app_command() {
  local action="${1:-}" goal path
  [ "$#" -gt 0 ] || return 2
  shift
  umask 077
  load_language
  case "$action:$#" in
    version:0) printf '%s\n' "$VERSION" ;;
    list:0) app_list_projects ;;
    info:1) app_project_info "$1" ;;
    layout:1)
      PROJECT="$(normalize_path "$1")" && project_context &&
        printf '%s\n' "$CTX_INSTRUCTIONS" "$CTX_PROGRESS" "$CTX_CONTINUE" "$CTX_PROMPTS" "$CTX_DOCS" "$CTX_ATTACHMENTS" ;;
    prefs:2)
      case "$2" in codex|claude) TOOL="$2" ;; *) return 2 ;; esac
      PROJECT="$(normalize_path "$1")" || return 1
      PREF_DIR="$(project_preference_dir "$PROJECT")" || return 1
      load_preferences
      printf '%s\n' "$MODEL" "$EFFORT" "$WORKMODE" ;;
    select:1) set_project "$1" && printf '%s\n' "$PROJECT" ;;
    create:4|create:5)
      case "$3" in codex|claude) TOOL="$3" ;; *) return 2 ;; esac
      goal="$4"
      single_line "$goal" && [ "${#goal}" -le 300 ] || { warn "$(ui 'Use um objetivo de até 300 caracteres em uma linha.' 'Use a one-line goal of up to 300 characters.')"; return 1; }
      create_project_at "$1" "$2" 2 "${5:-grouped}" || return 1
      if text_has_content "$goal"; then fill_project_objective "$goal" >/dev/null || return 1; fi
      printf '%s\n' "$PROJECT" ;;
    prepare:1)
      PROJECT="$(normalize_path "$1")" || return 1
      prepare_shared_project ;;
    launch:7) app_launch "$@" ;;
    probe:1) app_probe "$1" ;;
    checkpoint-files:1) app_checkpoint_files "$1" ;;
    checkpoint-append:2) app_checkpoint_append "$1" "$2" ;;
    worktree-create:3) app_worktree_create "$@" ;;
    worktree-list:1) mkdir -p "$STATE_DIR" && app_list_worktrees "$1" ;;
    worktree-remove:2) mkdir -p "$STATE_DIR" && app_remove_worktree "$1" "$2" ;;
    profile-save:5)
      case "$2" in codex|claude) ;; *) return 2 ;; esac
      case "$3" in trabalhar|planejar) ;; *) return 2 ;; esac
      case "$5" in ''|low|medium|high|xhigh|max|ultra) ;; *) return 2 ;; esac
      [ -z "$4" ] || valid_model "$4" || { printf '@invalid_model\n' >&2; return 1; }
      set_project "$1" || return 1
      TOOL="$2" WORKMODE="$3" MODEL="$4" EFFORT="$5"
      save_preferences ;;
    run-check:2)
      PROJECT="$(normalize_path "$1")" || return 1
      (cd -- "$PROJECT" && "${SHELL:-/bin/zsh}" -lc "$2") ;;
    select-agent:2)
      case "$2" in codex|claude) ;; *) return 2 ;; esac
      set_project "$1" && put "$PREF_DIR/tool" "$2" ;;
    tools:0) app_tool_status ;;
    rtk-gain:0) rtk_gains ;;
    rtk-hook:2) rtk_toggle "$1" "$2" confirmado ;;
    optimizer-hook:2) app_optimizer_control "$1" "$2" ;;
    git-status:1)
      PROJECT="$(normalize_path "$1")" && GIT_OPTIONAL_LOCKS=0 git_changes ;;
    attach:2)
      PROJECT="$(normalize_path "$1")" && copy_attachment_file "$2" ;;
    save-prompt:3)
      PROJECT="$(normalize_path "$1")" && write_project_prompt "$2" "$3" ;;
    backup:2)
      PROJECT="$(normalize_path "$1")" && path="$(normalize_path "$2")" &&
        path="$(project_backup_destination "$path")" && write_project_backup "$path" && printf '%s\n' "$path" ;;
    shell:1)
      PROJECT="$(normalize_path "$1")" && (cd -- "$PROJECT" && run_foreground "${SHELL:-/bin/bash}" -i) ;;
    dev-packages:1)
      app_dev_packages "$1" ;;
    dev:2)
      PROJECT="$(normalize_path "$1")" || return 1
      case "$2" in ''|/*|*'/../'*|../*|*/..|..) return 2 ;; esac
      if [ "$2" = . ]; then path="$PROJECT"; else path="$PROJECT/$2"; fi
      run_project_dev_server "$path" ;;
    diagnostics:0) diagnostics ;;
    menu:0) main ;;
    menu:1) set_project "$1" && main ;;
    update:1)
      case "$1" in
        codex|claude) TOOL="$1"; app_require_tool && run_foreground "$TOOL" update ;;
        rtk) mkdir -p "$STATE_DIR" && rtk_update confirmed ;;
        integrations) app_update_integrations ;;
        *) return 2 ;;
      esac ;;
    auth:1)
      case "$1" in codex|claude) TOOL="$1" ;; *) return 2 ;; esac
      if command -v "$TOOL" >/dev/null 2>&1 && logged_in; then printf '1\n'; else printf '0\n'; fi ;;
    login:2)
      case "$1" in codex|claude) TOOL="$1" ;; *) return 2 ;; esac
      case "$2" in login|switch) ;; *) return 2 ;; esac
      app_require_tool || return 1
      case "$TOOL" in
        codex)
          if [ "$2" = switch ]; then codex logout || return 1; fi
          run_foreground codex login ;;
        claude)
          if [ "$2" = switch ]; then claude auth logout || return 1; fi
          run_foreground claude auth login ;;
      esac ;;
    *) return 2 ;;
  esac
}

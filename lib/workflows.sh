# Machine-readable operations for the native panel. Each diagnostic message starts
# with @ (a localization key) or = (a value such as a version).
app_probe() {
  local tool="$1" agent root entry version newest='' status=0
  case "$tool" in
    optimizer-codex|optimizer-claude)
      agent="${tool#optimizer-}"
      if [ "$agent" = codex ]; then root="${CODEX_HOME:-$HOME/.codex}"
      else root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; fi
      for entry in "$root/plugins/cache/$APP_OPTIMIZER_MARKET/token-optimizer/"*; do
        [ -d "$entry" ] || continue
        version="v${entry##*/}"
        rtk_valid_tag "$version" || continue
        if [ -z "$newest" ] || rtk_tag_newer "$version" "$newest"; then newest="$version"; fi
      done
      if [ -n "$newest" ]; then printf '@cache\t%s\n' "${newest#v}"; else printf '@no_cache\n'; fi
      if "app_optimizer_$agent"; then printf '@plugin_on\n'; else printf '@plugin_off\n'; fi
      return ;;
    codex|claude|git|npm|rtk) ;;
    *) return 2 ;;
  esac
  if ! command -v "$tool" >/dev/null 2>&1; then printf '@missing_%s\n' "$tool"; return; fi
  if bounded_capture 5 "$tool" --version && [ -n "$CAPTURE" ]; then
    version="${CAPTURE%%$'\n'*}"
    printf '=%.180s\n' "$version"
  else printf '@version_error\n'; fi
  case "$tool" in
    codex|claude)
      TOOL="$tool"
      logged_in || status=$?
      if [ "$status" = 124 ]; then printf '@auth_unknown\n'
      elif [[ "$tool" = claude && "$CAPTURE" =~ \"loggedIn\"[[:space:]]*:[[:space:]]*false ]]; then printf '@auth_claude\n'
      elif [ "$status" = 0 ]; then printf '@auth_ok\n'
      elif printf '%s' "$CAPTURE" | grep -Eiq 'not (logged|signed) in|not authenticated'; then printf '@auth_%s\n' "$tool"
      else printf '@auth_unknown\n'; fi ;;
    rtk)
      for agent in codex claude; do
        printf '=%s\n' "$agent"
        if rtk_hook_active "$agent"; then printf '@hook_on\n'
        elif [ "$agent" = codex ]; then printf '@hook_off\trtk init --global --codex\n'
        else printf '@hook_off\trtk init --global\n'; fi
      done ;;
  esac
}

app_checkpoint_files() {
  local folder="$1" result
  if result="$(git --no-optional-locks -c core.quotePath=false -C "$folder" status --porcelain=v1 --untracked-files=all -- . 2>/dev/null)"; then
    if [ -z "$result" ]; then printf '@clean\n'
    else printf '%s\n' "$result" | awk 'NR<=80 {print "=" $0} NR==81 {print "@more_files"; exit}'; fi
  else printf '@no_status\n'; fi
}

app_checkpoint_append() {
  local note="$2" file
  PROJECT="$(normalize_path "$1")" || return 1
  file="$PROJECT/DOCS/ANDAMENTO.md"
  text_has_content "$note" || return 2
  [ "$(LC_ALL=C printf '%s' "$note" | wc -c)" -le 60000 ] || { printf '@too_large\n' >&2; return 1; }
  if ! safe_project_path DOCS/ANDAMENTO.md >/dev/null 2>&1 ||
      { [ -e "$file" ] && [ ! -f "$file" ]; }; then printf '@unsafe_notes\n' >&2; return 1; fi
  mkdir -p -- "$PROJECT/DOCS" && printf '%s' "$note" >> "$file"
}

app_worktree_create() {
  local folder agent="$2" task="$3" target branch top output
  case "$agent" in claude|codex) ;; *) return 2 ;; esac
  [[ "$task" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || { printf '@invalid_task\n' >&2; return 1; }
  folder="$(normalize_path "$1")" || return 1
  command -v git >/dev/null || { printf '@missing_git\n' >&2; return 1; }
  top="$(git -C "$folder" rev-parse --show-toplevel 2>/dev/null)" &&
    [ "$(normalize_path "$top")" = "$folder" ] &&
    git -C "$folder" rev-parse --verify 'HEAD^{commit}' >/dev/null 2>&1 || { printf '@need_repo\n' >&2; return 1; }
  target="$folder-$agent-$task"
  branch="assistente/$agent-$task"
  if [ -e "$target" ] || [ -L "$target" ] || git -C "$folder" show-ref --verify --quiet "refs/heads/$branch"; then
    printf '@exists\n' >&2; return 1
  fi
  mkdir -- "$target" || return 1
  if ! output="$(git -C "$folder" worktree add -b "$branch" "$target" HEAD 2>&1)"; then
    rmdir -- "$target" 2>/dev/null || true
    printf '%s\n' "$output" >&2
    return 1
  fi
  printf '%s\n' "$target"
}

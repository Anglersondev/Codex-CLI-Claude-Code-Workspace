project_context() {
  local lang instructions progress continuation close summary start plan attachments code archive backups
  local choice="${ASSISTENTE_PROJECT_LANG:-${APP_LANG:-pt-BR}}" file_choice='' folder_choice='' file
  case "$choice" in en|es|pt-BR) ;; *) choice=pt-BR ;; esac
  if [ "${CTX_CACHE:-}" = "$PROJECT:$choice" ]; then return 0; fi
  local table="$BASE_DIR/lib/project-layouts.tsv"
  while IFS=$'\t' read -r lang instructions progress continuation close summary start plan attachments code archive backups; do
    for file in "$instructions" "$progress" "$continuation" "$close" "$summary" "$start" "$plan"; do
      if [ -e "$PROJECT/$file" ] || [ -L "$PROJECT/$file" ]; then file_choice="$lang"; break; fi
    done
    [ -z "$file_choice" ] || break
    if [ -z "$folder_choice" ] && { [ -d "$PROJECT/${instructions%/*}" ] || [ -d "$PROJECT/$attachments" ]; }; then
      folder_choice="$lang"
    fi
  done < "$table"
  while IFS=$'\t' read -r lang CTX_INSTRUCTIONS CTX_PROGRESS CTX_CONTINUE CTX_CLOSE CTX_SUMMARY CTX_START CTX_PLAN CTX_ATTACHMENTS CTX_CODE CTX_ARCHIVE CTX_BACKUPS; do
    if [ "$lang" = "${file_choice:-${folder_choice:-$choice}}" ]; then
      CTX_LANGUAGE="$lang"
      CTX_RULES="${CTX_INSTRUCTIONS%/*}"
      CTX_DOCS="${CTX_PROGRESS%/*}"
      CTX_PROMPTS="${CTX_CONTINUE%/*}"
      CTX_CACHE="$PROJECT:$choice"
      return 0
    fi
  done < "$table"
  return 1
}

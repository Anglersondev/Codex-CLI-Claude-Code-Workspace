#!/bin/bash
# Projetos e instruções persistentes. Compatível com Bash 3.2.

text_has_content() { LC_ALL=C /usr/bin/grep -q '[^[:space:]]' <<< "$1"; }

project_profile() {
  local value=''
  if [ -L "$PROJECT/.assistente-ia" ] || [ -L "$PROJECT/.assistente-ia/tool" ]; then return 1; fi
  if [ -e "$PROJECT/.assistente-ia/tool" ]; then
    [ -f "$PROJECT/.assistente-ia/tool" ] || return 1
    IFS= read -r value < "$PROJECT/.assistente-ia/tool"
    case "$value" in codex|claude) printf '%s' "$value"; return 0 ;; *) return 1 ;; esac
  fi
  if [ -f "$PROJECT/AGENTS.md" ] && [ ! -e "$PROJECT/CLAUDE.md" ] && [ ! -d "$PROJECT/.claude" ]; then
    printf codex
  elif [ -f "$PROJECT/CLAUDE.md" ] && [ ! -e "$PROJECT/AGENTS.md" ]; then
    printf claude
  else return 1; fi
}

selected_project_agent() {
  local value
  if [ -n "$SESSION_TOOL" ]; then printf '%s' "$SESSION_TOOL"; return; fi
  if [ -n "$PREF_DIR" ] && [ "$(read_value "$PREF_DIR/path")" = "$PROJECT" ] && [ -f "$PREF_DIR/tool" ]; then
    value="$(read_value "$PREF_DIR/tool")"
    case "$value" in codex|claude) printf '%s' "$value"; return 0 ;; esac
  fi
  project_profile
}

choose_project_tool() {
  local profile
  if [ -n "$SESSION_TOOL" ]; then TOOL="$SESSION_TOOL"; return 0; fi
  profile="$(selected_project_agent)"
  if [ -n "$profile" ]; then
    TOOL="$profile"
    say "$(ui 'Ferramenta deste projeto' 'Agent for this project'): $TOOL"
    return 0
  fi
  if [ -e "$PROJECT/.assistente-ia/tool" ] || [ -L "$PROJECT/.assistente-ia/tool" ] || [ -L "$PROJECT/.assistente-ia" ]; then
    warn "$(ui 'Perfil do projeto inválido. Confira .assistente-ia/tool antes de continuar.' 'Invalid project profile. Check .assistente-ia/tool before continuing.')"
    return 1
  fi
  choose_tool
}

# Não atravessa links simbólicos ao gravar arquivos gerenciados pelo assistente.
safe_project_path() {
  local relative="$1" component current="$PROJECT" parts=()
  [ -n "$PROJECT" ] && [ -d "$PROJECT" ] || { warn 'Escolha o projeto antes de gravar arquivos.'; return 1; }
  case "$relative" in ''|/*|../*|*/../*|*/..) return 1 ;; esac
  local IFS='/'
  read -r -a parts <<< "$relative"
  for component in "${parts[@]}"; do
    current="$current/$component"
    if [ -L "$current" ]; then warn "Caminho é um link simbólico; arquivo preservado: $relative"; return 1; fi
  done
}

write_new_file() {
  local relative="$1"
  safe_project_path "$relative" || return 1
  if [ -e "$PROJECT/$relative" ]; then
    [ -f "$PROJECT/$relative" ] || { warn "$relative existe mas não é arquivo."; return 1; }
    cat >/dev/null
    return 0
  fi
  (set -o noclobber; cat > "$PROJECT/$relative")
}

instruction_entry() {
  project_context || return 1
  if [ "$CTX_LANGUAGE" = es ]; then
    printf '\n<!-- assistente-ia: instrucoes-do-projeto -->\n'
    if [ "${1:-$TOOL}" = claude ]; then printf '@%s\n' "$CTX_INSTRUCTIONS"
    else printf 'Lee %s antes de trabajar en este proyecto.\n' "$CTX_INSTRUCTIONS"; fi
    printf 'Consulta las solicitudes y los documentos cuando sean pertinentes.\n'
    return
  fi
  local APP_LANG="$CTX_LANGUAGE"
  printf '\n<!-- assistente-ia: instrucoes-do-projeto -->\n'
  if [ "${1:-$TOOL}" = claude ]; then
    printf '@%s\n' "$CTX_INSTRUCTIONS"
  else
    printf '%s\n' "$(ui "Antes de trabalhar, leia e siga $CTX_INSTRUCTIONS, relativo à raiz deste projeto." "Before working, read and follow $CTX_INSTRUCTIONS relative to this project root.")"
  fi
  printf '%s\n' "$(ui "Consulte $CTX_RULES/, $CTX_DOCS/ e $CTX_ATTACHMENTS/ quando forem relevantes." "Consult $CTX_RULES/, $CTX_DOCS/, and $CTX_ATTACHMENTS/ when relevant.")"
  printf '%s\n' "$(ui "$CTX_PROMPTS/ contém pedidos reutilizáveis. Execute o pedido escolhido pelo usuário." "$CTX_PROMPTS/ contains reusable requests. Run the request selected by the user.")"
}

efficiency_section() {
  project_context || return 1
  if [ "$CTX_LANGUAGE" = es ]; then cat <<EOF
## Eficiencia (ahorro de tokens)
- Lee los archivos pertinentes y mantén breves los resúmenes.
- Planifica los cambios grandes y divídelos en pasos.
- Guarda el progreso en $CTX_PROGRESS después de cada etapa importante.
EOF
    return
  fi
  local APP_LANG="$CTX_LANGUAGE"
  if [ "$APP_LANG" = en ]; then cat <<EOF
## Efficiency (token savings)
- Read only what is needed: search or list before opening entire files, and do not reread content already seen in the conversation.
- Reply briefly and directly: avoid repeating the request or dumping entire code files when a snippet or diff is enough.
- Plan large tasks first and divide them into steps.
- Record progress in $CTX_PROGRESS (about 40 lines maximum; condense instead of accumulating).
EOF
    return
  fi
  cat <<EOF
## Eficiência (economia de tokens)
- Leia só o necessário: busque (grep/lista) antes de abrir arquivos inteiros e não releia o que já viu na conversa.
- Responda curto e direto: sem repetir o pedido e sem despejar código inteiro quando um trecho ou diff basta.
- Em tarefas grandes, planeje primeiro e divida em etapas.
- Registre o andamento em $CTX_PROGRESS (máx. ~40 linhas; condense, não acumule).
EOF
}

prompt_encerrar_text() {
  project_context || return 1
  if [ "$CTX_LANGUAGE" = es ]; then cat <<EOF
Para cerrar la sesión, resume los cambios confirmados, las decisiones, las pruebas y la tarea siguiente.
Actualiza $CTX_PROGRESS con un máximo aproximado de 40 líneas y conserva los hechos relevantes.
EOF
    return
  fi
  local APP_LANG="$CTX_LANGUAGE"
  if [ "$APP_LANG" = en ]; then cat <<EOF
Let's wrap up this session. In a few lines, report what was completed, decisions, useful commands, outstanding work, and the next task.
Then update $CTX_PROGRESS, condensing older content: about 40 lines maximum, confirmed facts only.
Do not repeat code or long excerpts.
EOF
    return
  fi
  cat <<EOF
Vamos encerrar esta sessão. Responda em poucas linhas: o que foi concluído, decisões, comandos úteis, pendências e a próxima tarefa.
Depois atualize $CTX_PROGRESS condensando o conteúdo antigo: no máximo ~40 linhas, só fatos confirmados.
Não repita código nem trechos longos.
EOF
}

prompt_resumo_text() {
  project_context || return 1
  if [ "$CTX_LANGUAGE" = es ]; then cat <<EOF
Resume la conversación en hasta 15 líneas para retomarla en una sesión nueva.
Incluye el objetivo, el estado actual, las decisiones, la próxima tarea y los archivos que conviene leer.
EOF
    return
  fi
  local APP_LANG="$CTX_LANGUAGE"
  if [ "$APP_LANG" = en ]; then cat <<EOF
This conversation has grown long. Create a context summary of up to 15 lines that I can paste into a new conversation: goal, current state, decisions, and next task.
List the key files the new conversation should read. Do not include code.
EOF
    return
  fi
  cat <<EOF
Esta conversa ficou longa. Gere um resumo de contexto de até 15 linhas para eu colar numa conversa nova: objetivo, estado atual, decisões e próxima tarefa.
Liste também os arquivos-chave que a nova conversa deve ler. Não inclua código.
EOF
}

instructions_template_text() {
  project_context || return 1
  if [ "$CTX_LANGUAGE" = es ]; then cat <<EOF
# Instrucciones permanentes del proyecto

## Objetivo y contexto
- Objetivo: describe qué quieres crear y para quién.
- Contexto: describe el público, el negocio y las referencias principales.

## Preferencias de trabajo
- Responde en español con explicaciones claras.
- Lee los archivos pertinentes y conserva el trabajo existente.
- Presenta un plan breve antes de cambios grandes.
- Protege las credenciales y los archivos .env.
- Informa de los cambios, las comprobaciones realizadas y las tareas pendientes.
- Actualiza $CTX_PROGRESS al completar una etapa importante.

## Requisitos del proyecto
- Completa las tecnologías, el estilo, las restricciones y los criterios de éxito.

EOF
    return
  fi
  local APP_LANG="$CTX_LANGUAGE"
  if [ "$APP_LANG" = en ]; then cat <<EOF
# Permanent instructions for this project

## Goal and context
- Goal: describe what you want to build and for whom.
- Context: describe the business, audience, and important references.

## Working preferences
- Respond in English with clear explanations.
- Read relevant files and preserve existing work.
- Before large changes, present a short plan.
- Do not expose passwords, keys, tokens, or .env files.
- When done, report changes, checks actually performed, and remaining work.
- Update $CTX_PROGRESS after meaningful milestones.

## Project-specific requirements
- Fill in the technologies, style, constraints, and success criteria for this project.
- Consult other documents when relevant; do not load every attachment for each request.

EOF
    return
  fi
  cat <<EOF
# Instruções permanentes deste projeto

## Objetivo e contexto
- Objetivo: preencha o que deseja construir e para quem.
- Contexto: descreva o negócio, público e referências importantes.

## Preferências de trabalho
- Responda em português, com explicações claras.
- Leia os arquivos relevantes e preserve o trabalho existente.
- Antes de mudanças extensas, apresente um plano curto.
- Não exponha senhas, chaves, tokens ou arquivos .env.
- Ao concluir, informe mudanças, verificações realmente feitas e pendências.
- Atualize $CTX_PROGRESS ao concluir etapas relevantes.

## Requisitos específicos
- Preencha tecnologias, estilo, limites e critérios de sucesso deste projeto.
- Consulte outros documentos quando relevantes; não carregue todos os anexos a cada pedido.

EOF
}

prepare_project_files() {
  project_context || return 1
  local folder native agent entries APP_LANG="$CTX_LANGUAGE"
  case "$TOOL" in codex) native=AGENTS.md ;; claude) native=CLAUDE.md ;; *) return 1 ;; esac
  entries=("$native")
  if [ "${1:-}" = shared ]; then entries=(AGENTS.md CLAUDE.md); fi
  for native in "${entries[@]}" "${CTX_INSTRUCTIONS}" "${CTX_PROGRESS}" "${CTX_START}" "${CTX_PLAN}" "${CTX_CONTINUE}" "${CTX_CLOSE}" "${CTX_SUMMARY}" .assistente-ia/tool; do
    safe_project_path "$native" || return 1
    if [ -e "$PROJECT/$native" ] && [ ! -f "$PROJECT/$native" ]; then
      warn "$native $(ui 'existe mas não é arquivo.' 'exists but is not a file.')"
      return 1
    fi
  done
  for folder in .assistente-ia "${CTX_RULES}" "${CTX_PROMPTS}" "${CTX_DOCS}" "${CTX_ATTACHMENTS}"; do
    safe_project_path "$folder" || return 1
    mkdir -p "$PROJECT/$folder" || return 1
  done
  { instructions_template_text; efficiency_section; } | write_new_file "${CTX_INSTRUCTIONS}" || return 1
  if [ "$CTX_LANGUAGE" = es ]; then
    write_new_file "$CTX_PROGRESS" <<EOF || return 1
# Progreso del proyecto

## Cambios realizados

## Decisiones importantes

## Próximo paso

Registra hechos confirmados y tareas pendientes.
EOF
    write_new_file "$CTX_START" <<EOF || return 1
Lee $CTX_INSTRUCTIONS y los archivos pertinentes. Define el resultado esperado, ejecuta las comprobaciones y explica el resultado en español.
EOF
    write_new_file "$CTX_PLAN" <<EOF || return 1
Lee $CTX_INSTRUCTIONS y propón un plan breve. Espera confirmación antes de implementar.
EOF
    write_new_file "$CTX_CONTINUE" <<EOF || return 1
Lee $CTX_INSTRUCTIONS y $CTX_PROGRESS. Comprueba el estado de los archivos y continúa con el próximo paso registrado.
EOF
  elif [ "$APP_LANG" = en ]; then
    write_new_file "${CTX_PROGRESS}" <<EOF || return 1
# Project progress

## What works

## Important decisions

## Next step

## How to run and verify

Record confirmed facts and outstanding work. This file does not replace conversation history.
EOF
    write_new_file "${CTX_START}" <<EOF || return 1
Read ${CTX_INSTRUCTIONS} and the files relevant to the request below.
Goal of this task: [replace with the desired result].
Done when: [describe what must work].
Use ${CTX_ATTACHMENTS}/ and ${CTX_DOCS}/ when referenced. Preserve existing files.
Implement the task, run the necessary checks, and explain the result in English.
EOF
    write_new_file "${CTX_PLAN}" <<EOF || return 1
Read ${CTX_INSTRUCTIONS} and analyze relevant files.
I want to plan: [describe the change].
Present a short proposal with steps, decisions, and questions that block execution.
Wait for my request before implementing.
EOF
    write_new_file "${CTX_CONTINUE}" <<EOF || return 1
Read ${CTX_INSTRUCTIONS} and ${CTX_PROGRESS}.
Check the actual file state and identify the recorded next task.
Continue it if the scope is clear; otherwise, ask what is missing.
When finished, update progress with what was actually completed.
EOF
  else
  write_new_file "${CTX_PROGRESS}" <<EOF || return 1
# Andamento do projeto

## O que funciona

## Decisões importantes

## Próximo passo

## Como executar e verificar

Registre fatos confirmados e pendências. Este arquivo não substitui o histórico da conversa.
EOF
  write_new_file "${CTX_START}" <<EOF || return 1
Leia ${CTX_INSTRUCTIONS} e os arquivos relevantes para o pedido abaixo.
Objetivo desta tarefa: [substitua pelo resultado desejado].
Critérios para considerar pronto: [descreva o que precisa funcionar].
Use ${CTX_ATTACHMENTS}/ e ${CTX_DOCS}/ quando forem citados. Preserve arquivos existentes.
Implemente a tarefa, faça as verificações necessárias e explique o resultado em português.
EOF
  write_new_file "${CTX_PLAN}" <<EOF || return 1
Leia ${CTX_INSTRUCTIONS} e analise os arquivos relevantes.
Quero planejar: [descreva a mudança].
Apresente uma proposta curta com etapas, decisões e dúvidas que impedem a execução.
Aguarde meu pedido para implementar.
EOF
  write_new_file "${CTX_CONTINUE}" <<EOF || return 1
Leia ${CTX_INSTRUCTIONS} e ${CTX_PROGRESS}.
Confira o estado real dos arquivos e identifique a próxima tarefa registrada.
Continue essa tarefa se o escopo estiver definido; caso contrário, esclareça o que falta.
Ao terminar, atualize o andamento com o que foi realmente concluído.
EOF
  fi
  prompt_encerrar_text | write_new_file "${CTX_CLOSE}" || return 1
  prompt_resumo_text | write_new_file "${CTX_SUMMARY}" || return 1
  for native in "${entries[@]}"; do
    case "$native" in CLAUDE.md) agent=claude ;; *) agent=codex ;; esac
    { printf '# %s — %s\n' "$([ "$CTX_LANGUAGE" = es ] && printf "Instrucciones del proyecto" || ui "Orientações do projeto" "Project instructions")" "$agent"; instruction_entry "$agent"; } |
      write_new_file "$native" || return 1
  done
  if [ "${1:-}" = shared ]; then
    printf '%s\n' "$TOOL" | write_new_file .assistente-ia/tool
  else
    put "$PROJECT/.assistente-ia/tool" "$TOOL"
  fi
}

scaffold_project() {
  local target="$1" name="$2" kind="$3" previous="$PROJECT" status=0
  case "$TOOL" in codex|claude) ;; *) warn 'Escolha a ferramenta antes de criar o projeto.'; return 1 ;; esac
  PROJECT="$target"
  project_context || return 1
  if [ "$kind" = 2 ]; then
    prepare_project_files shared || status=1
    if [ "$status" -eq 0 ]; then
      if [ "$CTX_LANGUAGE" = es ]; then
        printf '# %s\n\n## Objetivo\n\nDescribe el propósito del proyecto.\n\n## Organización\n\n- %s: reglas compartidas.\n- %s: progreso y próximo paso.\n- %s/: solicitudes reutilizables.\n- %s/: archivos adjuntos.\n' "$name" "$CTX_INSTRUCTIONS" "$CTX_PROGRESS" "$CTX_PROMPTS" "$CTX_ATTACHMENTS" | write_new_file README.md || status=1
      elif [ "$CTX_LANGUAGE" = en ]; then
        printf "# %s\n\n## Goal\n\nDescribe the purpose of the project.\n\n## Layout\n\n- AGENTS.md and CLAUDE.md: entry files for Codex and Claude.\n- ${CTX_INSTRUCTIONS}: shared permanent instructions.\n- ${CTX_PROMPTS}/: reusable requests.\n- ${CTX_DOCS}/: decisions and progress.\n- ${CTX_ATTACHMENTS}/: images, PDFs, and references.\n- Code: in this root or any folders the project needs.\n" "$name" | write_new_file README.md || status=1
      else
        printf "# %s\n\n## Objetivo\n\nDescreva a finalidade do projeto.\n\n## Organização\n\n- AGENTS.md e CLAUDE.md: entradas para Codex e Claude.\n- ${CTX_INSTRUCTIONS}: instruções permanentes compartilhadas.\n- ${CTX_PROMPTS}/: pedidos reutilizáveis.\n- ${CTX_DOCS}/: decisões e andamento.\n- ${CTX_ATTACHMENTS}/: imagens, PDFs e referências.\n- Código: nesta raiz ou nas pastas que o projeto precisar.\n" "$name" | write_new_file README.md || status=1
      fi
      write_new_file .gitignore <<EOF || status=1
.DS_Store
.env
.env.*
!.env.example
node_modules/
.next/
dist/
build/
.venv/
__pycache__/
*.pem
*.key
${CTX_ARCHIVE}/
${CTX_BACKUPS}/
EOF
    fi
  else
    mkdir "$PROJECT/.assistente-ia" && put "$PROJECT/.assistente-ia/tool" "$TOOL" || status=1
  fi
  PROJECT="$previous"
  return "$status"
}

project_creation_root() {
  local parent="$1" base
  base="$(basename -- "$parent")"
  case "$base" in
    [Cc][Oo][Dd][Ee][Xx]|[Cc][Ll][Aa][Uu][Dd][Ee]) dirname -- "$parent" ;;
    *) printf '%s\n' "$parent" ;;
  esac
}

project_creation_group() {
  case "$TOOL" in codex) printf 'CODEX\n' ;; claude) printf 'CLAUDE\n' ;; *) return 1 ;; esac
}

create_project_at() {
  local parent="$1" name="$2" kind="$3" layout="${4:-grouped}" target root group folder
  valid_name "$name" || { warn "$(ui 'Nome de projeto inválido.' 'Invalid project name.')"; return 1; }
  case "$kind" in 1|2) ;; *) return 1 ;; esac
  parent="$(normalize_path "$parent")" || return 1
  case "$layout" in
    direct) target="${parent%/}/$name" ;;
    grouped)
      root="$(project_creation_root "$parent")" || return 1
      group="$(project_creation_group)" || return 1
      for folder in "${root%/}/CODEX" "${root%/}/CLAUDE"; do
        if [ -L "$folder" ] || { [ -e "$folder" ] && [ ! -d "$folder" ]; }; then
          warn "$(ui 'O destino precisa ser uma pasta comum:' 'The destination must be a regular directory:') $folder"
          return 1
        fi
      done
      target="${root%/}/$group/$name" ;;
    *) return 2 ;;
  esac
  [ ! -e "$target" ] && [ ! -L "$target" ] || { warn "$(ui 'Essa pasta já existe.' 'That folder already exists.')"; return 1; }
  if [ "$layout" = grouped ]; then mkdir -p -- "${root%/}/CODEX" "${root%/}/CLAUDE" || return 1; fi
  if ! mkdir -- "$target"; then
    warn "$(ui 'Não foi possível criar a pasta. Se ela já existe, abra o projeto existente.' 'Could not create the folder. If it already exists, open the existing project.')"
    return 1
  fi
  if ! scaffold_project "$target" "$name" "$kind"; then
    warn "$(ui 'Preparação incompleta em' 'Incomplete setup at') $target"
    return 1
  fi
  set_project "$target"
}

create_project() {
  local parent name target kind root group
  header_ui 'Criar projeto · 1 de 4: local' 'Create project · 1 of 4: location'
  say_ui 'Escolha a pasta que receberá o projeto compartilhado.' 'Choose the parent folder for the shared project.'
  choose_folder || return 1
  parent="$CHOSEN_FOLDER"
  header_ui 'Criar projeto · 2 de 4: nome' 'Create project · 2 of 4: name'
  while ask_ui 'Nome do projeto (Enter cancela): ' 'Project name (Enter cancels): '; do
    name="$REPLY"
    [ -n "$name" ] || return 1
    valid_name "$name" && break
    say_ui 'Use até 120 caracteres, sem /, \\, :, ponto inicial ou quebras de linha.' 'Use up to 120 characters, without /, \\, :, a leading dot, or line breaks.'
  done
  [ -n "$name" ] && valid_name "$name" || return 1
  header_ui 'Criar projeto · 3 de 4: ferramenta e estrutura' 'Create project · 3 of 4: agent and layout'
  say_ui 'Escolha o agente preferido. A mesma pasta funciona com os dois.' 'Choose the preferred agent. Both can use the same folder.'
  choose_tool || return 1
  root="$(project_creation_root "$parent")" || return 1
  group="$(project_creation_group)" || return 1
  target="${root%/}/$group/$name"
  [ ! -e "$target" ] && [ ! -L "$target" ] || { warn 'Essa pasta já existe. Abra o projeto existente; nada foi sobrescrito.'; return 1; }
  say_ui '1) Mínimo — pasta do projeto e identificação da ferramenta' '1) Minimal — project folder and agent profile'
  say_ui '2) Organizado — instruções, prompts, documentos e anexos (recomendado)' '2) Organized — instructions, prompts, documents, and attachments (recommended)'
  say_ui '0) Cancelar' '0) Cancel'
  while ask_ui 'Estrutura [2]: ' 'Layout [2]: '; do
    kind="${REPLY:-2}"
    case "$kind" in 1|2) break ;; 0) return 1 ;; *) say_ui 'Escolha 1, 2 ou 0.' 'Choose 1, 2, or 0.' ;; esac
  done
  case "$kind" in 1|2) ;; *) return 1 ;; esac
  header_ui 'Criar projeto · 4 de 4: conferir' 'Create project · 4 of 4: review'
  say "$(ui 'Nova pasta' 'New folder'): $target"
  say "$(ui 'Ferramenta' 'Agent'): $TOOL"
  say "$(ui 'Estrutura' 'Layout'): $([ "$kind" = 2 ] && ui organizada organized || ui mínima minimal)"
  ask_ui 'Enter para criar; 0 para cancelar: ' 'Press Enter to create; 0 to cancel: ' || return 1
  case "$REPLY" in ''|s|S) ;; *) say_ui 'Criação cancelada.' 'Creation canceled.'; return 1 ;; esac
  create_project_at "$parent" "$name" "$kind" || return 1
  say "$(ui 'Projeto pronto' 'Project ready'): $PROJECT"
  if [ "$kind" = 2 ]; then ask_project_objective || true; fi
}

prepare_shared_project() {
  local TOOL
  TOOL="$(project_profile)" || TOOL=codex
  prepare_project_files shared
}

organize_project_files() {
  project_context || return 1
  local native opposite path archive content
  case "$TOOL" in codex) native=AGENTS.md; opposite=CLAUDE.md ;; claude) native=CLAUDE.md; opposite=AGENTS.md ;; *) return 1 ;; esac
  for path in AGENTS.md CLAUDE.md .assistente-ia/tool "${CTX_INSTRUCTIONS}" "${CTX_ARCHIVE}" "${CTX_PROMPTS}" "${CTX_ATTACHMENTS}"; do
    safe_project_path "$path" || return 1
    if [ -e "$PROJECT/$path" ]; then
      case "$path" in *.md|*/tool) [ -f "$PROJECT/$path" ] || return 1 ;; *) [ -d "$PROJECT/$path" ] || return 1 ;; esac
    fi
  done
  # Configurações avançadas podem carregar outras regras; não fazer uma migração parcial.
  for path in AGENTS.override.md CLAUDE.local.md; do
    if [ -e "$PROJECT/$path" ] || [ -L "$PROJECT/$path" ]; then
      warn "Projeto tem $path. A organização automática exige revisão desse arquivo/pasta; nada foi alterado."
      return 1
    fi
  done
  if [ -L "$PROJECT/.claude" ] || { [ -e "$PROJECT/.claude" ] && [ ! -d "$PROJECT/.claude" ]; } ||
     { [ "$TOOL" = codex ] && [ -e "$PROJECT/.claude" ]; }; then
    warn 'Projeto tem .claude. A organização automática exige revisão desse arquivo/pasta; nada foi alterado.'
    return 1
  fi
  for path in "$native" "${CTX_INSTRUCTIONS}"; do
    if [ -f "$PROJECT/$path" ] && /usr/bin/grep -Fq "$opposite" "$PROJECT/$path"; then
      warn "$path referencia $opposite. Revise essa dependência antes de arquivar a entrada; nada foi alterado."
      return 1
    fi
  done
  mkdir -p "$PROJECT/${CTX_ARCHIVE}" || return 1
  archive="$(mktemp -d "$PROJECT/${CTX_ARCHIVE}/organizacao-XXXXXXXX")" || return 1
  for path in "$native" "$opposite" .assistente-ia/tool; do
    [ ! -f "$PROJECT/$path" ] || cp -p "$PROJECT/$path" "$archive/$(basename "$path").original" || return 1
  done
  prepare_project_files || { warn "Organização incompleta. Originais preservados em $archive"; return 1; }
  if ! entry_references_instructions "$PROJECT/$native"; then
    content="$(cat "$PROJECT/$native"; instruction_entry)"
    put "$PROJECT/$native" "$content" || return 1
  fi
  if [ -f "$PROJECT/$opposite" ]; then
    mv "$PROJECT/$opposite" "$archive/$opposite.arquivado" || return 1
  fi
  printf 'Ferramenta escolhida: %s\nOriginais: arquivos .original; arquivo da outra ferramenta: .arquivado.\nPROMPTS e documentos preexistentes foram preservados.\n' "$TOOL" > "$archive/LEIA-ME.txt"
  say "Organizado para $TOOL. Originais preservados em: $archive"
  say 'Abra uma nova conversa para carregar as instruções atualizadas.'
}

organize_project() {
  project_context || return 1
  header_ui 'Organizar projeto existente · com backup' 'Organize existing project · with backup'
  say_ui 'Escolha a ferramenta que será usada neste projeto.' 'Choose the agent to use in this project.'
  choose_tool || return 1
  say "$(ui 'Projeto' 'Project'): $PROJECT"
  say "$(ui 'Ferramenta' 'Agent'): $TOOL"
  say_ui "Vou criar ${CTX_RULES}/ e o perfil; manter prompts e documentos existentes." "I will create ${CTX_RULES}/ and the agent profile, preserving existing prompts and documents."
  say_ui "O arquivo de entrada da ferramenta oposta será arquivado em ${CTX_ARCHIVE}/." "The other agent entry file will be archived in ${CTX_ARCHIVE}/."
  say_ui 'O arquivo da ferramenta escolhida será preservado e receberá a referência às instruções.' 'The selected agent entry file will be preserved and linked to the instructions.'
  say_ui 'Os originais ficarão guardados no backup. Configurações avançadas exigem revisão manual.' 'Original files will be kept in the backup. Review advanced settings manually.'
  ask_ui 'Digite ORGANIZAR para aplicar; Enter cancela: ' 'Type ORGANIZE to apply; Enter cancels: ' || return 1
  [ "$REPLY" = ORGANIZAR ] || [ "$REPLY" = ORGANIZE ] || return 1
  organize_project_files
}

ensure_instruction_setup() {
  project_context || return 1
  local native
  choose_project_tool || return 1
  case "$TOOL" in codex) native=AGENTS.md ;; claude) native=CLAUDE.md ;; esac
  if [ -f "$PROJECT/$native" ] && [ -f "$PROJECT/${CTX_INSTRUCTIONS}" ] && entry_references_instructions "$PROJECT/$native"; then return 0; fi
  say 'Este projeto ainda não tem as instruções organizadas e conectadas ao agente.'
  organize_project || return 1
}

edit_instructions_terminal() {
  project_context || return 1
  local line content='' archive
  safe_project_path "${CTX_INSTRUCTIONS}" && safe_project_path "${CTX_BACKUPS}" || return 1
  say_ui 'Cole as instruções completas. FIM salva; CANCELAR preserva o arquivo atual.' 'Paste the full instructions. DONE saves; CANCEL keeps the current file.'
  while ask '> '; do
    line="$REPLY"
    case "$line" in
      CANCELAR|CANCEL) return 1 ;;
      FIM|DONE)
        text_has_content "$content" || { warn 'Instruções vazias; arquivo preservado.'; return 1; }
        [ "$(printf '%s' "$content" | wc -c | tr -d ' ')" -le 30000 ] || { warn 'Use até 30 KB nas instruções principais.'; return 1; }
        mkdir -p "$PROJECT/${CTX_BACKUPS}" || return 1
        archive="$(mktemp "$PROJECT/${CTX_BACKUPS}/${CTX_INSTRUCTIONS##*/}.XXXXXXXX")" || return 1
        cp -p "$PROJECT/${CTX_INSTRUCTIONS}" "$archive" || return 1
        put "$PROJECT/${CTX_INSTRUCTIONS}" "$content" || return 1
        say "$(ui 'Instruções salvas. Backup' 'Instructions saved. Backup'): $archive"
        say_ui 'Inicie uma nova conversa para usar as novas instruções.' 'Start a new conversation to use the new instructions.'
        return 0 ;;
    esac
    content="${content}${line}"$'\n'
    [ "${#content}" -le 30000 ] || { warn 'Instruções longas demais; arquivo preservado.'; return 1; }
  done
  return 1
}

instructions_menu() {
  project_context || return 1
  local choice
  ensure_instruction_setup || return 1
  while :; do
    header_ui 'Instruções permanentes deste projeto' 'Permanent instructions for this project'
    say_ui "Arquivo principal: ${CTX_INSTRUCTIONS}" "Main file: ${CTX_INSTRUCTIONS}"
    say_ui '1) Editar no TextEdit' '1) Edit in TextEdit'
    say_ui '2) Substituir pelo terminal (com backup)' '2) Replace in Terminal (with backup)'
    say_ui "3) Abrir pasta ${CTX_RULES} no Finder" "3) Open ${CTX_RULES} in Finder"
    say_ui '4) Criar atalhos de encerrar sessão e resumo (opcional)' '4) Create wrap-up and summary shortcuts (optional)'
    say_ui '0) Voltar' '0) Back'
    ask_ui 'Escolha: ' 'Choose: ' || return 1
    choice="$REPLY"
    case "$choice" in
      1) safe_project_path "${CTX_INSTRUCTIONS}" || return 1
         say_ui 'Salve como texto simples, mantendo a extensão .md. Depois inicie uma nova conversa.' 'Save as plain text with the .md extension, then start a new conversation.'
         edit_path "$PROJECT/${CTX_INSTRUCTIONS}" ;;
      2) edit_instructions_terminal ;;
      3) open_path "$PROJECT/${CTX_RULES}" ;;
      4) create_project_shortcuts ;;
      0) return 0 ;;
      *) say_ui 'Escolha 1, 2, 3, 4 ou 0.' 'Choose 1, 2, 3, 4, or 0.' ;;
    esac
  done
}

# Publica o arquivo completo com um hard link exclusivo, sem sobrescrever.
# O temporário nasce em pasta privada; noclobber protege sua primeira gravação.
write_new_file_atomic() {
  local relative="$1" directory temporary_dir temporary
  [ ! -L "$PROJECT" ] || { warn 'A pasta do projeto é um link simbólico. Nada foi criado.'; return 1; }
  safe_project_path "$relative" || return 1
  if [ -e "$PROJECT/$relative" ]; then
    [ -f "$PROJECT/$relative" ] || { warn "$relative existe mas não é arquivo."; return 1; }
    cat >/dev/null
    return 0
  fi
  directory="${relative%/*}"
  [ "$directory" != "$relative" ] || directory=.
  temporary_dir="$(mktemp -d "$PROJECT/$directory/.assistente-comando.XXXXXXXX")" || return 1
  temporary="$temporary_dir/novo.md"
  if ! (set -o noclobber; cat > "$temporary") || ! safe_project_path "$relative"; then
    rm -f "$temporary"; rmdir "$temporary_dir"; return 1
  fi
  # -n impede seguir um destino que virou symlink de diretório (BSD/macOS e GNU).
  if ! publish_new_file "$temporary" "$PROJECT/$relative"; then
    rm -f "$temporary"; rmdir "$temporary_dir"; return 1
  fi
  rm -f "$temporary"
  rmdir "$temporary_dir" || return 1
  safe_project_path "$relative" && [ -f "$PROJECT/$relative" ]
}

publish_new_file() {
  local staged="$1" destination="$2"
  if ln -n "$staged" "$destination" 2>/dev/null; then return 0; fi
  # Disks without hard links still allow exclusive creation.
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 1
  (
    set -o noclobber
    exec 3> "$destination" || exit 1
    if ! cat "$staged" >&3; then
      rm -f -- "$destination"
      exit 1
    fi
  )
}

create_project_shortcuts() {
  project_context || return 1
  local path name profile root relative prompt description close_name=encerrar summary_name=resumo dirs=() files=()
  [ ! -L "$PROJECT" ] || { warn 'A pasta do projeto é um link simbólico. Nada foi criado.'; return 1; }
  if [ "$APP_LANG" = en ]; then close_name=wrap-up; summary_name=summary; fi
  case "$TOOL" in
    claude)
      root=.claude/commands
      dirs=(.claude .claude/commands)
      files=(".claude/commands/$close_name.md" ".claude/commands/$summary_name.md") ;;
    codex)
      root=.agents/skills
      dirs=(.agents .agents/skills ".agents/skills/$close_name" ".agents/skills/$summary_name")
      files=(".agents/skills/$close_name/SKILL.md" ".agents/skills/$summary_name/SKILL.md") ;;
    *) return 1 ;;
  esac
  profile="$(project_profile)" || return 1
  [ "$profile" = "$TOOL" ] || return 1
  # Valida tudo antes de criar pastas; não segue links nem substitui configurações.
  for path in "${dirs[@]}"; do
    safe_project_path "$path" || return 1
    if [ -e "$PROJECT/$path" ] && [ ! -d "$PROJECT/$path" ]; then
      warn "$path existe mas não é uma pasta. Nada foi criado."; return 1
    fi
  done
  for path in "${files[@]}"; do
    safe_project_path "$path" || return 1
    if [ -e "$PROJECT/$path" ] && [ ! -f "$PROJECT/$path" ]; then
      warn "$path existe mas não é arquivo. Nada foi criado."; return 1
    fi
  done
  if [ "$TOOL" = claude ]; then
    for name in "$close_name" "$summary_name"; do safe_project_path ".claude/skills/$name" || return 1; done
  fi
  for path in "${CTX_CLOSE}" "${CTX_SUMMARY}"; do
    safe_project_path "$path" || return 1
    [ -f "$PROJECT/$path" ] || { warn "Falta $path. Organize o projeto antes de criar os comandos."; return 1; }
  done
  for path in "${dirs[@]}"; do
    safe_project_path "$path" && mkdir -p "$PROJECT/$path" || return 1
  done
  for name in "$close_name" "$summary_name"; do
    if [ "$TOOL" = claude ]; then
      relative="$root/$name.md"
      if [ -e "$PROJECT/.claude/skills/$name" ]; then
        warn "$(ui "Já existe a skill .claude/skills/$name; o comando /$name não foi criado para evitar conflito." "The .claude/skills/$name skill already exists; /$name was not created to avoid a conflict.")"
        continue
      fi
    else relative="$root/$name/SKILL.md"; fi
    if [ -e "$PROJECT/$relative" ]; then
      say "$(ui 'Preservado' 'Preserved') $relative ($(ui 'já existe' 'already exists'))."
      continue
    fi
    case "$name" in
      encerrar|wrap-up) prompt="$CTX_CLOSE"; description="$(ui 'Encerrar a sessão e registrar o andamento quando o usuário pedir para encerrar o trabalho.' 'Wrap up the session and record progress when the user asks to finish the work.')" ;;
      resumo|summary) prompt="$CTX_SUMMARY"; description="$(ui 'Resumir o contexto da conversa quando o usuário pedir um resumo para continuar em outra sessão.' 'Summarize conversation context when the user asks for a handoff to another session.')" ;;
    esac
    if [ "$TOOL" = claude ]; then
      printf '@%s\n' "$prompt" | write_new_file_atomic "$relative" || return 1
    else
      printf '%s\n' '---' "name: $name" "description: $description" '---' '' \
        "$(ui 'Use esta skill somente quando o usuário pedir esta ação.' 'Use this skill only when the user requests this action.')" \
        "$(ui "Leia $prompt a partir da raiz deste projeto e execute o pedido desse arquivo." "Read $prompt from this project root and carry out that request.")" \
        "$(ui 'Preserve o trabalho existente e registre apenas fatos confirmados.' 'Preserve existing work and record only confirmed facts.')" | write_new_file_atomic "$relative" || return 1
    fi
    say "$(ui 'Criado' 'Created') $relative."
  done
  if [ "$TOOL" = claude ]; then
    say "$(ui "Abra uma nova sessão do Claude Code neste projeto; use /$close_name ou /$summary_name se o atalho estiver disponível." "Open a new Claude Code session in this project; use /$close_name or /$summary_name if available.")"
  else say "$(ui "Abra uma nova sessão do Codex neste projeto; use \$$close_name ou \$$summary_name." "Open a new Codex session in this project; use \$$close_name or \$$summary_name.")"; fi
}

create_claude_commands() {
  [ "$TOOL" = claude ] || { warn 'Os comandos rápidos desta opção são do Claude Code.'; return 1; }
  create_project_shortcuts
}

# --- Verificação da estrutura do projeto -----------------------------------
PROMPT_LARGE_BYTES=8000
INSTRUCTION_MARKER='<!-- assistente-ia: instrucoes-do-projeto -->'

file_bytes() { wc -c < "$1" | tr -d ' '; }

# Imprime ' (grande — ...)' quando o arquivo parece documento, não prompt.
prompt_size_note() {
  project_context || return 1
  [ -f "$1" ] && [ -r "$1" ] || return 0
  [ "$(file_bytes "$1")" -le "$PROMPT_LARGE_BYTES" ] || printf " (grande — parece documento; melhor em ${CTX_DOCS}/)"
}

# Lista (um por linha) os .md/.txt grandes diretamente em PROMPTS/.
large_prompt_files() {
  project_context || return 1
  local file
  [ -d "$PROJECT/${CTX_PROMPTS}" ] && [ ! -L "$PROJECT/${CTX_PROMPTS}" ] || return 0
  for file in "$PROJECT/${CTX_PROMPTS}"/*.md "$PROJECT/${CTX_PROMPTS}"/*.txt "$PROJECT/${CTX_PROMPTS}"/*.MD "$PROJECT/${CTX_PROMPTS}"/*.TXT; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    [ "$(file_bytes "$file")" -le "$PROMPT_LARGE_BYTES" ] || printf '%s\n' "$file"
  done
}

project_native_entry() {
  local tool
  tool="$SESSION_TOOL"
  if [ -z "$tool" ]; then tool="$(project_profile)" || return 1; fi
  case "$tool" in codex) printf AGENTS.md ;; claude) printf CLAUDE.md ;; *) return 1 ;; esac
}

# Aviso forte: o objetivo ainda é o texto-modelo.
instructions_unfilled() {
  project_context || return 1
  local file="$PROJECT/${CTX_INSTRUCTIONS}"
  [ -f "$file" ] && [ ! -L "$file" ] && LC_ALL=C /usr/bin/grep -Fxq -e "$OBJECTIVE_PLACEHOLDER" -e "$OBJECTIVE_PLACEHOLDER_EN" -e "$OBJECTIVE_PLACEHOLDER_ES" "$file"
}

# Aviso leve: objetivo escrito, mas restam trechos do modelo (contexto/requisitos).
instructions_details_pending() {
  project_context || return 1
  local file="$PROJECT/${CTX_INSTRUCTIONS}"
  [ -f "$file" ] && [ ! -L "$file" ] && ! instructions_unfilled &&
    LC_ALL=C /usr/bin/grep -Eq '[Pp]reencha|[Dd]escreva o neg|[Ff]ill in|[Dd]escribe the business' "$file"
}

# Arquivo sem nenhuma linha fora do modelo (e da seção Eficiência): não há texto do usuário a proteger.
instructions_pristine() {
  project_context || return 1
  local file="$PROJECT/${CTX_INSTRUCTIONS}" template extra
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  template="$(mktemp "${TMPDIR:-/tmp}/assistente-modelo.XXXXXXXX")" || return 1
  { instructions_template_text; efficiency_section; } > "$template"
  extra="$(LC_ALL=C /usr/bin/grep -vxF -f "$template" "$file" | LC_ALL=C /usr/bin/grep -c '[^[:space:]]')"
  rm -f "$template"
  [ "${extra:-1}" = 0 ]
}

# Rótulo amigável do peso (bytes/4 ≈ tokens).
weight_label() {
  local tokens=$(( $1 / 4 ))
  if [ "$tokens" -ge 1000 ]; then
    if [ "$APP_LANG" = en ]; then printf '~%s.%sk tokens' "$((tokens/1000))" "$(((tokens%1000)/100))"
    else printf '~%s,%s mil tokens' "$((tokens/1000))" "$(((tokens%1000)/100))"; fi
  else printf '~%s tokens' "$tokens"; fi
}

# Aceita o marcador do kit ou qualquer referência direta (ex.: @INSTRUCOES/PROJETO.md).
entry_references_instructions() {
  project_context || return 1
  /usr/bin/grep -Fq "$INSTRUCTION_MARKER" "$1" 2>/dev/null || /usr/bin/grep -Fq "$CTX_INSTRUCTIONS" "$1" 2>/dev/null
}
entry_connected() {
  local native="$1"
  [ -n "$native" ] && [ -f "$PROJECT/$native" ] && [ ! -L "$PROJECT/$native" ] &&
    entry_references_instructions "$PROJECT/$native"
}

FIXED_WEIGHT_WARN_BYTES=12000
ANDAMENTO_WARN_BYTES=8000

# Bytes lidos em toda conversa: arquivo de entrada + INSTRUCOES/PROJETO.md.
fixed_weight_bytes() {
  project_context || return 1
  local total=0 file native="${1:-}" bytes
  if [ -z "$native" ]; then native="$(project_native_entry)" || native=''; fi
  for file in "$native" "${CTX_INSTRUCTIONS}"; do
    [ -n "$file" ] && [ -f "$PROJECT/$file" ] && [ ! -L "$PROJECT/$file" ] || continue
    bytes="$(file_bytes "$PROJECT/$file")" || continue
    total=$((total+bytes))
  done
  printf '%s' "$total"
}

andamento_bytes() {
  project_context || return 1
  local file="$PROJECT/${CTX_PROGRESS}"
  [ -f "$file" ] && [ ! -L "$file" ] || { printf 0; return 0; }
  file_bytes "$file"
}

has_efficiency_section() {
  project_context || return 1
  [ -f "$PROJECT/${CTX_INSTRUCTIONS}" ] && [ ! -L "$PROJECT/${CTX_INSTRUCTIONS}" ] &&
    /usr/bin/grep -Fq -e '## Eficiência' -e '## Efficiency' -e '## Eficiencia' "$PROJECT/${CTX_INSTRUCTIONS}"
}

missing_default_prompts() {
  project_context || return 1
  local name
  for name in "${CTX_CLOSE##*/}" "${CTX_SUMMARY##*/}"; do
    [ -e "$PROJECT/${CTX_PROMPTS}/$name" ] || [ -L "$PROJECT/${CTX_PROMPTS}/$name" ] || printf '%s\n' "$name"
  done
}

append_efficiency_section() {
  project_context || return 1
  local file="$PROJECT/${CTX_INSTRUCTIONS}" archive temporary
  safe_project_path "${CTX_INSTRUCTIONS}" && safe_project_path "${CTX_BACKUPS}" || return 1
  [ -f "$file" ] || return 1
  mkdir -p "$PROJECT/${CTX_BACKUPS}" || return 1
  archive="$(mktemp "$PROJECT/${CTX_BACKUPS}/${CTX_INSTRUCTIONS##*/}.XXXXXXXX")" || return 1
  cp -p "$file" "$archive" || return 1
  temporary="$(mktemp "$file.XXXXXXXX")" || return 1
  keep_file_mode "$file" "$temporary"
  if ! { cat "$file"; printf '\n'; efficiency_section; } > "$temporary" || ! mv -f "$temporary" "$file"; then
    rm -f "$temporary"; return 1
  fi
  say "Seção Eficiência adicionada. Backup: $archive"
}

create_missing_default_prompts() {
  project_context || return 1
  local name
  safe_project_path "${CTX_PROMPTS}" || return 1
  mkdir -p "$PROJECT/${CTX_PROMPTS}" || return 1
  for name in "${CTX_CLOSE##*/}" "${CTX_SUMMARY##*/}"; do
    [ ! -e "$PROJECT/${CTX_PROMPTS}/$name" ] && [ ! -L "$PROJECT/${CTX_PROMPTS}/$name" ] || continue
    case "$name" in
      "${CTX_CLOSE##*/}") prompt_encerrar_text | write_new_file "${CTX_PROMPTS}/$name" || return 1 ;;
      "${CTX_SUMMARY##*/}") prompt_resumo_text | write_new_file "${CTX_PROMPTS}/$name" || return 1 ;;
    esac
    say "Criado ${CTX_PROMPTS}/$name"
  done
}

# Avisos curtos e sem perguntas (no máximo 3 linhas), por prioridade.
project_quick_warnings() {
  project_context || return 1
  local native count=0 file shown=0 weight
  [ -n "$PROJECT" ] && [ -d "$PROJECT" ] || return 0
  if instructions_unfilled; then
    say "Aviso: ${CTX_INSTRUCTIONS} ainda é o modelo. Escreva o objetivo e as regras (menu 6 → 9)."
    shown=$((shown+1))
  elif instructions_details_pending; then
    say "Aviso leve: faltam detalhes em ${CTX_INSTRUCTIONS} (contexto e requisitos). Não é obrigatório para começar."
    shown=$((shown+1))
  fi
  while IFS= read -r file; do
    [ -n "$file" ] && count=$((count+1))
  done <<EOF
$(large_prompt_files)
EOF
  if [ "$count" -gt 0 ] && [ "$shown" -lt 3 ]; then
    say "Aviso: $count arquivo(s) grande(s) em ${CTX_PROMPTS}/ parecem documentos; mova para ${CTX_DOCS}/ (menu 6 → 12)."
    shown=$((shown+1))
  fi
  native="$(project_native_entry)" || native=''
  if ! entry_connected "$native" && [ "$shown" -lt 3 ]; then
    say 'Aviso: a entrada da ferramenta (AGENTS.md/CLAUDE.md) não aponta para as instruções (menu 6 → 11).'
    shown=$((shown+1))
  fi
  weight="$(fixed_weight_bytes)"
  if [ "$weight" -gt "$FIXED_WEIGHT_WARN_BYTES" ] && [ "$shown" -lt 3 ]; then
    say "Aviso: instruções fixas pesadas ($(weight_label "$weight") por conversa); enxugue ${CTX_INSTRUCTIONS}."
    shown=$((shown+1))
  fi
  if [ "$(andamento_bytes)" -gt "$ANDAMENTO_WARN_BYTES" ] && [ "$shown" -lt 3 ]; then
    say "Aviso: ${CTX_PROGRESS} está grande; condense com o prompt ${CTX_CLOSE##*/}."
    shown=$((shown+1))
  fi
  return 0
}

doctor_line() {
  if [ "$1" = ok ]; then printf '  ✓ %s\n' "$2"; else printf '  ! %s\n' "$2"; fi
}

move_prompt_to_docs() {
  project_context || return 1
  local file="$1" name
  name="$(basename "$file")"
  safe_project_path "${CTX_PROMPTS}/$name" && safe_project_path "${CTX_DOCS}" || return 1
  if [ -e "$PROJECT/${CTX_DOCS}/$name" ] || [ -L "$PROJECT/${CTX_DOCS}/$name" ]; then
    warn "Já existe ${CTX_DOCS}/$name. Nada foi movido."
    return 1
  fi
  mkdir -p "$PROJECT/${CTX_DOCS}" || return 1
  safe_project_path "${CTX_DOCS}/$name" || return 1
  mv -n "$file" "$PROJECT/${CTX_DOCS}/$name" || return 1
  [ ! -e "$file" ] || { warn "Não consegui mover $name."; return 1; }
  say "Movido para ${CTX_DOCS}/$name"
}

# Objetivo em uma frase: preenche só as linhas ainda em modelo (nunca sobrescreve texto seu).
OBJECTIVE_PLACEHOLDER='- Objetivo: preencha o que deseja construir e para quem.'
README_PLACEHOLDER='Descreva a finalidade do projeto.'
OBJECTIVE_PLACEHOLDER_ES='- Objetivo: describe qué quieres crear y para quién.'
OBJECTIVE_PLACEHOLDER_EN='- Goal: describe what you want to build and for whom.'
README_PLACEHOLDER_ES='Describe el propósito del proyecto.'
README_PLACEHOLDER_EN='Describe the purpose of the project.'

# Mantém as permissões do arquivo original ao regravá-lo (GNU stat, com alternativa do macOS).
# A ordem importa: no Linux, "stat -f" lista o sistema de arquivos e não falha de forma limpa.
keep_file_mode() {
  local mode=''
  mode="$(stat -c %a "$1" 2>/dev/null)" || mode=''
  case "$mode" in ''|*[!0-7]*) mode="$(stat -f %Lp "$1" 2>/dev/null)" || mode='' ;; esac
  case "$mode" in [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) chmod "$mode" "$2" 2>/dev/null ;; esac
  return 0
}

replace_first_line() {
  local file="$1" old="$2" new="$3" temporary line found=1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  temporary="$(mktemp "$file.XXXXXXXX")" || return 1
  keep_file_mode "$file" "$temporary"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$found" -ne 0 ] && [ "$line" = "$old" ]; then printf '%s\n' "$new"; found=0
    else printf '%s\n' "$line"; fi
  done < "$file" > "$temporary"
  if [ "$found" -ne 0 ] || ! mv -f "$temporary" "$file"; then rm -f "$temporary"; return 1; fi
}

objective_pending() {
  project_context || return 1
  [ -f "$PROJECT/${CTX_INSTRUCTIONS}" ] && [ ! -L "$PROJECT/${CTX_INSTRUCTIONS}" ] &&
    /usr/bin/grep -Fxq -e "$OBJECTIVE_PLACEHOLDER" -e "$OBJECTIVE_PLACEHOLDER_EN" -e "$OBJECTIVE_PLACEHOLDER_ES" "$PROJECT/${CTX_INSTRUCTIONS}" && return 0
  [ -f "$PROJECT/README.md" ] && [ ! -L "$PROJECT/README.md" ] &&
    /usr/bin/grep -Fxq -e "$README_PLACEHOLDER" -e "$README_PLACEHOLDER_EN" "$PROJECT/README.md"
}

fill_project_objective() {
  project_context || return 1
  local text="$1" archive done_files='' placeholder readme_placeholder
  safe_project_path "${CTX_INSTRUCTIONS}" && safe_project_path README.md && safe_project_path "${CTX_BACKUPS}" || return 1
  placeholder="$OBJECTIVE_PLACEHOLDER"
  [ "$CTX_LANGUAGE" != es ] || placeholder="$OBJECTIVE_PLACEHOLDER_ES"
  if [ -f "$PROJECT/${CTX_INSTRUCTIONS}" ] && /usr/bin/grep -Fxq -e "$OBJECTIVE_PLACEHOLDER_EN" "$PROJECT/${CTX_INSTRUCTIONS}"; then placeholder="$OBJECTIVE_PLACEHOLDER_EN"; fi
  if [ -f "$PROJECT/${CTX_INSTRUCTIONS}" ] && /usr/bin/grep -Fxq -e "$placeholder" "$PROJECT/${CTX_INSTRUCTIONS}"; then
    # Arquivo ainda igual ao modelo: nada do usuário a proteger, então sem backup.
    if ! instructions_pristine; then
      mkdir -p "$PROJECT/${CTX_BACKUPS}" || return 1
      archive="$(mktemp "$PROJECT/${CTX_BACKUPS}/${CTX_INSTRUCTIONS##*/}.XXXXXXXX")" || return 1
      cp -p "$PROJECT/${CTX_INSTRUCTIONS}" "$archive" || return 1
    fi
    if [ "$placeholder" = "$OBJECTIVE_PLACEHOLDER_EN" ]; then
      replace_first_line "$PROJECT/${CTX_INSTRUCTIONS}" "$placeholder" "- Goal: $text" && done_files="$CTX_INSTRUCTIONS"
    else
      replace_first_line "$PROJECT/${CTX_INSTRUCTIONS}" "$placeholder" "- Objetivo: $text" && done_files="$CTX_INSTRUCTIONS"
    fi
  fi
  readme_placeholder="$README_PLACEHOLDER"
  [ "$CTX_LANGUAGE" != es ] || readme_placeholder="$README_PLACEHOLDER_ES"
  if [ -f "$PROJECT/README.md" ] && /usr/bin/grep -Fxq -e "$README_PLACEHOLDER_EN" "$PROJECT/README.md"; then readme_placeholder="$README_PLACEHOLDER_EN"; fi
  if replace_first_line "$PROJECT/README.md" "$readme_placeholder" "$text"; then
    done_files="${done_files:+$done_files e }README.md"
  fi
  [ -n "$done_files" ] || { say_ui 'Nada a preencher: o objetivo já foi escrito.' 'Nothing to fill in: the goal is already written.'; return 0; }
  say "$(ui 'Objetivo registrado em' 'Goal recorded in') $done_files."
  [ -z "$archive" ] || say "$(ui "Backup de $CTX_INSTRUCTIONS" "$CTX_INSTRUCTIONS backup"): $archive"
  say_ui 'Quando quiser, complete o contexto e os requisitos em Cuidar do projeto → 9.' 'When ready, complete the context and requirements under Project care → 9.'
  say_ui 'Depois de editar as instruções, comece uma conversa nova.' 'Start a new conversation after editing the instructions.'
}

ask_project_objective() {
  project_context || return 1
  local text
  say_ui 'Em uma frase, para que serve este projeto? (Enter pula. Depois você preenche em Cuidar do projeto → 9, Editar as instruções.)' 'In one sentence, what is this project for? (Enter skips. You can fill this in later under Project care → 9, Edit instructions.)'
  ask '> ' || return 1
  text="$REPLY"
  text="${text#"${text%%[![:space:]]*}"}"; text="${text%"${text##*[![:space:]]}"}"
  text_has_content "$text" || return 0
  single_line "$text" || { warn 'Use uma linha só, sem tabulação.'; return 1; }
  [ "${#text}" -le 300 ] || { warn "Use até 300 caracteres; detalhes vão em ${CTX_INSTRUCTIONS}."; return 1; }
  fill_project_objective "$text"
}

project_doctor() {
  project_context || return 1
  local folder native profile file name issues=0 large=() weight missing
  ensure_project || return 1
  header_ui 'Verificar estrutura do projeto' 'Check project structure'
  for folder in "${CTX_RULES}" "${CTX_PROMPTS}" "${CTX_DOCS}" "${CTX_ATTACHMENTS}"; do
    if [ -d "$PROJECT/$folder" ] && [ ! -L "$PROJECT/$folder" ]; then doctor_line ok "$(ui 'Pasta' 'Folder') $folder/"
    else doctor_line warn "$(ui 'Pasta' 'Folder') $folder/ $(ui 'ausente ou inválida (menu 6 → 11 cria a estrutura)' 'missing or invalid (menu 6 → 11 creates the layout)')"; issues=$((issues+1)); fi
  done
  profile="$(project_profile)" || profile=''
  if [ -n "$profile" ]; then doctor_line ok "$(ui 'Perfil da ferramenta' 'Agent profile'): $profile"
  else doctor_line warn "$(ui 'Perfil da ferramenta indefinido (.assistente-ia/tool)' 'Agent profile undefined (.assistente-ia/tool)')"; issues=$((issues+1)); fi
  native="$(project_native_entry)" || native=''
  if entry_connected "$native"; then doctor_line ok "$native $(ui 'aponta para' 'points to') ${CTX_INSTRUCTIONS}"
  else doctor_line warn "$(ui 'Arquivo de entrada ausente ou sem referência às instruções (menu 6 → 11)' 'Entry file missing or not linked to instructions (menu 6 → 11)')"; issues=$((issues+1)); fi
  if [ ! -f "$PROJECT/${CTX_INSTRUCTIONS}" ]; then
    doctor_line warn "$CTX_INSTRUCTIONS $(ui 'não existe' 'does not exist')"; issues=$((issues+1))
  elif instructions_unfilled; then
    doctor_line warn "$CTX_INSTRUCTIONS $(ui 'ainda é o modelo. Escreva o objetivo e as regras (menu 6 → 9)' 'is still a template. Write the goal and rules (menu 6 → 9)')"; issues=$((issues+1))
  elif instructions_details_pending; then
    doctor_line ok "$CTX_INSTRUCTIONS $(ui 'com objetivo escrito' 'has a written goal')"
    say_ui "  → Faltam detalhes em ${CTX_INSTRUCTIONS} (contexto e requisitos). Não é obrigatório para começar." "  → ${CTX_INSTRUCTIONS} lacks context and requirements. You can start without them."
  else doctor_line ok "$CTX_INSTRUCTIONS $(ui 'preenchido' 'filled in')"; fi
  for file in AGENTS.md CLAUDE.md; do
    [ "$file" != "$native" ] && [ -e "$PROJECT/$file" ] || continue
    if entry_connected "$file"; then
      doctor_line ok "$file $(ui 'aponta para' 'points to') ${CTX_INSTRUCTIONS}"
    else
      doctor_line warn "$file $(ui 'usa instruções próprias; revise a referência para compartilhar contexto' 'uses independent instructions; review its link to share context')"
      issues=$((issues+1))
    fi
  done
  while IFS= read -r file; do
    [ -n "$file" ] && large[${#large[@]}]="$file"
  done <<EOF
$(large_prompt_files)
EOF
  if [ "${#large[@]}" -eq 0 ]; then doctor_line ok "$(ui 'PROMPTS/ só tem pedidos curtos' 'PROMPTS/ contains only short prompts')"
  else
    for file in "${large[@]}"; do
      name="$(basename "$file")"
      doctor_line warn "${CTX_PROMPTS}/$name $(ui 'é grande' 'is large') (~$(( $(file_bytes "$file") / 1024 )) KB); $(ui 'parece documento' 'looks like a document')"
      issues=$((issues+1))
    done
    say ''
    for file in "${large[@]}"; do
      name="$(basename "$file")"
      ask "$(ui 'Mover' 'Move') \"$name\" $(ui 'para' 'to') ${CTX_DOCS}/? $(ui '[s/N]' '[y/N]'): " || return 1
      case "$REPLY" in s|S|y|Y) move_prompt_to_docs "$file" || true ;; *) say_ui "Mantido em ${CTX_PROMPTS}/." "Kept in ${CTX_PROMPTS}/." ;; esac
    done
  fi
  weight="$(fixed_weight_bytes)"
  if [ "$weight" -gt "$FIXED_WEIGHT_WARN_BYTES" ]; then
    doctor_line warn "$(ui 'Instruções fixas pesadas' 'Large permanent instructions') ($(weight_label "$weight") $(ui 'em toda conversa); enxugue' 'in every conversation); shorten them')"; issues=$((issues+1))
  else doctor_line ok "$(ui 'Instruções fixas leves' 'Light permanent instructions') ($(weight_label "$weight") $(ui 'por conversa' 'per conversation'))"; fi
  if [ "$(andamento_bytes)" -gt "$ANDAMENTO_WARN_BYTES" ]; then
    doctor_line warn "$CTX_PROGRESS $(ui 'está grande (mais de 8 KB). Use o pedido' 'is large (over 8 KB). Use the prompt') $CTX_CLOSE"; issues=$((issues+1))
  fi
  if [ -f "$PROJECT/${CTX_INSTRUCTIONS}" ] && ! has_efficiency_section; then
    say_ui "  → Dica: $CTX_INSTRUCTIONS sem a seção Eficiência (economia de tokens)." "  → Tip: $CTX_INSTRUCTIONS lacks the Efficiency section (token savings)."
    ask_ui 'Adicionar a seção ao final (com backup)? [s/N]: ' 'Append the section (with backup)? [y/N]: ' || REPLY=''
    case "$REPLY" in s|S|y|Y) append_efficiency_section || true ;; *) say_ui 'Mantido como está.' 'Kept as is.' ;; esac
  fi
  missing="$(missing_default_prompts)"
  if [ -n "$missing" ]; then
    say "  → $(ui 'Dica: faltam pedidos prontos (prompts) em' 'Tip: default saved prompts are missing in') ${CTX_PROMPTS}/: $(printf '%s' "$missing" | tr '\n' ' ')"
    ask_ui 'Criar os pedidos prontos que faltam (sem sobrescrever)? [s/N]: ' 'Create the missing saved prompts (without overwriting)? [y/N]: ' || REPLY=''
    case "$REPLY" in s|S|y|Y) create_missing_default_prompts || true ;; *) say_ui 'Nada criado.' 'Nothing created.' ;; esac
  fi
  say ''
  if objective_pending; then
    doctor_line warn "$(ui 'O objetivo do projeto ainda está em modelo' 'The project goal is still a placeholder') ($CTX_INSTRUCTIONS / README.md)"
    issues=$((issues+1))
    ask_project_objective || true
    say ''
  fi
  if [ "$issues" -eq 0 ]; then say_ui 'Tudo certo com a estrutura.' 'Project structure looks good.'; fi
  say_ui "Instruções permanentes ficam em ${CTX_INSTRUCTIONS}." "Permanent instructions live in ${CTX_INSTRUCTIONS}."
  say_ui "$CTX_PROMPTS/ é só para pedidos reutilizáveis escolhidos um a um; requisitos e referências ficam em ${CTX_DOCS}/." "$CTX_PROMPTS/ is for reusable requests selected one at a time; requirements and references belong in ${CTX_DOCS}/."
}

# Assistente IA 1.0 Professional: auditoria e evolução (build 3)

Data: 27/11/2026. A versão pública continua **1.0** (`VERSION='1.0'`). O build interno passou de **2** para **3** (`lib/build-number`).

Este documento registra o que foi verificado, corrigido e acrescentado, com os resultados reais das execuções. Não afirma que o sistema está livre de bugs ou vulnerabilidades. As plataformas que não puderam ser executadas aparecem como **não verificadas**.

## 1. Commit inicial e entrega

| Item | Valor |
|---|---|
| Repositório | `Anglersondev/Codex-CLI-Claude-Code-Workspace` |
| Commit inicial | `ae8d800f425c442629726f5829c34484feffc761` (tag `v1.0`, 23/11/2026, "Ship Assistente IA 1.0 build 2 with project tools and macOS screenshots") |
| Branch de trabalho | `audit/1.0-professional`, somente local |
| Publicação | Nenhum push, tag, release ou comentário no GitHub. A entrega é um ZIP com o código e este relatório. |

Commits locais, em ordem:

1. `Fix Linux stat, efforts per agent, safe backups and Windows argument passing`
2. `Add prompt library, command palette, alternate-agent review and pro tools to the panel`
3. `Share the prompt library with the terminal and app bridge; add 1.0 Professional regression tests`
4. `Run tests on every push with least privilege, package the new panel modules, build 3`
5. `Document the 1.0 Professional audit, build 3` (documentação, rótulo e aspas no comando sugerido)

## 2. Escopo analisado

- Launcher de terminal em Bash 3.2 (`ASSISTENTE-IA-MAC.command`, também usado no Linux) e bibliotecas `lib/*.sh`, incluindo a ponte `--app` usada pelo app nativo do macOS.
- Painel Python/Tkinter para Linux e Windows (`desktop/core.py`, `panel.py`, `workflows.py`, `workflows.json`) e empacotamento (`desktop/package.sh`).
- Launcher PowerShell do Windows (`ASSISTENTE-IA-WINDOWS.ps1` e os `.cmd`).
- App SwiftUI do macOS (`macOS/*.swift`, `macOS/build.sh`, traduções `*.lproj`). O código foi lido. **Não foi compilado** (ver Limitações).
- Workflow do GitHub Actions e a execução `45254705331`, consultados por leitura na API.
- README nos três idiomas, `CHANGELOG.md`, `GUIA-DE-USO.md`, `MUDANCAS-E-TESTES.md`, `RTK.md`, as auditorias de 22 e 23/10/2026 e os resultados anteriores em `tests/`.
- Documentação oficial: Claude Code (`code.claude.com/docs`: CLI, settings, model-config, memory, statusline, hooks, plugins) e Codex (`developers.openai.com/codex`, que hoje redireciona para `learn.chatgpt.com`: CLI, config reference, AGENTS.md, hooks, permissões).

## 3. Causa real da falha do GitHub Actions

Execução `45254705331` (tag `v1.0`, 23/11/2026 19:59 UTC): Linux e Windows aprovados, macOS **cancelado**, execução geral com falha.

**Causa confirmada:** o job `macos` (`runs-on: macos-15`, Apple silicon) nunca recebeu um runner. A anotação do GitHub diz: *"The job was not acquired by Runner of type hosted even after multiple attempts"* e *"Due to capacity constraints, jobs targeting macOS arm64 runners may experience longer queue times."* Nenhum passo foi executado, então a falha não veio do código. A execução anterior da mesma tag (`45250766834`, 19:36 UTC) passou no macOS com 365 testes.

Defeitos reais encontrados no workflow, independentes da capacidade do runner:

| # | Severidade | Onde (commit inicial) | Problema | Correção |
|---|---|---|---|---|
| CI-1 | Alta | `.github/workflows/macos-app.yml`, passo "Attach bundle" | A lista de arquivos incluía `Assistente-IA-Build-*.txt`, mas nenhum passo gerava esse arquivo. Sem correspondência, o Bash passa o padrão literal e o `gh release upload` falha. Os apps usam esse arquivo para detectar builds novos da 1.0 (`Updates.swift`, `core.check_release`). | O build agora grava `Assistente-IA-Build-<n>.txt` com versão, build, commit, versão do macOS e do Swift e o tipo de assinatura. O SHA-256 cobre esse arquivo também. |
| CI-2 | Média | Mesmo passo | Com a release já publicada, o job imprimia "already published" e terminava com sucesso, sem anexar nada. Na execução de 19:36 isso aconteceu de fato. | Agora falha com `::error::` e não substitui nada. Arquivos só são substituídos (`--clobber`) quando a release ainda é rascunho. |
| CI-3 | Média | Job `portable-tests` no Windows | No `pwsh`, só o código de saída do último comando era considerado. Uma falha em `test_desktop.py` ficava escondida se o `--smoke-test` seguinte passasse. | `$PSNativeCommandUseErrorActionPreference = $true` com `$ErrorActionPreference = 'Stop'`. |
| CI-4 | Média | Topo do workflow | `permissions: contents: write` valia para todos os jobs que não a redefiniam. | `permissions: {}` no topo. Os testes recebem `contents: read`, e só o job do macOS recebe `contents: write`. |
| CI-5 | Média | Gatilhos | Os testes só rodavam em tags. Pushes e pull requests não eram testados. | Novo `.github/workflows/tests.yml` (push em `main`, pull requests, execução manual e chamada pelo workflow de release), com token somente leitura. |
| CI-6 | Baixa | Testes no Linux | O CI rodava apenas `test_desktop.py` e `test_workflows.py` no Linux. Os testes do launcher Bash e do RTK não rodavam no Linux, por isso as 5 falhas da seção 6 passaram despercebidas. | O Linux roda `--check`, `tests/test_rtk.sh` e a suíte Python inteira. O Windows roda também `test_windows_launcher.py` e `test_pro.py`. |
| CI-7 | Baixa | Job `macos` | Sem `timeout-minutes` e sem forma de repetir uma tag depois de falta de runner. | `timeout-minutes: 45` e `workflow_dispatch` com o nome da tag, validado por expressão regular. |

A mensagem "Node.js 20 is deprecated" vem do `actions/checkout@v4.2.2` fixado por SHA. É só um aviso e não foi alterada, porque não consegui verificar aqui o SHA de uma versão mais nova.

## 4. Problemas confirmados, causas e correções

Severidade segue a ordem pedida: **P0** segurança, corrupção de dados e operações destrutivas; **P1** bugs funcionais, estabilidade e compatibilidade; **P2** integração com agentes e contexto; **P3** desempenho.

| ID | Sev. | Arquivo e linha no commit inicial | Problema e causa | Correção (arquivo atual) | Teste de regressão |
|---|---|---|---|---|---|
| S1 | P0 | `ASSISTENTE-IA-WINDOWS.ps1:` função de início de sessão (`& $tool @argsList`) | No Windows, `codex` e `claude` instalados pelo npm são shims `.cmd`. O PowerShell executa o `.cmd` pelo `cmd.exe`, que reinterpreta `&`, `\|`, `%`, `^` e aspas. Um pedido como `A & calc` podia executar um comando (classe de falha conhecida como BatBadBut). | `Resolve-AgentCommand` usa o `.exe` nativo ou `node.exe` com o script do pacote npm, sem passar pelo `cmd.exe`. `ConvertTo-NativeArgument` aplica as regras de aspas do CreateProcess/MSVCRT, e `Invoke-Agent` devolve o código de saída real (`ASSISTENTE-IA-WINDOWS.ps1:43-88`). | `tests/test_windows_launcher.py::test_prompt_arguments_reach_the_program_unchanged` (aspas, barras, `& \| % ^ < > !`, quebra de linha, acentos e CJK). |
| S2 | P0 | `ASSISTENTE-IA-WINDOWS.ps1:` opção 5 de cuidados (`ZipFile::CreateFromDirectory`) | O backup do Windows incluía `.env`, chaves, `.git`, `node_modules` e seguia links. Compartilhar o ZIP expunha credenciais. | `Write-ProjectZip` aplica `lib/backup-excludes.txt`, ignora reparse points e cria o arquivo com `CreateNew`, sem sobrescrever. A cópia completa só acontece se o usuário pedir. | `test_safe_zip_skips_credentials_dependencies_and_links`, `test_zip_never_overwrites_an_existing_file`. |
| S3 | P0 | `ASSISTENTE-IA-MAC.command:1108-1109` (`zip -qry` ou `ditto` da pasta inteira) | Mesmo problema no terminal do macOS e do Linux: o ZIP levava credenciais, `.git` e dependências. | `backup_project` pergunta antes: Enter cria a cópia segura, `c` cria a completa e qualquer outra tecla cancela. `backup_entries_list` usa as mesmas regras do painel e não segue links. | `tests/test_pro.py::test_safe_backup_filters_match_between_shell_and_python`. |
| S4 | P0 | `desktop/core.py:385` (`archive.write(path, …)`) | Entre a prévia e a gravação, um arquivo podia ser trocado por link simbólico. O `zipfile` seguia o link e gravava no ZIP um arquivo de fora do projeto, como `~/.ssh/id_rsa`. É uma condição de corrida do tipo TOCTOU. | `add_backup_entry` abre com `O_NOFOLLOW`, confere `fstat` (arquivo regular) e copia pelo descritor já aberto (`desktop/core.py:374-390`). | Testes de backup existentes em `test_desktop.py` e o de paridade em `test_pro.py`. |
| S5 | P0 | `lib/backup-excludes.txt` (11 regras) | A lista não cobria `.npmrc`, `.pypirc`, `.netrc`, `.git-credentials`, `.aws`, `.ssh`, `.gnupg`, `.kube`, `.docker`, `*.p12`, `*.pfx`, `*.keystore`, `*.jks`, `*.kdbx`, `*.tfstate` e caches comuns. | Lista ampliada para 52 regras, com exceções `!.env.example`, `!.env.sample` e `!.env.template`. É a mesma para Bash, Python, PowerShell e Swift. | Mesmos testes de S2 e S3. |
| S6 | P1 | `ASSISTENTE-IA-MAC.command:643-649` e `lib/app.sh` (`launch`, `profile-save`) | O esforço salvo era enviado sem validação. Um nível de um agente (por exemplo `ultra`) podia ir para o outro, e um valor editado no arquivo chegava ao `-c model_reasoning_effort="…"` do Codex. | `valid_effort` aceita só os níveis documentados: Codex `low`, `medium`, `high`, `xhigh`, `max`, `ultra`; Claude Code `low`, `medium`, `high`, `xhigh`, `max`, `ultracode`. Vazio significa o padrão do modelo. Aplicado ao carregar preferências, ao abrir pela ponte do app e ao salvar perfil. | `test_pro.py::test_efforts_are_validated_per_agent` (inclui `codex:high;rm` e `claude:MAX`). |
| B1 | P1 | `lib/projects.sh:941` (`stat -f %Lp … \|\| stat -c %a`) | No Linux, `stat -f` é o modo de sistema de arquivos do GNU stat e devolve sucesso com outro conteúdo. A permissão do arquivo virava `600` em vez de `644` ao preencher o objetivo. | `keep_file_mode` tenta `stat -c %a` primeiro e só aceita um número octal. | `test_objetivo.py::test_o09…` (falhava antes; passa agora). |
| B2 | P1 | `lib/painel.sh:49` (`stat -f %m … \|\| stat -c %Y`) | Mesma causa: no Linux a data de modificação vinha errada, e o painel de uso tratava a statusline antiga como atual (mostrava ~230 mil tokens em vez de ~40 mil). | `painel_mtime` tenta `stat -c %Y` e valida o número antes de cair para `stat -f %m`. | `test_painel.py::test_s13…` (falhava antes; passa agora). |
| B3 | P1 | `desktop/core.py:403-408` (restauração) | ZIPs criados pelo app do macOS começam com `./`. A restauração do painel rejeitava o componente `.`, então uma cópia feita no Mac não restaurava no Linux nem no Windows. | O prefixo `./` inicial é aceito. Os demais componentes continuam validados, e a restauração confere o espaço livre antes de extrair. | `test_pro.py::RestoreTests` (aceita `./`, rejeita `./../`, caminho absoluto e nomes duplicados sem diferença de maiúsculas). |
| B4 | P1 | `macOS/Archives.swift:67` (`moveItem`) | O NSSavePanel já pergunta antes de substituir, mas o `moveItem` falha quando o destino existe. Salvar por cima de um ZIP antigo dava erro. | `replaceItemAt` quando o destino existe e `moveItem` nos outros casos, no mesmo volume. **Não compilado.** | Sem teste automático (Swift não roda neste ambiente). |
| B5 | P1 | `macOS/Backend.swift:66` | O app do Mac não oferecia `ultracode`, que o Claude Code documenta em `--effort`. | Incluído na lista do Claude. **Não compilado.** | Sem teste automático. |
| B6 | P1 | `tests/test_menu.py:189`, `:366` | Testes dependiam de `defaults`/`AppleLanguages` e de `osascript` do macOS, por isso falhavam no Linux. | Os testes agora fixam a plataforma que verificam. Foi acrescentado um teste de detecção de idioma pelo `LANG` no Linux. | `test_menu.py` inteiro passa no Linux. |
| B7 | P1 | `ASSISTENTE-IA-MAC.command`, `choose_prompt` e funções vizinhas | Mensagens só em português apareciam para quem escolheu inglês: escolha de arquivo, limite de 60 KB, imagem e pedidos salvos. | Mensagens passadas para `ui 'pt' 'en'`. Respostas `y`/`Y` também são aceitas. | Coberto pelos testes de menu existentes. |
| B8 | P2 | `desktop/panel.py` (checkpoint ao trocar de agente) | O checkpoint não registrava decisões tomadas nem problemas pendentes, itens pedidos para a transferência entre agentes. | Campos **Decisões tomadas** e **Problemas pendentes**, gravados como seções do checkpoint só quando preenchidos (`desktop/workflows.py:128-148`). | `test_workflows.py::test_gui_switch_cancel_save_and_parallel_launch` (estendido). |
| P1 | P3 | `desktop/panel.py:63` e `:672` (`after(250, self.poll)`) | O painel acordava 4 vezes por segundo mesmo sem nenhuma sessão aberta. | `schedule_poll`: 250 ms com terminal ou tarefa ativa, 1,5 s em repouso (`desktop/panel.py:844-850`). | Medido na seção 8: 120 → 20 trocas de contexto voluntárias em 30 s. |
| Q1 | Baixa | `desktop/pro.py` (versão em desenvolvimento) | A compactação de checkpoints juntava linhas em branco fora dos checkpoints movidos, alterando texto do usuário. | O texto fora dos checkpoints movidos fica byte a byte igual, no Bash e no Python. | `test_checkpoint_compaction_keeps_every_line_and_matches_shell`. |
| Q2 | Baixa | `desktop/panel.py` (sugestões em Verificações) | O nome da subpasta detectada entrava sem aspas no comando sugerido (`cd "pasta" && …`). O comando só é preenchido para revisão, mas um nome com `"` ou `$` mudava o comando. | `shlex.quote` fora do Windows. No Windows o nome não pode conter aspas. | Revisão de código. |
| Q3 | Baixa | `desktop/workflows.json` (`use_now`) | O botão da biblioteca dizia "Usar na próxima sessão", mas abre a sessão na hora. | "Abrir sessão nova com este pedido", nos três idiomas. | `test_pro.py::PanelTests`. |

### Verificado sem alteração

- Os modos de permissão já eram seguros por padrão: Codex com `--ask-for-approval on-request` e `--sandbox workspace-write` (ou `read-only` no modo Planejar), Claude com `--permission-mode default` (ou `plan`). Nenhum modo que desliga sandbox ou aprovações é ativado.
- O instalador do RTK confere SHA-256, e a integração preserva códigos de saída. Os 158 testes de `tests/test_rtk.sh` passam.
- A atualização do macOS confere o SHA-256 publicado pelo GitHub, a origem HTTPS, o tamanho, a versão e o build do pacote, e roda `codesign --verify`. **Isso garante integridade, não autenticidade.** O app é assinado ad hoc e não é notarizado, então quem controlar a conta ou a release pode publicar um pacote com SHA-256 válido. O Gatekeeper não é desativado.
- Linux e Windows só avisam e abrem a página de downloads. Nada é baixado ou instalado sozinho.
- A ponte `--app` usa argumentos separados. Dados de preferência são lidos como texto e nunca executados (`source`/`eval` só carregam bibliotecas do próprio kit).

## 5. Funcionalidades acrescentadas

Cada item foi comparado com o que já existia, para não duplicar recursos.

**Colaboração entre Codex e Claude (seção 6 do pedido).** O checkpoint já registrava arquivos alterados, testes e próximo passo. Agora registra também decisões e problemas pendentes. O botão **Salvar e pedir revisão** grava o checkpoint e abre **uma** sessão do outro agente no modo Planejar (sem alterar arquivos), com um pedido de revisão por severidade, com arquivo e linha. Não há ciclo automático: cada revisão exige um clique.

**Auditoria do contexto (seção 7).** Disponível em **Ferramentas do projeto → Auditoria do contexto** no painel, em `--app context-audit` para o app do Mac e ao fim de **Cuidar do projeto → 12 (Verificar se a pasta está organizada)** no terminal, que também oferece a compactação quando há checkpoints demais. Aponta:

- possíveis credenciais nos arquivos de contexto, só com arquivo e linha, sem o valor;
- arquivos de contexto grandes e andamento grande;
- `AGENTS.md` acima do limite padrão de 32 KiB do Codex (`project_doc_max_bytes`);
- `AGENTS.override.md` substituindo `AGENTS.md`;
- referências a arquivos `.md` inexistentes;
- imports `@` do `CLAUDE.md` ausentes ou além de 4 níveis (o limite documentado), ignorando blocos de código;
- linhas repetidas entre `AGENTS.md`/`CLAUDE.md` e as instruções do projeto;
- excesso de checkpoints;
- uma estimativa de contexto fixo por agente, rotulada "bytes ÷ 4; não é medição".

O relatório pode ser salvo sem a pasta pessoal e sem valores com cara de token.

**Compactação controlada de checkpoints.** Pede confirmação e move os checkpoints antigos para um arquivo **novo** em `DOCS/LEGADO/` (ou equivalente do idioma), mantendo os 3 mais recentes. O andamento ganha uma linha com o caminho do arquivo. Nada é apagado, e o texto que não é checkpoint fica idêntico. Recusa arquivos que são links simbólicos.

**Biblioteca de pedidos (seção 13).** 21 modelos nas categorias pedidas, em pt-BR, inglês e espanhol, em `lib/prompt-library.tsv`, um único arquivo lido pelo Bash, pelo Python e pela ponte do Mac (`--app library`, `--app library-text`). No painel há busca sem diferenciar acentos e maiúsculas, prévia, **Copiar para o projeto** (nunca sobrescreve: cria `nome-2.md` se já existir) e abertura de sessão com o pedido. No terminal, é a opção **7** de "Como você quer começar?", com busca por palavra. Nenhum pedido é enviado a serviços externos.

**Ações rápidas (seção 17).** `Ctrl+K` abre uma paleta de comandos leve no painel: filtro por texto e Enter para executar. Os atalhos existentes foram mantidos.

**Detecção de tecnologias e comandos (seções 10 e 12).** Lê só manifestos conhecidos e nunca instala nem executa nada. Reconhece Node.js (npm, pnpm, yarn, bun), Next.js, React, Vue, TypeScript, Python e pytest, Rust, Go, Swift, C#/.NET, PHP/Composer, WordPress (tema, plugin ou instalação) e HTML/CSS/JS, na raiz ou em `CODIGO/` e subpastas. Em **Verificações**, os comandos aparecem como sugestão para revisão, e o botão só preenche o campo.

**Worktrees removidos por fora (seção 11).** **Limpar registros de pastas removidas** mostra antes a prévia do `git worktree prune --dry-run`, pede confirmação e remove só os registros. Nenhum arquivo ou branch é apagado.

**Diagnóstico (seção 19).** O diagnóstico do painel inclui sistema, arquitetura, versão, build, Python, Tk, Node.js e terminal, e pode ser salvo sanitizado. A ponte do Mac ganhou `--app probe system`.

**CI e distribuição.** Ver seção 3. `desktop/package.sh` passou a incluir `pro.py`, `library.py`, `secret-patterns.txt` e `prompt-library.tsv` no pacote do Windows. Os dois pacotes foram gerados e abertos com `--smoke-test` neste ambiente.

**Contratos compartilhados (seção 20).** `lib/secret-patterns.txt`, `lib/backup-excludes.txt` e `lib/prompt-library.tsv` são lidos pelas implementações de cada plataforma. `lib/pro.sh` e `desktop/pro.py` usam os mesmos identificadores de achados. Os testes de paridade comparam as duas saídas sobre os mesmos arquivos.

## 6. Testes executados

Comandos utilizados (na raiz do repositório):

```bash
/bin/bash ASSISTENTE-IA-MAC.command --check
/bin/bash tests/test_rtk.sh
ASSISTENTE_TEST_NATIVE_TERMINAL=1 ASSISTENTE_TEST_WORKFLOW_UI=1 xvfb-run -a python3.12 -m unittest discover -s tests -p 'test_*.py'
xvfb-run -a python3.12 desktop/panel.py --smoke-test
pwsh -NoProfile -File ASSISTENTE-IA-WINDOWS.ps1 -Check
shellcheck -s bash -S warning ASSISTENTE-IA-MAC.command lib/*.sh
```

| Verificação | Antes (`ae8d800`) | Depois (build 3) |
|---|---|---|
| `--check` | exit 0 | exit 0 |
| `tests/test_rtk.sh` | 158 PASS, 0 FAIL | 158 PASS, 0 FAIL |
| Suíte Python | 369 testes: **4 falhas, 1 erro**, 7 ignorados (sem Tk) | **395 testes, OK**, 5 ignorados (com Tk e Xvfb) |
| `panel.py --smoke-test` | não executado (sem Tk) | exit 0, também nos dois pacotes gerados |
| PowerShell 7.4.6 no Linux | não executado | `-Check` (com `LOCALAPPDATA` definido, como no Windows) e os 3 testes de `test_windows_launcher.py` passam |
| shellcheck (avisos) | 13 nos 4 scripts principais | 13; nenhum aviso novo |
| Gramática Python 3.9 (`ast`, `feature_version=(3,9)`) | não verificado | aprovado em `desktop/*.py` |

Os 5 ignorados: 4 exigem o JavaScript for Automation do macOS e 1 exige o terminal do Windows.

Testes novos: `tests/test_pro.py` (22 testes) e `tests/test_windows_launcher.py` (3 testes), mais extensões em `test_menu.py` e `test_workflows.py`. Nenhum teste foi removido ou desativado.

`test_pro.py` cobre:

- **Biblioteca:** completude nos três idiomas, busca, linhas malformadas, Bash igual ao Python, ponte do app e menu do terminal (usar, copiar, não sobrescrever).
- **Contexto:** achados iguais no Bash e no Python, e relatório sem o valor do segredo.
- **Checkpoints:** compactação idêntica nas duas implementações, sem perda de linhas e preservando a permissão `640`; recusa de link simbólico.
- **Projetos e backup:** detecção de 7 tipos de projeto, filtros de backup e sanitização.
- **Agentes e Git:** esforço por agente; limpeza de worktree com prévia, confirmação e branch preservada.
- **Restauração:** prefixo `./` aceito; fuga de diretório, caminho absoluto, duplicados e destino existente recusados.
- **Traduções:** chaves dos `Localizable.strings` iguais nos três idiomas e marcadores `{}` iguais em `workflows.json`.
- **Painel:** janelas da biblioteca, paleta, auditoria e compactação (cancelar e confirmar).
- **Build:** número do build válido, com a versão pública 1.0.

Resultados completos: `tests/resultado-1.0-professional.txt`.

## 7. Compatibilidade verificada

| Plataforma | Estado | Como |
|---|---|---|
| Linux x86_64 (Ubuntu 24.04, Bash 5.2, Python 3.12, Tk 8.6) | **Verificado** | Suíte completa, painel em Xvfb, terminal xterm, pacotes gerados |
| Windows 10 e 11 | **Não verificado** | O PowerShell 7.4.6 rodou no Linux: análise sintática, `-Check`, aspas de argumentos e ZIP. O Windows PowerShell 5.1, o `cmd.exe`, os shims do npm e o Tk do Windows não foram executados. O novo CI roda esses testes em `windows-latest`. |
| macOS Apple silicon e Intel | **Não verificado** | Sem compilador Swift neste ambiente (o download do toolchain é bloqueado pela rede e o apt do Ubuntu 24.04 não tem pacote). O SwiftUI e o AppKit só existem no macOS. As duas mudanças em Swift foram revisadas à mão. O Bash 3.2 do macOS não foi executado. O código novo evita recursos do Bash 4+ (verificação por busca). |
| Python 3.9 (mínimo documentado) | Parcial | Só a gramática foi verificada. A execução foi com Python 3.12. |

A última execução real do macOS no CI (`45250766834`, tag `v1.0`) passou com 365 testes. Não há execução no macOS do código desta entrega.

## 8. Métricas reais de desempenho

Medições no mesmo contêiner (4 vCPU, 16 GB), painel no Xvfb, sem agentes instalados. São amostras únicas ou de 3 a 5 execuções, não médias estatísticas. O consumo dos agentes externos não entra porque eles não foram executados.

| Métrica | Antes | Depois |
|---|---|---|
| `panel.py --smoke-test` (5 execuções) | 0,235–0,313 s | 0,216–0,297 s |
| RAM do painel em repouso (RSS após 6 s) | 39,8 MB | 40,4 MB |
| CPU do painel em 30 s de repouso | 4 ticks (0,04 s) | 1 tick (0,01 s) |
| Trocas de contexto voluntárias em 30 s | 120 | 20 |
| Threads do painel | 2 | 2 |
| `--check` | 0,054–0,058 s | 0,050–0,069 s |
| `--app info` (abrir projeto pela ponte) | 0,046–0,049 s | 0,051–0,061 s |
| `--app tools` (diagnóstico sem agentes) | 0,086–0,094 s | 0,086–0,092 s |
| Código versionado (sem `.git` e caches) | 3,72 MB | 3,85 MB |
| `--app context-audit` (AGENTS.md de 12 KB, 12 checkpoints) | não existia | 0,091–0,112 s |
| `--app library` | não existia | 0,021–0,030 s |
| Auditoria de contexto no Python (média de 20) | não existia | 2,3 ms |
| Busca na biblioteca (média de 50) | não existia | 0,69 ms |

A mudança real está no repouso: o painel acorda menos (polling adaptativo). As diferenças de tempo nos comandos do launcher ficam dentro da variação entre execuções. O RSS subiu cerca de 0,6 MB pelos módulos novos. Nenhum processo ou monitor permanente foi adicionado. A auditoria, a biblioteca e a detecção rodam só sob demanda.

## 9. Limitações

- O app do macOS não foi compilado nem executado. As mudanças em Swift (B4, B5) não têm teste automático aqui.
- O app nativo do Mac ainda não tem botões próprios para a biblioteca, a auditoria do contexto, a compactação, a limpeza de worktrees nem a revisão pelo outro agente. A ponte `--app` já oferece esses comandos, e o terminal do Mac já tem a biblioteca (opção 7) e a auditoria (Cuidar do projeto → 12). Não acrescentei interface em Swift sem poder compilar.
- A estimativa de tokens é bytes ÷ 4, não uma contagem real do modelo.
- A detecção de credenciais usa 7 padrões conhecidos (chaves `sk-`, GitHub, AWS, Google, Slack, chaves privadas). Credenciais em outros formatos não são detectadas.
- `codex login status` continua sendo usado para conferir o login. Ele não aparece nas páginas da documentação atual que foram lidas. Se a CLI não o aceitar, o painel mostra "status indisponível" e não bloqueia o uso.
- A cópia segura exclui pastas `build` e `dist` e arquivos `*.key`. Isso inclui apresentações do Keynote com essa extensão. A prévia mostra o que entra, e a cópia completa continua disponível.
- O menu de terminal tem textos em português e inglês. Quem escolhe espanhol vê o menu em inglês, com projetos e biblioteca em espanhol (comportamento anterior, mantido).

## 10. Pendências

Itens do pedido que não foram implementados nesta entrega, com o motivo:

| Item | Motivo |
|---|---|
| Interface Swift para os recursos novos (seção 9 acima) | Exige compilar e testar no macOS. |
| Favoritar, importar e exportar pedidos da biblioteca | Os pedidos copiados viram arquivos `.md` comuns em `PROMPTS/`. Importar já existe no terminal (opção 5) e pelo editor. Favoritos exigiriam novo estado persistente. |
| Exportação e importação de preferências | Não implementada. As preferências são arquivos de texto em `ASSISTENTE_STATE_DIR` e podem ser copiadas manualmente. |
| Histórico de resultados das verificações com tempo de execução | O painel guarda só o último resultado com data e código de saída. |
| Detecção de instruções conflitantes (não só duplicadas) | Exige interpretar texto livre. A auditoria aponta duplicadas, referências inválidas e tamanho. |
| Atualizar `actions/checkout` para uma versão com Node 24 | Precisa do SHA da versão nova, que não consegui verificar aqui. |
| Assinatura Developer ID e notarização | Exige conta Apple Developer. O `build.sh` já aceita `ASSISTENTE_SIGN_IDENTITY`. |

## 11. Riscos residuais

- Quem controlar a conta do GitHub ou a release pode publicar um pacote com SHA-256 válido. Só a assinatura Developer ID com notarização daria autenticidade no macOS.
- A ponte `--app run-check` executa no shell do usuário o comando que ele mesmo configurou em Verificações. É um recurso intencional. As sugestões detectadas nunca são executadas sem que o usuário as copie para o campo e clique em executar.
- As proteções contra links e condições de corrida cobrem os caminhos gerenciados do projeto e os backups. Não são uma sandbox de todo o sistema de arquivos. A observação da auditoria de 23/10 sobre `STATE_DIR` continua válida.
- O CI novo foi validado como YAML, com `shellcheck` nos blocos Bash e análise sintática do bloco PowerShell. Não foi executado no GitHub. A primeira execução real deve ser acompanhada.
- Instruções em `AGENTS.md`, `CLAUDE.md` e nos pedidos da biblioteca orientam os agentes, mas não garantem o resultado que eles produzem.

## 12. Instruções de compilação

macOS (Command Line Tools da Apple):

```bash
/bin/bash ASSISTENTE-IA-MAC.command --check
python3 -I -m unittest discover -s tests -p 'test_*.py'
/bin/bash tests/test_rtk.sh
/bin/bash macOS/build.sh "$PWD/Assistente IA.app"
```

Pacotes de Linux e Windows (em qualquer sistema com Bash e `zip`):

```bash
mkdir -p saida && /bin/bash desktop/package.sh "$PWD/saida"
```

Testes do painel no Linux (Tk e Xvfb):

```bash
sudo apt-get install -y xvfb xterm python3-tk
ASSISTENTE_TEST_NATIVE_TERMINAL=1 ASSISTENTE_TEST_WORKFLOW_UI=1 xvfb-run -a python3 -m unittest discover -s tests -p 'test_*.py'
xvfb-run -a python3 desktop/panel.py --smoke-test
```

Windows (PowerShell):

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File ASSISTENTE-IA-WINDOWS.ps1 -Check
python -m unittest discover -s tests -p test_pro.py
python desktop/panel.py --smoke-test
```

Para uma release, crie a tag `v1.0` (ou outra) **manualmente**. O workflow cria um **rascunho** com os ZIPs, `Assistente-IA-Build-<n>.txt` e `SHA256SUMS.txt`, e quem publica é você. Se faltar runner do macOS, use **Run workflow** com o nome da tag.

## 13. Instruções de utilização dos recursos novos

- **Biblioteca de pedidos:** no painel, **Ferramentas do projeto → Biblioteca de pedidos…** ou `Ctrl+K`. No terminal, **Começar uma conversa nova → 7**.
- **Auditoria do contexto:** **Ferramentas do projeto → Auditoria do contexto**. No terminal, **Cuidar do projeto → 12**. Use **Salvar relatório…** para guardar uma cópia sanitizada.
- **Compactar checkpoints:** **Ferramentas do projeto → Compactar checkpoints antigos…** e confirme. Os antigos vão para `DOCS/LEGADO/`, e os 3 últimos ficam no andamento.
- **Revisão pelo outro agente:** troque o agente da sessão, preencha o checkpoint e clique em **Salvar e pedir revisão**. O outro agente abre no modo Planejar com o pedido de revisão. Depois, volte ao primeiro agente com um checkpoint que liste os problemas confirmados.
- **Comandos detectados:** em **Verificações**, revise a sugestão, clique em **Usar** para preencher o campo e execute quando quiser.
- **Worktrees removidos à mão:** **Gerenciar sessões isoladas… → Limpar registros de pastas removidas**.
- **Cópia ZIP no terminal:** Enter cria a cópia segura, `c` cria a completa e outra tecla cancela.

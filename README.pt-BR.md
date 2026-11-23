# Workspace para Codex CLI e Claude Code

**Assistente IA** é um painel leve para trabalhar com Codex CLI e Claude Code no macOS, Linux e Windows. Escolha o projeto e o agente no app. A conversa abre no Terminal, na pasta certa. Os dois agentes podem usar as mesmas instruções, os mesmos pedidos reutilizáveis e o mesmo registro de andamento.

[English](README.md) · [Español](README.es.md) · [Versões publicadas](https://github.com/Anglersondev/Codex-CLI-Claude-Code-Workspace/releases)

## Baixar e abrir

| Sistema | Download | Como abrir |
| --- | --- | --- |
| **macOS** | [Baixar para Mac](https://github.com/Anglersondev/Codex-CLI-Claude-Code-Workspace/releases/latest/download/Assistente-IA-App-macOS.zip) | macOS 13 ou posterior. Descompacte e abra `Assistente IA.app`. O pacote inclui Apple Silicon e Intel. |
| **Linux** | [Baixar para Linux](https://github.com/Anglersondev/Codex-CLI-Claude-Code-Workspace/releases/latest/download/Assistente-IA-App-Linux.zip) | Com Python 3.9+, Tkinter e um terminal gráfico, execute `sh ASSISTENTE-IA-LINUX-GUI.sh` na pasta descompactada. |
| **Windows** | [Baixar para Windows](https://github.com/Anglersondev/Codex-CLI-Claude-Code-Workspace/releases/latest/download/Assistente-IA-App-Windows.zip) | Com Python 3.9+ e Tcl/Tk, dê dois cliques em `ASSISTENTE-IA-WINDOWS-GUI.cmd` na pasta descompactada. |
| **Código-fonte** | [Baixar o código-fonte](https://github.com/Anglersondev/Codex-CLI-Claude-Code-Workspace/releases/latest/download/Assistente-IA-Source.zip) | Inclui o app, os lançadores de Terminal, os testes e a licença MIT. |

Instale o [Codex CLI](https://learn.chatgpt.com/docs/cli) ou o [Claude Code](https://code.claude.com/docs/en/setup) e entre na sua conta. No Debian ou Ubuntu, use o pacote `python3-tk`. No Windows, o [instalador oficial do Python](https://www.python.org/downloads/windows/) oferece Tcl/Tk.

O app distribuído para Mac usa assinatura ad hoc. Se o macOS bloquear a abertura, use o lançador do Terminal ou [compile localmente](README.md#build-and-verify-from-source).

## Primeiro projeto

1. Clique em **Pasta padrão** na barra lateral para escolher onde guardar projetos novos.
2. Clique em **Novo** para criar uma pasta ou **Abrir** para selecionar um projeto existente.
3. Selecione **Codex** ou **Claude Code** e clique em **Nova sessão**, **Continuar** ou **Histórico**.
4. Use o Terminal para conversar e trabalhar. Ao encerrar a sessão, o painel volta a ficar disponível.

Em **Ajustes → Idioma**, escolha português do Brasil, inglês, espanhol ou o idioma do sistema. **Opções da sessão** reúne modelo, permissões e pedido inicial.

## Contexto compartilhado e andamento

- **`AGENTS.md` e `CLAUDE.md`** são as entradas de cada agente. Aponte as duas para `INSTRUCOES/PROJETO.md` para compartilhar regras e objetivos.
- **`DOCS/ANDAMENTO.md`** guarda decisões, testes e o próximo passo. Use **Salvar andamento da sessão** antes de trocar de agente ou conta. Depois selecione **Retomar pelo andamento** para começar outro chat com o resumo.
- **`PROMPTS/`** é a pasta dos pedidos que você escolhe reutilizar. **`ANEXOS/`** guarda os arquivos de apoio.
- Em projetos existentes, **Preparar contexto compartilhado** cria os arquivos faltantes e preserva instruções próprias. O painel avisa quando as regras permanentes ficam extensas.

A conta e o histórico ficam com o agente oficial. Em **Ajustes**, você pode trocar de conta e continuar na mesma pasta.

## Ferramentas e atualizações

O painel tem atalhos para criar pedidos, adicionar anexos, abrir o Terminal, ver o status do Git, iniciar `npm run dev` e criar uma cópia ZIP. Em **Mais ações**, você encontra os atalhos do teclado. A cópia ZIP pode incluir arquivos ocultos.

Quando o RTK está configurado, o Assistente pode evitar a compactação duplicada de saída com o Token Optimizer. O Mac oferece controles das integrações e instalação opcional de atualizações verificadas. Linux e Windows podem avisar quando houver novas versões publicadas.

Os menus completos de Terminal estão nos arquivos `ASSISTENTE-IA-MAC.command`, `ASSISTENTE-IA-LINUX.sh` e `ASSISTENTE-IA-WINDOWS.cmd`. Consulte o [guia de Terminal](GUIA-DE-USO.md), o [guia para Linux e Windows](desktop/LEIA-ME.md), a [documentação do RTK](RTK.md) e o [histórico de versões](CHANGELOG.md).

## Autor e apoio

Desenvolvido por **Anglerson**. [anglerson.com.br](https://anglerson.com.br) · [Pague um café ☕](https://pixgg.com/Anglerson)

[Licença MIT](LICENSE)

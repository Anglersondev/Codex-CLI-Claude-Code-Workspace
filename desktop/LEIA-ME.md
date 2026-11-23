# Assistente IA 1.0 para Linux e Windows

Descompacte o ZIP inteiro. Em **Ajustes → Idioma**, selecione português do Brasil, inglês, espanhol ou **Automático** para seguir o sistema.

| Sistema | Como abrir | Requisitos |
| --- | --- | --- |
| Linux | Abra `ASSISTENTE-IA-LINUX-GUI.sh` ou execute `sh ASSISTENTE-IA-LINUX-GUI.sh`. | Python 3.9+, Tkinter (pacote `python3-tk` no Debian e Ubuntu) e um terminal gráfico como GNOME Terminal, Konsole ou xterm. |
| Windows | Dê dois cliques em `ASSISTENTE-IA-WINDOWS-GUI.cmd`. | Python 3.9+ para Windows com Tcl/Tk, disponível no [site do Python](https://www.python.org/downloads/windows/). |

Instale o Codex CLI ou Claude Code usando o instalador oficial. Em **Ajustes**, use **Entrar** para autenticar o agente escolhido.

1. Clique em **Pasta padrão** e escolha onde guardar novos projetos.
2. Clique em **Novo** para criar ou **Abrir** para selecionar uma pasta existente.
3. Selecione Codex ou Claude e clique em **Nova sessão**. O agente abre na pasta do projeto.
4. Ao sair, o painel fica disponível para escolher o próximo projeto. A janela pode permanecer em segundo plano em ambientes Linux que restringem a mudança automática de foco.

**Contexto e arquivos** reúne instruções, pedidos reutilizáveis, anexos, Terminal, Git, servidor npm e cópia ZIP. A cópia guarda inclusive arquivos ocultos. Em **Ferramentas do projeto**, você encontra **Atalhos do teclado** e ações como copiar o caminho e salvar o andamento.

**Ajustes** reúne troca de conta, atualização dos agentes, economia do RTK e avisos opcionais de novas versões publicadas. Use o link **Versões publicadas** para baixar os ZIPs mais recentes. O instalador automático do próprio Assistente fica na edição nativa do Mac.

Para usar o menu de terminal, abra `ASSISTENTE-IA-LINUX.sh` no Linux ou `ASSISTENTE-IA-WINDOWS.cmd` no Windows.

## English

Extract the full ZIP. Open `ASSISTENTE-IA-LINUX-GUI.sh` on Linux (`sh ASSISTENTE-IA-LINUX-GUI.sh`) or double-click `ASSISTENTE-IA-WINDOWS-GUI.cmd` on Windows. Install Python 3.9+ with Tkinter and the official CLI for Codex or Claude Code. Linux needs a graphical terminal and may require the `python3-tk` package. Use **Settings → Language** to follow the system or select Brazilian Portuguese, English, or Spanish.

Click **Default folder**, choose where to create projects, and select **New** or **Open**. Select your agent and click **New session**. The project panel is available again when the terminal session ends. Use **Settings** for account access, integration preferences, release notifications, and the project links.

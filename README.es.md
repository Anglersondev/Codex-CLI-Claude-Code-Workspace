# Espacio de trabajo para Codex CLI y Claude Code

![Assistente IA para Codex CLI y Claude Code en macOS, Linux y Windows](assets/workspace-banner.svg)

**Assistente IA** es un panel de escritorio ligero para Codex CLI y Claude Code en macOS, Linux y Windows. Elige un proyecto y un agente en el panel. La sesión se abre en el terminal del sistema, en la carpeta seleccionada. Ambos agentes pueden compartir instrucciones, solicitudes reutilizables y notas de progreso.

[![GitHub Release](https://img.shields.io/github/v/release/Anglersondev/Codex-CLI-Claude-Code-Workspace?style=flat-square&label=release)](https://github.com/Anglersondev/Codex-CLI-Claude-Code-Workspace/releases/latest) [![MIT License](https://img.shields.io/badge/license-MIT-2877c7?style=flat-square)](LICENSE)

**[Descargar la última versión](https://github.com/Anglersondev/Codex-CLI-Claude-Code-Workspace/releases/latest)** · [English](README.md) · [Português (Brasil)](README.pt-BR.md) · [Historial de versiones](CHANGELOG.md)

[Instalación](#descargar-e-instalar) · [Primer proyecto](#trabajar-con-un-proyecto) · [Contexto compartido](#contexto-compartido-y-progreso)

## Descargar e instalar

| Sistema | Descarga | Cómo abrir |
| --- | --- | --- |
| **macOS** | [Assistente IA para Mac](https://github.com/Anglersondev/Codex-CLI-Claude-Code-Workspace/releases/latest/download/Assistente-IA-App-macOS.zip) | macOS 13 o posterior. Extrae el ZIP y abre `Assistente IA.app`. |
| **Linux** | [Assistente IA para Linux](https://github.com/Anglersondev/Codex-CLI-Claude-Code-Workspace/releases/latest/download/Assistente-IA-App-Linux.zip) | Instala Python 3.9+, Tkinter y un terminal gráfico. En la carpeta extraída, ejecuta `sh ASSISTENTE-IA-LINUX-GUI.sh`. |
| **Windows** | [Assistente IA para Windows](https://github.com/Anglersondev/Codex-CLI-Claude-Code-Workspace/releases/latest/download/Assistente-IA-App-Windows.zip) | Instala Python 3.9+ con Tcl/Tk. Extrae el ZIP y abre `ASSISTENTE-IA-WINDOWS-GUI.cmd`. |
| **Código fuente** | [ZIP del código fuente](https://github.com/Anglersondev/Codex-CLI-Claude-Code-Workspace/releases/latest/download/Assistente-IA-Source.zip) | Incluye lanzadores, código, pruebas y licencia MIT. |

Instala [Codex CLI](https://learn.chatgpt.com/docs/cli) o [Claude Code](https://code.claude.com/docs/en/setup) e inicia sesión. La descarga de macOS tiene una firma ad hoc. Si el sistema bloquea la app, puedes usar el lanzador de terminal o [compilarla localmente](README.md#build-and-verify-from-source).

## Trabajar con un proyecto

1. Usa **Carpeta predeterminada** para elegir dónde guardar los proyectos nuevos.
2. Pulsa **Nuevo** o **Abrir**. Después elige **Codex** o **Claude Code**.
3. Selecciona **Nueva sesión**, **Continuar** o **Historial**. Trabaja en el terminal y vuelve al panel al terminar.
4. En **Ajustes → Idioma**, elige español, inglés, portugués de Brasil o **Automático**.

`AGENTS.md` y `CLAUDE.md` apuntan a `INSTRUCOES/PROJETO.md` en los proyectos organizados. Usa ese archivo para compartir reglas y objetivos. Guarda decisiones y el próximo paso en `DOCS/ANDAMENTO.md`. Al cambiar de agente o cuenta, **Continuar desde las notas del proyecto** abre una sesión nueva con ese resumen. Cada agente conserva su propio historial.

El panel reúne solicitudes guardadas, archivos adjuntos, estado de Git, servidor npm, copias ZIP y acceso a la terminal. Los menús de terminal siguen disponibles en los lanzadores de cada sistema. Consulta la [guía para Linux y Windows](desktop/LEIA-ME.md) o la [documentación completa](README.md).

## Contexto compartido y progreso

| Para… | Usa… |
| --- | --- |
| Volver al último chat del mismo agente | **Continuar**. |
| Buscar una conversación anterior | **Historial**. |
| Cambiar de agente o cuenta conservando el contexto | **Guardar progreso de la sesión** y luego **Continuar desde las notas del proyecto**. |

Los cambios de archivos quedan en la carpeta del proyecto cuando el agente los realiza. Para conservar un resumen reutilizable, usa **Guardar progreso de la sesión** o pide al agente que actualice `DOCS/ANDAMENTO.md`. Cada agente conserva su propio historial.

**Ejemplo:** modifica un menú con Codex y pide que anote el archivo modificado, la compilación ejecutada y el siguiente paso. Después, selecciona Claude Code y pulsa **Continuar desde las notas del proyecto** para que compruebe lo que falta.

Si el botón para continuar desde las notas está deshabilitado, anota el siguiente paso en `DOCS/ANDAMENTO.md` y comprueba que exista `PROMPTS/CONTINUAR.md`. Si el agente no se abre, ejecuta `codex --version` o `claude --version` en el terminal y comprueba el inicio de sesión.

## Autor y apoyo

Desarrollado por **Anglerson**. [anglerson.com.br](https://anglerson.com.br) · [Invítame a un café ☕](https://pixgg.com/Anglerson)

[Licencia MIT](LICENSE)

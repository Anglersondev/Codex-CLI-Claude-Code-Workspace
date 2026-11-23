import AppKit
import SwiftUI

func shortProjectLocation(_ folder: URL) -> String {
    let parent = folder.deletingLastPathComponent()
    let components = parent.pathComponents.filter { $0 != "/" }
    return components.isEmpty ? "/" : components.suffix(2).joined(separator: "  /  ")
}

struct TerminalCommandsMenu: View {
    let onCopy: (String) -> Void

    private let commands = [
        ("Codex CLI", ["codex", "codex resume --last", "codex resume", "codex login status"]),
        ("Claude Code", ["claude", "claude --continue", "claude --resume", "claude auth status"]),
        ("Git", ["git status --short --branch", "git diff"]),
        ("npm", ["npm run dev"]),
        ("RTK", ["rtk gain", "rtk git status", "rtk bypass git status"]),
    ]

    var body: some View {
        Menu {
            ForEach(commands, id: \.0) { group in
                Menu(group.0) {
                    ForEach(group.1, id: \.self) { command in
                        Button(command) { onCopy(command) }
                    }
                }
            }
        } label: {
            Label(tr("Comandos do Terminal"), systemImage: "terminal")
        }
        .help(tr("Escolha um comando para copiar."))
    }
}

struct DefaultFolderControl: View {
    @Binding var path: String

    var body: some View {
        let folder = defaultProjectFolder(path)
        Button {
            if let chosen = chooseDirectory(startingAt: folder, prompt: tr("Definir pasta padrão")) {
                path = chosen.path
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundStyle(Color(nsColor: .systemBlue))
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Pasta padrão")).font(.caption.weight(.semibold))
                    Text(folder?.lastPathComponent ?? tr("Escolha uma pasta"))
                        .lineLimit(1).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
        .help(folder?.path ?? tr("Definir pasta padrão"))
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .accessibilityLabel(Text(tr("Definir pasta padrão")))
        .accessibilityValue(folder?.path ?? "")
    }
}

struct ProjectAction: Identifiable {
    let path: String
    var id: String { path }
}

struct NewPromptPanel: View {
    let project: String
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var text = ""
    @ViewState private var failure: String?

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        !cleanName.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 60_000
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(tr("Novo pedido")).font(.title2.bold())
            TextField(tr("Nome do pedido"), text: $name)
            TextEditor(text: $text).font(.body)
                .accessibilityLabel(Text(tr("Texto do pedido")))
                .frame(minHeight: 150)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.25)))
            if let failure { Text(failure).font(.callout).foregroundStyle(.red) }
            HStack {
                Button(tr("Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(tr("Salvar pedido")) { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).disabled(!canSave || workspace.busy)
            }
        }
        .padding(22).frame(width: 490)
    }

    private func save() async {
        if await workspace.savePrompt(project: project, name: cleanName, text: text) {
            dismiss()
        } else {
            failure = workspace.message
            workspace.message = nil
        }
    }
}

struct DevPackages: Identifiable {
    let path: String
    let folders: [String]
    var id: String { path }
}

struct DevPanel: View {
    let project: DevPackages
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selection: String

    init(project: DevPackages, workspace: Workspace) {
        self.project = project
        self.workspace = workspace
        self._selection = ViewState(wrappedValue: project.folders[0])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(tr("Iniciar servidor local")).font(.title2.bold())
            Picker(tr("Pasta do código"), selection: $selection) {
                ForEach(project.folders, id: \.self) {
                    Text($0 == "." ? tr("Raiz do projeto") : $0).tag($0)
                }
            }
            Text(tr("O Terminal executará npm run dev na pasta selecionada. Use Ctrl+C para encerrar o servidor."))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(tr("Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(tr("Executar npm run dev")) {
                    let args = ["dev", project.path, selection]
                    dismiss()
                    Task { await workspace.terminalAction(args) }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 465)
    }
}

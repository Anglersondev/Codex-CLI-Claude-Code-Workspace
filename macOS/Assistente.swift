import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Explicit wrapper keeps the build compatible with standalone Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct Assistente: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var workspace = Workspace.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PanelLanguage.preferenceKey) private var language: PanelLanguage = .automatic

    private var interfaceLocale: Locale { Locale(identifier: language.effective.rawValue) }

    var body: some Scene {
        WindowGroup("Assistente IA") {
            Dashboard(workspace: workspace)
                .frame(minWidth: 760, minHeight: 570)
                .environment(\.locale, interfaceLocale)
        }
        .defaultSize(width: 940, height: 650)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button(tr("Sobre o Assistente IA")) { openWindow(id: "about") }
            }
        }
        Window(tr("Sobre o Assistente IA"), id: "about") {
            VStack(alignment: .leading, spacing: 15) {
                Text("Assistente IA").font(.title2.bold())
                AboutLinks()
            }
            .padding(24).frame(minWidth: 330)
            .environment(\.locale, interfaceLocale)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        let workspace = Workspace.shared
        guard let update = workspace.staged else { return }
        guard workspace.jobs.isEmpty, UserDefaults.standard.bool(forKey: "installAppUpdates") else {
            update.discard()
            UserDefaults.standard.removeObject(forKey: "lastAppCheck")
            return
        }
        do {
            try Updates.install(update, at: Bundle.main.bundleURL)
        } catch {
            UserDefaults.standard.set(tr("Falha ao aplicar a atualização. %@", error.localizedDescription), forKey: "appUpdateError")
            UserDefaults.standard.removeObject(forKey: "lastAppCheck")
            update.discard()
        }
    }
}

struct Dashboard: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.scenePhase) private var phase
    @AppStorage("projectParent") private var projectParent = ""
    @ViewState private var showSettings = false
    @ViewState private var showCreate = false
    @ViewState private var prepare = false
    @ViewState private var wrap = false
    @ViewState private var promptEditor: ProjectAction?
    @ViewState private var packages: DevPackages?
    private let accent = Color(nsColor: .systemBlue)

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $workspace.selected) {
                    Section(tr("Projetos recentes")) {
                        ForEach(workspace.projects, id: \.self) { path in
                            Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
                                .lineLimit(1).help(path).tag(path)
                        }
                    }
                }
                .listStyle(.sidebar)
                Divider()
                DefaultFolderControl(path: $projectParent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                Divider()
                HStack {
                    Button { showCreate = true } label: { Label(tr("Novo"), systemImage: "plus") }
                        .keyboardShortcut("n")
                    Spacer()
                    Button(action: openFolder) { Label(tr("Abrir…"), systemImage: "folder") }
                        .keyboardShortcut("o")
                }
                .buttonStyle(.borderless)
                .disabled(workspace.busy)
                .padding(13)
            }
            .navigationSplitViewColumnWidth(min: 182, ideal: 215, max: 285)
        } detail: {
            Group {
                if let path = workspace.selected {
                    ScrollView {
                        projectDetail(path)
                            .padding(.horizontal, 25).padding(.vertical, 21)
                            .frame(maxWidth: 820, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(spacing: 15) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 43, weight: .light)).foregroundStyle(accent)
                        Text(tr("Escolha um projeto")).font(.title2.bold())
                        Text(tr("Crie uma pasta compartilhada ou abra um projeto existente.")).foregroundStyle(.secondary)
                        HStack {
                            Button(tr("Novo projeto…")) { showCreate = true }.buttonStyle(.borderedProminent)
                            Button(tr("Abrir pasta…"), action: openFolder)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .toolbar {
                ToolbarItem {
                    TerminalCommandsMenu { command in
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        workspace.notice = tr("Comando copiado. Cole no Terminal.")
                    }
                }
                ToolbarItem {
                    Button { showSettings = true } label: { Label(tr("Ajustes"), systemImage: "gearshape") }
                        .help(tr("Contas, integrações e atualizações"))
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
        }
        .tint(accent)
        .task {
            if let previousError = UserDefaults.standard.string(forKey: "appUpdateError") {
                workspace.appUpdate = previousError
                UserDefaults.standard.removeObject(forKey: "appUpdateError")
            }
            await workspace.reloadProjects()
            await workspace.refreshTools()
            await workspace.runDailyUpdates()
        }
        .task(id: workspace.selected) {
            guard let path = workspace.selected else { return }
            workspace.notice = nil
            await workspace.loadProject(path)
            await workspace.loadPreferences(path, workspace.agent)
        }
        .onChange(of: workspace.agent) { agent in
            if let path = workspace.selected { Task { await workspace.loadPreferences(path, agent) } }
        }
        .task(id: workspace.jobs.map(\.id)) { await workspace.checkTerminalJobs() }
        .onChange(of: phase) { phase in
            if phase == .active {
                Task {
                    if let path = workspace.selected { await workspace.loadProject(path, pickAgent: false) }
                    await workspace.runDailyUpdates()
                }
            }
        }
        .sheet(isPresented: $showCreate) { CreateProject(workspace: workspace) }
        .sheet(isPresented: $showSettings) { SettingsPanel(workspace: workspace) }
        .sheet(item: $promptEditor) { item in
            NewPromptPanel(project: item.path, workspace: workspace)
        }
        .sheet(item: $packages) { item in
            DevPanel(project: item, workspace: workspace)
        }
        .sheet(item: Binding(get: { showSettings ? nil : workspace.detail }, set: { workspace.detail = $0 })) { result in
            TextPanel(result: result)
        }
        .alert("Assistente IA", isPresented: Binding(
            get: { !showSettings && workspace.message != nil }, set: { if !$0 { workspace.message = nil } }
        )) {
            Button("OK") { workspace.message = nil }
        } message: {
            Text(workspace.message ?? "")
        }
        .confirmationDialog(tr("Preparar pasta compartilhada?"), isPresented: $prepare, titleVisibility: .visible) {
            Button(tr("Criar arquivos faltantes")) {
                if let path = workspace.selected { Task { await workspace.prepare(path) } }
            }
        } message: {
            Text(tr("Cria as entradas e os arquivos de contexto que faltarem. Os arquivos existentes são preservados."))
        }
        .confirmationDialog(tr("Salvar andamento da sessão?"), isPresented: $wrap, titleVisibility: .visible) {
            Button(tr("Retomar e pedir resumo")) { Task { await workspace.start("resumo") } }
        } message: {
            Text(tr("O agente retomará sua conversa mais recente e atualizará DOCS/ANDAMENTO.md."))
        }
    }

    private func openFolder() {
        if let url = chooseDirectory(startingAt: defaultProjectFolder(projectParent)) {
            Task { await workspace.openProject(url.path) }
        }
    }

    private func projectDetail(_ path: String) -> some View {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        return VStack(alignment: .leading, spacing: 16) {
            projectHeader(folder)
            section("Sessão no Terminal") {
                Text(tr("Agente desta sessão")).font(.subheadline.weight(.semibold))
                Picker(tr("Agente desta sessão"), selection: $workspace.agent) {
                    ForEach(Agent.allCases) { agent in Text(agent.name).tag(agent) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(Text(tr("Agente desta sessão")))
                Text(tr("Codex e Claude podem trabalhar nesta mesma pasta."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 9) {
                    Button { Task { await workspace.start("novo") } } label: {
                        Label(tr("Nova sessão"), systemImage: "terminal")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    Button(tr("Continuar")) { Task { await workspace.start("recente") } }
                    Button(tr("Histórico…")) { Task { await workspace.start("escolher") } }
                }
                .disabled(!workspace.sessionReady || workspace.busy || workspace.updatingIntegrations)
                Text(tr("Ao sair da sessão no Terminal, você volta a esta janela."))
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(tr("Opções da sessão")) {
                  Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text(tr("Permissões")).foregroundStyle(.secondary)
                        Picker(tr("Permissões"), selection: $workspace.workMode) {
                            Text(tr("Trabalhar")).tag("trabalhar")
                            Text(tr("Planejar · leitura")).tag("planejar")
                        }.labelsHidden()
                    }
                    GridRow {
                        Text(tr("Modelo")).foregroundStyle(.secondary)
                        HStack {
                            TextField(tr("Padrão do agente"), text: $workspace.model).accessibilityLabel(Text(tr("Modelo")))
                            Picker(tr("Esforço"), selection: $workspace.effort) {
                                Text(tr("Automático")).tag("")
                                ForEach(workspace.agent.efforts, id: \.self) { Text($0).tag($0) }
                            }.frame(maxWidth: 172)
                        }
                    }
                    GridRow {
                        Text(tr("Pedido inicial")).foregroundStyle(.secondary)
                        HStack {
                            Button(workspace.prompt?.lastPathComponent ?? tr("Escolher arquivo…")) { choosePrompt(folder) }
                                .lineLimit(1)
                            if workspace.prompt != nil {
                                Button { workspace.prompt = nil } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).accessibilityLabel(Text(tr("Remover pedido inicial")))
                            }
                        }
                    }
                  }.padding(.top, 8)
                }
                if !workspace.jobs.isEmpty {
                    Label(tr("Sessões no Terminal pelo app: %d", workspace.jobs.count), systemImage: "terminal")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let notice = workspace.notice {
                Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
            }
            section("Contexto do projeto") {
                if workspace.context.count >= 3 {
                    HStack(spacing: 9) {
                        contextLabel("AGENTS.md", workspace.context.contains("override") ? tr("Sobrescrito") : entryLabel(workspace.context[0]), workspace.context[0] == "shared" && !workspace.context.contains("override"))
                        contextLabel("CLAUDE.md", entryLabel(workspace.context[1]), workspace.context[1] == "shared")
                    }
                    if workspace.context[2] == "template" {
                        Label(tr("Escreva o objetivo em PROJETO.md antes de começar."), systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        if workspace.context[2] == "missing" || workspace.context.prefix(2).contains("missing") {
                            Button(tr("Preparar contexto…")) { prepare = true }
                        }
                        openIfPresent("Instruções", "INSTRUCOES/PROJETO.md", in: folder)
                        openIfPresent("Andamento", "DOCS/ANDAMENTO.md", in: folder)
                        openIfPresent("Prompts", "PROMPTS", in: folder)
                    }
                    let continuePrompt = folder.appendingPathComponent("PROMPTS/CONTINUAR.md")
                    if workspace.context[2] != "missing" {
                        HStack {
                            Button(tr("Salvar andamento…")) { wrap = true }
                            if FileManager.default.fileExists(atPath: continuePrompt.path) {
                                Button(tr("Retomar pelo andamento")) { Task { await workspace.start("novo", using: continuePrompt) } }
                                    .disabled(!workspace.context.contains("progress"))
                            }
                        }
                        .disabled(!workspace.sessionReady || workspace.busy || workspace.updatingIntegrations)
                        if workspace.context.contains("progress") {
                            Text(tr("Abre uma conversa nova com o agente selecionado e usa o resumo do projeto."))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(tr("Registre o próximo passo em Andamento para retomar depois."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if workspace.context.contains("large-context") {
                        Label(tr("Instruções extensas. Mova referências que usa só às vezes para DOCS."), systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if workspace.context.prefix(2).contains("custom") {
                        Text(tr("Uma entrada usa regras próprias. Confira a referência a PROJETO.md se quiser compartilhar essas regras."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if workspace.context.contains("override") {
                        Text(tr("AGENTS.override.md tem prioridade no Codex."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            section("Atalhos do projeto") {
                HStack {
                    Button(tr("Novo pedido…")) { promptEditor = ProjectAction(path: path) }
                        .keyboardShortcut("p", modifiers: [.command, .shift])
                    Button(tr("Adicionar anexo…")) { pickAttachment(for: folder) }
                        .keyboardShortcut("a", modifiers: [.command, .shift])
                    openIfPresent("Documentos", "DOCS", in: folder)
                    openIfPresent("Anexos", "ANEXOS", in: folder)
                }
                .disabled(workspace.busy)
                Divider()
                HStack {
                    Button {
                        Task { await workspace.terminalAction(["shell", path]) }
                    } label: { Label("Terminal", systemImage: "terminal") }
                        .keyboardShortcut("t", modifiers: [.command, .shift])
                    Button {
                        Task { await workspace.showReport(tr("Status do Git"), ["git-status", path]) }
                    } label: { Label("Git", systemImage: "arrow.triangle.branch") }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                    Button {
                        Task { await showDevPackages(path) }
                    } label: { Label(tr("Servidor npm…"), systemImage: "play.circle") }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                    Button {
                        pickBackupDestination(folder)
                    } label: { Label(tr("Cópia ZIP…"), systemImage: "archivebox") }
                        .keyboardShortcut("b", modifiers: [.command, .shift])
                }
                .disabled(workspace.busy)
            }
        }
    }

    private func projectHeader(_ folder: URL) -> some View {
        let path = folder.path
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 47, height: 47)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(folder.lastPathComponent).font(.system(size: 26, weight: .semibold)).lineLimit(1).help(path)
                Text(shortProjectLocation(folder))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head).help(path)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([folder]) } label: {
                    Label("Finder", systemImage: "arrow.up.right")
                }
                Menu {
                    Button(tr("Preparar contexto compartilhado…")) { prepare = true }
                    Button(tr("Salvar andamento da última sessão…")) { wrap = true }
                        .disabled(!workspace.sessionReady)
                    Divider()
                    Button(tr("Copiar caminho completo")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    }
                } label: { Label(tr("Mais ações"), systemImage: "ellipsis.circle") }
                    .fixedSize()
                    .disabled(workspace.busy)
            }
            .fixedSize()
        }
    }

    private func pickAttachment(for folder: URL) {
        let panel = NSOpenPanel()
        panel.directoryURL = folder
        panel.prompt = tr("Adicionar")
        if panel.runModal() == .OK, let url = panel.url {
            Task { await workspace.attach(url, to: folder.path) }
        }
    }

    private func pickBackupDestination(_ folder: URL) {
        if let target = chooseDirectory(startingAt: folder.deletingLastPathComponent(), prompt: tr("Salvar cópia ZIP neste local")) {
            Task { await workspace.backup(folder.path, to: target) }
        }
    }

    private func showDevPackages(_ path: String) async {
        await workspace.perform {
            let folders = Backend.lines(try await Backend.run(["dev-packages", path]))
            guard !folders.isEmpty else { throw AppFailure(tr("Nenhum package.json encontrado neste projeto.")) }
            packages = DevPackages(path: path, folders: folders)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(tr(title)).font(.headline)
            content()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.14)))
    }

    private func entryLabel(_ status: String) -> String {
        switch status {
        case "shared": return tr("Compartilhado")
        case "custom": return tr("Personalizado")
        default: return tr("Ausente")
        }
    }

    private func contextLabel(_ name: String, _ status: String, _ ready: Bool) -> some View {
        Label("\(name) · \(status)", systemImage: ready ? "checkmark.circle" : "doc.text")
            .font(.caption).padding(.horizontal, 8).padding(.vertical, 5)
            .background((ready ? accent : .secondary).opacity(0.13), in: Capsule())
    }

    @ViewBuilder private func openIfPresent(_ title: String, _ relative: String, in folder: URL) -> some View {
        let url = folder.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: url.path) {
            Button(tr(title)) { NSWorkspace.shared.open(url) }
        }
    }

    private func choosePrompt(_ folder: URL) {
        let panel = NSOpenPanel()
        panel.directoryURL = folder.appendingPathComponent("PROMPTS", isDirectory: true)
        panel.allowedContentTypes = [.plainText] + [UTType(filenameExtension: "md")].compactMap { $0 }
        panel.prompt = tr("Usar pedido")
        if panel.runModal() == .OK { workspace.prompt = panel.url }
    }
}

@MainActor
func chooseDirectory(startingAt folder: URL? = nil, prompt: String = tr("Escolher pasta")) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = folder
    panel.prompt = prompt
    return panel.runModal() == .OK ? panel.url : nil
}

struct CreateProject: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @ViewState private var parent = defaultProjectFolder()
    @ViewState private var rememberParent = false
    @ViewState private var name = ""
    @ViewState private var goal = ""
    @ViewState private var agent: Agent = .codex
    @AppStorage("groupNewProjectsByAgent") private var grouped = true

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(tr("Novo projeto")).font(.title2.bold())
            Form {
                TextField(tr("Nome"), text: $name)
                TextField(tr("Objetivo (opcional)"), text: $goal)
                Picker(tr("Primeiro agente"), selection: $agent) {
                    ForEach(Agent.allCases) { Text($0.name).tag($0) }
                }
                Picker(tr("Organização"), selection: $grouped) {
                    Text(tr("Separar por agente")).tag(true)
                    Text(tr("Criar direto na pasta escolhida")).tag(false)
                }
                LabeledContent(tr("Criar em")) {
                    HStack {
                        Text(destination?.path ?? tr("Escolha uma pasta")).lineLimit(1).truncationMode(.head)
                        Button(tr("Escolher…")) { if let selection = chooseDirectory() { parent = selection } }
                    }
                }
            }
            Toggle(tr("Usar esta pasta nos próximos projetos"), isOn: $rememberParent)
            Text(tr("A pasta vai receber as entradas dos dois agentes, instruções compartilhadas e prompts.")).foregroundStyle(.secondary)
            HStack {
                Button(tr("Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(tr("Só criar")) { create(false) }.disabled(parent == nil || cleanName.isEmpty)
                Button(tr("Criar e abrir Terminal")) { create(true) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(parent == nil || cleanName.isEmpty)
            }
        }
        .padding(24).frame(width: 535)
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var projectRoot: URL? {
        guard let parent, grouped else { return parent }
        return ["CODEX", "CLAUDE"].contains(parent.lastPathComponent.uppercased())
            ? parent.deletingLastPathComponent() : parent
    }
    private var destination: URL? {
        guard let root = projectRoot else { return nil }
        let folder = grouped ? root.appendingPathComponent(agent.rawValue.uppercased()) : root
        return cleanName.isEmpty ? folder : folder.appendingPathComponent(cleanName)
    }

    private func create(_ open: Bool) {
        guard let parent else { return }
        dismiss()
        if rememberParent { UserDefaults.standard.set(projectRoot?.path ?? parent.path, forKey: "projectParent") }
        Task { await workspace.create(parent: parent, name: cleanName, goal: goal, agent: agent, grouped: grouped, open: open) }
    }
}

struct TextPanel: View {
    let result: Workspace.TextResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(result.title).font(.title2.bold())
            ScrollView {
                Text(result.text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(tr("Fechar")) { dismiss() }.keyboardShortcut(.defaultAction)
        }.padding(22).frame(width: 620, height: 380)
    }
}

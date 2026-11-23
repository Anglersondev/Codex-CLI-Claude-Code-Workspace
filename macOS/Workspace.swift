import AppKit
import SwiftUI
import UniformTypeIdentifiers

func defaultProjectFolder(_ path: String = UserDefaults.standard.string(forKey: "projectParent") ?? "") -> URL? {
    if !path.isEmpty,
       (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
}

@MainActor
final class Workspace: ObservableObject {
    static let shared = Workspace()
    @Published var projects: [String] = []
    @Published var selected: String?
    @Published var agent: Agent = .codex
    @Published var model = ""
    @Published var effort = ""
    @Published var workMode = "trabalhar"
    @Published var prompt: URL?
    @Published var context: [String] = []
    @Published var tools: [String] = []
    @Published var accounts: [Agent: Bool] = [:]
    @Published var busy = false
    @Published var jobs: [TerminalJob] = []
    @Published var message: String?
    @Published var detail: TextResult?
    @Published var notice: String?
    @Published var appUpdate = ""
    @Published var integrationUpdate = ""
    @Published var checkingApp = false
    @Published var updatingIntegrations = false
    @Published var staged: StagedUpdate?
    private var projectDetailsLoaded: String?
    private var preferencesLoaded: String?

    struct TextResult: Identifiable {
        let title: String
        let text: String
        var id: String { title }
    }

    func reloadProjects() async {
        do {
            projects = Backend.lines(try await Backend.run(["list"]))
            if selected == nil || !projects.contains(selected ?? "") { selected = projects.first }
        } catch {
            message = error.localizedDescription
        }
    }

    func openProject(_ path: String) async {
        await perform {
            let result = try await Backend.run(["select", path])
            selected = Backend.lines(result).first
            await reloadProjects()
        }
    }

    func create(parent: URL, name: String, goal: String, agent: Agent, grouped: Bool, open: Bool) async {
        await perform {
            let result = try await Backend.run(["create", parent.path, name, agent.rawValue, goal, grouped ? "grouped" : "direct"])
            guard let path = Backend.lines(result).first else { throw AppFailure(tr("A pasta criada não foi retornada.")) }
            selected = path
            await reloadProjects()
            if open {
                try await terminal(["launch", path, agent.rawValue, "novo", "trabalhar", "", "", ""])
            }
        }
    }

    func loadProject(_ path: String, pickAgent: Bool = true) async {
        if pickAgent {
            projectDetailsLoaded = nil
            context = []
            prompt = nil
        }
        do {
            let info = Backend.lines(try await Backend.run(["info", path]))
            guard selected == path, !Task.isCancelled else { return }
            context = Array(info.dropFirst())
            if pickAgent { agent = Agent(rawValue: info.first ?? "") ?? .codex }
            projectDetailsLoaded = path
        } catch {
            if selected == path { message = error.localizedDescription }
        }
    }

    func loadPreferences(_ path: String, _ agent: Agent) async {
        guard projectDetailsLoaded == path else { return }
        do {
            let options = Backend.lines(try await Backend.run(["prefs", path, agent.rawValue]))
            guard selected == path, self.agent == agent, !Task.isCancelled, options.count == 3 else { return }
            model = options[0]
            effort = agent.efforts.contains(options[1]) ? options[1] : ""
            workMode = options[2]
            preferencesLoaded = path + ":" + agent.rawValue
        } catch {
            if selected == path { message = error.localizedDescription }
        }
    }

    var sessionReady: Bool {
        guard let selected else { return false }
        return projectDetailsLoaded == selected && preferencesLoaded == selected + ":" + agent.rawValue
    }

    func prepare(_ path: String) async {
        await perform {
            _ = try await Backend.run(["prepare", path])
            await loadProject(path, pickAgent: false)
        }
    }

    func savePrompt(project: String, name: String, text: String) async -> Bool {
        await perform {
            _ = try await Backend.run(["save-prompt", project, name, text])
            if selected == project {
                prompt = URL(fileURLWithPath: project).appendingPathComponent("PROMPTS/\(name).md")
                notice = tr("Pedido salvo e selecionado para a próxima sessão.")
            }
        }
    }

    func attach(_ file: URL, to project: String) async {
        await perform {
            _ = try await Backend.run(["attach", project, file.path])
            if selected == project { notice = tr("Arquivo copiado para ANEXOS.") }
        }
    }

    func backup(_ project: String, to destination: URL) async {
        await perform {
            let output = try await Backend.run(["backup", project, destination.path])
            guard let path = Backend.lines(output).first else { return }
            if selected == project { notice = tr("Cópia ZIP criada.") }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    func start(_ verb: String, using promptOverride: URL? = nil) async {
        guard let selected, sessionReady else { return }
        let arguments = ["launch", selected, agent.rawValue, verb, workMode,
                         model.trimmingCharacters(in: .whitespacesAndNewlines), effort, (promptOverride ?? prompt)?.path ?? ""]
        await perform { try await terminal(arguments) }
    }

    func terminalAction(_ args: [String]) async {
        await perform { try await terminal(args) }
    }

    private func terminal(_ args: [String]) async throws {
        jobs.append(try await Backend.openTerminal(args))
    }

    func checkTerminalJobs() async {
        while !jobs.isEmpty && !Task.isCancelled {
            let fm = FileManager.default
            let stalled = jobs.filter { !fm.fileExists(atPath: $0.startedFile.path) && Date().timeIntervalSince($0.created) > 25 }
            let finished = jobs.filter { fm.fileExists(atPath: $0.statusFile.path) } + stalled
            if !finished.isEmpty {
                for job in finished { try? fm.removeItem(at: job.folder) }
                jobs.removeAll { job in finished.contains { $0.id == job.id } }
                if !stalled.isEmpty {
                    message = tr("O Terminal não iniciou a sessão. Abra o Terminal uma vez e tente novamente.")
                }
                await refreshTools()
                if let path = selected { await loadProject(path, pickAgent: false) }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
    }

    func reloadAccounts() async {
        async let codex = try? Backend.run(["auth", "codex"])
        async let claude = try? Backend.run(["auth", "claude"])
        let (codexStatus, claudeStatus) = await (codex, claude)
        accounts = [.codex: codexStatus == "1\n", .claude: claudeStatus == "1\n"]
    }

    func refreshTools() async {
        do {
            tools = Backend.lines(try await Backend.run(["tools"]))
        } catch {
            message = error.localizedDescription
        }
        await reloadAccounts()
    }

    func showReport(_ title: String, _ args: [String]) async {
        await perform { detail = TextResult(title: title, text: try await Backend.run(args)) }
    }

    @discardableResult
    func perform(_ operation: () async throws -> Void) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            try await operation()
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func checkAppUpdate(automatic: Bool) async {
        guard !checkingApp, staged == nil else { return }
        checkingApp = true
        defer { checkingApp = false }
        do {
            let release = try await Updates.latest()
            guard let version = release.version else { throw AppFailure(tr("A versão publicada tem um formato desconhecido.")) }
            if Updates.newer(version, than: Updates.currentVersion) {
                appUpdate = tr("Versão %@ publicada no GitHub.", version)
                if automatic && UserDefaults.standard.bool(forKey: "installAppUpdates") {
                    let update = try await Updates.stage(release)
                    if UserDefaults.standard.bool(forKey: "installAppUpdates") {
                        staged = update
                        appUpdate = tr("Versão %@ pronta. Será aplicada ao sair do app.", version)
                    } else { update.discard() }
                }
            } else {
                appUpdate = tr("Assistente atualizado (%@).", Updates.currentVersion)
            }
        } catch {
            appUpdate = error.localizedDescription
        }
    }

    func discardAppUpdate() {
        staged?.discard()
        staged = nil
        appUpdate = ""
    }

    func updateIntegrations(showReport: Bool) async {
        guard jobs.isEmpty, !busy, !updatingIntegrations else { return }
        updatingIntegrations = true
        defer { updatingIntegrations = false }
        do {
            let output = try await Backend.run(["update", "integrations"])
            integrationUpdate = tr("Integrações verificadas. Abra uma nova sessão para aplicar mudanças.")
            if showReport && !output.isEmpty { detail = TextResult(title: tr("Atualização das integrações"), text: output) }
        } catch {
            integrationUpdate = tr("Alguma integração precisa de atenção.")
            if showReport { message = error.localizedDescription }
        }
        await refreshTools()
    }

    func runDailyUpdates() async {
        let preferences = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        if preferences.bool(forKey: "installAppUpdates"), now - preferences.double(forKey: "lastAppCheck") >= 86_400 {
            preferences.set(now, forKey: "lastAppCheck")
            await checkAppUpdate(automatic: true)
        }
        if preferences.bool(forKey: "updateIntegrations"), jobs.isEmpty, !busy,
           now - preferences.double(forKey: "lastIntegrationCheck") >= 86_400 {
            preferences.set(now, forKey: "lastIntegrationCheck")
            await updateIntegrations(showReport: false)
        }
    }
}

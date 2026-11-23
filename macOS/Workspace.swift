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

struct ProjectLayout {
    let instructions: String
    let progress: String
    let continuing: String
    let prompts: String
    let docs: String
    let attachments: String

    init?(_ paths: [String]) {
        guard paths.count == 6 else { return nil }
        (instructions, progress, continuing, prompts, docs, attachments) =
            (paths[0], paths[1], paths[2], paths[3], paths[4], paths[5])
    }
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
    @Published var layout: ProjectLayout?
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
            layout = nil
            prompt = nil
        }
        do {
            async let infoOutput = Backend.run(["info", path])
            async let layoutOutput = Backend.run(["layout", path])
            let info = Backend.lines(try await infoOutput)
            let resolvedLayout = ProjectLayout(Backend.lines(try await layoutOutput))
            guard selected == path, !Task.isCancelled else { return }
            layout = resolvedLayout
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
            if selected == project, let layout {
                prompt = URL(fileURLWithPath: project).appendingPathComponent("\(layout.prompts)/\(name).md")
                notice = tr("Pedido salvo e selecionado para a próxima sessão.")
            }
        }
    }

    func attach(_ file: URL, to project: String) async {
        await perform {
            _ = try await Backend.run(["attach", project, file.path])
            if selected == project { notice = tr("Anexo copiado.") }
        }
    }

    func restore(_ archive: URL, to parent: URL) async {
        await perform {
            let restored = try await Task.detached(priority: .utility) { try ProjectArchive.restore(source: archive, parent: parent) }.value
            notice = wf("restored")
            NSWorkspace.shared.activateFileViewerSelecting([restored])
        }
    }

    func reopenWorktree(_ entry: Worktree) async {
        await perform {
            _ = try await Backend.run(["select", entry.path])
            selected = entry.path
            await reloadProjects()
            let info = Backend.lines(try await Backend.run(["info", entry.path]))
            let preferred = Agent(rawValue: info.first ?? "") ?? entry.agent
            let options = Backend.lines(try await Backend.run(["prefs", entry.path, preferred.rawValue]))
            guard options.count == 3 else { return }
            try await terminal(["launch", entry.path, preferred.rawValue, "recente", options[2], options[0], options[1], ""])
        }
    }

    private var verificationJobs: [URL: ProjectCheck] = [:]

    func runCheck(_ check: ProjectCheck) async {
        guard let selected else { return }
        await perform {
            let config = ProjectChecks(path: selected)
            let command = config.command(check)
            guard !command.isEmpty else { throw AppFailure(wf("no_command")) }
            let job = try await terminal(["run-check", selected, command])
            verificationJobs[job.id] = check
            notice = wf("check_in_progress")
        }
    }

    func start(_ verb: String, using promptOverride: URL? = nil) async {
        guard let selected, sessionReady else { return }
        let arguments = ["launch", selected, agent.rawValue, verb, workMode,
                         model.trimmingCharacters(in: .whitespacesAndNewlines), effort, (promptOverride ?? prompt)?.path ?? ""]
        await perform { _ = try await terminal(arguments) }
    }

    func terminalAction(_ args: [String]) async {
        await perform { _ = try await terminal(args) }
    }

    @discardableResult
    private func terminal(_ args: [String]) async throws -> TerminalJob {
        if ["launch", "run-check", "shell", "dev", "menu"].contains(args.first ?? ""),
           args.count > 1, jobs.contains(where: { $0.project == args[1] }) {
            throw AppFailure(wf("busy_folder"))
        }
        let job = try await Backend.openTerminal(args)
        jobs.append(job)
        return job
    }

    func checkTerminalJobs() async {
        while !jobs.isEmpty && !Task.isCancelled {
            let fm = FileManager.default
            let stalled = jobs.filter { !fm.fileExists(atPath: $0.startedFile.path) && Date().timeIntervalSince($0.created) > 25 }
            let finished = jobs.filter { fm.fileExists(atPath: $0.statusFile.path) } + stalled
            if !finished.isEmpty {
                for job in finished {
                    if let check = verificationJobs.removeValue(forKey: job.id), let path = job.project {
                        let raw = try? String(contentsOf: job.statusFile, encoding: .utf8)
                        let code = raw.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        let result = code == 130 || code == 143 || code == 129 ? nil : code
                        ProjectChecks(path: path).record(check, code: result)
                        if path == selected {
                            notice = "\(check.runLabel) · \(CheckResult(code: result, date: Date()).report)"
                        }
                    }
                    try? fm.removeItem(at: job.folder)
                }
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
            if Updates.isUpdate(release) {
                appUpdate = tr("Versão %@ publicada no GitHub.", release.build.map { "\(version) · build \($0)" } ?? version)
                if automatic && UserDefaults.standard.bool(forKey: "installAppUpdates") {
                    let update = try await Updates.stage(release)
                    if UserDefaults.standard.bool(forKey: "installAppUpdates") {
                        staged = update
                        appUpdate = tr("Versão %@ pronta. Será aplicada ao sair do app.", release.build.map { "\(version) · build \($0)" } ?? version)
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

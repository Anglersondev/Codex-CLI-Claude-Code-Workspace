import Foundation
import SwiftUI

let workflowStrings: [String: [String]] = {
    guard let url = Bundle.main.url(forResource: "workflows", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let table = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
    return table
}()

var workflowLanguageIndex: Int {
    switch PanelLanguage.current { case .english: return 1; case .spanish: return 2; default: return 0 }
}

func wf(_ key: String) -> String {
    workflowStrings[key]?[workflowLanguageIndex] ?? key
}

private func decodedReport(_ raw: String) -> String {
    Backend.lines(raw).map { line in
        if line.first == "=" { return String(line.dropFirst()) }
        let parts = line.dropFirst().split(separator: "\t", maxSplits: 1).map(String.init)
        return parts.isEmpty ? "" : ([wf(parts[0])] + parts.dropFirst()).joined(separator: " ")
    }.joined(separator: "\n")
}

func environmentReport() async throws -> String {
    let tools = [("codex", "Codex CLI"), ("claude", "Claude Code"), ("git", "Git"), ("npm", "npm"), ("rtk", "RTK"),
                 ("optimizer-codex", "Token Optimizer · Codex"), ("optimizer-claude", "Token Optimizer · Claude")]
    return try await withThrowingTaskGroup(of: (Int, String).self) { group in
        for (index, tool) in tools.enumerated() {
            group.addTask { (index, tool.1 + "\n" + decodedReport(try await Backend.run(["probe", tool.0]))) }
        }
        var sections = Array(repeating: "", count: tools.count)
        for try await (index, report) in group { sections[index] = report }
        return sections.joined(separator: "\n\n")
    }
}

struct WorkflowProject: Identifiable {
    let path: String
    let agent: Agent
    var other: Agent { agent == .codex ? .claude : .codex }
    var id: String { path }
}

struct CheckpointPanel: View {
    let project: WorkflowProject
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @ViewState private var changes = ""
    @ViewState private var tests = ""
    @ViewState private var next = ""
    @ViewState private var loaded = false
    @ViewState private var failure: String?

    private func progressText(_ key: String) -> String {
        wf(key).replacingOccurrences(of: "{path}", with: workspace.layout?.progress ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(wf("review")).font(.title2.bold())
            Text(project.agent.name + " → " + project.other.name).font(.headline)
            Text(progressText("note_destination")).foregroundStyle(.secondary)
            if !loaded { ProgressView().controlSize(.small) }
            editor("files", $changes, height: 85)
            editor("tests", $tests, height: 46)
            editor("next", $next, height: 46)
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Button(wf("cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(wf("switch_only")) { Task { await finish(save: false) } }
                Button(wf("save_only")) { Task { await finish(save: true, select: false) } }
                    .disabled(!canSave)
                Button(wf("save_open")) { Task { await finish(save: true) } }
                    .buttonStyle(.borderedProminent).disabled(!canSave)
            }
        }
        .disabled(workspace.busy)
        .padding(22).frame(width: 545)
        .task {
            do { changes = decodedReport(try await Backend.run(["checkpoint-files", project.path])) }
            catch { changes = wf("no_status") }
            loaded = true
        }
    }

    private func editor(_ key: String, _ value: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(wf(key)).font(.subheadline.weight(.semibold))
            TextEditor(text: value).frame(height: height).accessibilityLabel(Text(wf(key)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.3)))
        }
    }

    private var canSave: Bool { loaded && !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func finish(save: Bool, select: Bool = true) async {
        let path = project.path, agent = project.other
        if save {
            let saved = await workspace.perform {
                if select && workspace.jobs.contains(where: { $0.project == path }) { throw AppFailure(wf("busy_folder")) }
                let stamp = ISO8601DateFormatter().string(from: Date())
                let result = tests.trimmingCharacters(in: .whitespacesAndNewlines)
                let note = "\n\n## \(wf("checkpoints")) · \(stamp) · \(project.agent.rawValue) → \(agent.rawValue)\n" +
                    "\n### \(wf("files"))\n\(changes)\n\n### \(wf("tests"))\n\(result.isEmpty ? wf("no_tests") : result)\n" +
                    "\n### \(wf("next"))\n\(next)\n"
                guard note.utf8.count <= 60000 else { throw AppFailure(wf("too_large")) }
                _ = try await Backend.run(["checkpoint-append", path, note])
                workspace.notice = progressText("saved")
            }
            guard saved else {
                failure = workspace.message
                workspace.message = nil
                return
            }
        }
        dismiss()
        guard select else { await workspace.loadProject(path, pickAgent: false); return }
        let done = await workspace.perform {
            _ = try await Backend.run(["select-agent", path, agent.rawValue])
            workspace.agent = agent
            workspace.prompt = nil
            await workspace.loadProject(path, pickAgent: false)
            await workspace.loadPreferences(path, agent)
        }
        if done && save {
            await workspace.terminalAction(["launch", path, agent.rawValue, "handoff", workspace.workMode,
                                            workspace.model, workspace.effort, progressText("resume_prompt")])
        }
    }
}

struct WorktreePanel: View {
    let project: WorkflowProject
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @ViewState private var agent: Agent
    @ViewState private var task = String(UUID().uuidString.prefix(8)).lowercased()
    @ViewState private var failure: String?

    init(project: WorkflowProject, workspace: Workspace) {
        self.project = project
        self.workspace = workspace
        _agent = ViewState(wrappedValue: project.other)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(wf("isolated_title")).font(.title2.bold())
            Picker(wf("agent"), selection: $agent) {
                ForEach(Agent.allCases) { Text($0.name).tag($0) }
            }.pickerStyle(.segmented)
            TextField(wf("task"), text: $task)
            let valid = task.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil
            if valid {
                LabeledContent(wf("branch"), value: "assistente/\(agent.rawValue)-\(task)")
                LabeledContent(wf("folder"), value: "\(project.path)-\(agent.rawValue)-\(task)")
            } else { Text(wf("invalid_task")).foregroundStyle(.secondary) }
            Text(wf("base")).font(.callout).foregroundStyle(.secondary)
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(wf("cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if workspace.busy { ProgressView().controlSize(.small) }
                Button(wf("create_open")) { Task { await create() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!valid)
            }
        }.disabled(workspace.busy).interactiveDismissDisabled(workspace.busy).padding(22).frame(width: 500)
    }

    private func create() async {
        var folder = ""
        let done = await workspace.perform {
            let output = try await Backend.run(["worktree-create", project.path, agent.rawValue, task])
            guard let path = Backend.lines(output).first else { throw AppFailure(wf("need_repo")) }
            folder = path
            _ = try await Backend.run(["select-agent", path, agent.rawValue])
            workspace.selected = path
            await workspace.reloadProjects()
        }
        if done {
            dismiss()
            await workspace.terminalAction(["launch", folder, agent.rawValue, "novo", "trabalhar", "", "", ""])
        } else {
            failure = workspace.message
            workspace.message = nil
        }
    }
}

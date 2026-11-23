import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct Worktree: Identifiable {
    let path: String
    let branch: String
    let status: String
    let changes: String
    var id: String { path }
    var agent: Agent { branch.hasPrefix("assistente/claude-") ? .claude : .codex }
}

struct WorktreesPanel: View {
    let project: String
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @ViewState private var entries: [Worktree] = []
    @ViewState private var selected: String?
    @ViewState private var pendingRemoval: Worktree?
    @ViewState private var error: String?
    @ViewState private var loading = true

    private var entry: Worktree? { entries.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(wf("worktrees")).font(.title2.bold())
            if loading && entries.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                Text(error ?? wf("no_worktrees")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selected) {
                    ForEach(entries) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(item.branch, systemImage: "arrow.triangle.branch").font(.headline)
                            Text(item.path).font(.caption).lineLimit(1).truncationMode(.middle)
                        }.padding(.vertical, 4).tag(item.id)
                    }
                }
                if let entry {
                    let key = entry.status == "clean" ? "worktree_clean" : (entry.status == "dirty" ? "pending" : "worktree_unknown")
                    Label(wf(key), systemImage: entry.status == "clean" ? "checkmark.circle" : "exclamationmark.circle")
                    if !entry.changes.isEmpty {
                        ScrollView {
                            Text(entry.changes).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 80)
                    }
                    HStack {
                        Button(wf("open_folder")) { NSWorkspace.shared.open(URL(fileURLWithPath: entry.path)) }
                        Button(wf("remove_worktree")) { pendingRemoval = entry }
                            .disabled(loading || entry.status != "clean" || workspace.jobs.contains { $0.project == entry.path })
                        Spacer()
                        Button(wf("open_session")) {
                            dismiss()
                            Task { await workspace.reopenWorktree(entry) }
                        }.buttonStyle(.borderedProminent)
                            .disabled(loading || entry.status == "unknown" || workspace.jobs.contains { $0.project == entry.path })
                    }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            HStack {
                Button(tr("Fechar")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(tr("Atualizar")) { Task { await refresh() } }.disabled(loading)
            }
        }.padding(22).frame(width: 680, height: 440)
        .task { await refresh() }
        .confirmationDialog(wf("confirm_remove_worktree"), isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible) {
            Button(wf("remove_worktree"), role: .destructive) {
                guard let item = pendingRemoval else { return }
                Task {
                    do {
                        loading = true
                        _ = try await Backend.run(["worktree-remove", project, item.path])
                        await workspace.reloadProjects()
                        await refresh()
                    } catch {
                        loading = false
                        self.error = error.localizedDescription
                    }
                }
            }
        }
    }

    private func refresh() async {
        loading = true
        defer { loading = false }
        do {
            let records = try await Backend.run(["worktree-list", project]).components(separatedBy: "\u{0}")
            entries = stride(from: 0, to: records.count - 1, by: 4).compactMap { index in
                guard index + 3 < records.count else { return nil }
                return Worktree(path: records[index], branch: records[index + 1], status: records[index + 2], changes: records[index + 3])
            }
            if !entries.contains(where: { $0.id == selected }) { selected = entries.first?.id }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ProfilePanel: View {
    let project: String
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @ViewState private var agent: Agent
    @ViewState private var model = ""
    @ViewState private var mode = "trabalhar"
    @ViewState private var effort = ""
    @ViewState private var loaded = false
    @ViewState private var error: String?

    init(project: String, workspace: Workspace) {
        self.project = project
        self.workspace = workspace
        _agent = ViewState(initialValue: workspace.agent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(wf("profile").replacingOccurrences(of: "…", with: "")).font(.title2.bold())
            Form {
                Picker(wf("choose_agent"), selection: $agent) {
                    ForEach(Agent.allCases) { Text($0.name).tag($0) }
                }
                Picker(tr("Permissões"), selection: $mode) {
                    Text(wf("work")).tag("trabalhar")
                    Text(wf("planning")).tag("planejar")
                }.disabled(!loaded)
                TextField(wf("model"), text: $model).disabled(!loaded)
                Picker(tr("Esforço"), selection: $effort) {
                    Text(tr("Automático")).tag("")
                    ForEach(agent.efforts, id: \.self) { Text($0).tag($0) }
                }.disabled(!loaded)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button(tr("Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(wf("save")) {
                    Task {
                        do {
                            _ = try await Backend.run(["profile-save", project, agent.rawValue, mode,
                                                       model.trimmingCharacters(in: .whitespacesAndNewlines), effort])
                            workspace.agent = agent
                            await workspace.loadPreferences(project, agent)
                            workspace.notice = wf("profile_saved")
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!loaded)
            }
        }.padding(22).frame(width: 460)
        .task(id: agent) {
            loaded = false
            let chosen = agent
            do {
                let values = Backend.lines(try await Backend.run(["prefs", project, chosen.rawValue]))
                guard !Task.isCancelled, chosen == agent, values.count == 3 else { return }
                (model, effort, mode) = (values[0], values[1], values[2])
                loaded = true
            } catch { self.error = error.localizedDescription }
        }
    }
}

enum ProjectCheck: String, CaseIterable, Identifiable {
    case test, build
    var id: Self { self }
    var commandLabel: String { wf(rawValue + "_command") }
    var runLabel: String { wf("run_" + rawValue) }
    var symbol: String { self == .test ? "checkmark.circle" : "hammer" }
}

struct CheckResult: Codable {
    let code: Int?
    let date: Date

    var report: String {
        let result: String
        if let code {
            result = code == 0 ? wf("check_ok") : wf("check_error").replacingOccurrences(of: "{code}", with: String(code))
        } else { result = wf("check_interrupted") }
        return "\(result) · \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct ProjectChecks {
    let path: String
    private var id: String { Data(path.utf8).base64EncodedString() }

    func command(_ check: ProjectCheck) -> String {
        UserDefaults.standard.string(forKey: "project-check-\(id)-\(check.rawValue)") ?? ""
    }

    func setCommand(_ command: String, for check: ProjectCheck) {
        let cleaned = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned != self.command(check) {
            UserDefaults.standard.removeObject(forKey: "project-result-\(id)-\(check.rawValue)")
        }
        UserDefaults.standard.set(cleaned, forKey: "project-check-\(id)-\(check.rawValue)")
    }

    func result(_ check: ProjectCheck) -> CheckResult? {
        guard let data = UserDefaults.standard.data(forKey: "project-result-\(id)-\(check.rawValue)") else { return nil }
        return try? JSONDecoder().decode(CheckResult.self, from: data)
    }

    func record(_ check: ProjectCheck, code: Int?) {
        UserDefaults.standard.set(try? JSONEncoder().encode(CheckResult(code: code, date: Date())),
                                  forKey: "project-result-\(id)-\(check.rawValue)")
    }

    var checkpoint: String {
        ProjectCheck.allCases.compactMap { check in result(check).map { "- \(check.runLabel) · \($0.report)" } }
            .joined(separator: "\n")
    }
}

struct ChecksPanel: View {
    let project: String
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @ViewState private var test = ""
    @ViewState private var build = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(wf("checks")).font(.title2.bold())
            Text(wf("checks_hint")).foregroundStyle(.secondary)
            Form {
                TextField(ProjectCheck.test.commandLabel, text: $test).font(.system(.body, design: .monospaced))
                TextField(ProjectCheck.build.commandLabel, text: $build).font(.system(.body, design: .monospaced))
            }
            HStack {
                Button(tr("Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(wf("save")) {
                    ProjectChecks(path: project).setCommand(test, for: .test)
                    ProjectChecks(path: project).setCommand(build, for: .build)
                    workspace.notice = wf("saved_checks")
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(workspace.jobs.contains { $0.project == project })
            }
        }.padding(22).frame(width: 490)
        .onAppear {
            test = ProjectChecks(path: project).command(.test)
            build = ProjectChecks(path: project).command(.build)
        }
    }
}

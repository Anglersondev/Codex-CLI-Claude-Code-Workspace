import AppKit
import SwiftUI

struct SettingsPanel: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @AppStorage("installAppUpdates") private var installAppUpdates = false
    @AppStorage("updateIntegrations") private var updateIntegrations = false
    @AppStorage("avoidDoubleCompression") private var avoidDoubleCompression = true
    @AppStorage("projectParent") private var projectParent = ""
    @AppStorage(PanelLanguage.preferenceKey) private var language: PanelLanguage = .automatic
    @ViewState private var accountToSwitch: Agent?
    @ViewState private var confirmSwitch = false
    @ViewState private var rtkAgent: Agent?
    @ViewState private var confirmRTK = false
    @ViewState private var optimizerAgent: Agent?
    @ViewState private var confirmOptimizer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(tr("Ajustes")).font(.title2.bold())
                Spacer()
                Button(tr("Concluir")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Form {
                Picker(tr("Idioma"), selection: $language) {
                    ForEach(PanelLanguage.allCases) { option in
                        Text(verbatim: option.title).tag(option)
                    }
                }
                Section(tr("Projetos")) {
                    LabeledContent(tr("Pasta padrão")) {
                        HStack {
                            Text(defaultProjectFolder(projectParent)?.path ?? tr("Escolher pasta")).lineLimit(1).truncationMode(.head)
                            Button(tr("Escolher…")) {
                                if let url = chooseDirectory(startingAt: defaultProjectFolder(projectParent)) { projectParent = url.path }
                            }
                        }
                    }
                }
                Section(tr("Agentes e contas")) {
                    ForEach(Agent.allCases) { agent in agentRow(agent) }
                    Button(wf("diagnosis")) {
                        Task {
                            await workspace.perform {
                                workspace.detail = Workspace.TextResult(title: wf("diagnosis"), text: try await environmentReport())
                            }
                        }
                    }.disabled(workspace.busy)
                    if workspace.busy { ProgressView().controlSize(.small) }
                }
                Section(tr("Integrações")) {
                    LabeledContent("RTK") {
                        HStack {
                            Text(version(2)).foregroundStyle(.secondary)
                            if !value(2).isEmpty, value(2) != "?" {
                                Menu(tr("Hooks")) {
                                    ForEach(Agent.allCases) { agent in
                                        Button(integrationAction(agent, enabled: isRTKEnabled(agent))) {
                                            rtkAgent = agent
                                            confirmRTK = true
                                        }
                                    }
                                }.fixedSize().disabled(actionDisabled)
                                Button(tr("Economia")) { Task { await workspace.showReport(tr("Economia registrada pelo RTK"), ["rtk-gain"]) } }
                            } else {
                                Link(tr("Instalar"), destination: URL(string: "https://www.rtk-ai.app/docs/getting-started/installation/")!)
                            }
                        }
                    }
                    LabeledContent("Token Optimizer") {
                        HStack {
                            Text(optimizerSummary).foregroundStyle(.secondary)
                            Menu(tr("Gerenciar")) {
                                ForEach(Agent.allCases) { agent in
                                    Button(integrationAction(agent, enabled: isOptimizerEnabled(agent))) {
                                        optimizerAgent = agent
                                        confirmOptimizer = true
                                    }
                                    .disabled(agent == .codex && value(5) != "1")
                                }
                            }.fixedSize().disabled(actionDisabled)
                        }
                    }
                    if !value(2).isEmpty {
                        Text(tr("Hook do RTK · Codex %@ · Claude %@", rtkStatus(.codex), rtkStatus(.claude)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle(tr("Evitar dupla compactação do Terminal"), isOn: $avoidDoubleCompression)
                    Text(tr("Nas sessões abertas pelo app, o RTK fica responsável pela saída do Bash quando seu hook está configurado. Os outros recursos do Token Optimizer continuam disponíveis."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(tr("Atualizações automáticas")) {
                    Toggle(tr("Instalar novas versões do Assistente pelo GitHub"), isOn: $installAppUpdates)
                    Toggle(tr("Atualizar RTK e Token Optimizer"), isOn: $updateIntegrations)
                    Text(tr("O app consulta no máximo uma vez por dia quando estiver em uso. Atualizações do Assistente são aplicadas ao sair."))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(tr("Verificar Assistente")) {
                            Task { await workspace.checkAppUpdate(automatic: installAppUpdates) }
                        }.disabled(workspace.checkingApp)
                        Button(tr("Atualizar integrações agora")) {
                            Task { await workspace.updateIntegrations(showReport: true) }
                        }.disabled(actionDisabled)
                        if workspace.checkingApp || workspace.updatingIntegrations { ProgressView().controlSize(.small) }
                    }
                    if !workspace.appUpdate.isEmpty { Text(workspace.appUpdate).font(.callout) }
                    if !workspace.integrationUpdate.isEmpty { Text(workspace.integrationUpdate).font(.callout) }
                    if workspace.staged != nil {
                        Button(tr("Sair para aplicar")) { NSApp.terminate(nil) }.disabled(!workspace.jobs.isEmpty)
                    }
                    Link(tr("Versões publicadas"), destination: Updates.releases)
                }
                Section(tr("Sobre")) { AboutLinks() }
            }
            .formStyle(.grouped)
        }
        .padding(20).frame(width: 680, height: 610)
        .sheet(item: $workspace.detail) { TextPanel(result: $0) }
        .alert("Assistente IA", isPresented: Binding(
            get: { workspace.message != nil }, set: { if !$0 { workspace.message = nil } }
        )) {
            Button("OK") { workspace.message = nil }
        } message: { Text(workspace.message ?? "") }
        .confirmationDialog(tr("Trocar de conta?"), isPresented: $confirmSwitch, titleVisibility: .visible) {
            Button(tr("Sair e entrar com outra conta")) {
                if let agent = accountToSwitch { Task { await workspace.terminalAction(["login", agent.rawValue, "switch"]) } }
            }
        } message: {
            Text(tr("O login global de %@ será trocado. A pasta selecionada fica aberta. O acesso ao histórico anterior depende da conta e do agente.", accountToSwitch?.name ?? tr("este agente")))
        }
        .confirmationDialog(tr("Alterar integração global do RTK?"), isPresented: $confirmRTK, titleVisibility: .visible) {
            Button(tr("Aplicar ao agente")) {
                if let agent = rtkAgent {
                    let action = isRTKEnabled(agent) ? "desativar" : "ativar"
                    Task { await workspace.terminalAction(["rtk-hook", agent.rawValue, action]) }
                }
            }
        } message: {
            Text(tr("A configuração vale para %@ em todas as pastas. Abra uma nova sessão depois.", rtkAgent?.name ?? tr("este agente")))
        }
        .confirmationDialog(tr("Alterar Token Optimizer?"), isPresented: $confirmOptimizer, titleVisibility: .visible) {
            Button(tr("Aplicar ao agente")) {
                if let agent = optimizerAgent {
                    let action = isOptimizerEnabled(agent) ? "disable" : "enable"
                    Task { await workspace.terminalAction(["optimizer-hook", agent.rawValue, action]) }
                }
            }
        } message: {
            Text(tr("No Codex, o botão controla os hooks automáticos. No Claude Code, controla o plugin do usuário. Abra outra sessão depois."))
        }
        .onChange(of: installAppUpdates) { enabled in
            if enabled {
                UserDefaults.standard.removeObject(forKey: "lastAppCheck")
                Task { await workspace.runDailyUpdates() }
            } else { workspace.discardAppUpdate() }
        }
        .onChange(of: updateIntegrations) { enabled in
            if enabled {
                UserDefaults.standard.removeObject(forKey: "lastIntegrationCheck")
                Task { await workspace.runDailyUpdates() }
            }
        }
    }

    private var actionDisabled: Bool {
        workspace.busy || workspace.updatingIntegrations || !workspace.jobs.isEmpty
    }

    private func value(_ index: Int) -> String {
        workspace.tools.indices.contains(index) ? workspace.tools[index] : ""
    }

    private func version(_ index: Int) -> String {
        if workspace.tools.isEmpty { return tr("Verificando…") }
        if value(index) == "?" { return tr("Versão indisponível") }
        return value(index).isEmpty ? tr("Ausente") : value(index)
    }

    private func isRTKEnabled(_ agent: Agent) -> Bool {
        value(agent == .codex ? 3 : 4) == "1"
    }

    private func rtkStatus(_ agent: Agent) -> String {
        isRTKEnabled(agent) ? tr("configurado") : tr("ausente")
    }

    private func isOptimizerEnabled(_ agent: Agent) -> Bool {
        value(agent == .codex ? 7 : 6) == "1"
    }

    private func integrationAction(_ agent: Agent, enabled: Bool) -> String {
        tr(enabled ? "Desativar %@…" : "Ativar %@…", agent.name)
    }

    private var optimizerSummary: String {
        let names = Agent.allCases.filter(isOptimizerEnabled).map(\.name)
        switch names.count {
        case 2: return tr("%@ e %@", names[0], names[1])
        case 1: return names[0]
        default: return tr("Pausado ou ausente")
        }
    }

    @ViewBuilder private func agentRow(_ agent: Agent) -> some View {
        let index = agent == .codex ? 0 : 1
        LabeledContent(agent.name) {
            HStack(spacing: 9) {
                Text(version(index)).foregroundStyle(.secondary)
                if !value(index).isEmpty, value(index) != "?" {
                    if workspace.accounts[agent] == true {
                        Button(tr("Trocar conta…")) { accountToSwitch = agent; confirmSwitch = true }
                            .disabled(actionDisabled)
                    } else if workspace.accounts[agent] == false {
                        Button(tr("Entrar")) { Task { await workspace.terminalAction(["login", agent.rawValue, "login"]) } }
                            .disabled(actionDisabled)
                    }
                    Button(tr("Atualizar")) { Task { await workspace.terminalAction(["update", agent.rawValue]) } }
                        .disabled(actionDisabled)
                } else if !workspace.tools.isEmpty {
                    let source = agent == .codex ? "https://developers.openai.com/codex/cli" : "https://code.claude.com/docs/en/setup"
                    if let url = URL(string: source) { Link(tr("Instalar"), destination: url) }
                }
            }
        }
    }
}

struct AboutLinks: View {
    @AppStorage(PanelLanguage.preferenceKey) private var language: PanelLanguage = .automatic

    var body: some View {
        let current = language.effective
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: current.localized("Versão %@"), Updates.currentVersion) + " · build \(Updates.currentBuild)")
                .foregroundStyle(.secondary)
            Link(current.localized("Desenvolvido por Anglerson"), destination: URL(string: "https://anglerson.com.br")!)
            Link(current.localized("Pague um café ☕"), destination: URL(string: "https://pixgg.com/Anglerson")!)
        }
    }
}

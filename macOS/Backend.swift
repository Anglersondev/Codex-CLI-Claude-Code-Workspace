import AppKit
import Foundation

enum PanelLanguage: String, CaseIterable, Identifiable {
    case automatic, portuguese = "pt-BR", english = "en", spanish = "es"

    static let preferenceKey = "interfaceLanguage"
    var id: String { rawValue }

    var effective: PanelLanguage {
        guard self == .automatic else { return self }
        if let preset = ProcessInfo.processInfo.environment["ASSISTENTE_LANG"],
           let language = PanelLanguage(rawValue: preset), language != .automatic {
            return language
        }
        let language = Bundle.main.preferredLocalizations.first ?? "pt-BR"
        if language.hasPrefix("en") { return .english }
        if language.hasPrefix("es") { return .spanish }
        return .portuguese
    }

    static var current: PanelLanguage {
        let preference = UserDefaults.standard.string(forKey: preferenceKey) ?? ""
        return (PanelLanguage(rawValue: preference) ?? .automatic).effective
    }

    var title: String {
        switch self {
        case .automatic: return tr("Automático")
        case .portuguese: return "Português (Brasil)"
        case .english: return "English"
        case .spanish: return "Español"
        }
    }

    // The legacy Bash launcher ships Portuguese and English menus.
    var terminalLanguage: String {
        self == .portuguese ? "pt-BR" : "en"
    }

    private static let translations: [PanelLanguage: Bundle] = Dictionary(uniqueKeysWithValues:
        allCases.compactMap { language in
            guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { return nil }
            return (language, bundle)
        }
    )

    func localized(_ key: String) -> String {
        (Self.translations[self] ?? .main).localizedString(forKey: key, value: key, table: nil)
    }
}

func tr(_ key: String, _ arguments: CVarArg...) -> String {
    let language = PanelLanguage.current
    let message = language.localized(key)
    return arguments.isEmpty ? message : String(format: message, locale: Locale(identifier: language.rawValue), arguments: arguments)
}

enum Agent: String, CaseIterable, Identifiable {
    case codex, claude

    var id: String { rawValue }
    var name: String { self == .codex ? "Codex" : "Claude Code" }
    var efforts: [String] {
        self == .codex ? ["low", "medium", "high", "xhigh", "max", "ultra"] : ["low", "medium", "high", "xhigh", "max"]
    }
}

struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Backend {
    static let launcher = Bundle.main.resourceURL!.appendingPathComponent("ASSISTENTE-IA-MAC.command")

    static func capture(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.hasPrefix("@"), let description = workflowStrings[String(message.dropFirst())] {
                throw AppFailure(description[workflowLanguageIndex])
            }
            throw AppFailure(message.isEmpty ? tr("A operação terminou com código %d.", process.terminationStatus) : message)
        }
        return text
    }

    static func run(_ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            var environment = ProcessInfo.processInfo.environment
            environment["ASSISTENTE_LANG"] = PanelLanguage.current.terminalLanguage
            return try capture("/bin/bash", [launcher.path, "--app"] + arguments, environment: environment)
        }.value
    }

    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").dropLast().map { $0 }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @MainActor
    static func openTerminal(_ arguments: [String]) async throws -> TerminalJob {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw AppFailure(tr("O Terminal do macOS não foi encontrado."))
        }
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("assistente-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let job = TerminalJob(folder: folder, project: arguments.first == "launch" ? arguments[1] : nil)
        let script = folder.appendingPathComponent("Assistente-IA.command")
        let command = (["/bin/bash", launcher.path, "--app"] + arguments).map(shellQuote).joined(separator: " ")
        let stateOverride = ProcessInfo.processInfo.environment["ASSISTENTE_STATE_DIR"].map {
            "export ASSISTENTE_STATE_DIR=\(shellQuote($0))"
        } ?? ""
        let avoidDoubleCompression = UserDefaults.standard.object(forKey: "avoidDoubleCompression") as? Bool ?? true
        let body = """
        #!/bin/bash
        export ASSISTENTE_LANG=\(shellQuote(PanelLanguage.current.terminalLanguage))
        export ASSISTENTE_BASH_COMPRESSION=\(avoidDoubleCompression ? "avoid" : "inherit")
        \(stateOverride)
        : > \(shellQuote(job.startedFile.path))
        finish() {
          status=$?
          /bin/rm -f \(shellQuote(script.path))
          printf '%s\\n' "$status" > \(shellQuote(job.statusFile.path))
          /usr/bin/open -a \(shellQuote(Bundle.main.bundlePath))
        }
        trap finish EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        trap 'exit 129' HUP
        \(command)
        status=$?
        if [ "$status" -ne 0 ] && [ "$status" -ne 130 ]; then
          printf '\\n%s\\n' \(shellQuote(tr("Enter para voltar ao Assistente.")))
          IFS= read -r ignored
        fi
        exit "$status"
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: configuration)
            return job
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }
}

struct TerminalJob: Identifiable {
    let folder: URL
    let project: String?
    let created = Date()
    var id: URL { folder }
    var startedFile: URL { folder.appendingPathComponent("started") }
    var statusFile: URL { folder.appendingPathComponent("status") }
}

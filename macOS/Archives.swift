import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ProjectArchive {
    private static let rules = (try? String(contentsOf: Bundle.main.resourceURL!
        .appendingPathComponent("lib/backup-excludes.txt"), encoding: .utf8))?
        .split(whereSeparator: \.isNewline).map(String.init) ?? []

    private static func included(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { return false }
        let name = url.lastPathComponent.lowercased()
        if rules.contains("!" + name) { return true }
        return !rules.contains { pattern in
            if pattern.hasPrefix("*") { return name.hasSuffix(pattern.dropFirst()) }
            if pattern.hasSuffix("*") { return name.hasPrefix(pattern.dropLast()) }
            return pattern == name
        }
    }

    static func contents(of folder: URL) throws -> [String] {
        var failure: Error?
        let fm = FileManager.default
        guard let contents = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
                                           errorHandler: { _, error in failure = error; return false }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let root = folder.lastPathComponent
        let base = folder.deletingLastPathComponent().path
        var names = [root]
        for case let url as URL in contents {
            if try included(url) {
                names.append(String(url.path.dropFirst(base.count + (base == "/" ? 0 : 1))))
            } else { contents.skipDescendants() }
        }
        if let failure { throw failure }
        return names
    }

    private static func workFolder(in parent: URL) throws -> URL {
        let folder = parent.appendingPathComponent(".assistente-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }

    static func save(project: URL, names: [String], to target: URL) throws {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath()
        let root = project.resolvingSymlinksInPath()
        guard parent != root && !parent.path.hasPrefix(root.path + "/") else { throw AppFailure(wf("outside_project")) }
        let base = root.deletingLastPathComponent()
        let temporary = try workFolder(in: parent)
        defer { try? fm.removeItem(at: temporary) }
        let list = temporary.appendingPathComponent("entries")
        let archive = temporary.appendingPathComponent("backup.zip")
        for entry in names.dropFirst() {
            var candidate = base.appendingPathComponent(entry)
            while candidate.path != root.path {
                guard try included(candidate) else { throw AppFailure(wf("project_changed")) }
                candidate.deleteLastPathComponent()
            }
        }
        try Data((names.map { "./" + $0 }.joined(separator: "\0") + "\0").utf8).write(to: list)
        _ = try Backend.capture("/usr/bin/bsdtar", ["-cf", archive.path, "--format", "zip", "--no-recursion",
            "--no-xattrs", "--no-acls", "--no-fflags", "--no-mac-metadata", "-C", base.path, "--null", "-T", list.path])
        // NSSavePanel already asked before replacing an existing file; replace it in one step.
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: archive, backupItemName: nil, options: [])
        } else {
            try fm.moveItem(at: archive, to: target)
        }
    }

    static func restore(source: URL, parent: URL) throws -> URL {
        let fm = FileManager.default
        let staging = try workFolder(in: parent)
        defer { try? fm.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("restore.zip")
        try fm.copyItem(at: source, to: archive)
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data([0x50, 0x4b, 3, 4]) else {
            throw AppFailure(wf("unsafe_zip"))
        }
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        let names = Backend.lines(try Backend.capture("/usr/bin/bsdtar", ["-tf", archive.path], environment: environment))
        let metadata = Backend.lines(try Backend.capture("/usr/bin/bsdtar", ["-tvf", archive.path], environment: environment))
        guard !names.isEmpty, names.count <= 100_000, names.count == metadata.count else {
            throw AppFailure(wf("unsafe_zip"))
        }
        var total: UInt64 = 0
        var seen = Set<String>()
        for (name, attributes) in zip(names, metadata) {
            let details = attributes.split(separator: " ", maxSplits: 6)
            guard details.count >= 6, details[0].first == "-" || details[0].first == "d",
                  let size = UInt64(details[4]), size <= 20 * 1024 * 1024 * 1024 - total else {
                throw AppFailure(wf("unsafe_zip"))
            }
            total += size
            let clean = name.hasPrefix("./") ? name.dropFirst(2) : name[...]
            let path = clean.hasSuffix("/") ? clean.dropLast() : clean
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.allSatisfy({ component in
                !component.isEmpty && component != "." && component != ".." &&
                    !component.contains("\\") && !component.contains(":") &&
                    !component.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            }), seen.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw AppFailure(wf("unsafe_zip"))
            }
        }
        let extracted = staging.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: false)
        _ = try Backend.capture("/usr/bin/bsdtar", ["-xkf", archive.path, "--no-same-owner",
            "--no-same-permissions", "--no-acls", "--no-xattrs", "--no-fflags", "--no-mac-metadata", "-C", extracted.path])
        let name = source.deletingPathExtension().lastPathComponent
        guard name != ".", name != "..", !name.isEmpty else { throw AppFailure(wf("unsafe_zip")) }
        let target = parent.appendingPathComponent(name, isDirectory: true)
        guard !fm.fileExists(atPath: target.path) else { throw AppFailure(wf("zip_conflict")) }
        try fm.moveItem(at: extracted, to: target)
        return target
    }
}

struct BackupPanel: View {
    let project: String
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @ViewState private var entries: [String]?
    @ViewState private var error: String?
    @ViewState private var writing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(wf("backup_review")).font(.title2.bold())
            Text(wf("backup_excludes")).foregroundStyle(.secondary)
            if let entries {
                let count = wf("backup_count").replacingOccurrences(of: "{count}", with: String(entries.count))
                Text(count).font(.subheadline.bold())
                ScrollView {
                    Text(entries.joined(separator: "\n")).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            } else if error == nil { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(tr("Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if writing { ProgressView().controlSize(.small) }
                Button(wf("save_zip"), action: save).disabled(entries == nil || writing)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(22).frame(width: 615, height: 455).interactiveDismissDisabled(writing)
        .task {
            do {
                let root = URL(fileURLWithPath: project, isDirectory: true)
                entries = try await Task.detached(priority: .utility) { try ProjectArchive.contents(of: root) }.value
            } catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        guard let entries else { return }
        let root = URL(fileURLWithPath: project, isDirectory: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.directoryURL = root.deletingLastPathComponent()
        let date = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = root.lastPathComponent + "-" + date + ".zip"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        writing = true
        Task {
            defer { writing = false }
            do {
                try await Task.detached(priority: .utility) { try ProjectArchive.save(project: root, names: entries, to: target) }.value
                workspace.notice = tr("Cópia ZIP criada.")
                NSWorkspace.shared.activateFileViewerSelecting([target])
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

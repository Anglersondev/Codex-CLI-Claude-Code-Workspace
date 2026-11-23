import AppKit
import CryptoKit
import Foundation
import Security

struct Release: Decodable {
    struct Asset: Decodable {
        let name: String
        let size: Int
        let digest: String?
        let browser_download_url: URL
    }

    let tag_name: String
    let assets: [Asset]

    var build: Int? {
        assets.compactMap { asset in
            guard asset.name.range(of: #"^Assistente-IA-Build-[1-9][0-9]{0,8}\.txt$"#, options: .regularExpression) != nil else { return nil as Int? }
            return Int(asset.name.dropFirst("Assistente-IA-Build-".count).dropLast(4))
        }.max()
    }

    var version: String? {
        guard tag_name.range(of: #"^v?[0-9]{1,4}\.[0-9]{1,4}(\.[0-9]{1,4})?$"#, options: .regularExpression) != nil else { return nil }
        return tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name
    }
}

struct StagedUpdate {
    let app: URL
    let directory: URL
    let version: String

    func discard() {
        try? FileManager.default.removeItem(at: directory)
    }
}

enum Updates {
    static let repo = "Anglersondev/Codex-CLI-Claude-Code-Workspace"
    static let releases = URL(string: "https://github.com/\(repo)/releases")!
    static let assetName = "Assistente-IA-App-macOS.zip"
    static let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 90
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    static func newer(_ candidate: String, than installed: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            let values = version.split(separator: ".").compactMap { Int($0) }
            return Array((values + [0, 0, 0]).prefix(3))
        }
        return parts(installed).lexicographicallyPrecedes(parts(candidate))
    }

    static func isUpdate(_ release: Release) -> Bool {
        guard let version = release.version else { return false }
        if newer(version, than: currentVersion) { return true }
        return !newer(currentVersion, than: version) && (release.build ?? 0) > currentBuild
    }

    static func latest() async throws -> Release {
        let endpoint = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppFailure(tr("O GitHub não respondeu com uma versão publicada."))
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    static func stage(_ release: Release) async throws -> StagedUpdate {
        guard let version = release.version, isUpdate(release),
              let asset = release.assets.first(where: { $0.name == assetName }),
              let digest = asset.digest,
              digest.range(of: #"^sha256:[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              asset.browser_download_url.absoluteString == "\(releases.absoluteString)/download/\(release.tag_name)/\(assetName)",
              (1...25_000_000).contains(asset.size) else {
            throw AppFailure(tr("A versão publicada precisa do ZIP do app e do SHA-256 fornecido pelo GitHub."))
        }
        let destination = Bundle.main.bundleURL
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: destination.deletingLastPathComponent().path),
              !destination.path.contains("/AppTranslocation/") else {
            throw AppFailure(tr("Mova o app para uma pasta gravável, como Aplicativos, para atualizar automaticamente."))
        }
        let (download, response) = try await session.download(from: asset.browser_download_url)
        defer { try? fm.removeItem(at: download) }
        let host = response.url?.host ?? ""
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.url?.scheme == "https",
              host == "github.com" || host == "release-assets.githubusercontent.com" || host == "objects.githubusercontent.com" else {
            throw AppFailure(tr("O download da versão publicada falhou."))
        }
        let directory = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        do {
            let archive = directory.appendingPathComponent(assetName)
            try fm.moveItem(at: download, to: archive)
            return try await Task.detached(priority: .utility) {
                try verifyAndExtract(archive, directory: directory, version: version, build: release.build, size: asset.size, digest: digest, installed: destination)
            }.value
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    static func verifyAndExtract(_ archive: URL, directory: URL, version: String, build: Int?, size: Int, digest: String, installed: URL) throws -> StagedUpdate {
        let fm = FileManager.default
        let values = try archive.resourceValues(forKeys: [.fileSizeKey])
        guard values.fileSize == size else { throw AppFailure(tr("O tamanho do ZIP diverge do publicado.")) }
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == "sha256:" + checksum else { throw AppFailure(tr("O SHA-256 do ZIP diverge do publicado.")) }
        let extraction = directory.appendingPathComponent("release", isDirectory: true)
        _ = try Backend.capture("/usr/bin/ditto", ["-x", "-k", archive.path, extraction.path])
        let app = extraction.appendingPathComponent("Assistente IA.app", isDirectory: true)
        let candidate = Bundle(url: app)
        guard let current = Bundle(url: installed),
              candidate?.bundleIdentifier == current.bundleIdentifier,
              candidate?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version,
              build == nil || Int(candidate?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") == build,
              (try app.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == false else {
            throw AppFailure(tr("O bundle baixado tem versão ou identificação diferente da esperada."))
        }
        _ = try Backend.capture("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        if let team = signatureTeam(installed), signatureTeam(app) != team {
            throw AppFailure(tr("A assinatura do desenvolvedor diverge da instalação atual."))
        }
        try fm.removeItem(at: archive)
        return StagedUpdate(app: app, directory: directory, version: version)
    }

    private static func signatureTeam(_ app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func install(_ update: StagedUpdate, at destination: URL) throws {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: update.app, backupItemName: nil, options: [.usingNewMetadataOnly])
        update.discard()
    }
}

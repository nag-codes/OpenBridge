import Foundation

nonisolated enum BridgeAIProviderSecretKind: String, Sendable {
    case apiKey
    case oauthAccessToken
    case oauthRefreshToken
}

private final nonisolated class BridgeAIProviderStoreURLOverride: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?

    func set(_ url: URL?) {
        lock.withLock {
            self.url = url
        }
    }

    func get() -> URL? {
        lock.withLock {
            url
        }
    }
}

nonisolated enum BridgeAIProviderSecretStore {
    private static let storeURLOverride = BridgeAIProviderStoreURLOverride()

    private struct StoreFile: Codable {
        var settings = BridgeAIProviderSettings()
        var secrets: [String: String] = [:]

        init(settings: BridgeAIProviderSettings = BridgeAIProviderSettings(), secrets: [String: String] = [:]) {
            self.settings = settings
            self.secrets = secrets
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            settings = try container.decodeIfPresent(BridgeAIProviderSettings.self, forKey: .settings)
                ?? BridgeAIProviderSettings()
            secrets = try container.decodeIfPresent([String: String].self, forKey: .secrets) ?? [:]
        }
    }

    static func readSettings() async -> BridgeAIProviderSettings {
        await Task.detached {
            (try? loadStore().settings) ?? BridgeAIProviderSettings()
        }.value
    }

    static func saveSettings(_ settings: BridgeAIProviderSettings) async throws {
        try await Task.detached {
            var store = try loadStore()
            store.settings = settings
            try saveStore(store)
        }.value
        await notifyAIProviderStoreDidChange()
    }

    static func readSecret(
        for provider: BridgeAIProvider,
        kind: BridgeAIProviderSecretKind
    ) async -> String {
        await Task.detached {
            (try? loadStore().secrets[account(provider: provider, kind: kind)]) ?? ""
        }.value
    }

    static func saveSecret(
        _ secret: String,
        for provider: BridgeAIProvider,
        kind: BridgeAIProviderSecretKind
    ) async throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        try await Task.detached {
            let account = account(provider: provider, kind: kind)
            var store = try loadStore()
            if trimmed.isEmpty {
                store.secrets.removeValue(forKey: account)
                try saveStore(store)
                return
            }
            store.secrets[account] = trimmed
            try saveStore(store)
        }.value
        await notifyAIProviderStoreDidChange()
    }

    static func hasSecret(
        for provider: BridgeAIProvider,
        kind: BridgeAIProviderSecretKind
    ) async -> Bool {
        let value = await readSecret(for: provider, kind: kind)
        return !value.isEmpty
    }

    private static func account(provider: BridgeAIProvider, kind: BridgeAIProviderSecretKind) -> String {
        "\(provider.rawValue).\(kind.rawValue)"
    }

    private static func notifyAIProviderStoreDidChange() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .aiProviderSettingsDidChange, object: nil)
        }
    }

    private static var storeURL: URL {
        if let override = resolvedStoreURLOverride {
            return override
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("OpenBridge", isDirectory: true)
            .appendingPathComponent("AI Providers", isDirectory: true)
            .appendingPathComponent("secrets.json", isDirectory: false)
    }

    static func setStoreURLForTesting(_ url: URL?) {
        storeURLOverride.set(url)
    }

    private static var resolvedStoreURLOverride: URL? {
        storeURLOverride.get()
    }

    private static func loadStore() throws -> StoreFile {
        let url = storeURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return StoreFile()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(StoreFile.self, from: data)
    }

    private static func saveStore(_ store: StoreFile) throws {
        let url = storeURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(store)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

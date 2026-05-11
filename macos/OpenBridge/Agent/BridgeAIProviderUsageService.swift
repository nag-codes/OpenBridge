import Foundation
import KWWKAI

nonisolated struct BridgeAIProviderUsageSnapshot: Codable, Equatable, Sendable {
    var fiveHour: BridgeAIProviderUsageWindow?
    var oneWeek: BridgeAIProviderUsageWindow?
    var updatedAt: Date?
    var source: BridgeAIProviderUsageSource
    var message: String?

    static let unavailable = BridgeAIProviderUsageSnapshot(
        fiveHour: nil,
        oneWeek: nil,
        updatedAt: nil,
        source: .unavailable,
        message: nil
    )

    var isAvailable: Bool {
        fiveHour != nil || oneWeek != nil
    }

    func label(for window: BridgeAIProviderUsageWindowKind) -> String {
        switch self.window(for: window) {
        case let usage?:
            "\(Int(usage.remainingPercent.rounded()))% left"
        case nil:
            "unavailable"
        }
    }

    func tone(for window: BridgeAIProviderUsageWindowKind) -> UsageBadgeTone {
        guard let usage = self.window(for: window) else { return .unavailable }
        if usage.remainingPercent <= 10 {
            return .danger
        }
        if usage.remainingPercent <= 25 {
            return .warning
        }
        return .good
    }

    func resetText(for window: BridgeAIProviderUsageWindowKind) -> String {
        guard let resetsAt = self.window(for: window)?.resetsAt else { return "Unknown reset" }
        return "Resets \(resetsAt.formatted(date: .omitted, time: .shortened))"
    }

    private func window(for window: BridgeAIProviderUsageWindowKind) -> BridgeAIProviderUsageWindow? {
        switch window {
        case .fiveHour:
            fiveHour
        case .oneWeek:
            oneWeek
        }
    }
}

nonisolated enum BridgeAIProviderUsageWindowKind: String, Codable, Sendable {
    case fiveHour
    case oneWeek
}

nonisolated enum UsageBadgeTone: Sendable {
    case good
    case warning
    case danger
    case unavailable
}

nonisolated struct BridgeAIProviderUsageWindow: Codable, Equatable, Sendable {
    var usedPercent: Double
    var resetsAt: Date?
    var durationSeconds: Int?

    var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }
}

nonisolated enum BridgeAIProviderUsageSource: String, Codable, Sendable {
    case unavailable
    case openAICodexUsage
    case anthropicSessionCache

    var title: String {
        switch self {
        case .unavailable:
            "Unavailable"
        case .openAICodexUsage:
            "ChatGPT subscription"
        case .anthropicSessionCache:
            "Claude subscription"
        }
    }
}

enum BridgeAIProviderUsageService {
    static func refresh(provider: BridgeAIProvider) async -> BridgeAIProviderUsageSnapshot {
        switch provider {
        case .openAI:
            await refreshOpenAI()
        case .anthropic:
            await refreshAnthropic()
        case .openAIChatCompletions, .googleGemini, .amazonBedrock, .azureOpenAIResponses, .cerebras,
             .cloudflareAIGateway, .cloudflareWorkersAI, .deepSeek, .fireworks, .githubCopilot, .groq, .huggingFace,
             .kimiCoding, .minimax, .minimaxCN, .mistral, .moonshotAI, .moonshotAICN, .opencode, .opencodeGo,
             .openRouter, .vercelAIGateway, .xAI, .xiaomi, .zAI, .openAICompatible:
            BridgeAIProviderUsageSnapshot(
                fiveHour: nil,
                oneWeek: nil,
                updatedAt: nil,
                source: .unavailable,
                message: "\(provider.displayName) does not expose ChatGPT-style 5-hour or weekly subscription limits."
            )
        }
    }

    static func refreshConfigured(
        settings: BridgeAIProviderSettings,
        configuredSecrets: [BridgeAIProvider: Bool]
    ) async -> [BridgeAIProvider: BridgeAIProviderUsageSnapshot] {
        var snapshots: [BridgeAIProvider: BridgeAIProviderUsageSnapshot] = [:]
        await withTaskGroup(of: (BridgeAIProvider, BridgeAIProviderUsageSnapshot).self) { group in
            for provider in BridgeAIProvider.allCases {
                let config = settings[provider]
                guard config.isEnabled, configuredSecrets[provider] == true else { continue }
                guard config.authMethod == .oauth else { continue }
                group.addTask {
                    await (provider, refresh(provider: provider))
                }
            }

            for await (provider, snapshot) in group {
                snapshots[provider] = snapshot
            }
        }
        return snapshots
    }

    private static func refreshOpenAI() async -> BridgeAIProviderUsageSnapshot {
        let settings = await BridgeAIProviderSecretStore.readSettings()
        let config = settings[.openAI]
        guard config.isEnabled, config.authMethod == .oauth else {
            return BridgeAIProviderUsageSnapshot(
                fiveHour: nil,
                oneWeek: nil,
                updatedAt: nil,
                source: .unavailable,
                message: "OpenAI subscription limits require Sign in with OpenAI."
            )
        }

        do {
            let token = try await refreshedOpenAIToken(config: config)
            let accountID = config.oauthAccountID
                ?? BridgeAIProviderRegistry.openAIAccountID(fromJWT: token)
            guard let accountID, !accountID.isEmpty else {
                return BridgeAIProviderUsageSnapshot(
                    fiveHour: nil,
                    oneWeek: nil,
                    updatedAt: nil,
                    source: .unavailable,
                    message: "OpenAI account id was not present in the OAuth token."
                )
            }

            let payload = try await fetchOpenAIUsage(accessToken: token, accountID: accountID)
            return BridgeAIProviderUsageSnapshot(
                fiveHour: payload.window(matching: .fiveHour),
                oneWeek: payload.window(matching: .oneWeek),
                updatedAt: Date(),
                source: .openAICodexUsage,
                message: nil
            )
        } catch {
            return BridgeAIProviderUsageSnapshot(
                fiveHour: nil,
                oneWeek: nil,
                updatedAt: Date(),
                source: .unavailable,
                message: error.localizedDescription
            )
        }
    }

    private static func refreshAnthropic() async -> BridgeAIProviderUsageSnapshot {
        let settings = await BridgeAIProviderSecretStore.readSettings()
        let config = settings[.anthropic]
        guard config.isEnabled, config.authMethod == .oauth else {
            return BridgeAIProviderUsageSnapshot(
                fiveHour: nil,
                oneWeek: nil,
                updatedAt: nil,
                source: .unavailable,
                message: "Claude subscription limits require Anthropic OAuth."
            )
        }

        do {
            let token = try await refreshedAnthropicToken(config: config)
            let payload = try await fetchAnthropicUsage(accessToken: token)
            return BridgeAIProviderUsageSnapshot(
                fiveHour: payload.fiveHour?.usageWindow(durationSeconds: 5 * 60 * 60),
                oneWeek: payload.sevenDay?.usageWindow(durationSeconds: 7 * 24 * 60 * 60),
                updatedAt: Date(),
                source: .anthropicSessionCache,
                message: nil
            )
        } catch {
            return BridgeAIProviderUsageSnapshot(
                fiveHour: nil,
                oneWeek: nil,
                updatedAt: Date(),
                source: .unavailable,
                message: error.localizedDescription
            )
        }
    }

    private static func refreshedOpenAIToken(config: BridgeAIProviderConfig) async throws -> String {
        let access = await BridgeAIProviderSecretStore.readSecret(for: .openAI, kind: .oauthAccessToken)
        let refresh = await BridgeAIProviderSecretStore.readSecret(for: .openAI, kind: .oauthRefreshToken)
        guard !refresh.isEmpty, config.oauthExpiresAt.map({ $0 <= Date() }) == true else {
            return access
        }

        let credentials = OAuthCredentials(
            access: access,
            refresh: refresh,
            expires: Int64((config.oauthExpiresAt ?? Date()).timeIntervalSince1970 * 1000)
        )
        let refreshed = try await OpenAICodexOAuthProvider().refresh(
            credentials,
            using: URLSessionHTTPClient()
        )
        try await BridgeAIProviderSecretStore.saveSecret(
            refreshed.access,
            for: .openAI,
            kind: .oauthAccessToken
        )
        try await BridgeAIProviderSecretStore.saveSecret(
            refreshed.refresh,
            for: .openAI,
            kind: .oauthRefreshToken
        )

        var settings = await BridgeAIProviderSecretStore.readSettings()
        var nextConfig = settings[.openAI]
        nextConfig.oauthExpiresAt = Date(timeIntervalSince1970: Double(refreshed.expires) / 1000)
        nextConfig.oauthAccountID = BridgeAIProviderRegistry.openAIAccountID(fromJWT: refreshed.access)
        settings[.openAI] = nextConfig
        try await BridgeAIProviderSecretStore.saveSettings(settings)
        return refreshed.access
    }

    private static func refreshedAnthropicToken(config: BridgeAIProviderConfig) async throws -> String {
        let access = await BridgeAIProviderSecretStore.readSecret(for: .anthropic, kind: .oauthAccessToken)
        let refresh = await BridgeAIProviderSecretStore.readSecret(for: .anthropic, kind: .oauthRefreshToken)
        guard !refresh.isEmpty, config.oauthExpiresAt.map({ $0 <= Date() }) == true else {
            return access
        }

        let credentials = OAuthCredentials(
            access: access,
            refresh: refresh,
            expires: Int64((config.oauthExpiresAt ?? Date()).timeIntervalSince1970 * 1000)
        )
        let refreshed = try await AnthropicOAuthProvider().refresh(
            credentials,
            using: URLSessionHTTPClient()
        )
        try await BridgeAIProviderSecretStore.saveSecret(
            refreshed.access,
            for: .anthropic,
            kind: .oauthAccessToken
        )
        try await BridgeAIProviderSecretStore.saveSecret(
            refreshed.refresh,
            for: .anthropic,
            kind: .oauthRefreshToken
        )

        var settings = await BridgeAIProviderSecretStore.readSettings()
        var nextConfig = settings[.anthropic]
        nextConfig.oauthExpiresAt = Date(timeIntervalSince1970: Double(refreshed.expires) / 1000)
        settings[.anthropic] = nextConfig
        try await BridgeAIProviderSecretStore.saveSettings(settings)
        return refreshed.access
    }

    private static func fetchOpenAIUsage(
        accessToken: String,
        accountID: String
    ) async throws -> OpenAIUsagePayload {
        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BridgeAIProviderUsageError.invalidResponse
        }
        guard 200 ..< 300 ~= httpResponse.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BridgeAIProviderUsageError.requestFailed(httpResponse.statusCode, body)
        }
        return try JSONDecoder().decode(OpenAIUsagePayload.self, from: data)
    }

    private static func fetchAnthropicUsage(accessToken: String) async throws -> AnthropicUsagePayload {
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BridgeAIProviderUsageError.invalidResponse
        }
        guard 200 ..< 300 ~= httpResponse.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BridgeAIProviderUsageError.requestFailed(httpResponse.statusCode, body)
        }
        return try JSONDecoder().decode(AnthropicUsagePayload.self, from: data)
    }
}

private enum BridgeAIProviderUsageError: LocalizedError {
    case invalidResponse
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Usage request returned an invalid response."
        case let .requestFailed(statusCode, body):
            body.isEmpty ? "Usage request failed with HTTP \(statusCode)." : "Usage request failed with HTTP \(statusCode): \(body)"
        }
    }
}

private struct OpenAIUsagePayload: Decodable {
    var rateLimit: OpenAIRateLimit?
    var additionalRateLimits: [OpenAIAdditionalRateLimit]?

    private enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
    }

    func window(matching kind: BridgeAIProviderUsageWindowKind) -> BridgeAIProviderUsageWindow? {
        allWindows()
            .min { lhs, rhs in
                abs((lhs.durationSeconds ?? 0) - kind.expectedDurationSeconds)
                    < abs((rhs.durationSeconds ?? 0) - kind.expectedDurationSeconds)
            }
            .flatMap { window in
                guard let duration = window.durationSeconds else { return nil }
                let tolerance = kind.durationToleranceSeconds
                guard abs(duration - kind.expectedDurationSeconds) <= tolerance else { return nil }
                return window
            }
    }

    private func allWindows() -> [BridgeAIProviderUsageWindow] {
        var windows = rateLimit?.windows ?? []
        for additional in additionalRateLimits ?? [] {
            windows.append(contentsOf: additional.rateLimit?.windows ?? [])
        }
        return windows
    }
}

private struct OpenAIAdditionalRateLimit: Decodable {
    var rateLimit: OpenAIRateLimit?

    private enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }
}

private struct OpenAIRateLimit: Decodable {
    var primaryWindow: OpenAIRateLimitWindow?
    var secondaryWindow: OpenAIRateLimitWindow?

    private enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    var windows: [BridgeAIProviderUsageWindow] {
        [primaryWindow, secondaryWindow].compactMap { $0?.usageWindow }
    }
}

private struct OpenAIRateLimitWindow: Decodable {
    var usedPercent: Double
    var limitWindowSeconds: Int?
    var resetAt: Int64?

    private enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }

    var usageWindow: BridgeAIProviderUsageWindow {
        BridgeAIProviderUsageWindow(
            usedPercent: usedPercent,
            resetsAt: resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            durationSeconds: limitWindowSeconds
        )
    }
}

private struct AnthropicUsagePayload: Decodable {
    var fiveHour: AnthropicUsageWindow?
    var sevenDay: AnthropicUsageWindow?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct AnthropicUsageWindow: Decodable {
    var usedPercent: Double
    var resetsAt: Date?

    private enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case utilization
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let usedPercentage = try container.decodeIfPresent(Double.self, forKey: .usedPercentage) {
            usedPercent = usedPercentage
        } else if let utilization = try container.decodeIfPresent(Double.self, forKey: .utilization) {
            usedPercent = utilization <= 1 ? utilization * 100 : utilization
        } else {
            usedPercent = 0
        }

        if let timestamp = try? container.decodeIfPresent(Int64.self, forKey: .resetsAt) {
            resetsAt = Date(timeIntervalSince1970: TimeInterval(timestamp))
        } else if let dateString = try container.decodeIfPresent(String.self, forKey: .resetsAt) {
            resetsAt = ISO8601DateFormatter.openBridgeUsage.date(from: dateString)
        } else {
            resetsAt = nil
        }
    }

    func usageWindow(durationSeconds: Int) -> BridgeAIProviderUsageWindow {
        BridgeAIProviderUsageWindow(
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            durationSeconds: durationSeconds
        )
    }
}

private extension ISO8601DateFormatter {
    static let openBridgeUsage: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension BridgeAIProviderUsageWindowKind {
    var expectedDurationSeconds: Int {
        switch self {
        case .fiveHour:
            5 * 60 * 60
        case .oneWeek:
            7 * 24 * 60 * 60
        }
    }

    var durationToleranceSeconds: Int {
        switch self {
        case .fiveHour:
            30 * 60
        case .oneWeek:
            24 * 60 * 60
        }
    }
}

import KWWKAI
import SwiftUI

struct AIProviderDetailView: View {
    let provider: BridgeAIProvider

    @State private var config: BridgeAIProviderConfig
    @State private var apiKey = ""
    @State private var oauthAccessToken = ""
    @State private var oauthRefreshToken = ""
    @State private var oauthExpiresAt = Date().addingTimeInterval(50 * 60)
    @State private var usageSnapshot = BridgeAIProviderUsageSnapshot.unavailable
    @State private var isRefreshingUsage = false
    @State private var isSaving = false
    @State private var isLoggingIn = false
    @State private var loginAttemptID = 0
    @State private var loginTask: Task<Void, Never>?
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    init(provider: BridgeAIProvider) {
        self.provider = provider
        _config = State(initialValue: BridgeAIProviderSettings()[provider])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                authPicker
                endpointSection

                if config.authMethod == .apiKey {
                    apiTokenSection
                } else {
                    oauthSection
                }

                if supportsUsageDisplay {
                    usageSection
                }
                actionsSection
                storageCard
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(provider.displayName)
        .task {
            config = await BridgeAIProviderSecretStore.readSettings()[provider]
            await loadSecrets()
            await refreshUsage()
        }
        .onDisappear {
            loginTask?.cancel()
            loginTask = nil
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            ProviderIcon(provider: provider, size: 68)

            VStack(alignment: .leading, spacing: 8) {
                Text(provider.displayName)
                    .font(.system(size: 30, weight: .semibold))

                HStack(spacing: 10) {
                    Label(statusTitle, systemImage: statusIcon)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(statusColor)

                    if supportsUsageDisplay {
                        Divider()
                            .frame(height: 16)

                        UsageBadge(
                            title: "5h",
                            value: usageSnapshot.label(for: .fiveHour),
                            tone: usageSnapshot.tone(for: .fiveHour)
                        )
                        UsageBadge(
                            title: "1w",
                            value: usageSnapshot.label(for: .oneWeek),
                            tone: usageSnapshot.tone(for: .oneWeek)
                        )
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                if supportsUsageDisplay {
                    Button {
                        Task { await refreshUsage() }
                    } label: {
                        if isRefreshingUsage {
                            Label("Refreshing Usage", systemImage: "arrow.clockwise")
                        } else {
                            Label("Refresh Usage", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRefreshingUsage || !hasConfiguredAuth)

                    Text(usageUpdatedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var authPicker: some View {
        Picker("Authentication", selection: $config.authMethod) {
            ForEach(provider.supportedAuthMethods) { method in
                Text(method.segmentTitle).tag(method)
            }
        }
        .pickerStyle(.segmented)
    }

    private var endpointSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Endpoint")
                        .font(.headline)
                    Spacer()
                    Button("Reset to default") {
                        config.baseURL = provider.defaultBaseURL
                    }
                    .disabled(config.baseURL == provider.defaultBaseURL)
                }

                TextField("Base URL", text: $config.baseURL)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var apiTokenSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("API Token")
                    .font(.headline)

                Text("Paste a provider token. OpenBridge stores it locally and only resolves it when a session uses this provider.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                SecureField(provider.apiKeyPlaceholder, text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var oauthSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("OAuth is the recommended way to connect your \(provider.displayName) account.\nOpenBridge opens a browser window for you to sign in and authorize access.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                startOAuthLogin()
            } label: {
                HStack {
                    Spacer()
                    if isLoggingIn {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(oauthButtonTitle)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                }
                .frame(height: 30)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoggingIn && loginTask == nil)

            Button("Use API token instead") {
                config.authMethod = .apiKey
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)

            connectedAccountSection
        }
    }

    private var connectedAccountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connected Account")
                .font(.headline)

            SettingsCard {
                VStack(spacing: 0) {
                    DetailRow(
                        title: "Account",
                        value: connectedAccountTitle,
                        systemImage: hasConfiguredAuth ? "checkmark.circle.fill" : nil,
                        tint: hasConfiguredAuth ? .green : .secondary
                    )
                    DetailDivider()
                    DetailRow(title: "Authentication", value: config.authMethod.displayName)
                    DetailDivider()
                    DetailRow(title: "Endpoint", value: displayBaseURL)
                    DetailDivider()
                    DetailRow(title: "Token expires", value: tokenExpiryText)
                    DetailDivider()
                    DetailRow(title: "Permissions", value: "Models, chat completions")
                }
            }
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Usage Summary")
                .font(.headline)

            SettingsCard {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        UsageMetric(
                            title: "5-Hour Limit",
                            value: usageSnapshot.label(for: .fiveHour),
                            detail: usageSnapshot.resetText(for: .fiveHour)
                        )
                        VerticalDivider()
                        UsageMetric(
                            title: "Weekly Limit",
                            value: usageSnapshot.label(for: .oneWeek),
                            detail: usageSnapshot.resetText(for: .oneWeek)
                        )
                        VerticalDivider()
                        UsageMetric(title: "Source", value: usageSnapshot.source.title)
                    }
                    .frame(height: 78)

                    Divider()

                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text(usageSnapshot.message ?? "Usage comes from the provider subscription limit endpoint and is refreshed locally.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.top, 12)
                }
            }
        }
    }

    private var actionsSection: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Save Changes") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)

                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button("Reset Provider...", role: .destructive) {
                    Task { await resetProvider() }
                }
                .disabled(isLoggingIn)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var storageCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lock")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text("Your API keys and OAuth tokens are stored locally.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private var isOAuthLoggedIn: Bool {
        !oauthAccessToken.isEmpty
    }

    private var hasConfiguredAuth: Bool {
        config.isEnabled && hasStoredAuth
    }

    private var supportsUsageDisplay: Bool {
        hasConfiguredAuth && config.authMethod == .oauth
    }

    private var hasStoredAuth: Bool {
        switch config.authMethod {
        case .apiKey:
            !apiKey.isEmpty
        case .oauth:
            isOAuthLoggedIn
        }
    }

    private var statusTitle: String {
        if hasConfiguredAuth {
            return "Configured"
        }
        if config.isEnabled {
            return "Missing \(config.authMethod.displayName)"
        }
        return "Not configured"
    }

    private var statusIcon: String {
        hasConfiguredAuth ? "checkmark.circle.fill" : "circle.fill"
    }

    private var statusColor: Color {
        if hasConfiguredAuth {
            return .green
        }
        return config.isEnabled ? .orange : .secondary
    }

    private var connectedAccountTitle: String {
        if let accountID = config.oauthAccountID, !accountID.isEmpty {
            return accountID
        }
        return hasConfiguredAuth ? "Connected" : "Not connected"
    }

    private var displayBaseURL: String {
        config.baseURL.isEmpty ? provider.defaultBaseURL : config.baseURL
    }

    private var tokenExpiryText: String {
        guard config.authMethod == .oauth, isOAuthLoggedIn else { return "Not applicable" }
        return oauthExpiresAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var oauthButtonTitle: String {
        if isLoggingIn {
            return "Restart Sign In"
        }
        return isOAuthLoggedIn ? "Sign In Again" : "Open Browser for OAuth"
    }

    private var usageUpdatedText: String {
        guard let updatedAt = usageSnapshot.updatedAt else { return "Not synced" }
        return "Updated \(updatedAt.formatted(date: .omitted, time: .shortened))"
    }

    private func loadSecrets() async {
        apiKey = await BridgeAIProviderSecretStore.readSecret(for: provider, kind: .apiKey)
        oauthAccessToken = await BridgeAIProviderSecretStore.readSecret(for: provider, kind: .oauthAccessToken)
        oauthRefreshToken = await BridgeAIProviderSecretStore.readSecret(for: provider, kind: .oauthRefreshToken)
        oauthExpiresAt = config.oauthExpiresAt ?? Date().addingTimeInterval(50 * 60)
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        statusMessage = nil
        defer { isSaving = false }

        do {
            if config.authMethod == .apiKey {
                try await BridgeAIProviderSecretStore.saveSecret(apiKey, for: provider, kind: .apiKey)
            } else {
                try await BridgeAIProviderSecretStore.saveSecret(
                    oauthAccessToken,
                    for: provider,
                    kind: .oauthAccessToken
                )
                try await BridgeAIProviderSecretStore.saveSecret(
                    oauthRefreshToken,
                    for: provider,
                    kind: .oauthRefreshToken
                )
                config.oauthExpiresAt = oauthExpiresAt
            }

            config.isEnabled = hasStoredAuth || config.isEnabled
            var settings = await BridgeAIProviderSecretStore.readSettings()
            settings[provider] = config
            try await BridgeAIProviderSecretStore.saveSettings(settings)
            statusMessage = "Saved"
            await refreshUsage()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startOAuthLogin() {
        loginTask?.cancel()
        loginAttemptID += 1
        let attemptID = loginAttemptID
        loginTask = Task {
            await loginOAuth(attemptID: attemptID)
        }
    }

    private func loginOAuth(attemptID: Int) async {
        isLoggingIn = true
        errorMessage = nil
        statusMessage = "Opening browser..."
        defer {
            if loginAttemptID == attemptID {
                isLoggingIn = false
                loginTask = nil
            }
        }

        do {
            let callbacks = OAuthLogin.Callbacks(
                onAuthURL: { url in
                    Browser.open(url)
                },
                onProgress: { message in
                    Task { @MainActor in
                        guard loginAttemptID == attemptID else { return }
                        statusMessage = message
                    }
                }
            )
            let credentials = try await oauthLogin(callbacks: callbacks)
            guard loginAttemptID == attemptID, !Task.isCancelled else { return }
            oauthAccessToken = credentials.access
            oauthRefreshToken = credentials.refresh
            oauthExpiresAt = Date(timeIntervalSince1970: Double(credentials.expires) / 1000)
            try await BridgeAIProviderSecretStore.saveSecret(
                credentials.access,
                for: provider,
                kind: .oauthAccessToken
            )
            try await BridgeAIProviderSecretStore.saveSecret(
                credentials.refresh,
                for: provider,
                kind: .oauthRefreshToken
            )

            config.authMethod = .oauth
            config.isEnabled = true
            config.oauthExpiresAt = oauthExpiresAt
            if provider == .openAI {
                config.oauthAccountID = BridgeAIProviderRegistry.openAIAccountID(fromJWT: credentials.access)
            }
            if provider == .githubCopilot,
               case let .string(endpoint) = credentials.extras["endpoint"] ?? .null,
               !endpoint.isEmpty
            {
                config.baseURL = endpoint
            }

            var settings = await BridgeAIProviderSecretStore.readSettings()
            settings[provider] = config
            try await BridgeAIProviderSecretStore.saveSettings(settings)
            statusMessage = "Signed in"
            await refreshUsage()
        } catch is CancellationError {
            guard loginAttemptID == attemptID else { return }
            statusMessage = nil
        } catch {
            guard loginAttemptID == attemptID else { return }
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }

    private func resetProvider() async {
        errorMessage = nil
        do {
            try await BridgeAIProviderSecretStore.saveSecret("", for: provider, kind: .apiKey)
            try await BridgeAIProviderSecretStore.saveSecret("", for: provider, kind: .oauthAccessToken)
            try await BridgeAIProviderSecretStore.saveSecret("", for: provider, kind: .oauthRefreshToken)
            apiKey = ""
            oauthAccessToken = ""
            oauthRefreshToken = ""
            config.isEnabled = false
            config.oauthExpiresAt = nil
            config.oauthAccountID = nil
            usageSnapshot = .unavailable

            var settings = await BridgeAIProviderSecretStore.readSettings()
            settings[provider] = config
            try await BridgeAIProviderSecretStore.saveSettings(settings)
            statusMessage = "Provider reset"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func oauthLogin(callbacks: OAuthLogin.Callbacks) async throws -> OAuthCredentials {
        switch provider {
        case .openAI:
            try await OAuthLogin.loginOpenAICodex(callbacks: callbacks)
        case .openAIChatCompletions:
            throw OAuthError.unknownProvider(provider.rawValue)
        case .anthropic:
            try await OAuthLogin.loginAnthropic(callbacks: callbacks)
        case .githubCopilot:
            try await OAuthLogin.loginGitHubCopilot(callbacks: callbacks)
        case .googleGemini:
            throw OAuthError.unknownProvider(provider.rawValue)
        case .amazonBedrock, .azureOpenAIResponses, .cerebras, .cloudflareAIGateway, .cloudflareWorkersAI, .deepSeek,
             .fireworks, .groq, .huggingFace, .kimiCoding, .minimax, .minimaxCN, .mistral, .moonshotAI, .moonshotAICN,
             .opencode, .opencodeGo, .openRouter, .vercelAIGateway, .xAI, .xiaomi, .zAI, .openAICompatible:
            throw OAuthError.unknownProvider(provider.rawValue)
        }
    }

    private func refreshUsage() async {
        guard supportsUsageDisplay else {
            usageSnapshot = .unavailable
            return
        }
        isRefreshingUsage = true
        defer { isRefreshingUsage = false }
        usageSnapshot = await BridgeAIProviderUsageService.refresh(provider: provider)
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            }
    }
}

private struct DetailRow: View {
    let title: String
    let value: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
            }
        }
        .font(.callout)
        .frame(height: 32)
    }
}

private struct DetailDivider: View {
    var body: some View {
        Divider()
    }
}

private struct VerticalDivider: View {
    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1)
            .padding(.vertical, 4)
    }
}

private struct UsageMetric: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }
}

private extension BridgeAIProviderAuthMethod {
    var segmentTitle: String {
        switch self {
        case .apiKey: "API Token"
        case .oauth: "OAuth"
        }
    }
}

#Preview {
    NavigationStack {
        AIProviderDetailView(provider: .openAI)
            .environment(SettingsManager.shared)
    }
}

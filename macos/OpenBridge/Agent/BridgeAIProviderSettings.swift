import Foundation
import KWWKAI

nonisolated enum BridgeAIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI = "openai"
    case openAIChatCompletions = "openai-chat-completions"
    case anthropic
    case googleGemini = "google-gemini"
    case amazonBedrock = "amazon-bedrock"
    case azureOpenAIResponses = "azure-openai-responses"
    case cerebras
    case cloudflareAIGateway = "cloudflare-ai-gateway"
    case cloudflareWorkersAI = "cloudflare-workers-ai"
    case deepSeek = "deepseek"
    case fireworks
    case githubCopilot = "github-copilot"
    case groq
    case huggingFace = "huggingface"
    case kimiCoding = "kimi-coding"
    case minimax
    case minimaxCN = "minimax-cn"
    case mistral
    case moonshotAI = "moonshotai"
    case moonshotAICN = "moonshotai-cn"
    case opencode
    case opencodeGo = "opencode-go"
    case openRouter = "openrouter"
    case vercelAIGateway = "vercel-ai-gateway"
    case xAI = "xai"
    case xiaomi
    case zAI = "zai"
    case openAICompatible = "openai-compatible"

    var id: String {
        rawValue
    }

    static var displayOrder: [BridgeAIProvider] {
        [
            .openAI,
            .anthropic,
            .googleGemini,
            .amazonBedrock,
            .azureOpenAIResponses,
            .cerebras,
            .cloudflareAIGateway,
            .cloudflareWorkersAI,
            .deepSeek,
            .fireworks,
            .githubCopilot,
            .groq,
            .huggingFace,
            .kimiCoding,
            .minimax,
            .minimaxCN,
            .mistral,
            .moonshotAI,
            .moonshotAICN,
            .opencode,
            .opencodeGo,
            .openRouter,
            .vercelAIGateway,
            .xAI,
            .xiaomi,
            .zAI,
            .openAIChatCompletions,
            .openAICompatible,
        ]
    }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .openAIChatCompletions: "OpenAI Chat Completions"
        case .anthropic: "Anthropic"
        case .googleGemini: "Google Gemini"
        case .amazonBedrock: "Amazon Bedrock"
        case .azureOpenAIResponses: "Azure OpenAI Responses"
        case .cerebras: "Cerebras"
        case .cloudflareAIGateway: "Cloudflare AI Gateway"
        case .cloudflareWorkersAI: "Cloudflare Workers AI"
        case .deepSeek: "DeepSeek"
        case .fireworks: "Fireworks"
        case .githubCopilot: "GitHub Copilot"
        case .groq: "Groq"
        case .huggingFace: "Hugging Face"
        case .kimiCoding: "Kimi Coding"
        case .minimax: "MiniMax"
        case .minimaxCN: "MiniMax CN"
        case .mistral: "Mistral AI"
        case .moonshotAI: "Moonshot AI"
        case .moonshotAICN: "Moonshot AI CN"
        case .opencode: "OpenCode"
        case .opencodeGo: "OpenCode Go"
        case .openRouter: "OpenRouter"
        case .vercelAIGateway: "Vercel AI Gateway"
        case .xAI: "xAI"
        case .xiaomi: "Xiaomi"
        case .zAI: "Z.ai"
        case .openAICompatible: "OpenAI-compatible"
        }
    }

    var iconName: String {
        switch self {
        case .openAI, .openAIChatCompletions: "sparkles"
        case .anthropic: "brain.head.profile"
        case .googleGemini: "diamond"
        case .amazonBedrock: "cube.transparent"
        case .azureOpenAIResponses: "cloud"
        case .cerebras: "cpu"
        case .cloudflareAIGateway, .cloudflareWorkersAI: "cloud"
        case .deepSeek: "waveform.path.ecg"
        case .fireworks: "sparkles"
        case .githubCopilot: "person.crop.circle.badge.checkmark"
        case .groq: "bolt"
        case .huggingFace: "face.smiling"
        case .kimiCoding, .moonshotAI, .moonshotAICN: "moon"
        case .minimax, .minimaxCN: "slider.horizontal.3"
        case .mistral: "wind"
        case .opencode, .opencodeGo: "curlybraces"
        case .openRouter: "arrow.triangle.branch"
        case .vercelAIGateway: "triangle"
        case .xAI: "xmark"
        case .xiaomi: "square"
        case .zAI: "sparkle.magnifyingglass"
        case .openAICompatible: "server.rack"
        }
    }

    var logoImageName: String {
        switch self {
        case .openAI, .openAIChatCompletions: "openai"
        case .anthropic: "claude"
        case .googleGemini: "google"
        case .amazonBedrock: "amazonaws"
        case .azureOpenAIResponses: "microsoftazure"
        case .cerebras: "cerebras"
        case .cloudflareAIGateway, .cloudflareWorkersAI: "cloudflare"
        case .deepSeek: "deepseek"
        case .fireworks: "fireworks"
        case .githubCopilot: "copilot"
        case .groq: "groq"
        case .huggingFace: "huggingface"
        case .kimiCoding: "kimi"
        case .minimax, .minimaxCN: "minimax"
        case .mistral: "mistral"
        case .moonshotAI, .moonshotAICN: "moonshot"
        case .opencode, .opencodeGo: "opencode"
        case .openRouter: "openrouter"
        case .vercelAIGateway: "vercel"
        case .xAI: "xai"
        case .xiaomi: "xiaomi"
        case .zAI: "zai"
        case .openAICompatible: "openai"
        }
    }

    var usesTemplateLogoRendering: Bool {
        switch self {
        case .openAI, .openAIChatCompletions, .openAICompatible:
            true
        case .anthropic, .googleGemini, .amazonBedrock, .azureOpenAIResponses, .cerebras, .cloudflareAIGateway,
             .cloudflareWorkersAI, .deepSeek, .fireworks, .githubCopilot, .groq, .huggingFace, .kimiCoding, .minimax,
             .minimaxCN, .mistral, .moonshotAI, .moonshotAICN, .opencode, .opencodeGo, .openRouter, .vercelAIGateway,
             .xAI, .xiaomi, .zAI:
            false
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI, .openAIChatCompletions: "https://api.openai.com"
        case .anthropic: "https://api.anthropic.com"
        case .googleGemini: "https://generativelanguage.googleapis.com"
        case .amazonBedrock: "us-east-1"
        case .azureOpenAIResponses: "https://YOUR-RESOURCE.openai.azure.com"
        case .cerebras: "https://api.cerebras.ai/v1"
        case .cloudflareAIGateway: "https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}"
        case .cloudflareWorkersAI: "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai/v1"
        case .deepSeek: "https://api.deepseek.com"
        case .fireworks: "https://api.fireworks.ai/inference"
        case .githubCopilot: "https://api.individual.githubcopilot.com"
        case .groq: "https://api.groq.com/openai/v1"
        case .huggingFace: "https://router.huggingface.co/v1"
        case .kimiCoding: "https://api.kimi.com/coding"
        case .minimax: "https://api.minimax.io/anthropic"
        case .minimaxCN: "https://api.minimaxi.com/anthropic"
        case .mistral: "https://api.mistral.ai"
        case .moonshotAI: "https://api.moonshot.ai/v1"
        case .moonshotAICN: "https://api.moonshot.cn/v1"
        case .opencode: "https://opencode.ai/zen"
        case .opencodeGo: "https://opencode.ai/zen/go/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .vercelAIGateway: "https://ai-gateway.vercel.sh"
        case .xAI: "https://api.x.ai/v1"
        case .xiaomi: "https://token-plan-ams.xiaomimimo.com/anthropic"
        case .zAI: "https://api.z.ai/api/coding/paas/v4"
        case .openAICompatible: ""
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .openAI, .openAIChatCompletions: "sk-..."
        case .anthropic: "sk-ant-..."
        case .googleGemini: "AIza..."
        case .amazonBedrock: "AWS_ACCESS_KEY_ID:AWS_SECRET_ACCESS_KEY[:AWS_SESSION_TOKEN]"
        case .azureOpenAIResponses: "Azure OpenAI API key"
        case .githubCopilot: "Use OAuth"
        case .openRouter: "sk-or-..."
        default: "API key"
        }
    }

    var supportedAuthMethods: [BridgeAIProviderAuthMethod] {
        switch self {
        case .openAI, .anthropic, .githubCopilot:
            [.oauth, .apiKey]
        case .openAIChatCompletions, .googleGemini, .amazonBedrock, .azureOpenAIResponses, .cerebras,
             .cloudflareAIGateway, .cloudflareWorkersAI, .deepSeek, .fireworks, .groq, .huggingFace, .kimiCoding,
             .minimax, .minimaxCN, .mistral, .moonshotAI, .moonshotAICN, .opencode, .opencodeGo, .openRouter,
             .vercelAIGateway, .xAI, .xiaomi, .zAI, .openAICompatible:
            [.apiKey]
        }
    }

    var defaultAuthMethod: BridgeAIProviderAuthMethod {
        supportedAuthMethods.first ?? .apiKey
    }

    var modelProviderIDs: Set<String> {
        switch self {
        case .openAI:
            ["chatgpt-codex", "openai", "openai-codex"]
        case .openAIChatCompletions:
            ["openai"]
        case .anthropic:
            ["anthropic"]
        case .googleGemini:
            ["google", "google-gemini", "google-gemini-cli", "google-antigravity", "google-vertex"]
        case .openAICompatible:
            []
        default:
            [rawValue]
        }
    }

    static func provider(for model: Model) -> BridgeAIProvider? {
        if model.provider == "openai", model.api == "openai-completions" {
            return .openAIChatCompletions
        }
        return allCases.first { $0.modelProviderIDs.contains(model.provider) }
    }
}

nonisolated enum BridgeAIProviderAuthMethod: String, CaseIterable, Codable, Identifiable, Sendable {
    case apiKey
    case oauth

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .apiKey: "API Key"
        case .oauth: "OAuth"
        }
    }
}

nonisolated struct BridgeAIProviderConfig: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var authMethod: BridgeAIProviderAuthMethod
    var baseURL: String
    var oauthExpiresAt: Date?
    var oauthAccountID: String?

    init(
        isEnabled: Bool = false,
        authMethod: BridgeAIProviderAuthMethod = .oauth,
        baseURL: String = "",
        oauthExpiresAt: Date? = nil,
        oauthAccountID: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.authMethod = authMethod
        self.baseURL = baseURL
        self.oauthExpiresAt = oauthExpiresAt
        self.oauthAccountID = oauthAccountID
    }

    func resolvedBaseURL(for provider: BridgeAIProvider) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != provider.defaultBaseURL else { return nil }
        return trimmed
    }
}

nonisolated struct BridgeAIProviderSettings: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case providers
        case selectedModelProvider
        case selectedModelID
    }

    var providers: [BridgeAIProvider: BridgeAIProviderConfig]
    var selectedModelProvider: String
    var selectedModelID: String

    init(
        providers: [BridgeAIProvider: BridgeAIProviderConfig] = [:],
        selectedModelProvider: String = "openai",
        selectedModelID: String = "gpt-5"
    ) {
        var configs = providers
        for provider in BridgeAIProvider.allCases {
            if configs[provider] == nil {
                configs[provider] = BridgeAIProviderConfig(
                    authMethod: provider.defaultAuthMethod,
                    baseURL: provider.defaultBaseURL
                )
            }
        }
        self.providers = configs
        self.selectedModelProvider = selectedModelProvider
        self.selectedModelID = selectedModelID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            providers: container.decodeIfPresent(
                [BridgeAIProvider: BridgeAIProviderConfig].self,
                forKey: .providers
            ) ?? [:],
            selectedModelProvider: container.decodeIfPresent(String.self, forKey: .selectedModelProvider)
                ?? "openai",
            selectedModelID: container.decodeIfPresent(String.self, forKey: .selectedModelID)
                ?? "gpt-5"
        )
    }

    subscript(provider: BridgeAIProvider) -> BridgeAIProviderConfig {
        get {
            providers[provider] ?? BridgeAIProviderConfig(
                authMethod: provider.defaultAuthMethod,
                baseURL: provider.defaultBaseURL
            )
        }
        set { providers[provider] = newValue }
    }
}

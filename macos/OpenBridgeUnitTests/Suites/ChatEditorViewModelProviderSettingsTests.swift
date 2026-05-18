import ComposerEditor
import Foundation
@testable import OpenBridge
import Testing

@MainActor
struct ChatEditorViewModelProviderSettingsTests {
    @Test
    func `provider settings notification refreshes composer model state`() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("secrets.json", isDirectory: false)
        BridgeAIProviderSecretStore.setStoreURLForTesting(storeURL)
        defer {
            BridgeAIProviderSecretStore.setStoreURLForTesting(nil)
            try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
        }

        let viewModel = ChatEditorViewModel()
        #expect(viewModel.hasAvailableModelSelection == false)

        var settings = BridgeAIProviderSettings(selectedModelProvider: "openai", selectedModelID: "gpt-5")
        var openAIConfig = settings[.openAI]
        openAIConfig.isEnabled = true
        openAIConfig.authMethod = .apiKey
        settings[.openAI] = openAIConfig

        try await BridgeAIProviderSecretStore.saveSettings(settings)
        try await waitUntil {
            viewModel.hasAvailableModelSelection
                && viewModel.selectedModelProvider == "openai"
                && viewModel.selectedModelID == "gpt-5"
        }

        #expect(viewModel.composerRealModelSelectorConfig?.selectedModelTitle == "GPT-5")
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - start > timeout {
                Issue.record("Timed out waiting for condition.")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

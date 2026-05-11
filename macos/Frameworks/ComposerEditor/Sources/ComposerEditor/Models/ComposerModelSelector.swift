import Foundation
import SwiftUI

public struct ComposerModelOption: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String?
    public let selectedTone: ComposerModelOptionTone?

    public init(
        id: String,
        title: String,
        systemImage: String? = nil,
        selectedTone: ComposerModelOptionTone? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.selectedTone = selectedTone
    }
}

public enum ComposerModelOptionTone: Sendable {
    case primary
    case warning
}

public struct ComposerModelGroup: Sendable {
    public let provider: String
    public let models: [ComposerModelOption]
    public let subtitle: String?
    public let showsHeader: Bool

    public init(provider: String, models: [ComposerModelOption], subtitle: String? = nil, showsHeader: Bool = true) {
        self.provider = provider
        self.models = models
        self.subtitle = subtitle
        self.showsHeader = showsHeader
    }
}

public struct ComposerMenuActionItem {
    public let title: String
    public let systemImage: String?
    public let isSelected: Bool
    public let isDisabled: Bool
    public let action: () -> Void

    public init(
        title: String,
        systemImage: String? = nil,
        isSelected: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.isDisabled = isDisabled
        self.action = action
    }
}

public struct ComposerMenuSubmenuItem {
    public let title: String
    public let systemImage: String?
    public let isDisabled: Bool
    public let items: [ComposerMenuActionItem]

    public init(
        title: String,
        systemImage: String? = nil,
        isDisabled: Bool = false,
        items: [ComposerMenuActionItem]
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isDisabled = isDisabled
        self.items = items
    }
}

public enum ComposerModelMenuItem {
    case action(ComposerMenuActionItem)
    case submenu(ComposerMenuSubmenuItem)
}

public struct ComposerModelMenuSection {
    public let title: String
    public let items: [ComposerModelMenuItem]

    public init(title: String, items: [ComposerModelMenuItem]) {
        self.title = title
        self.items = items
    }
}

public struct ComposerModelSelectorConfig {
    public var groups: [ComposerModelGroup]
    public var isLoading: Bool
    public var selectedModelId: Binding<String>
    public var selectedModelTitle: String
    public var selectedModelSubtitle: String?
    public var emptyActionSystemImage: String?
    public var topMenuSections: [ComposerModelMenuSection]
    public var accessibilityIdentifier: String
    public var accessibilityLabel: String
    public var onOpen: () -> Void
    public var onSelect: (String) -> Void
    public var onEmptyAction: (() -> Void)?

    public init(
        groups: [ComposerModelGroup],
        isLoading: Bool,
        selectedModelId: Binding<String>,
        selectedModelTitle: String,
        selectedModelSubtitle: String? = nil,
        emptyActionSystemImage: String? = nil,
        topMenuSections: [ComposerModelMenuSection] = [],
        accessibilityIdentifier: String = "chat.composer.modelSelector",
        accessibilityLabel: String = "Select model",
        onOpen: @escaping () -> Void,
        onSelect: @escaping (String) -> Void,
        onEmptyAction: (() -> Void)? = nil
    ) {
        self.groups = groups
        self.isLoading = isLoading
        self.selectedModelId = selectedModelId
        self.selectedModelTitle = selectedModelTitle
        self.selectedModelSubtitle = selectedModelSubtitle
        self.emptyActionSystemImage = emptyActionSystemImage
        self.topMenuSections = topMenuSections
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityLabel = accessibilityLabel
        self.onOpen = onOpen
        self.onSelect = onSelect
        self.onEmptyAction = onEmptyAction
    }
}

struct ComposerModelSelectorView: View {
    @Environment(\.colorScheme) private var colorScheme

    let config: ComposerModelSelectorConfig
    let disabled: Bool

    @State private var isHovered = false

    var body: some View {
        if shouldShowEmptyActionButton, let onEmptyAction = config.onEmptyAction {
            Button(action: onEmptyAction) {
                selectorLabel(
                    systemImage: config.emptyActionSystemImage,
                    title: config.selectedModelTitle,
                    subtitle: nil,
                    showsChevron: false
                )
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityIdentifier(config.accessibilityIdentifier)
            .accessibilityLabel(config.accessibilityLabel)
            .onHover { hovering in
                isHovered = hovering
            }
        } else {
            Menu {
                if !config.topMenuSections.isEmpty {
                    ForEach(Array(config.topMenuSections.enumerated()), id: \.offset) { _, section in
                        Section {
                            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                                modelMenuItem(item)
                            }
                        } header: {
                            Text(section.title)
                        }
                    }
                    Divider()
                }

                if config.groups.isEmpty, config.isLoading {
                    Text("Loading models...")
                        .foregroundColor(.secondary)
                } else if config.groups.isEmpty {
                    Text("No models available")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(config.groups, id: \.provider) { group in
                        groupSection(group)
                    }
                }
            } label: {
                selectorLabel(
                    systemImage: selectedModelOption?.systemImage,
                    title: config.selectedModelTitle,
                    subtitle: config.selectedModelSubtitle,
                    showsChevron: true
                )
            }
            .menuStyle(.button)
            .buttonStyle(OnPressButtonStyle {
                config.onOpen()
            })
            .menuIndicator(.hidden)
            .disabled(disabled)
            .accessibilityIdentifier(config.accessibilityIdentifier)
            .accessibilityLabel(config.accessibilityLabel)
            .onHover { hovering in
                isHovered = hovering
            }
        }
    }

    private var shouldShowEmptyActionButton: Bool {
        config.groups.isEmpty && !config.isLoading && config.onEmptyAction != nil
    }

    private func selectorLabel(
        systemImage: String?,
        title: String,
        subtitle: String?,
        showsChevron: Bool
    ) -> some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, alignment: .leading)
            if let subtitle {
                Text("(\(subtitle))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, alignment: .leading)
            }
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0.7)
            }
        }
        .frame(minWidth: 0)
        .foregroundStyle(selectedModelForegroundColor)
        .opacity(disabled ? ComposerControlStyle.disabledForegroundOpacity : 1.0)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(buttonBackgroundColor)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private var buttonBackgroundColor: Color {
        let opacity = ComposerControlStyle.backgroundOpacity(
            isDarkMode: colorScheme == .dark,
            isActive: isHovered,
            isDisabled: disabled
        )
        return Color.primary.opacity(opacity)
    }

    private var selectedModelOption: ComposerModelOption? {
        config.groups
            .flatMap(\.models)
            .first { $0.id == config.selectedModelId.wrappedValue }
    }

    private var selectedModelForegroundColor: Color {
        selectedModelOption.flatMap { selectedToneColor(for: $0) } ?? .primary
    }

    private func groupModelRows(_ group: ComposerModelGroup) -> some View {
        ForEach(group.models, id: \.id) { model in
            Button {
                config.onSelect(model.id)
            } label: {
                modelMenuRowLabel(
                    model,
                    isSelected: config.selectedModelId.wrappedValue == model.id
                )
            }
        }
    }

    @ViewBuilder
    private func modelMenuRowLabel(_ model: ComposerModelOption, isSelected: Bool) -> some View {
        if isSelected {
            Label(model.title, systemImage: "checkmark")
        } else if let systemImage = model.systemImage {
            Label(model.title, systemImage: systemImage)
        } else {
            Text(model.title)
        }
    }

    private func selectedToneColor(for model: ComposerModelOption) -> Color? {
        guard let selectedTone = model.selectedTone else { return nil }
        return color(for: selectedTone)
    }

    private func color(for tone: ComposerModelOptionTone) -> Color {
        switch tone {
        case .primary:
            .primary
        case .warning:
            Color(red: 240.0 / 255.0, green: 95.0 / 255.0, blue: 28.0 / 255.0)
        }
    }

    @ViewBuilder
    private func groupSection(_ group: ComposerModelGroup) -> some View {
        if group.showsHeader {
            Section {
                groupModelRows(group)
            } header: {
                groupHeader(group)
            }
        } else {
            Section {
                groupModelRows(group)
            }
        }
    }

    @ViewBuilder
    private func groupHeader(_ group: ComposerModelGroup) -> some View {
        let title = formattedProviderTitle(group.provider)
        if let subtitle = group.subtitle {
            Text("\(title) (\(subtitle))")
        } else {
            Text(title)
        }
    }

    @ViewBuilder
    private func modelMenuItem(_ item: ComposerModelMenuItem) -> some View {
        switch item {
        case let .action(action):
            Button(action: action.action) {
                menuItemLabel(
                    title: action.title,
                    systemImage: action.isSelected ? "checkmark" : action.systemImage
                )
            }
            .disabled(action.isDisabled)

        case let .submenu(submenu):
            Menu {
                ForEach(Array(submenu.items.enumerated()), id: \.offset) { _, childAction in
                    Button(action: childAction.action) {
                        menuItemLabel(
                            title: childAction.title,
                            systemImage: childAction.isSelected ? "checkmark" : childAction.systemImage
                        )
                    }
                    .disabled(childAction.isDisabled)
                }
            } label: {
                menuItemLabel(title: submenu.title, systemImage: submenu.systemImage)
            }
            .disabled(submenu.isDisabled)
        }
    }

    @ViewBuilder
    private func menuItemLabel(title: String, systemImage: String?) -> some View {
        if let systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }
}

private func formattedProviderTitle(_ provider: String) -> String {
    switch provider.lowercased() {
    case "openai":
        "OpenAI"
    case "anthropic":
        "Anthropic"
    case "gemini":
        "Google"
    default:
        provider
    }
}

private struct OnPressButtonStyle: ButtonStyle {
    var onPress: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { oldValue, newValue in
                if !oldValue, newValue {
                    onPress()
                }
            }
    }
}

// MARK: - Previews

#Preview("Model Selector — Disabled") {
    @Previewable @State var selectedModelId = "claude-sonnet"

    let config = ComposerModelSelectorConfig(
        groups: [
            ComposerModelGroup(
                provider: "anthropic",
                models: [
                    ComposerModelOption(id: "claude-opus", title: "Claude Opus"),
                    ComposerModelOption(id: "claude-sonnet", title: "Claude Sonnet"),
                ]
            ),
        ],
        isLoading: false,
        selectedModelId: $selectedModelId,
        selectedModelTitle: "Claude Sonnet",
        selectedModelSubtitle: "anthropic",
        onOpen: {},
        onSelect: { selectedModelId = $0 }
    )

    VStack(spacing: 24) {
        VStack(spacing: 4) {
            Text("Enabled").font(.caption).foregroundStyle(.secondary)
            ComposerModelSelectorView(config: config, disabled: false)
        }
        VStack(spacing: 4) {
            Text("Disabled (streaming)").font(.caption).foregroundStyle(.secondary)
            ComposerModelSelectorView(config: config, disabled: true)
        }
    }
    .padding(40)
}

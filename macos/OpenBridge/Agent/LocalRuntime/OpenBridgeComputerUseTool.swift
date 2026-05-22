import ApplicationServices
import Foundation
import KWWKAgent
import KWWKAI
import KWWKComputerUseCore

final class OpenBridgeComputerUseClientStore: @unchecked Sendable {
    private let lock = NSLock()
    private var client = ComputerUseClient()

    func current() -> ComputerUseClient {
        lock.withLock { client }
    }

    func finishAndReset() {
        let oldClient = lock.withLock {
            let oldClient = client
            client = ComputerUseClient()
            return oldClient
        }
        oldClient.finish()
    }
}

enum OpenBridgeComputerUseAgent {
    private static let availableActions = [
        "start",
        "end",
        "list-apps",
        "open-app",
        "list-windows",
        "get-app-state",
        "click",
        "type-text",
        "set-value",
        "press-key",
        "scroll",
        "perform-secondary-action",
        "drag",
    ]

    static let systemPrompt = """
    You control local macOS apps through the computer_use tool.

    Use the startup inventory below to choose app names, bundle ids, and window_title values.
    Call start before the first Computer Use action for a user request, and call end when you are done operating local macOS apps.
    Use open-app when the target app is installed but not running.
    Begin by calling get-app-state every turn you want to use Computer Use; follow-up actions operate on the latest captured app state.
    After navigation changes a window title, omit window_title unless the user explicitly asked for a specific window.
    Computer Use actions run in the background; avoid disrupting the user's active app, clipboard, or foreground workflow.
    Prefer accessibility: call get-app-state with include_screenshot=false first, and use element_index whenever possible.
    Element indexes are the sequential integers from the latest accessibility tree and become stale after navigation, scrolling, or layout changes.
    Request screenshots only when accessibility is missing/incomplete, when the target is canvas/WebGL/game-like, or when the task truly requires visual/pixel inspection.
    For list traversal tasks, keep an explicit visited set from stable labels/descriptions, use the harness candidate targets and diffs after every action, and scroll only after all relevant visible rows are visited.
    If a scroll result says there was no observable state change, do not infer that the list ended by itself; try a different scrollable container or keyboard/list navigation if more items are expected.
    If the user asks to click, open, inspect, or traverse items, do not count a visible row as visited until a successful action result shows you actually selected/opened it.
    After each action, use the action result or fetch the latest state to verify the UI changed as expected.
    Ask the user before destructive or externally visible actions such as sending, deleting, purchasing, or posting.
    """

    static func systemPromptWithStartupInventory(clientStore: OpenBridgeComputerUseClientStore) -> String {
        let inventory = startupInventoryText(client: clientStore.current())
        guard !inventory.isEmpty else { return systemPrompt }
        return "\(systemPrompt)\n\n\(inventory)"
    }

    static func makeTool(
        clientStore: OpenBridgeComputerUseClientStore,
        requestStartConfirmation: @escaping @Sendable ([String]) async -> PermissionConfirmationReply
    ) -> AgentTool {
        AgentTool(
            name: "computer_use",
            label: "Computer Use",
            description: """
            Control local macOS applications using accessibility snapshots and background input.

            Input object: {"action":"<name>","args":{...},"thinking":"optional short note"}

            Actions:
            - start: args {"apps"?: string[]}; begins a local macOS Computer Use sequence and returns startup app/window inventory
            - end: args {}; ends the current Computer Use sequence and restores any background activation state
            - list-apps: args {}; returns currently running apps plus apps used in the last 14 days, with frontmost/running/last-used/uses flags when available
            - open-app: args {"app": string}; launches an app by name, bundle id, or .app path if needed, without activating it, and returns the app-list line for the app
            - list-windows: args {"app": string}
            - get-app-state: args {"app": string, "window_title"?: string, "include_screenshot"?: boolean}; returns app_state and records the latest snapshot; default include_screenshot=false
            - click: args {"element_index"?: integer, "x"?: number, "y"?: number, "include_screenshot_after"?: boolean}; use element_index or x/y from the latest snapshot
            - type-text: args {"text": string, "element_index"?: integer, "include_screenshot_after"?: boolean}
            - set-value: args {"element_index": integer, "value": string, "include_screenshot_after"?: boolean}
            - press-key: args {"key": string, "include_screenshot_after"?: boolean}
            - scroll: args {"element_index": integer, "direction": "up"|"down"|"left"|"right", "pages"?: number, "include_screenshot_after"?: boolean}; pages is a viewport-relative amount and supports fractions
            - perform-secondary-action: args {"element_index": integer, "action": string, "include_screenshot_after"?: boolean}
            - drag: args {"from_x": number, "from_y": number, "to_x": number, "to_y": number, "include_screenshot_after"?: boolean}

            Examples:
            - {"action":"start","args":{"apps":["Slack"]}}
            - {"action":"get-app-state","args":{"app":"Slack","window_title":"Slack","include_screenshot":false}}
            - {"action":"click","args":{"element_index":12}}
            - {"action":"type-text","args":{"text":"hello"}}
            - {"action":"end","args":{}}
            """,
            parameters: [
                "type": "object",
                "properties": [:],
                "additionalProperties": true,
            ],
            execute: { _, args, cancellation, _ in
                try cancellation?.throwIfCancelled()
                return try await execute(
                    args: args,
                    clientStore: clientStore,
                    requestStartConfirmation: requestStartConfirmation
                )
            }
        )
    }

    private static func startupInventoryText(client: ComputerUseClient) -> String {
        let apps = client.runningApps()
        guard !apps.isEmpty else { return "" }

        var lines = [
            "Startup macOS app/window inventory.",
            "<computer_use_inventory>",
            "<apps>",
        ]
        lines.append(contentsOf: apps.map(formatRunningApp))
        lines.append("</apps>")

        guard AXIsProcessTrusted() else {
            lines.append("<windows unavailable=\"accessibility_permission_required\" />")
            lines.append("</computer_use_inventory>")
            return lines.joined(separator: "\n")
        }

        lines.append("<windows>")
        var wroteWindowApp = false
        for app in apps {
            let identifier = app.bundleID.isEmpty ? app.name : app.bundleID
            guard let windows = try? client.windows(app: identifier), !windows.isEmpty else {
                continue
            }

            wroteWindowApp = true
            lines.append("\(app.name) - \(app.bundleID) [pid \(app.pid)]")
            for (index, window) in windows.enumerated() {
                let flagText = window.isMain ? " [main]" : ""
                lines.append("[\(index)] window_id=\(window.windowID) title=\"\(window.title)\"\(flagText)")
            }
        }
        if !wroteWindowApp {
            lines.append("(no readable windows)")
        }
        lines.append("</windows>")
        lines.append("</computer_use_inventory>")
        return lines.joined(separator: "\n")
    }

    private static func execute(
        args raw: KWWKAI.JSONValue,
        clientStore: OpenBridgeComputerUseClientStore,
        requestStartConfirmation: @escaping @Sendable ([String]) async -> PermissionConfirmationReply
    ) async throws -> AgentToolResult {
        guard case let .object(payload) = raw else {
            throw ComputerUseError.invalidArgument("tool payload must be an object")
        }
        guard case let .string(action) = payload["action"] ?? .null else {
            return actionHelpResult(reason: "Missing required field 'action'.")
        }
        guard availableActions.contains(action) else {
            return actionHelpResult(reason: "Unknown action '\(action)'.")
        }
        let actionArgs: [String: KWWKAI.JSONValue]
        if case let .object(dict) = payload["args"] ?? .object([:]) {
            actionArgs = dict
        } else {
            throw ComputerUseError.invalidArgument("args must be an object")
        }

        let output = try await executeAction(
            action: action,
            args: actionArgs,
            clientStore: clientStore,
            requestStartConfirmation: requestStartConfirmation
        )
        return toolResult(action: action, output: output)
    }

    private static func executeAction(
        action: String,
        args: [String: KWWKAI.JSONValue],
        clientStore: OpenBridgeComputerUseClientStore,
        requestStartConfirmation: @escaping @Sendable ([String]) async -> PermissionConfirmationReply
    ) async throws -> ComputerUseCommandOutput {
        let client = clientStore.current()
        switch action {
        case "start":
            return await startOutput(
                args: args,
                clientStore: clientStore,
                requestStartConfirmation: requestStartConfirmation
            )
        case "end":
            clientStore.finishAndReset()
            return ComputerUseCommandOutput(text: "Computer Use session ended. Background activation state has been restored.")
        case "list-apps":
            return client.listApps()
        case "open-app":
            return try await client.openApp(requiredString(args, "app"))
        case "list-windows":
            return try client.listWindows(app: requiredString(args, "app"))
        case "get-app-state":
            return try client.getAppState(
                app: requiredString(args, "app"),
                windowTitle: optionalString(args, "window_title"),
                includeScreenshot: optionalBool(args, "include_screenshot") ?? false
            )
        case "click":
            let includeScreenshotAfter = optionalBool(args, "include_screenshot_after") ?? false
            if let elementIndex = optionalInt(args, "element_index") {
                return try await client.click(
                    elementIndex: elementIndex,
                    includeScreenshotAfter: includeScreenshotAfter
                )
            }
            return try await client.click(
                x: requiredDouble(args, "x"),
                y: requiredDouble(args, "y"),
                includeScreenshotAfter: includeScreenshotAfter
            )
        case "type-text":
            return try await client.typeText(
                text: requiredString(args, "text"),
                elementIndex: optionalInt(args, "element_index"),
                includeScreenshotAfter: optionalBool(args, "include_screenshot_after") ?? false
            )
        case "set-value":
            return try await client.setValue(
                elementIndex: requiredInt(args, "element_index"),
                value: requiredString(args, "value"),
                includeScreenshotAfter: optionalBool(args, "include_screenshot_after") ?? false
            )
        case "press-key":
            return try await client.pressKey(
                key: requiredString(args, "key"),
                includeScreenshotAfter: optionalBool(args, "include_screenshot_after") ?? false
            )
        case "scroll":
            return try await client.scroll(
                elementIndex: requiredInt(args, "element_index"),
                direction: requiredString(args, "direction"),
                pages: optionalDouble(args, "pages") ?? 1,
                includeScreenshotAfter: optionalBool(args, "include_screenshot_after") ?? false
            )
        case "perform-secondary-action":
            return try await client.performSecondaryAction(
                elementIndex: requiredInt(args, "element_index"),
                action: requiredString(args, "action"),
                includeScreenshotAfter: optionalBool(args, "include_screenshot_after") ?? false
            )
        case "drag":
            return try await client.drag(
                fromX: requiredDouble(args, "from_x"),
                fromY: requiredDouble(args, "from_y"),
                toX: requiredDouble(args, "to_x"),
                toY: requiredDouble(args, "to_y"),
                includeScreenshotAfter: optionalBool(args, "include_screenshot_after") ?? false
            )
        default:
            throw ComputerUseError.invalidArgument("unknown action \(action)")
        }
    }

    private static func toolResult(action: String, output: ComputerUseCommandOutput) -> AgentToolResult {
        var blocks: [ToolResultBlock] = [.text(TextContent(text: output.text))]
        if let path = output.metadata?.screenshotPath,
           let image = toolResultImage(at: path)
        {
            blocks.append(.image(image))
        }
        return AgentToolResult(
            content: blocks,
            details: details(for: output.metadata),
            uiDisplay: [uiSummary(action: action, output: output)]
        )
    }

    private static func actionHelpResult(reason: String) -> AgentToolResult {
        AgentToolResult(
            content: [.text(TextContent(text: actionHelpText(reason: reason)))],
            uiDisplay: ["invalid action: available actions returned"]
        )
    }

    private static func actionHelpText(reason: String) -> String {
        """
        Invalid computer_use input: \(reason)

        Tool input must be an object:
        {"action":"<action-name>","args":{...},"thinking":"optional short note"}

        Available actions:
        - start
        - end
        - list-apps
        - open-app
        - list-windows
        - get-app-state
        - click
        - type-text
        - set-value
        - press-key
        - scroll
        - perform-secondary-action
        - drag

        Minimal examples:
        - {"action":"start","args":{"apps":["Slack"]}}
        - {"action":"list-apps","args":{}}
        - {"action":"open-app","args":{"app":"Slack"}}
        - {"action":"list-windows","args":{"app":"Slack"}}
        - {"action":"get-app-state","args":{"app":"Slack","include_screenshot":false}}
        - {"action":"click","args":{"element_index":12}}
        - {"action":"press-key","args":{"key":"cmd+f"}}
        - {"action":"end","args":{}}
        """
    }

    private static func startOutput(
        args: [String: KWWKAI.JSONValue],
        clientStore: OpenBridgeComputerUseClientStore,
        requestStartConfirmation: @escaping @Sendable ([String]) async -> PermissionConfirmationReply
    ) async -> ComputerUseCommandOutput {
        let apps = optionalStringArray(args, "apps")
        let reply = await requestStartConfirmation(apps)
        guard reply.approved else {
            return ComputerUseCommandOutput(text: "Computer Use start was denied by the user.")
        }
        clientStore.finishAndReset()
        let client = clientStore.current()

        var lines = ["Computer Use session started."]
        if !apps.isEmpty {
            lines.append("Apps in focus: \(apps.joined(separator: ", "))")
        }
        lines.append("Call get-app-state before click/type/scroll actions, then call end when finished.")

        let inventory = startupInventoryText(client: client)
        if !inventory.isEmpty {
            lines.append("")
            lines.append(inventory)
        }
        return ComputerUseCommandOutput(text: lines.joined(separator: "\n"))
    }

    static func startDescription(apps: [String]) -> String {
        var lines = ["Agent wants to start Computer Use."]
        if !apps.isEmpty {
            lines.append("Apps in focus: \(apps.joined(separator: ", "))")
        }
        lines.append("Computer Use can inspect and operate local macOS app windows until the agent calls end or the run is cancelled.")
        return lines.joined(separator: "\n")
    }

    private static func toolResultImage(at path: String) -> ImageContent? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ImageContent(data: data.base64EncodedString(), mimeType: mimeType(for: url))
    }

    private static func details(for metadata: ComputerUseSnapshotMetadata?) -> KWWKAI.JSONValue? {
        guard let metadata else { return nil }
        var object: [String: KWWKAI.JSONValue] = [
            "snapshot_id": .string(metadata.id),
            "app": .string(metadata.appName),
            "bundle_id": .string(metadata.bundleID),
            "pid": .int(Int(metadata.pid)),
            "window_title": .string(metadata.windowTitle),
            "window_id": .int(metadata.windowID),
        ]
        if let path = metadata.screenshotPath {
            object["screenshot_path"] = .string(path)
        }
        if let size = metadata.screenshotSize {
            object["screenshot_size"] = .object([
                "width": .int(Int(size.width)),
                "height": .int(Int(size.height)),
            ])
        }
        return .object(object)
    }

    private static func uiSummary(action: String, output: ComputerUseCommandOutput) -> String {
        if let metadata = output.metadata {
            var suffix = "snapshot \(metadata.id)"
            if metadata.screenshotPath != nil {
                suffix += " + screenshot"
            }
            return "\(action): \(suffix)"
        }
        let lineCount = output.text.split(separator: "\n").count
        return "\(action): \(lineCount) lines"
    }

    private static func formatRunningApp(_ app: RunningAppDescriptor) -> String {
        let active = app.isActive ? " frontmost" : ""
        return "- \(app.name) (\(app.bundleID)) pid=\(app.pid)\(active)"
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: "image/png"
        }
    }

    private static func requiredString(_ args: [String: KWWKAI.JSONValue], _ key: String) throws -> String {
        guard let value = optionalString(args, key), !value.isEmpty else {
            throw ComputerUseError.invalidArgument("\(key) is required")
        }
        return value
    }

    private static func optionalString(_ args: [String: KWWKAI.JSONValue], _ key: String) -> String? {
        guard case let .string(value) = args[key] ?? .null else {
            return nil
        }
        return value
    }

    private static func optionalStringArray(_ args: [String: KWWKAI.JSONValue], _ key: String) -> [String] {
        guard case let .array(values) = args[key] ?? .null else {
            return []
        }
        return values.compactMap { value in
            guard case let .string(text) = value else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func requiredInt(_ args: [String: KWWKAI.JSONValue], _ key: String) throws -> Int {
        guard let value = optionalInt(args, key) else {
            throw ComputerUseError.invalidArgument("\(key) is required")
        }
        return value
    }

    private static func optionalInt(_ args: [String: KWWKAI.JSONValue], _ key: String) -> Int? {
        switch args[key] ?? .null {
        case let .int(value):
            value
        case let .double(value):
            Int(value)
        case let .string(value):
            Int(value)
        default:
            nil
        }
    }

    private static func requiredDouble(_ args: [String: KWWKAI.JSONValue], _ key: String) throws -> Double {
        guard let value = optionalDouble(args, key) else {
            throw ComputerUseError.invalidArgument("\(key) is required")
        }
        return value
    }

    private static func optionalDouble(_ args: [String: KWWKAI.JSONValue], _ key: String) -> Double? {
        switch args[key] ?? .null {
        case let .int(value):
            Double(value)
        case let .double(value):
            value
        case let .string(value):
            Double(value)
        default:
            nil
        }
    }

    private static func optionalBool(_ args: [String: KWWKAI.JSONValue], _ key: String) -> Bool? {
        switch args[key] ?? .null {
        case let .bool(value):
            value
        case let .string(value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                true
            case "false", "no", "0":
                false
            default:
                nil
            }
        default:
            nil
        }
    }
}

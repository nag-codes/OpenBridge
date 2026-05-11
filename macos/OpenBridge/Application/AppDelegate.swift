import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // this property is set when calling NSApp.restart()
    // exit without user interaction, fallback will syscall exit after some sec
    // fail to do so may result strange behavior
    var terminateImmediately: Bool = false
    var dockIconControlTimer: Timer?

    override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        let isE2EMode = ProcessInfo.processInfo.arguments.contains("-e2eMode")

        if !isE2EMode {
            showMacOSVersionWarningIfNeeded()
        }
        ChatAttachmentPreviewStore.clearAllPreviewDirectories()
        Windows.shared.boot()

        #if DEBUG
            AppIcon.validateAll()
        #endif

        updateDockIconActivationPolicy()
        startDockIconControlTimer()
        NSApp.mainMenu = MainMenuCoordinator.shared.menu
        NSApp.appearance = SettingsManager.shared.appearance.nsAppearance

        // Apply persisted app icon on startup
        SettingsManager.shared.appIcon.apply()

        _ = GlobalShortcutManager.shared
        _ = ChatViewModel.shared
        _ = BarMenuCoordinator.shared

        _ = SparkleUpdateManager.shared

        NotchCenter.shared.boot()

        // Pre-compile WebKit content rules for ScrubberKit (async, starts early)
        ScrubberDispatcher.setup()
        // Preload common sound effects
        SoundsService.preload()

        let launchArguments = ProcessInfo.processInfo.arguments
        let openSettingsOnLaunch = isE2EMode && launchArguments.contains("-e2eOpenSettings")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Windows.shared.open(.chat)
            if openSettingsOnLaunch {
                Windows.shared.open(.settings)
            }
        }

        AnalyticsManager.initialize()
        AnalyticsManager.track(.init(do: .appLaunched))

        // Skip VM preload in E2E runs because the test environment does not provide
        // virtualization support.
        if !isE2EMode {
            // Preload agent VM immediately on app launch (no login required).
            // Credentials are fetched on demand when executing tasks.
            AgentSessionManager.shared.preload()
            HeartbeatNotificationService.shared.boot()
        }
    }

    private func showMacOSVersionWarningIfNeeded() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion < 15 else { return }
        let alert = NSAlert()
        alert.messageText = "Unsupported macOS Version"
        alert.informativeText = "OpenBridge works best on macOS 15 (Sequoia) or later. You are running macOS \(version.majorVersion).\(version.minorVersion). Some features may not work correctly."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue Anyway")
        alert.runModal()
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        if terminateImmediately { return .terminateNow }
        // additional logic goes here
        return .terminateNow
    }

    func applicationWillTerminate(_: Notification) {
        ChatAttachmentPreviewStore.clearAllPreviewDirectories()
        HeartbeatNotificationService.shared.shutdown()
        AgentSessionManager.shared.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}

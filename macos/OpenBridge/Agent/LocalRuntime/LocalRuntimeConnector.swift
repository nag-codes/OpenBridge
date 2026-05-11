import Foundation
import OSLog

private let logger = Logger(subsystem: Logger.loggingSubsystem, category: "LocalRuntimeConnector")

private nonisolated func makeConnectorWebSocketSession() -> URLSession {
    let configuration = URLSessionConfiguration.default
    configuration.waitsForConnectivity = false
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 604_800
    configuration.httpMaximumConnectionsPerHost = 1
    return URLSession(configuration: configuration)
}

private enum PermissionKind: String, Hashable {
    case hostAccess = "host_access"

    init(rawValueOrDefault rawValue: String?) throws {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            self = .hostAccess
            return
        }
        guard let value = PermissionKind(rawValue: trimmed) else {
            throw ConnectorError.invalidParams("unsupported permission kind: \(trimmed)")
        }
        self = value
    }

    var approvalLabel: String {
        switch self {
        case .hostAccess:
            "permission"
        }
    }
}

private struct PermissionGrantKey: Hashable {
    let sessionKey: String
    let kind: PermissionKind
}

struct PermissionConfirmationReply: Sendable {
    let approved: Bool
    /// Populated only for ComputerUse start confirmations; host_access and
    /// similar always see nil.
    let mode: String?
}

private struct PendingConfirmation {
    var continuations: [CheckedContinuation<PermissionConfirmationReply, Never>]
    let sessionId: String?
    let grantKey: PermissionGrantKey?
}

private enum PermissionReplyReason {
    static let expired = "expired"
}

/// Persistent connector that exposes local execution environments to the agent runtime.
@MainActor @Observable
final class LocalRuntimeConnector {
    enum State: String {
        case disconnected, connecting, connected, reconnecting
    }

    enum EnvironmentKind {
        case localMacOS
        case localVM

        var userVisibleName: String {
            switch self {
            case .localMacOS:
                "This Mac"
            case .localVM:
                "Safe Workspace on This Mac"
            }
        }

        var connectName: String {
            userVisibleName
        }

        var connectAlias: String {
            switch self {
            case .localMacOS:
                "local"
            case .localVM:
                "sandbox"
            }
        }

        var permissionEnvironmentLabel: String {
            userVisibleName
        }

        static func userVisibleName(forAlias alias: String) -> String {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return trimmed }

            let normalized = trimmed
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
            if normalized == "sandbox" || normalized.hasPrefix("sandbox-") || normalized == "local-vm" || normalized.hasPrefix("local-vm-") {
                return EnvironmentKind.localVM.userVisibleName
            }
            if normalized == "local" || normalized.hasPrefix("local-") {
                return EnvironmentKind.localMacOS.userVisibleName
            }
            if normalized == "cloud-vm" {
                return EnvironmentKind.localVM.userVisibleName
            }
            if normalized == "vfs" {
                return "Agent Files"
            }
            return trimmed
        }
    }

    enum Target {
        case localMacOS
        case embeddedVM(EmbeddedVMRuntimeBridge)
    }

    private struct ConnectAck: Decodable {
        let type: String
        let envId: String?

        private enum CodingKeys: String, CodingKey {
            case type
            case envId = "env_id"
        }
    }

    private struct ResponseRoute {
        let connectionID: UUID
        let task: URLSessionWebSocketTask
    }

    private struct RequestTaskRecord {
        let connectionID: UUID
        let requestID: String
        let task: Task<Void, Never>
    }

    // MARK: - Public State

    private(set) var state: State = .disconnected
    private(set) var envID: String?

    // MARK: - Configuration

    let agentGroupId: String
    let environmentKind: EnvironmentKind
    let target: Target

    private static let maxSkillInventoryDescriptionLength = 3000

    // MARK: - Private

    private var webSocketTask: URLSessionWebSocketTask?
    private var activeConnectionID: UUID?
    private var prevEnvID: String?
    private var connectionTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var requestTasks: [UUID: RequestTaskRecord] = [:]
    private var responseRoutes: [String: ResponseRoute] = [:]
    private var routedRequestIDs: Set<String> = []
    private var shouldResetBackoffAfterDisconnect = false
    private let writeSerializer = WriteSerializer()
    private var runningProcesses: [String: Process] = [:]
    private var processLock = NSLock()
    private var grantedPermissionKeys: Set<PermissionGrantKey> = []
    private var pendingPermissionConfirmationIDsByGrantKey: [PermissionGrantKey: String] = [:]
    /// Routes incoming write_stream data chunks to the handler goroutine.
    private var streamChannels: [String: AsyncStream<ConnectorStreamData>.Continuation] = [:]
    private var streamChannelLock = NSLock()
    @ObservationIgnored
    private var skillInventoryObserver: NSObjectProtocol?
    private let webSocketSession: URLSession

    // MARK: - Init

    init(agentGroupId: String, environmentKind: EnvironmentKind, target: Target) {
        self.agentGroupId = agentGroupId
        self.environmentKind = environmentKind
        self.target = target
        webSocketSession = makeConnectorWebSocketSession()
        skillInventoryObserver = NotificationCenter.default.addObserver(
            forName: .skillInventoryDidChange,
            object: SkillManager.shared,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.sendSkillMetadataSnapshotIfConnected()
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let skillInventoryObserver {
                NotificationCenter.default.removeObserver(skillInventoryObserver)
            }
        }
        webSocketSession.invalidateAndCancel()
    }

    // MARK: - Lifecycle

    func connect() {
        guard connectionTask == nil else { return }
        connectionTask = Task { [weak self] in
            guard let self else { return }
            await runWithReconnect()
        }
    }

    func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        pingTask?.cancel()
        pingTask = nil
        cancelAllRequestTasks()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        activeConnectionID = nil
        shouldResetBackoffAfterDisconnect = false
        state = .disconnected
        clearAllGrantedPermissions()
        killAllProcesses()
        finishAllStreamChannels()
    }

    // MARK: - Connection Loop

    private func runWithReconnect() async {
        var backoff: UInt64 = 1
        shouldResetBackoffAfterDisconnect = false
        while !Task.isCancelled {
            state = backoff == 1 ? .connecting : .reconnecting

            do {
                try await connectAndServe()
            } catch {
                if Task.isCancelled { break }
                if shouldResetBackoffAfterDisconnect {
                    backoff = 1
                    shouldResetBackoffAfterDisconnect = false
                }
                logger.warning("Disconnected: \(error.localizedDescription)")
            }

            state = .disconnected
            if Task.isCancelled { break }

            logger.info("Reconnecting in \(backoff)s")
            do {
                try await Task.sleep(for: .seconds(backoff))
            } catch {
                break
            }
            backoff = min(backoff * 2, 5)
        }
        state = .disconnected
    }

    private func connectAndServe() async throws {
        let connectionID = UUID()
        let task = webSocketSession.webSocketTask(with: buildConnectRequest())
        activeConnectionID = connectionID
        webSocketTask = task
        task.resume()
        defer {
            pingTask?.cancel()
            pingTask = nil
            cancelRequestTasks(for: connectionID)
            if webSocketTask === task {
                webSocketTask = nil
            }
            if activeConnectionID == connectionID {
                activeConnectionID = nil
            }
            finishAllStreamChannels()
            killAllProcesses()
        }

        try await sendInitialSkillMetadata(on: task)
        let envId = try await receiveConnectedEnvID(from: task)
        prevEnvID = envId
        envID = envId
        state = .connected
        shouldResetBackoffAfterDisconnect = true
        logger.info("Connected, env_id=\(envId)")

        startPingLoop(for: task)
        try await serveRequests(on: task, connectionID: connectionID)
    }

    private func buildConnectRequest() -> URLRequest {
        var request = URLRequest(url: buildConnectURL())
        request.timeoutInterval = 30
        return request
    }

    private func receiveConnectedEnvID(from task: URLSessionWebSocketTask) async throws -> String {
        let ackMessage = try await withTimeout(.seconds(30)) {
            try await task.receive()
        }
        let ackData = try data(from: ackMessage)
        let ack = try JSONDecoder().decode(ConnectAck.self, from: ackData)
        guard ack.type == "connected", let envId = ack.envId else {
            throw ConnectorError.notConnected
        }
        return envId
    }

    private func serveRequests(on task: URLSessionWebSocketTask, connectionID: UUID) async throws {
        while !Task.isCancelled {
            let message = try await task.receive()
            await handleSocketMessage(message, on: task, connectionID: connectionID)
        }
    }

    private func handleSocketMessage(
        _ message: URLSessionWebSocketTask.Message,
        on task: URLSessionWebSocketTask,
        connectionID: UUID
    ) async {
        guard let data = try? data(from: message),
              let msg = try? JSONDecoder().decode(ConnectorMessage.self, from: data)
        else {
            return
        }

        if msg.type == "stream", let streamData = msg.stream {
            routeStreamChunk(id: msg.id, data: streamData)
            return
        }

        guard msg.type == "request" else { return }

        responseRoutes[msg.id] = ResponseRoute(connectionID: connectionID, task: task)
        routedRequestIDs.insert(msg.id)
        let requestTaskID = UUID()
        let requestTask = Task { [weak self] in
            guard let self else { return }
            defer { unregisterRequestTask(requestTaskID) }
            await handleRequest(msg)
        }
        requestTasks[requestTaskID] = RequestTaskRecord(connectionID: connectionID, requestID: msg.id, task: requestTask)
    }

    private func data(from message: URLSessionWebSocketTask.Message) throws -> Data {
        switch message {
        case let .string(text): return Data(text.utf8)
        case let .data(data): return data
        @unknown default: throw ConnectorError.notConnected
        }
    }

    private func startPingLoop(for task: URLSessionWebSocketTask) {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }

                do {
                    try await waitForPong(on: task, timeout: .seconds(10))
                } catch {
                    logger.warning("WebSocket ping failed: \(error.localizedDescription)")
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
    }

    private func waitForPong(on task: URLSessionWebSocketTask, timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let pingState = PingContinuationState(continuation: continuation)
            let timeoutTask = Task {
                try? await Task.sleep(for: timeout)
                pingState.resume(.failure(PingError.timeout))
            }
            pingState.setTimeoutTask(timeoutTask)

            task.sendPing { error in
                pingState.cancelTimeout()
                if let error {
                    pingState.resume(.failure(error))
                } else {
                    pingState.resume(.success(()))
                }
            }
        }
    }

    private nonisolated func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimeoutError.timeout
            }

            guard let result = try await group.next() else {
                throw TimeoutError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    private func unregisterRequestTask(_ id: UUID) {
        guard let entry = requestTasks.removeValue(forKey: id) else { return }
        if responseRoutes[entry.requestID]?.connectionID == entry.connectionID {
            responseRoutes.removeValue(forKey: entry.requestID)
            routedRequestIDs.remove(entry.requestID)
        } else if responseRoutes[entry.requestID] == nil {
            routedRequestIDs.remove(entry.requestID)
        }
    }

    private func cancelRequestTasks(for connectionID: UUID) {
        for entry in requestTasks.values where entry.connectionID == connectionID {
            entry.task.cancel()
        }
    }

    private func cancelAllRequestTasks() {
        for entry in requestTasks.values {
            entry.task.cancel()
        }
    }

    // MARK: - URL Construction

    private func buildConnectURL() -> URL {
        guard var components = URLComponents(string: "ws://127.0.0.1") else {
            fatalError("Invalid API base URL")
        }
        components.path = "/v1/user/agent/connect"
        components.scheme = "ws"

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "name", value: environmentKind.connectName),
            URLQueryItem(name: "alias", value: environmentKind.connectAlias),
            URLQueryItem(name: "group_id", value: agentGroupId),
            URLQueryItem(name: "initial_metadata", value: "1"),
            URLQueryItem(name: "os", value: "darwin"),
            URLQueryItem(name: "arch", value: currentArch()),
        ]
        if let prevEnvID {
            queryItems.append(URLQueryItem(name: "env_id", value: prevEnvID))
        }
        components.queryItems = queryItems

        let descEncoded = localDescription().addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? ""
        let separator = components.percentEncodedQuery == nil ? "?" : "&"
        components.percentEncodedQuery = (components.percentEncodedQuery ?? "") + "\(separator)description=\(descEncoded)"
        return components.url!
    }

    private func currentArch() -> String {
        #if arch(arm64)
            return "arm64"
        #else
            return "x86_64"
        #endif
    }

    func localDescription() -> String {
        let localHome = NSHomeDirectory()
        var parts = ["darwin/\(currentArch())"]
        if let version = ProcessInfo.processInfo.operatingSystemVersionString as String? {
            parts.append(version)
        }
        parts.append("home=\(localHome)")
        parts.append("cpus=\(ProcessInfo.processInfo.processorCount)")
        switch environmentKind {
        case .localMacOS:
            parts.append("This Mac environment; use environment=\"local\" to target it. This is the computer the user is currently using and the highest-risk protected environment. Commands and file operations affect the host directly with no connector sandbox. Do not use this by default and do not switch here on your own initiative. First use environment=\"sandbox\" whenever it can accomplish the goal. Only after concluding sandbox cannot do the job should you request or trigger local permission and execute host commands or other protected host operations. Permission is temporary for the current task execution; do not assume a past approval applies to later user requests. Before requesting or triggering local permission, describe exactly what you plan to do. This Mac shares the user's files with the safe local workspace. Never operate on both This Mac and the safe local workspace filesystems in the same task; choose one environment for filesystem work. If a task truly requires host execution, stay on This Mac for that task instead of continuing to modify files from the safe local workspace. This environment disappears when the OpenBridge client disconnects.")
        case .localVM:
            let mountDescription = Self.localVMMountDescription(SettingsManager.shared.localVMMounts)
            parts.append("Safe Workspace on This Mac; use environment=\"sandbox\" to target it. This is the default environment and usually the safest way to work with the user's local files. Commands and file operations execute inside a protected bundled workspace, not directly on This Mac. Mounted host folders are available at their listed absolute macOS paths and edits stay staged until the user accepts applying them back to the host. Mounted folders: \(mountDescription). Prefer this environment unless the user explicitly requests direct host work or sandbox cannot complete the task. If sandbox can finish the task, stay here and do not request host access. Never operate on both the safe local workspace and This Mac filesystems in the same task; choose one environment for filesystem work. If the task truly requires host execution, stop using the safe local workspace filesystem for that task and switch fully to environment=\"local\". Commands here do not trigger host GUI or process side effects. Use absolute macOS paths under the mounted folders in file tools and shell commands, and report those absolute macOS paths back to the user. Do not assume Desktop, Documents, or Downloads are available unless their parent folder is mounted. This environment disappears when the OpenBridge client disconnects.")
        }
        parts.append(Self.localSkillInventoryDescription(
            skills: SkillManager.shared.skills,
            homeDirectory: localHome,
            maxLength: Self.maxSkillInventoryDescriptionLength
        ))
        return parts.joined(separator: "; ")
    }

    private static func localVMMountDescription(_ mounts: [LocalVMMount]) -> String {
        let effectiveMounts = mounts.isEmpty ? LocalVMMount.defaultMounts() : mounts
        return effectiveMounts
            .map { mount in
                let mode = mount.readOnly ? "read-only" : "reviewed writes"
                if mount.vmPath == mount.hostPath {
                    return "\(mount.hostPath) (\(mode))"
                }
                return "\(mount.hostPath) mounted at \(mount.vmPath) (\(mode))"
            }
            .joined(separator: ", ")
    }

    static func localSkillInventoryDescription(
        skills: [Skill],
        homeDirectory: String,
        maxLength: Int = 3000
    ) -> String {
        let skillsRoot = Self.skillsRootPath(homeDirectory: homeDirectory)
        let activeSkills = Self.activeSkills(skills)

        let prefix = """
        local skills available via this machine: read the referenced SKILL.md files through the local environment when relevant; root \(skillsRoot); discovered \(activeSkills.count) active skill(s)
        """

        guard !activeSkills.isEmpty else {
            return prefix + ": none"
        }

        var entries: [String] = []
        entries.reserveCapacity(activeSkills.count)

        for skill in activeSkills {
            let entry = "\(skill.name) [\(skillCategoryLabel(skill.category))] - \(normalizedDescription(skill.description)) @ \(skill.fileURL.path)"
            entries.append(entry)
        }

        var result = prefix + ": "
        var remainingCount = activeSkills.count

        for entry in entries {
            let separator = result.hasSuffix(": ") ? "" : " | "
            let candidate = result + separator + entry
            if candidate.count > maxLength {
                break
            }
            result = candidate
            remainingCount -= 1
        }

        if remainingCount > 0 {
            let suffix = " | ... (\(remainingCount) more skill(s) not shown)"
            if result.count + suffix.count <= maxLength {
                result += suffix
            } else if suffix.count < maxLength {
                let limit = maxLength - suffix.count
                result = String(result.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + suffix
            }
        }

        return result
    }

    static func localSkillMetadata(skills: [Skill]) -> [EnvironmentSkillMetadata] {
        activeSkills(skills).map { skill in
            EnvironmentSkillMetadata(
                name: skill.name,
                description: normalizedDescription(skill.description),
                location: skill.fileURL.path,
                source: skillCategoryLabel(skill.category)
            )
        }
    }

    private static func localCapabilities(for _: EnvironmentKind) -> EnvironmentCapabilities {
        EnvironmentCapabilities()
    }

    private static func activeSkills(_ skills: [Skill]) -> [Skill] {
        skills
            .filter { !$0.disabled && $0.visibility != .hidden }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private static func skillsRootPath(homeDirectory: String) -> String {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".openbridge/skills", isDirectory: true)
            .path
    }

    private func sendSkillMetadataSnapshotIfConnected() async {
        guard state == .connected, webSocketTask != nil else { return }
        await sendResponse(.metadata(
            skills: Self.localSkillMetadata(skills: SkillManager.shared.skills),
            capabilities: Self.localCapabilities(for: environmentKind)
        ))
    }

    private func sendInitialSkillMetadata(on task: URLSessionWebSocketTask) async throws {
        try await sendMessage(.metadata(
            skills: Self.localSkillMetadata(skills: SkillManager.shared.skills),
            capabilities: Self.localCapabilities(for: environmentKind)
        ), on: task)
    }

    private static func skillCategoryLabel(_ category: Skill.Category) -> String {
        switch category {
        case .custom:
            "custom"
        case .synced:
            "sync"
        case .imported:
            "imported"
        case .reflected:
            "reflected"
        case .system:
            "system"
        }
    }

    private static func normalizedDescription(_ description: String) -> String {
        let trimmed = description
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: ";", with: ",")
        if trimmed.isEmpty {
            return "No description"
        }
        if trimmed.count <= 140 {
            return trimmed
        }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: 140)
        return String(trimmed[..<endIndex]) + "..."
    }

    // MARK: - Request Dispatch

    private func handleRequest(_ msg: ConnectorMessage) async {
        guard let method = msg.method else {
            await sendResponse(.error(id: msg.id, message: "missing method"))
            return
        }

        if await handleReadRequest(method, msg: msg) {
            return
        }
        if await handleWriteRequest(method, msg: msg) {
            return
        }

        switch method {
        case ConnectorMethod.readStream:
            await dispatchReadStream(msg)
        case ConnectorMethod.writeStream:
            await dispatchWriteStream(msg)
        case ConnectorMethod.exec:
            await handleExecRequest(msg)
        case ConnectorMethod.requestPermission:
            await handleRequestPermission(msg)
        default:
            await sendResponse(.error(id: msg.id, message: "unknown method: \(method)"))
        }
    }

    private func handleReadRequest(_ method: String, msg: ConnectorMessage) async -> Bool {
        switch method {
        case ConnectorMethod.read:
            await dispatchWithReadCheck(msg, pathKey: \.path) { try await self.handleRead(params: $0, sessionID: msg.sessionId) }
        case ConnectorMethod.stat:
            await dispatchWithReadCheck(msg, pathKey: \.path) { try await self.handleStat(params: $0, sessionID: msg.sessionId) }
        case ConnectorMethod.list:
            await dispatchWithReadCheck(msg, pathKey: \.path) { try await self.handleList(params: $0, sessionID: msg.sessionId) }
        case ConnectorMethod.glob:
            await dispatchWithReadCheck(msg, pathKey: \.optionalPath) { try await self.handleGlob(params: $0, sessionID: msg.sessionId) }
        case ConnectorMethod.grep:
            await dispatchWithReadCheck(msg, pathKey: \.optionalPath) { try await self.handleGrep(params: $0, sessionID: msg.sessionId) }
        default:
            return false
        }
        return true
    }

    private func handleWriteRequest(_ method: String, msg: ConnectorMessage) async -> Bool {
        switch method {
        case ConnectorMethod.write:
            await dispatchWithWriteCheck(msg, description: describeWrite(msg.params)) {
                try await self.handleWrite(params: $0, sessionID: msg.sessionId)
            }
        case ConnectorMethod.delete:
            await dispatchWithWriteCheck(msg, description: describeDelete(msg.params)) {
                try await self.handleDelete(params: $0, sessionID: msg.sessionId)
            }
        default:
            return false
        }
        return true
    }

    private func handleExecRequest(_ msg: ConnectorMessage) async {
        switch environmentKind {
        case .localMacOS:
            await handleLocalMacExecRequest(msg)
        case .localVM:
            await handleExec(msg, commandOverride: nil)
        }
    }

    private func handleLocalMacExecRequest(_ msg: ConnectorMessage) async {
        if requiresExecPermission(sessionId: msg.sessionId) {
            await sendResponse(.error(id: msg.id, message: protectedEnvironmentError(action: "execute command")))
            return
        }
        await handleExec(msg, commandOverride: nil)
    }

    private func dispatchWithReadCheck(
        _ msg: ConnectorMessage,
        pathKey: KeyPath<PathExtractor, String?>,
        handler: @Sendable (JSONValue) async throws -> JSONValue
    ) async {
        guard let params = msg.params else {
            await sendResponse(.error(id: msg.id, message: "missing params"))
            return
        }
        if hasGrantedPermission(sessionId: msg.sessionId, kind: .hostAccess) {
            do {
                let result = try await handler(params)
                await sendResponse(.response(id: msg.id, result: result))
            } catch {
                await sendResponse(.error(id: msg.id, message: error.localizedDescription))
            }
            return
        }
        let extractor = PathExtractor(params: params)
        if let raw = extractor[keyPath: pathKey] {
            let (_, elevated) = checkReadPath(raw)
            if requiresPathPermission(elevated: elevated) {
                await sendResponse(.error(id: msg.id, message: protectedEnvironmentError(action: "read \(raw)")))
                return
            }
        }
        do {
            let result = try await handler(params)
            await sendResponse(.response(id: msg.id, result: result))
        } catch {
            await sendResponse(.error(id: msg.id, message: error.localizedDescription))
        }
    }

    private func dispatchWithWriteCheck(
        _ msg: ConnectorMessage,
        description: String,
        handler: @Sendable (JSONValue) async throws -> JSONValue
    ) async {
        guard let params = msg.params else {
            await sendResponse(.error(id: msg.id, message: "missing params"))
            return
        }
        if hasGrantedPermission(sessionId: msg.sessionId, kind: .hostAccess) {
            do {
                let result = try await handler(params)
                await sendResponse(.response(id: msg.id, result: result))
            } catch {
                await sendResponse(.error(id: msg.id, message: error.localizedDescription))
            }
            return
        }
        let extractor = PathExtractor(params: params)
        if let raw = extractor.path {
            _ = checkWritePath(raw)
            if requiresMutationPermission() {
                await sendResponse(.error(id: msg.id, message: protectedEnvironmentError(action: description)))
                return
            }
        }
        do {
            let result = try await handler(params)
            await sendResponse(.response(id: msg.id, result: result))
        } catch {
            await sendResponse(.error(id: msg.id, message: error.localizedDescription))
        }
    }

    private var pendingConfirmations: [String: PendingConfirmation] = [:]

    private func describeWrite(_ params: JSONValue?) -> String {
        guard let params, let p = try? params.decode(WriteParams.self) else {
            return String(localized: "Write to a file")
        }
        let size = p.content.utf8.count
        return String(localized: "Write \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) to \(p.path)")
    }

    private func describeDelete(_ params: JSONValue?) -> String {
        guard let params, let p = try? params.decode(DeleteParams.self) else {
            return String(localized: "Delete a file")
        }
        let recursive = (p.recursive == true) ? " (recursive)" : ""
        return String(localized: "Delete \(p.path)\(recursive)")
    }

    private func describeExec(_ command: String) -> String {
        let truncated = command.count > 200 ? String(command.prefix(200)) + "..." : command
        return String(localized: "Run command:\n\(truncated)")
    }

    private func describeExec(_ params: JSONValue?) -> String {
        guard let params, let p = try? params.decode(ExecParams.self) else {
            return String(localized: "Run a shell command")
        }
        if let description = p.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            return description
        }
        return describeExec(p.command)
    }

    // MARK: - Streaming Dispatch

    private func dispatchReadStream(_ msg: ConnectorMessage) async {
        guard let params = msg.params else {
            await sendResponse(.error(id: msg.id, message: "missing params"))
            return
        }
        if hasGrantedPermission(sessionId: msg.sessionId, kind: .hostAccess) {
            await handleReadStream(msg)
            return
        }
        let extractor = PathExtractor(params: params)
        if let raw = extractor.path {
            let (_, elevated) = checkReadPath(raw)
            if requiresPathPermission(elevated: elevated) {
                await sendResponse(.error(id: msg.id, message: protectedEnvironmentError(action: "stream read \(raw)")))
                return
            }
        }
        await handleReadStream(msg)
    }

    private func dispatchWriteStream(_ msg: ConnectorMessage) async {
        guard let params = msg.params else {
            await sendResponse(.error(id: msg.id, message: "missing params"))
            return
        }
        if hasGrantedPermission(sessionId: msg.sessionId, kind: .hostAccess) {
            await handleWriteStream(msg)
            return
        }
        let extractor = PathExtractor(params: params)
        if let raw = extractor.path {
            _ = checkWritePath(raw)
            if requiresMutationPermission() {
                let description =
                    if let p = try? params.decode(WriteStreamParams.self) {
                        String(localized: "Stream write to \(p.path)")
                    } else {
                        String(localized: "Stream write to a file")
                    }
                await sendResponse(.error(id: msg.id, message: protectedEnvironmentError(action: description)))
                return
            }
        }
        await handleWriteStream(msg)
    }

    // MARK: - Stream Channel Management

    func registerStreamChannel(for requestId: String) -> AsyncStream<ConnectorStreamData> {
        let (stream, continuation) = AsyncStream<ConnectorStreamData>.makeStream()
        streamChannelLock.lock()
        streamChannels[requestId] = continuation
        streamChannelLock.unlock()
        return stream
    }

    func unregisterStreamChannel(for requestId: String) {
        streamChannelLock.lock()
        let continuation = streamChannels.removeValue(forKey: requestId)
        streamChannelLock.unlock()
        continuation?.finish()
    }

    private func routeStreamChunk(id: String, data: ConnectorStreamData) {
        streamChannelLock.lock()
        let continuation = streamChannels[id]
        streamChannelLock.unlock()
        continuation?.yield(data)
    }

    // MARK: - WebSocket Write

    func sendResponse(_ msg: ConnectorMessage) async {
        let route = responseRoutes[msg.id]
        guard let task = route?.task ?? webSocketTask else { return }
        if let route {
            guard route.connectionID == activeConnectionID, webSocketTask === task else { return }
        } else if routedRequestIDs.contains(msg.id) {
            return
        }
        do {
            try await sendMessage(msg, on: task)
        } catch {
            logger.error("WS write failed: \(error.localizedDescription)")
        }
    }

    private func sendMessage(_ msg: ConnectorMessage, on task: URLSessionWebSocketTask) async throws {
        let data = try JSONEncoder().encode(msg)
        let text = String(data: data, encoding: .utf8) ?? ""
        try await writeSerializer.send(text, on: task)
    }

    // MARK: - Path Safety

    private static let deniedReadPaths: [String] = {
        let home = NSHomeDirectory()
        return [
            (home as NSString).appendingPathComponent(".ssh"),
            (home as NSString).appendingPathComponent(".gnupg"),
            (home as NSString).appendingPathComponent(".aws"),
            (home as NSString).appendingPathComponent("Library/Keychains"),
        ]
    }()

    private static let allowedWritePaths: [String] = [
        "/private/tmp",
        "/private/var/folders",
        "/tmp",
    ]

    func resolvePath(_ requested: String) -> String {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardized
        return URL(fileURLWithPath: requested, relativeTo: home).standardized.path
    }

    func requiresPathPermission(elevated: Bool) -> Bool {
        guard elevated else { return false }
        guard environmentKind == .localMacOS else { return false }
        return SettingsManager.shared.localEnvironmentPermissionMode != .fullAccess
    }

    func requiresMutationPermission() -> Bool {
        guard environmentKind == .localMacOS else { return false }
        guard SettingsManager.shared.localEnvironmentPermissionMode != .fullAccess else { return false }
        return true
    }

    func requiresExecPermission(sessionId: String?) -> Bool {
        guard environmentKind == .localMacOS else { return false }
        guard SettingsManager.shared.localEnvironmentPermissionMode != .fullAccess else { return false }
        return !hasGrantedPermission(sessionId: sessionId, kind: .hostAccess)
    }

    func requestHostAccessForTool(description: String, sessionId: String?) async -> Bool {
        await requestPermission(
            method: "tool",
            kind: .hostAccess,
            description: description,
            sessionId: sessionId
        )
    }

    func requestToolPermission(requestedEnvironment: String, description: String, sessionID: String?) async throws -> JSONValue {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else {
            throw ConnectorError.invalidParams("description is required")
        }

        switch environmentKind {
        case .localVM:
            return .dict([
                "approved": true,
                "environment_id": environmentKind.connectAlias,
                "environment_label": environmentKind.permissionEnvironmentLabel,
                "message": "permission is not required for this environment",
            ])
        case .localMacOS:
            guard normalizedSessionKey(sessionID) != nil else {
                throw ConnectorError.invalidParams("request_permission requires session context")
            }
            if hasGrantedPermission(sessionId: sessionID, kind: .hostAccess) {
                return .dict([
                    "approved": true,
                    "environment_id": environmentKind.connectAlias,
                    "environment_label": environmentKind.permissionEnvironmentLabel,
                    "message": "permission is already granted for this task",
                ])
            }

            let requestEnvironment = requestedEnvironment.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestDescription = requestEnvironment.isEmpty
                ? trimmedDescription
                : "\(trimmedDescription)\nRequested environment: \(EnvironmentKind.userVisibleName(forAlias: requestEnvironment))"
            let approved = await requestPermission(
                method: requestEnvironment.isEmpty ? environmentKind.connectAlias : requestEnvironment,
                kind: .hostAccess,
                description: requestDescription,
                sessionId: sessionID
            )
            return .dict([
                "approved": approved,
                "environment_id": environmentKind.connectAlias,
                "environment_label": environmentKind.permissionEnvironmentLabel,
                "message": approved ? "permission granted for this task" : "permission denied for this task",
            ])
        }
    }

    func protectedEnvironmentError(action: String) -> String {
        let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = trimmed.isEmpty ? "this operation" : trimmed
        return "environment \"local\" is protected; call request_permission(environment=\"local\", description=\"...\") before trying to \(detail)"
    }

    func checkReadPath(_ requested: String) -> (String, Bool) {
        let path = resolvePath(requested)
        for denied in Self.deniedReadPaths {
            if path == denied || path.hasPrefix(denied + "/") {
                return (path, true)
            }
        }
        return (path, false)
    }

    func checkWritePath(_ requested: String) -> (String, Bool) {
        let path = resolvePath(requested)
        for allowed in Self.allowedWritePaths {
            if path == allowed || path.hasPrefix(allowed + "/") {
                return (path, false)
            }
        }
        return (path, true)
    }

    // MARK: - Process Tracking

    func trackProcess(_ id: String, _ process: Process) {
        processLock.lock()
        runningProcesses[id] = process
        processLock.unlock()
    }

    func untrackProcess(_ id: String) {
        processLock.lock()
        runningProcesses.removeValue(forKey: id)
        processLock.unlock()
    }

    private func finishAllStreamChannels() {
        streamChannelLock.lock()
        let continuations = streamChannels.values
        streamChannels.removeAll()
        streamChannelLock.unlock()
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func killAllProcesses() {
        processLock.lock()
        let processes = runningProcesses.values
        runningProcesses.removeAll()
        processLock.unlock()
        for process in processes {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    func canResolveSessionConfirmation(id: String) -> Bool {
        canResolveConfirmation(id: id)
    }

    func resolveSessionConfirmation(id: String, approved: Bool, mode: String? = nil) {
        resolveConfirmation(id: id, approved: approved, mode: mode)
    }

    func clearSessionPermission(sessionId: String) {
        clearGrantedPermission(sessionId: sessionId)
    }
}

extension LocalRuntimeConnector {
    /// Inject a permission_request carrying mode-selection metadata and await
    /// the reply. Used by ComputerUse `start` to let the user pick background
    /// vs foreground in the chat card.
    func awaitComputerUseStart(
        availableModes: [String],
        apps: [String]?,
        permissions: [SessionHistoryMessage.ComputerUsePermissionPane]?,
        description: String,
        sessionId: String?
    ) async -> PermissionConfirmationReply {
        await awaitPermissionConfirmation(
            kind: .hostAccess, // computer_use no longer uses PermissionKind; this is unused when computerUseStart is non-nil
            description: description,
            sessionId: sessionId,
            computerUseStart: SessionHistoryMessage.ComputerUseStartInfo(
                availableModes: availableModes,
                apps: apps,
                permissions: permissions
            )
        )
    }

    func hasGrantedHostAccessPermission(sessionId: String?) -> Bool {
        hasGrantedPermission(sessionId: sessionId, kind: .hostAccess)
    }

    func hasGrantedHostAccessPermissionForTesting(sessionId: String?) -> Bool {
        hasGrantedHostAccessPermission(sessionId: sessionId)
    }
}

private extension LocalRuntimeConnector {
    // MARK: - User Confirmation

    func clearGrantedPermission(sessionId: String) {
        guard let sessionKey = normalizedSessionKey(sessionId) else { return }
        cancelPendingPermissionRequests(for: sessionKey)
        grantedPermissionKeys = Set(grantedPermissionKeys.filter { $0.sessionKey != sessionKey })
    }

    /// Injects a permission_request message into the session that triggered the
    /// request (identified by sessionId) and suspends until the user clicks
    /// Allow or Deny in the chat UI. Returns false immediately if no session
    /// is available so the connector does not hang indefinitely.
    func requestPermission(
        method _: String,
        kind: PermissionKind,
        description: String,
        sessionId: String?
    ) async -> Bool {
        if hasGrantedPermission(sessionId: sessionId, kind: kind) {
            return true
        }

        let reply = await awaitPermissionConfirmation(
            kind: kind,
            description: description,
            sessionId: sessionId,
            computerUseStart: nil
        )
        return reply.approved
    }

    func awaitPermissionConfirmation(
        kind: PermissionKind,
        description: String,
        sessionId: String?,
        computerUseStart: SessionHistoryMessage.ComputerUseStartInfo?
    ) async -> PermissionConfirmationReply {
        let sessionKey = normalizedSessionKey(sessionId)
        // ComputerUse start requests do not use grant caching — each start is
        // an explicit user confirmation; the grant key is only populated for
        // host_access-style permissions.
        let grantKey: PermissionGrantKey? = if computerUseStart == nil {
            sessionKey.map { PermissionGrantKey(sessionKey: $0, kind: kind) }
        } else {
            nil
        }

        if let grantKey,
           let pendingConfirmationID = pendingPermissionConfirmationIDsByGrantKey[grantKey],
           pendingConfirmations[pendingConfirmationID] != nil
        {
            return await withCheckedContinuation { continuation in
                guard var pending = pendingConfirmations[pendingConfirmationID] else {
                    continuation.resume(returning: PermissionConfirmationReply(approved: false, mode: nil))
                    return
                }
                pending.continuations.append(continuation)
                pendingConfirmations[pendingConfirmationID] = pending
            }
        }
        if let grantKey {
            pendingPermissionConfirmationIDsByGrantKey.removeValue(forKey: grantKey)
        }

        let confirmationId = "connector-\(UUID().uuidString)"
        let requestMessage = SessionHistoryMessage(
            id: confirmationId,
            type: "permission_request",
            role: "assistant",
            timestamp: Date().timeIntervalSince1970,
            content: nil,
            messageId: nil,
            taskId: nil,
            action: nil,
            taskTitle: nil,
            todos: nil,
            sandboxId: nil,
            acceptedSummary: nil,
            reviewDiff: nil,
            reviewDiffTotal: nil,
            confirmationId: confirmationId,
            traceparent: nil,
            tracestate: nil,
            question: nil,
            questionReply: nil,
            saveFileRequest: nil,
            saveFileReply: nil,
            permissionRequest: SessionHistoryMessage.PermissionRequestInfo(
                environmentId: environmentKind.connectAlias,
                environmentLabel: environmentKind.permissionEnvironmentLabel,
                kind: computerUseStart != nil ? "computer_use_start" : kind.rawValue,
                description: description,
                computerUseStart: computerUseStart
            ),
            permissionReply: nil,
            secretInput: nil,
            secretInputReply: nil,
            schedule: nil,
            toolUseId: nil,
            errorType: nil,
            error: nil
        )
        guard AgentSessionManager.shared.injectMessage(requestMessage, intoSessionID: sessionId) else {
            return PermissionConfirmationReply(approved: false, mode: nil)
        }

        return await withCheckedContinuation { continuation in
            pendingConfirmations[confirmationId] = PendingConfirmation(
                continuations: [continuation],
                sessionId: sessionId,
                grantKey: grantKey
            )
            if let grantKey {
                pendingPermissionConfirmationIDsByGrantKey[grantKey] = confirmationId
            }
        }
    }

    func handleRequestPermission(_ msg: ConnectorMessage) async {
        guard let params = msg.params else {
            await sendResponse(.error(id: msg.id, message: "missing params"))
            return
        }

        let request: RequestPermissionParams
        do {
            request = try params.decode(RequestPermissionParams.self)
        } catch {
            await sendResponse(.error(id: msg.id, message: "invalid params: \(error.localizedDescription)"))
            return
        }

        let trimmedDescription = request.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else {
            await sendResponse(.error(id: msg.id, message: "description is required"))
            return
        }

        let kind: PermissionKind
        do {
            kind = try .init(rawValueOrDefault: request.kind)
        } catch {
            await sendResponse(.error(id: msg.id, message: error.localizedDescription))
            return
        }

        switch environmentKind {
        case .localVM:
            await sendResponse(.response(id: msg.id, result: .dict([
                "approved": true,
                "environment_id": environmentKind.connectAlias,
                "environment_label": environmentKind.permissionEnvironmentLabel,
                "message": "permission is not required for this environment",
            ])))
        case .localMacOS:
            guard normalizedSessionKey(msg.sessionId) != nil else {
                await sendResponse(.error(id: msg.id, message: "request_permission requires session context"))
                return
            }

            if hasGrantedPermission(sessionId: msg.sessionId, kind: kind) {
                await sendResponse(.response(id: msg.id, result: .dict([
                    "approved": true,
                    "environment_id": environmentKind.connectAlias,
                    "environment_label": environmentKind.permissionEnvironmentLabel,
                    "message": "\(kind.approvalLabel) is already granted for this session",
                ])))
                return
            }

            let requestEnvironment = request.environment.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestDescription = if requestEnvironment.isEmpty {
                trimmedDescription
            } else {
                "\(trimmedDescription)\nRequested environment: \(EnvironmentKind.userVisibleName(forAlias: requestEnvironment))"
            }
            let approved = await requestPermission(
                method: request.environment,
                kind: kind,
                description: requestDescription,
                sessionId: msg.sessionId
            )
            await sendResponse(.response(id: msg.id, result: .dict([
                "approved": approved,
                "environment_id": environmentKind.connectAlias,
                "environment_label": environmentKind.permissionEnvironmentLabel,
                "message": approved
                    ? "\(kind.approvalLabel) granted for this session"
                    : "\(kind.approvalLabel) denied for this session",
            ])))
        }
    }

    func canResolveConfirmation(id: String) -> Bool {
        pendingConfirmations[id] != nil
    }

    func resolveConfirmation(id: String, approved: Bool, mode: String? = nil) {
        guard let pending = pendingConfirmations.removeValue(forKey: id) else { return }
        if let grantKey = pending.grantKey,
           pendingPermissionConfirmationIDsByGrantKey[grantKey] == id
        {
            pendingPermissionConfirmationIDsByGrantKey.removeValue(forKey: grantKey)
        }

        let finalApproved = approved
        let reason: String? = nil

        if finalApproved, let grantKey = pending.grantKey {
            grantedPermissionKeys.insert(grantKey)
        }
        injectPermissionReply(
            confirmationId: id,
            sessionId: pending.sessionId,
            approved: finalApproved,
            reason: reason,
            mode: mode
        )
        resumePendingConfirmation(pending, approved: finalApproved, mode: mode)
    }

    func normalizedSessionKey(_ sessionId: String?) -> String? {
        let trimmed = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func cancelPendingPermissionRequests(for sessionKey: String) {
        let grantKeys = pendingPermissionConfirmationIDsByGrantKey.keys.filter { $0.sessionKey == sessionKey }
        for grantKey in grantKeys {
            guard let confirmationID = pendingPermissionConfirmationIDsByGrantKey.removeValue(forKey: grantKey),
                  let pending = pendingConfirmations.removeValue(forKey: confirmationID)
            else {
                continue
            }
            injectPermissionReply(
                confirmationId: confirmationID,
                sessionId: pending.sessionId,
                approved: false,
                reason: PermissionReplyReason.expired
            )
            resumePendingConfirmation(pending, approved: false)
        }
    }

    func hasGrantedPermission(sessionId: String?, kind: PermissionKind = .hostAccess) -> Bool {
        guard environmentKind == .localMacOS else { return true }
        if kind == .hostAccess,
           SettingsManager.shared.localEnvironmentPermissionMode == .fullAccess
        {
            return true
        }
        guard let sessionKey = normalizedSessionKey(sessionId) else { return false }
        return grantedPermissionKeys.contains(PermissionGrantKey(sessionKey: sessionKey, kind: kind))
    }

    func clearAllGrantedPermissions() {
        grantedPermissionKeys.removeAll()
        pendingPermissionConfirmationIDsByGrantKey.removeAll()
        let pendingEntries = pendingConfirmations
        pendingConfirmations.removeAll()
        for (confirmationID, pending) in pendingEntries {
            injectPermissionReply(
                confirmationId: confirmationID,
                sessionId: pending.sessionId,
                approved: false,
                reason: PermissionReplyReason.expired
            )
            resumePendingConfirmation(pending, approved: false)
        }
    }

    func injectPermissionReply(
        confirmationId: String,
        sessionId: String?,
        approved: Bool,
        reason: String?,
        mode: String? = nil
    ) {
        guard let sessionId else { return }
        let replyMessage = SessionHistoryMessage(
            id: "reply-\(confirmationId)",
            type: "permission_reply",
            role: "assistant",
            timestamp: Date().timeIntervalSince1970,
            content: nil,
            messageId: nil,
            taskId: nil,
            action: nil,
            taskTitle: nil,
            todos: nil,
            sandboxId: nil,
            acceptedSummary: nil,
            reviewDiff: nil,
            reviewDiffTotal: nil,
            confirmationId: confirmationId,
            traceparent: nil,
            tracestate: nil,
            question: nil,
            questionReply: nil,
            saveFileRequest: nil,
            saveFileReply: nil,
            permissionRequest: nil,
            permissionReply: SessionHistoryMessage.PermissionReplyInfo(
                approved: approved,
                reason: reason,
                mode: mode
            ),
            secretInput: nil,
            secretInputReply: nil,
            schedule: nil,
            toolUseId: nil,
            errorType: nil,
            error: nil
        )
        AgentSessionManager.shared.injectMessage(replyMessage, intoSessionID: sessionId)
    }

    func resumePendingConfirmation(
        _ pending: PendingConfirmation,
        approved: Bool,
        mode: String? = nil
    ) {
        let reply = PermissionConfirmationReply(approved: approved, mode: mode)
        for continuation in pending.continuations {
            continuation.resume(returning: reply)
        }
    }
}

private actor WriteSerializer {
    func send(_ text: String, on task: URLSessionWebSocketTask) async throws {
        try await task.send(.string(text))
    }
}

private enum PingError: LocalizedError {
    case timeout

    var errorDescription: String? {
        switch self {
        case .timeout:
            "websocket ping timed out"
        }
    }
}

private enum TimeoutError: LocalizedError {
    case timeout

    var errorDescription: String? {
        switch self {
        case .timeout:
            "operation timed out"
        }
    }
}

private final class PingContinuationState: @unchecked Sendable {
    // Safety: access to `continuation` and `timeoutTask` is serialized by `lock`,
    // and `resume` clears them before resuming so callers can safely race success
    // vs timeout callbacks without actor hops.
    private let lock = NSLock()
    private nonisolated(unsafe) var continuation: CheckedContinuation<Void, Error>?
    private nonisolated(unsafe) var timeoutTask: Task<Void, Never>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    nonisolated func setTimeoutTask(_ timeoutTask: Task<Void, Never>) {
        lock.lock()
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    nonisolated func cancelTimeout() {
        lock.lock()
        let timeoutTask = timeoutTask
        self.timeoutTask = nil
        lock.unlock()
        timeoutTask?.cancel()
    }

    nonisolated func resume(_ result: Result<Void, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let timeoutTask = timeoutTask
        self.timeoutTask = nil
        lock.unlock()
        timeoutTask?.cancel()

        switch result {
        case .success:
            continuation.resume()
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: ";=&+/")
        return cs
    }()
}

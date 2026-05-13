import Foundation

private let maxReadSize = 10 * 1024 * 1024 // 10MB
let localRuntimeConnectorMaxMatches = 10000
private let localRuntimeConnectorGrepTimeout: TimeInterval = 10
private let localRuntimeConnectorMaxGrepLineLength = 16 * 1024

// MARK: - File Operation Handlers

extension LocalRuntimeConnector {
    func handleToolRead(params: JSONValue, sessionID: String? = nil) async throws -> JSONValue {
        let p = try params.decode(ReadParams.self)
        let (_, elevated) = checkReadPath(p.path)
        if requiresPathPermission(elevated: elevated),
           !hasGrantedHostAccessPermission(sessionId: sessionID)
        {
            throw ConnectorError.invalidParams(protectedEnvironmentError(action: "read \(p.path)"))
        }
        return try await handleRead(params: params, sessionID: sessionID)
    }

    func handleRead(params: JSONValue, sessionID: String? = nil) async throws -> JSONValue {
        let p = try params.decode(ReadParams.self)
        let path = resolvePath(p.path)

        switch target {
        case .localMacOS:
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let totalSize = (attrs[.size] as? Int64) ?? 0
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try makeReadResult(data: data, totalSize: totalSize, offset: p.offset ?? 0, limit: p.limit ?? 0)

        case let .embeddedVM(bridge):
            let data = try await bridge.readFile(sessionID: sessionID, at: path)
            return try makeReadResult(data: data, totalSize: Int64(data.count), offset: p.offset ?? 0, limit: p.limit ?? 0)
        }
    }

    func handleToolWrite(params: JSONValue, sessionID: String? = nil) async throws -> JSONValue {
        let p = try params.decode(WriteParams.self)
        _ = checkWritePath(p.path)
        if requiresMutationPermission(),
           !hasGrantedHostAccessPermission(sessionId: sessionID)
        {
            throw ConnectorError.invalidParams(protectedEnvironmentError(action: "write \(p.path)"))
        }
        return try await handleWrite(params: params, sessionID: sessionID)
    }

    func handleWrite(params: JSONValue, sessionID: String? = nil) async throws -> JSONValue {
        let p = try params.decode(WriteParams.self)
        let path = resolvePath(p.path)
        let content = try decodeWriteContent(p)

        guard content.count <= maxReadSize else {
            throw ConnectorError.fileTooLarge(p.path, Int64(content.count))
        }

        switch target {
        case .localMacOS:
            let parentDir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            let mode = p.mode ?? 0o644
            FileManager.default.createFile(atPath: path, contents: content, attributes: [.posixPermissions: mode])

        case let .embeddedVM(bridge):
            try await bridge.writeFile(sessionID: sessionID, at: path, data: content)
        }

        return .dict(["size": content.count])
    }

    func handleToolExec(params: JSONValue, sessionID: String? = nil, callerAgentID: String? = nil) async throws -> JSONValue {
        let p = try params.decode(ExecParams.self)
        if requiresExecPermission(sessionId: sessionID) {
            throw ConnectorError.invalidParams(protectedEnvironmentError(action: "execute command"))
        }

        let workingDir = (p.workingDir.flatMap { $0.isEmpty ? nil : $0 }).map(resolvePath) ?? NSHomeDirectory()
        let timeout = TimeInterval(p.timeout ?? 10)
        let env = p.env ?? [:]

        switch target {
        case .localMacOS:
            let result = try await runToolExecProcess(command: p.command, workingDir: workingDir, timeout: timeout, env: env)
            return .dict([
                "exit_code": result.exitCode,
                "stdout": result.stdout,
                "stderr": result.stderr,
            ])
        case let .embeddedVM(bridge):
            let result = try await bridge.executeShellCommand(
                p.command,
                workingDir: sandboxWorkingDirectory(workingDir),
                timeoutSeconds: Int(timeout),
                env: env,
                sessionID: sessionID,
                callerAgentID: callerAgentID
            )
            return .dict([
                "exit_code": result.exitCode,
                "stdout": result.stdout,
                "stderr": result.stderr,
            ])
        }
    }

    func handleDelete(params: JSONValue, sessionID: String? = nil) async throws -> JSONValue {
        let p = try params.decode(DeleteParams.self)
        let path = resolvePath(p.path)

        switch target {
        case .localMacOS:
            try FileManager.default.removeItem(atPath: path)
        case let .embeddedVM(bridge):
            try await bridge.deleteFile(sessionID: sessionID, at: path, recursive: p.recursive == true)
        }

        return .dict(["deleted": true])
    }

    func handleStat(params: JSONValue, sessionID: String? = nil) async throws -> JSONValue {
        let p = try params.decode(StatParams.self)
        let path = resolvePath(p.path)

        switch target {
        case .localMacOS:
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let fileType = attrs[.type] as? FileAttributeType
            let kind =
                if fileType == .typeDirectory {
                    "dir"
                } else if fileType == .typeSymbolicLink {
                    "symlink"
                } else {
                    "file"
                }
            let size = (attrs[.size] as? Int64) ?? 0
            let mode = (attrs[.posixPermissions] as? Int) ?? 0
            let modifiedAt = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return .dict([
                "path": p.path,
                "kind": kind,
                "size": size,
                "mode": mode,
                "modified_at": Int(modifiedAt),
            ])

        case let .embeddedVM(bridge):
            let stat = try await bridge.stat(sessionID: sessionID, path: path)
            return .dict([
                "path": p.path,
                "kind": stat.kind,
                "size": stat.size,
                "mode": stat.mode,
                "modified_at": stat.modifiedAt,
            ])
        }
    }

    func handleList(params: JSONValue, sessionID: String? = nil) async throws -> JSONValue {
        let p = try params.decode(ListParams.self)
        let path = resolvePath(p.path)

        switch target {
        case .localMacOS:
            let url = URL(fileURLWithPath: path)
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            )

            var entries: [JSONValue] = []
            for item in contents {
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                let kind =
                    if values.isSymbolicLink == true {
                        "symlink"
                    } else if values.isDirectory == true {
                        "dir"
                    } else {
                        "file"
                    }
                entries.append(.dict([
                    "name": item.lastPathComponent,
                    "kind": kind,
                    "size": values.fileSize ?? 0,
                    "modified_at": Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0),
                ]))
            }
            return .dict(["entries": entries])

        case let .embeddedVM(bridge):
            let entries = try await bridge.list(sessionID: sessionID, path: path)
            return .dict([
                "entries": entries.map { entry in
                    JSONValue.dict([
                        "name": entry.name,
                        "kind": entry.kind,
                        "size": entry.size,
                        "modified_at": entry.modifiedAt,
                    ])
                },
            ])
        }
    }

    func handleGlob(params: JSONValue, sessionID: String? = nil) async throws -> JSONValue {
        let p = try params.decode(GlobParams.self)
        let basePath = p.path.map(resolvePath) ?? NSHomeDirectory()

        switch target {
        case .localMacOS:
            let maxMatches = localRuntimeConnectorMaxMatches
            return try await runLocalToolOperation {
                localGlob(pattern: p.pattern, basePath: basePath, limit: maxMatches)
            }

        case let .embeddedVM(bridge):
            let result = try await bridge.glob(sessionID: sessionID, pattern: p.pattern, basePath: basePath, limit: localRuntimeConnectorMaxMatches)
            return .dict(["matches": result.matches, "truncated": result.truncated])
        }
    }

    func handleGrep(params: JSONValue, sessionID: String? = nil) async throws -> JSONValue {
        let p = try params.decode(GrepParams.self)
        let basePath = p.path.map(resolvePath) ?? NSHomeDirectory()

        switch target {
        case .localMacOS:
            let maxMatches = localRuntimeConnectorMaxMatches
            let maxFileSize = maxReadSize
            let maxLineLength = localRuntimeConnectorMaxGrepLineLength
            let grepTimeout = localRuntimeConnectorGrepTimeout
            return try await runLocalToolOperation {
                try localGrep(
                    pattern: p.pattern,
                    basePath: basePath,
                    globPattern: p.glob,
                    limit: maxMatches,
                    timeout: grepTimeout,
                    maxFileSize: maxFileSize,
                    maxLineLength: maxLineLength
                )
            }

        case let .embeddedVM(bridge):
            let result = try await bridge.grep(sessionID: sessionID, pattern: p.pattern, basePath: basePath, globPattern: p.glob, limit: localRuntimeConnectorMaxMatches)
            return .dict([
                "matches": result.matches.map { match in
                    JSONValue.dict([
                        "file": match.file,
                        "line": match.line,
                        "content": match.content,
                    ])
                },
                "truncated": result.truncated,
            ])
        }
    }

    private func makeReadResult(data: Data, totalSize: Int64, offset: Int, limit: Int) throws -> JSONValue {
        var content = data
        var truncated = false
        if content.count > maxReadSize {
            content = content.prefix(maxReadSize)
            truncated = true
        }

        let isBinary = detectBinary(content)
        if isBinary {
            return .dict([
                "content": content.base64EncodedString(),
                "encoding": "base64",
                "size": totalSize,
                "truncated": truncated,
            ])
        }

        let contentBytes = [UInt8](content)
        // swiftlint:disable:next optional_data_string_conversion
        var text = String(bytes: contentBytes, encoding: .utf8) ?? String(decoding: contentBytes, as: UTF8.self)
        if offset > 0 || limit > 0 {
            var lines = text.components(separatedBy: "\n")
            let start = max(0, offset > 0 ? offset - 1 : 0)
            if start < lines.count {
                lines = Array(lines[start...])
            } else {
                lines = []
            }
            if limit > 0, limit < lines.count {
                lines = Array(lines[..<limit])
            }
            text = lines.joined(separator: "\n")
        }

        return .dict([
            "content": text,
            "encoding": "utf8",
            "size": totalSize,
            "truncated": truncated,
        ])
    }

    private func decodeWriteContent(_ params: WriteParams) throws -> Data {
        if params.encoding == "base64" {
            guard let decoded = Data(base64Encoded: params.content) else {
                throw ConnectorError.invalidParams("base64 decode failed")
            }
            return decoded
        }
        return Data(params.content.utf8)
    }
}

// MARK: - Exec

extension LocalRuntimeConnector {
    private static let maxOutputBytes = 65536

    private struct ToolExecResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private final class ToolExecTimeoutState: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func markTimedOut() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var timedOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func sandboxWorkingDirectory(_ path: String) -> String {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return normalized == "/" ? NSHomeDirectory() : normalized
    }

    private func runToolExecProcess(
        command: String,
        workingDir: String,
        timeout: TimeInterval,
        env: [String: String]
    ) async throws -> ToolExecResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDir)
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, override in override }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let devNull = FileHandle(forReadingAtPath: "/dev/null") {
            process.standardInput = devNull
        }

        try process.run()
        let timeoutState = ToolExecTimeoutState()
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(max(1, Int(timeout))))
            guard !Task.isCancelled, process.isRunning else { return }
            timeoutState.markTimedOut()
            process.terminate()
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
        timeoutTask.cancel()

        let stdout = readLimitedOutput(stdoutPipe.fileHandleForReading)
        let stderr = readLimitedOutput(stderrPipe.fileHandleForReading)
        if timeoutState.timedOut {
            throw ConnectorError.invalidParams("command timed out after \(Int(timeout))s")
        }
        return ToolExecResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    private func readLimitedOutput(_ handle: FileHandle) -> String {
        let data = handle.readDataToEndOfFile()
        let limited = data.count > Self.maxOutputBytes ? data.prefix(Self.maxOutputBytes) : data[...]
        return String(data: Data(limited), encoding: .utf8) ?? ""
    }
}

// MARK: - Helpers

private nonisolated func runLocalToolOperation<T: Sendable>(
    _ operation: @escaping @Sendable () throws -> T
) async throws -> T {
    try await Task.detached(priority: .userInitiated) {
        try operation()
    }.value
}

private nonisolated func localGlob(pattern: String, basePath: String, limit: Int) -> JSONValue {
    var matches: [String] = []
    var truncated = false
    let baseURL = URL(fileURLWithPath: basePath)
    let enumerator = FileManager.default.enumerator(
        at: baseURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )

    while let fileURL = enumerator?.nextObject() as? URL {
        let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
        if resourceValues?.isDirectory == true { continue }

        let rel = fileURL.path.replacingOccurrences(of: basePath + "/", with: "")
        if fnmatchGlob(pattern: pattern, path: rel) {
            matches.append(rel)
            if matches.count >= limit {
                truncated = true
                break
            }
        }
    }
    return .dict(["matches": matches, "truncated": truncated])
}

// swiftlint:disable:next cyclomatic_complexity
private nonisolated func localGrep(
    pattern: String,
    basePath: String,
    globPattern: String?,
    limit: Int,
    timeout: TimeInterval,
    maxFileSize: Int,
    maxLineLength: Int
) throws -> JSONValue {
    let regex = try NSRegularExpression(pattern: pattern)
    let deadline = Date().addingTimeInterval(timeout)
    var matches: [JSONValue] = []
    var truncated = false
    var timedOut = false
    let baseURL = URL(fileURLWithPath: basePath)
    let enumerator = FileManager.default.enumerator(
        at: baseURL,
        includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
    )

    while let fileURL = enumerator?.nextObject() as? URL {
        if matches.count >= limit {
            truncated = true
            break
        }
        if Date() >= deadline {
            timedOut = true
            truncated = true
            break
        }

        let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if resourceValues?.isDirectory == true { continue }
        if let size = resourceValues?.fileSize, size > maxFileSize { continue }

        let rel = fileURL.path.replacingOccurrences(of: basePath + "/", with: "")
        if let globPattern, !fnmatchGlob(pattern: globPattern, path: rel) {
            continue
        }
        guard let data = try? Data(contentsOf: fileURL) else { continue }
        if detectBinary(data) { continue }
        guard let text = String(bytes: data, encoding: .utf8) else { continue }

        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if Date() >= deadline {
                timedOut = true
                truncated = true
                break
            }
            guard line.count <= maxLineLength else { continue }
            let lineText = String(line)
            let range = NSRange(lineText.startIndex..., in: lineText)
            if regex.firstMatch(in: lineText, range: range) != nil {
                matches.append(.dict([
                    "file": rel,
                    "line": index + 1,
                    "content": lineText,
                ]))
                if matches.count >= limit {
                    truncated = true
                    break
                }
            }
        }
        if timedOut || truncated { break }
    }

    return .dict([
        "matches": matches,
        "truncated": truncated,
        "timed_out": timedOut,
    ])
}

private nonisolated func fnmatchGlob(pattern: String, path: String) -> Bool {
    let flags: Int32 = 0
    return fnmatch(pattern, path, flags) == 0
}

nonisolated func detectBinary(_ data: Data) -> Bool {
    let checkRange = data.prefix(512)
    return checkRange.contains(0)
}

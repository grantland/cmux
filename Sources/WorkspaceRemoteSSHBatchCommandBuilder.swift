import Foundation

enum WorkspaceRemoteSSHBatchCommandBuilder {
    private static let batchSSHControlOptionKeys: Set<String> = [
        "controlmaster",
        "controlpersist",
    ]

    static func daemonTransportArguments(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String
    ) -> [String] {
        var serveArguments = ["serve", "--stdio"]
        if let slot = configuration.persistentDaemonSlot?.trimmingCharacters(in: .whitespacesAndNewlines),
           !slot.isEmpty {
            serveArguments += ["--persistent", "--slot", slot]
        }
        let daemonCommand = ([remotePath] + serveArguments)
            .map(shellSingleQuoted)
            .joined(separator: " ")
        let script = "exec \(daemonCommand)"
        let command = "sh -c \(shellSingleQuoted(script))"
        return ["-T"]
            + batchArguments(configuration: configuration)
            + ["-o", "RequestTTY=no", configuration.destination, command]
    }

    static func daemonSocketForwardArguments(
        configuration: WorkspaceRemoteConfiguration,
        localPort: Int,
        remoteSocketPath: String
    ) -> [String] {
        ["-N", "-T", "-S", "none"]
            + batchArguments(configuration: configuration)
            + [
                "-o", "ExitOnForwardFailure=yes",
                "-o", "RequestTTY=no",
                "-L", "127.0.0.1:\(localPort):\(remoteSocketPath)",
                configuration.destination,
            ]
    }

    static func reverseRelayControlMasterArguments(
        configuration: WorkspaceRemoteConfiguration,
        controlCommand: String,
        forwardSpec: String
    ) -> [String]? {
        guard let controlPath = sshOptionValue(named: "ControlPath", in: configuration.sshOptions)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !controlPath.isEmpty,
              controlPath.lowercased() != "none" else {
            return nil
        }

        var args = batchArguments(configuration: configuration)
        args += ["-O", controlCommand, "-R", forwardSpec, configuration.destination]
        return args
    }

    static func reverseRelayControlMasterCancelArguments(
        configuration: WorkspaceRemoteConfiguration,
        relayPort: Int
    ) -> [String]? {
        guard relayPort > 0 else { return nil }
        return reverseRelayControlMasterArguments(
            configuration: configuration,
            controlCommand: "cancel",
            forwardSpec: "127.0.0.1:\(relayPort)"
        )
    }

    private static func batchArguments(configuration: WorkspaceRemoteConfiguration) -> [String] {
        let effectiveSSHOptions = backgroundSSHOptions(configuration.sshOptions)
        var args: [String] = [
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
        ]
        if !hasSSHOptionKey(effectiveSSHOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        args += ["-o", "BatchMode=yes"]
        // Batch helpers may reuse an existing ControlPath, but must not negotiate a new master.
        args += ["-o", "ControlMaster=no"]
        if let port = configuration.port {
            args += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            args += ["-o", option]
        }
        return args
    }

    private static func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        for option in options {
            if sshOptionKey(option) == loweredKey {
                return true
            }
        }
        return false
    }

    private static func normalizedSSHOptions(_ options: [String]) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }
    }

    private static func backgroundSSHOptions(_ options: [String]) -> [String] {
        normalizedSSHOptions(options).filter { option in
            guard let key = sshOptionKey(option) else { return false }
            return !batchSSHControlOptionKeys.contains(key)
        }
    }

    private static func sshOptionValue(named key: String, in options: [String]) -> String? {
        let loweredKey = key.lowercased()
        for option in normalizedSSHOptions(options) {
            let parts = option.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == "=" || $0.isWhitespace }
            )
            guard parts.count == 2, parts[0].lowercased() == loweredKey else {
                continue
            }
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func sshOptionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

/// Builds the spawn invocation for the generic `exec` transport (e.g.
/// `docker exec -i <container>`, `kubectl exec -i <pod> --`). The user-supplied `execCommand`
/// argv is the wrapper; the remote daemon command (`<remotePath> serve --stdio [...]`) is
/// appended so the wrapper runs it on the remote and bridges its stdio.
nonisolated enum WorkspaceRemoteExecCommandBuilder {
    /// Returns the executable to spawn and its arguments, or `nil` when `execCommand` is empty.
    static func daemonTransportInvocation(
        execCommand: [String],
        remotePath: String,
        persistentDaemonSlot: String? = nil
    ) -> (executable: String, arguments: [String])? {
        guard let executable = execCommand.first else { return nil }
        var remoteArgv = [remotePath, "serve", "--stdio"]
        if let slot = persistentDaemonSlot?.trimmingCharacters(in: .whitespacesAndNewlines),
           !slot.isEmpty {
            remoteArgv += ["--persistent", "--slot", slot]
        }
        let arguments = Array(execCommand.dropFirst()) + remoteArgv
        return (executable: executable, arguments: arguments)
    }
}

/// Substitutes `%host` / `%port` / `%user` placeholders in a configured exec transport's argv
/// and environment values. `%port` / `%user` are left literal when the corresponding value is
/// absent (the caller validates required placeholders); unknown placeholders are left untouched.
nonisolated enum WorkspaceRemoteExecPlaceholders {
    static func substitute(_ values: [String], host: String, port: Int?, user: String?) -> [String] {
        values.map { substituteOne($0, host: host, port: port, user: user) }
    }

    static func substitute(_ env: [String: String], host: String, port: Int?, user: String?) -> [String: String] {
        env.mapValues { substituteOne($0, host: host, port: port, user: user) }
    }

    private static func substituteOne(_ value: String, host: String, port: Int?, user: String?) -> String {
        var out = value.replacingOccurrences(of: "%host", with: host)
        if let port { out = out.replacingOccurrences(of: "%port", with: String(port)) }
        if let user { out = out.replacingOccurrences(of: "%user", with: user) }
        return out
    }
}

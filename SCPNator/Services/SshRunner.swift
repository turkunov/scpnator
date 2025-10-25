import Foundation

struct CommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

final class SshRunner {
    static let shared = SshRunner()
    private init() {}

    func shellEscapeSingleQuotes(_ input: String) -> String {
        return input.replacingOccurrences(of: "'", with: "'\\''")
    }

    // Copy a private key into a stable app folder and return the file URL.
    // Using a stable path allows macOS Keychain (UseKeychain=yes) to remember
    // the passphrase for this exact path, matching Terminal behavior.
    private func ensureStableIdentityCopy(originalPath: String) throws -> URL {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let keysDir = appSupport.appendingPathComponent("SCPNator/Keys", isDirectory: true)
        if !fileManager.fileExists(atPath: keysDir.path) {
            try fileManager.createDirectory(at: keysDir, withIntermediateDirectories: true)
        }
        let originalName = URL(fileURLWithPath: originalPath).lastPathComponent
        let stableURL = keysDir.appendingPathComponent(originalName, isDirectory: false)

        // Copy or update if source is newer/different size
        let needsCopy: Bool = {
            guard let srcAttrs = try? fileManager.attributesOfItem(atPath: originalPath) else { return true }
            guard let dstAttrs = try? fileManager.attributesOfItem(atPath: stableURL.path) else { return true }
            let srcSize = (srcAttrs[.size] as? NSNumber)?.uint64Value ?? 0
            let dstSize = (dstAttrs[.size] as? NSNumber)?.uint64Value ?? UInt64.max
            let srcMod = (srcAttrs[.modificationDate] as? Date) ?? .distantPast
            let dstMod = (dstAttrs[.modificationDate] as? Date) ?? .distantPast
            return srcSize != dstSize || srcMod > dstMod
        }()
        if needsCopy {
            let data = try Data(contentsOf: URL(fileURLWithPath: originalPath))
            try data.write(to: stableURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stableURL.path)
        }
        return stableURL
    }

    // Discover SSH_AUTH_SOCK for GUI-launched apps (no inherited env)
    private func discoverSSHAuthSock() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["getenv", "SSH_AUTH_SOCK"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty, FileManager.default.fileExists(atPath: value) {
                return value
            }
        } catch {
            return nil
        }
        return nil
    }

    // Resolve an identity file path to use with ssh/scp.
    // - Prefers the security-scoped bookmark if present
    // - If a .pub file is selected, use the corresponding private key
    // - Falls back to ~/.ssh/id_ed25519 then ~/.ssh/id_rsa when none selected
    private func resolveIdentityPath() -> (path: String?, scopedURL: URL?) {
        let settings = SettingsStore.shared
        if let bookmarked = settings.identityFileURL() {
            var path = bookmarked.path
            if path.hasSuffix(".pub") { path.removeLast(4) }
            _ = bookmarked.startAccessingSecurityScopedResource()
            return (path, bookmarked)
        }
        var path = settings.identityKeyPath
        if path.hasSuffix(".pub") { path.removeLast(4) }
        if path.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let candidates = ["id_rsa", "id_ed25519"].map { home.appendingPathComponent(".ssh/\($0)").path }
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
                path = candidate
                break
            }
        }
        return (path.isEmpty ? nil : path, nil)
    }

    @discardableResult
    func runSshCommand(server: String, username: String, passphrase: String, remoteCommand: String, timeoutSeconds: TimeInterval = 120) async throws -> CommandResult {
        // Wrap remote command to ensure POSIX sh
        let wrapped = "sh -lc '" + remoteCommand + "'"

        // Always prefer explicit identity file; fall back to agent only if none configured
        var env = ProcessInfo.processInfo.environment
        if env["SSH_AUTH_SOCK"] == nil, let sock = discoverSSHAuthSock() { env["SSH_AUTH_SOCK"] = sock }

        var tempIdentityURL: URL? = nil
        var scopedURL: URL? = nil
        var identityPathForChild: String? = nil
        let resolved = resolveIdentityPath()
        scopedURL = resolved.scopedURL
        if let identityPath = resolved.path {
            do {
                let tmp = try ensureStableIdentityCopy(originalPath: identityPath)
                tempIdentityURL = tmp
                identityPathForChild = tmp.path
            } catch {
                identityPathForChild = identityPath
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args: [String] = [
            "ssh",
            "-vvv",
            "-F", "/dev/null",
            "-o", "BatchMode=yes", // non-interactive
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "PreferredAuthentications=publickey",
            "-o", "UseKeychain=yes",
            "-o", "LogLevel=DEBUG3",
        ]
        if identityPathForChild != nil { args.append(contentsOf: ["-o", "IdentitiesOnly=no"]) }
        if let identityPathForChild {
            // Always include RSA compatibility flags to match terminal behavior
            args.append(contentsOf: ["-o", "PubkeyAcceptedAlgorithms=+ssh-rsa", "-o", "HostkeyAlgorithms=+ssh-rsa"])
            args.append(contentsOf: ["-i", identityPathForChild])
        }
        args.append("\(username)@\(server)")
        args.append(wrapped)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = env

        try process.run()

        let stdoutData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()

        process.waitUntilExit()
        // Cleanup
        if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }
        return CommandResult(exitCode: process.terminationStatus,
                             stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                             stderr: String(data: stderrData, encoding: .utf8) ?? "")
    }

    @discardableResult
    func scpFromRemote(server: String,
                       username: String,
                       passphrase: String,
                       remotePath: String,
                       isDirectory: Bool,
                       destinationDir: URL,
                       onOutput: ((String) -> Void)? = nil) async throws -> CommandResult {
        // Always prefer explicit identity file; fall back to agent only if none configured
        var env = ProcessInfo.processInfo.environment
        if env["SSH_AUTH_SOCK"] == nil, let sock = discoverSSHAuthSock() { env["SSH_AUTH_SOCK"] = sock }

        var tempIdentityURL: URL? = nil
        var scopedURL: URL? = nil
        var identityPathForChild: String? = nil
        let resolved = resolveIdentityPath()
        scopedURL = resolved.scopedURL
        if let identityPath = resolved.path {
            do {
                let tmp = try ensureStableIdentityCopy(originalPath: identityPath)
                tempIdentityURL = tmp
                identityPathForChild = tmp.path
            } catch {
                identityPathForChild = identityPath
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = ["scp",
                    "-vvv",
                    "-F", "/dev/null",
                    "-o", "BatchMode=yes",
                    "-o", "StrictHostKeyChecking=no",
                    "-o", "UserKnownHostsFile=/dev/null",
                    "-o", "GlobalKnownHostsFile=/dev/null",
                    "-o", "PreferredAuthentications=publickey",
                    "-o", "UseKeychain=yes",
                    "-o", "LogLevel=DEBUG3",
                    "-p"]
        if identityPathForChild != nil { args.append(contentsOf: ["-o", "IdentitiesOnly=no"]) }
        if let identityPathForChild {
            // Always include RSA compatibility flags to match terminal behavior
            args.append(contentsOf: ["-o", "PubkeyAcceptedAlgorithms=+ssh-rsa", "-o", "HostkeyAlgorithms=+ssh-rsa"])
            args.append(contentsOf: ["-i", identityPathForChild])
        }
        if isDirectory { args.append("-r") }
        args.append("\(username)@\(server):\(remotePath)")
        args.append(destinationDir.path)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = env

        // Stream output for progress
        let outHandle = stderrPipe.fileHandleForReading
        outHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.count > 0, let text = String(data: data, encoding: .utf8) {
                onOutput?(text)
            }
        }

        try process.run()

        let stdoutData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        outHandle.readabilityHandler = nil
        if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }

        let result = CommandResult(exitCode: process.terminationStatus,
                                   stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                                   stderr: String(data: stderrData, encoding: .utf8) ?? "")
        if result.exitCode != 0 {
            throw NSError(domain: "SCP", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: result.stderr.isEmpty ? "scp failed" : result.stderr])
        }
        return result
    }

    @discardableResult
    func scpToRemote(server: String,
                     username: String,
                     passphrase: String,
                     localPath: String,
                     isDirectory: Bool,
                     destinationRemoteDir: String,
                     onOutput: ((String) -> Void)? = nil) async throws -> CommandResult {
        var env = ProcessInfo.processInfo.environment
        if env["SSH_AUTH_SOCK"] == nil, let sock = discoverSSHAuthSock() { env["SSH_AUTH_SOCK"] = sock }

        var tempIdentityURL: URL? = nil
        var scopedURL: URL? = nil
        var identityPathForChild: String? = nil
        let resolved = resolveIdentityPath()
        scopedURL = resolved.scopedURL
        if let identityPath = resolved.path {
            do {
                let tmp = try ensureStableIdentityCopy(originalPath: identityPath)
                tempIdentityURL = tmp
                identityPathForChild = tmp.path
            } catch {
                identityPathForChild = identityPath
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = ["scp",
                    "-vvv",
                    "-F", "/dev/null",
                    "-o", "BatchMode=yes",
                    "-o", "StrictHostKeyChecking=no",
                    "-o", "UserKnownHostsFile=/dev/null",
                    "-o", "GlobalKnownHostsFile=/dev/null",
                    "-o", "PreferredAuthentications=publickey",
                    "-o", "UseKeychain=yes",
                    "-o", "LogLevel=DEBUG3",
                    "-p"]
        if identityPathForChild != nil { args.append(contentsOf: ["-o", "IdentitiesOnly=no"]) }
        if let identityPathForChild {
            args.append(contentsOf: ["-o", "PubkeyAcceptedAlgorithms=+ssh-rsa", "-o", "HostkeyAlgorithms=+ssh-rsa"])
            args.append(contentsOf: ["-i", identityPathForChild])
        }
        if isDirectory { args.append("-r") }
        args.append(localPath)
        var remoteDir = destinationRemoteDir
        if !remoteDir.hasSuffix("/") { remoteDir += "/" }
        // Do NOT wrap in quotes here; scp will perform its own escaping when constructing the remote command.
        let remoteTarget = "\(username)@\(server):\(remoteDir)"
        args.append(remoteTarget)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = env

        let outHandle = stderrPipe.fileHandleForReading
        outHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.count > 0, let text = String(data: data, encoding: .utf8) {
                onOutput?(text)
            }
        }

        try process.run()

        let stdoutData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        outHandle.readabilityHandler = nil
        if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }

        let result = CommandResult(exitCode: process.terminationStatus,
                                   stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                                   stderr: String(data: stderrData, encoding: .utf8) ?? "")
        if result.exitCode != 0 {
            throw NSError(domain: "SCP", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: result.stderr.isEmpty ? "scp failed" : result.stderr])
        }
        return result
    }

    // Check whether a path exists on the remote host (file or directory)
    func remotePathExists(server: String,
                          username: String,
                          passphrase: String,
                          path: String) async -> Bool {
        let escaped = shellEscapeSingleQuotes(path)
        let cmd = "if [ -e '" + escaped + "' ]; then echo exists; else echo missing; fi"
        guard let result = try? await runSshCommand(server: server, username: username, passphrase: passphrase, remoteCommand: cmd) else { return false }
        return result.stdout.contains("exists")
    }
}



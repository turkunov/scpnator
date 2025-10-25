import Foundation

final class RemoteBrowserService {
    static let shared = RemoteBrowserService()
    private init() {}

    func listDirectory(server: String, username: String, passphrase: String, path: String) async throws -> [RemoteItem] {
        // Expand leading ~ safely by cd'ing into home, then listing suffix
        let cmd: String
        if path == "~" || path.hasPrefix("~/") {
            var suffix = String(path.dropFirst()) // remove leading ~
            if suffix.hasPrefix("/") { suffix.removeFirst() }
            let target = suffix.isEmpty ? "." : suffix
            let escaped = SshRunner.shared.shellEscapeSingleQuotes(target)
            cmd = "cd ~ && ls -laF --group-directories-first '" + escaped + "' 2>/dev/null"
        } else {
            let escaped = SshRunner.shared.shellEscapeSingleQuotes(path)
            cmd = "ls -laF --group-directories-first '" + escaped + "' 2>/dev/null"
        }
        let result = try await SshRunner.shared.runSshCommand(server: server, username: username, passphrase: passphrase, remoteCommand: cmd)
        if result.exitCode != 0 { throw NSError(domain: "RemoteBrowser", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: result.stderr]) }
        let lines = result.stdout.split(separator: "\n")
        let items: [RemoteItem] = lines.compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("total ") else { return nil }
            // Format: drwxr-xr-x ... name[/]  (with -F adds / for directories, @ for symlink etc)
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 9 else { return nil }
            let perm = columns[0]
            let nameWithFlag = columns.dropFirst(8).joined(separator: " ")
            let name: String
            let kind: RemoteItemKind
            if nameWithFlag.hasSuffix("/") {
                name = String(nameWithFlag.dropLast())
                kind = .directory
            } else if nameWithFlag.hasSuffix("@") {
                name = String(nameWithFlag.dropLast())
                kind = perm.hasPrefix("l") ? .symlink : .file
            } else {
                name = nameWithFlag
                if perm.hasPrefix("d") { kind = .directory }
                else if perm.hasPrefix("l") { kind = .symlink }
                else { kind = .file }
            }
            return RemoteItem(name: name, kind: kind, relativePath: "")
        }
        return items.sorted { a, b in
            // Directories first, then alphabetical
            if a.kind != b.kind { return a.kind == .directory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}



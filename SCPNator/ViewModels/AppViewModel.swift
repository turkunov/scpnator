import Foundation
import SwiftUI
import Combine

@MainActor
final class AppViewModel: ObservableObject {
    @Published var currentPath: String
    @Published var items: [RemoteItem] = []
    @Published var selection = Set<String>()
    // Local (Downloads) side
    @Published var localCurrentURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    private(set) var localRootURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    @Published var localItems: [LocalItem] = []
    @Published var localSelection = Set<String>()
    @Published var isLoading = false
    @Published var isTransferring = false
    @Published var transferStatuses: [TransferItemStatus] = []

    let settings = SettingsStore.shared

    init() {
        self.currentPath = SettingsStore.shared.baseDirectory
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let listed = try await RemoteBrowserService.shared.listDirectory(server: settings.serverAddress, username: settings.username, passphrase: settings.passphrase, path: currentPath)
            items = listed
        } catch {
            items = []
            print("Refresh failed: \(error.localizedDescription)")
        }
        refreshLocalOnly()
    }

    func navigateInto(_ item: RemoteItem) async {
        guard item.kind == .directory else { return }
        if currentPath.hasSuffix("/") {
            currentPath += item.name
        } else {
            currentPath += "/" + item.name
        }
        selection.removeAll()
        await refresh()
    }

    func goUp() async {
        var path = currentPath
        if path.hasSuffix("/") { path.removeLast() }
        if let range = path.range(of: "/", options: .backwards) {
            currentPath = String(path[..<range.lowerBound])
        }
        selection.removeAll()
        await refresh()
    }

    // MARK: - Local (Downloads) management
    func initializeLocalDownloadsIfNeeded() async {
        // Use saved bookmark if available; else prompt once for Downloads
        if let bookmarked = settings.bookmarkedLocalURL() {
            _ = bookmarked.startAccessingSecurityScopedResource()
            localCurrentURL = bookmarked
            localRootURL = bookmarked
        } else {
            let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            await MainActor.run {
                let panel = NSOpenPanel()
                panel.title = "Allow SCPNator to access your Downloads"
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = "Allow"
                panel.directoryURL = downloads
                if panel.runModal() == .OK, let url = panel.url {
                    SettingsStore.shared.updateLocalAccess(url: url)
                    _ = url.startAccessingSecurityScopedResource()
                    localCurrentURL = url
                    localRootURL = url
                } else {
                    localCurrentURL = downloads
                    localRootURL = downloads
                }
            }
        }
        refreshLocalOnly()
    }

    func refreshLocalOnly() {
        do {
            localItems = try LocalBrowserService.shared.listDirectory(url: localCurrentURL)
        } catch {
            localItems = []
        }
    }

    func navigateIntoLocal(_ item: LocalItem) {
        guard item.isDirectory else { return }
        localCurrentURL.appendPathComponent(item.name)
        refreshLocalOnly()
    }

    func goUpLocal() {
        var next = localCurrentURL.standardizedFileURL
        next.deleteLastPathComponent()
        if next.path.hasPrefix(localRootURL.standardizedFileURL.path) {
            localCurrentURL = next
        } else {
            localCurrentURL = localRootURL
        }
        refreshLocalOnly()
    }

    func toggleSelection(for item: RemoteItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    func beginTransferToDownloads() async {
        guard !isTransferring else { return }
        let selectedItems = items.filter { selection.contains($0.id) }
        guard !selectedItems.isEmpty else { return }
        isTransferring = true
        defer { isTransferring = false }

        transferStatuses = selectedItems.map { TransferItemStatus(item: $0, state: .pending, message: "") }
        let destination = localCurrentURL

        for index in transferStatuses.indices {
            transferStatuses[index].state = .running
            let item = transferStatuses[index].item
            let remote = currentPath.hasSuffix("/") ? (currentPath + item.name) : (currentPath + "/" + item.name)
            do {
                _ = try await SshRunner.shared.scpFromRemote(server: settings.serverAddress,
                                                             username: settings.username,
                                                             passphrase: settings.passphrase,
                                                             remotePath: remote,
                                                             isDirectory: item.kind == .directory,
                                                             destinationDir: destination,
                                                             onOutput: { _ in })
                transferStatuses[index].state = .succeeded
            } catch {
                transferStatuses[index].state = .failed
                transferStatuses[index].message = error.localizedDescription
            }
        }
    }

    // MARK: - Drag-and-drop transfers
    func downloadRemoteItems(_ remoteItems: [RemoteItem]) async {
        guard !remoteItems.isEmpty, !isTransferring else { return }
        // Local overwrite confirmation
        let fm = FileManager.default
        let collisions = remoteItems.filter { fm.fileExists(atPath: localCurrentURL.appendingPathComponent($0.name).path) }.map { $0.name }
        if !collisions.isEmpty {
            let proceed = Self.confirmOverwrite(names: collisions, location: localCurrentURL.path)
            if !proceed { return }
        }
        isTransferring = true
        defer { isTransferring = false }
        transferStatuses = remoteItems.map { TransferItemStatus(item: $0, state: .pending, message: "") }
        for index in transferStatuses.indices {
            transferStatuses[index].state = .running
            let item = transferStatuses[index].item
            let remote = currentPath.hasSuffix("/") ? (currentPath + item.name) : (currentPath + "/" + item.name)
            do {
                _ = try await SshRunner.shared.scpFromRemote(server: settings.serverAddress,
                                                             username: settings.username,
                                                             passphrase: settings.passphrase,
                                                             remotePath: remote,
                                                             isDirectory: item.kind == .directory,
                                                             destinationDir: localCurrentURL,
                                                             onOutput: { _ in })
                transferStatuses[index].state = .succeeded
                refreshLocalOnly()
            } catch {
                transferStatuses[index].state = .failed
                transferStatuses[index].message = error.localizedDescription
            }
        }
    }

    func uploadLocalURLs(_ localURLs: [URL]) async {
        guard !localURLs.isEmpty, !isTransferring else { return }
        // Remote overwrite confirmation (probe each path)
        var collisions: [String] = []
        for url in localURLs {
            let candidate = currentPath.hasSuffix("/") ? (currentPath + url.lastPathComponent) : (currentPath + "/" + url.lastPathComponent)
            let exists = await SshRunner.shared.remotePathExists(server: settings.serverAddress, username: settings.username, passphrase: settings.passphrase, path: candidate)
            if exists { collisions.append(url.lastPathComponent) }
        }
        if !collisions.isEmpty {
            let proceed = Self.confirmOverwrite(names: collisions, location: currentPath)
            if !proceed { return }
        }
        isTransferring = true
        defer { isTransferring = false }
        let itemsToShow: [RemoteItem] = localURLs.map { url in
            let isDir = ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false
            return RemoteItem(name: url.lastPathComponent, kind: isDir ? .directory : .file, relativePath: "")
        }
        transferStatuses = itemsToShow.map { TransferItemStatus(item: $0, state: .pending, message: "") }
        for index in transferStatuses.indices {
            transferStatuses[index].state = .running
            let localURL = localURLs[index]
            let isDir = ((try? localURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false
            do {
                _ = try await SshRunner.shared.scpToRemote(server: settings.serverAddress,
                                                           username: settings.username,
                                                           passphrase: settings.passphrase,
                                                           localPath: localURL.path,
                                                           isDirectory: isDir,
                                                           destinationRemoteDir: currentPath,
                                                           onOutput: { _ in })
                transferStatuses[index].state = .succeeded
                await refresh()
            } catch {
                transferStatuses[index].state = .failed
                transferStatuses[index].message = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String ?? error.localizedDescription
            }
        }
    }

    private static func confirmOverwrite(names: [String], location: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = names.count == 1 ? "File exists" : "Files exist"
        alert.informativeText = names.joined(separator: ", ") + " already exist in \(location). Overwrite?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

struct TransferItemStatus: Identifiable {
    enum State { case pending, running, succeeded, failed }
    let id = UUID()
    let item: RemoteItem
    var state: State
    var message: String
}



import Foundation
import AppKit
import Combine

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var serverAddress: String {
        didSet { UserDefaults.standard.set(serverAddress, forKey: Self.Keys.serverAddress) }
    }
    @Published var username: String {
        didSet { UserDefaults.standard.set(username, forKey: Self.Keys.username) }
    }
    @Published var baseDirectory: String {
        didSet { UserDefaults.standard.set(baseDirectory, forKey: Self.Keys.baseDirectory) }
    }
    @Published var lastLocalPath: String {
        didSet { UserDefaults.standard.set(lastLocalPath, forKey: Self.Keys.lastLocalPath) }
    }
    @Published var lastRemotePath: String {
        didSet { UserDefaults.standard.set(lastRemotePath, forKey: Self.Keys.lastRemotePath) }
    }
    @Published var passphrase: String {
        didSet {
            let accountKey = Self.accountKey(username: username, server: serverAddress)
            try? KeychainHelper.shared.setPassword(passphrase, service: Self.serviceName, account: accountKey)
        }
    }

    @Published var identityKeyPath: String {
        didSet { UserDefaults.standard.set(identityKeyPath, forKey: Self.Keys.identityKeyPath) }
    }
    private var identityKeyBookmark: Data? {
        didSet { UserDefaults.standard.set(identityKeyBookmark, forKey: Self.Keys.identityKeyBookmark) }
    }

    private struct SelfKeys {
        static let serverAddress = "settings.serverAddress"
        static let username = "settings.username"
        static let baseDirectory = "settings.baseDirectory"
        static let identityKeyPath = "settings.identityKeyPath"
        static let identityKeyBookmark = "settings.identityKeyBookmark"
        static let lastLocalPath = "settings.lastLocalPath"
        static let lastRemotePath = "settings.lastRemotePath"
        static let localAccessBookmark = "settings.localAccessBookmark"
    }

    private enum SelfDefaults {
        static let serverAddress = ""
        static let username = ""
        static let baseDirectory = "~"
        static let lastRemotePath = "~"
    }

    private static let Keys = SelfKeys.self
    private static let Defaults = SelfDefaults.self
    private static let serviceName = "com.scpnator.app"

    private init() {
        let storedServer = UserDefaults.standard.string(forKey: Self.Keys.serverAddress) ?? Self.Defaults.serverAddress
        let storedUsername = UserDefaults.standard.string(forKey: Self.Keys.username) ?? Self.Defaults.username
        let storedBaseDir = UserDefaults.standard.string(forKey: Self.Keys.baseDirectory) ?? Self.Defaults.baseDirectory
        self.serverAddress = storedServer
        self.username = storedUsername
        self.baseDirectory = storedBaseDir
        // Initialize lastLocalPath without using self before all stored properties are set
        let storedLocal = UserDefaults.standard.string(forKey: Self.Keys.lastLocalPath)
        let homeURL = FileManager.default.homeDirectory(forUser: NSUserName()) ?? FileManager.default.homeDirectoryForCurrentUser
        let defaultDownloads = homeURL.appendingPathComponent("Downloads").path
        var initialLocalPath = (storedLocal?.isEmpty == false ? storedLocal! : defaultDownloads)
        if initialLocalPath.contains("/Containers/") { initialLocalPath = defaultDownloads }
        self.lastLocalPath = initialLocalPath
        self.lastRemotePath = UserDefaults.standard.string(forKey: Self.Keys.lastRemotePath) ?? Self.Defaults.lastRemotePath
        self.identityKeyPath = UserDefaults.standard.string(forKey: Self.Keys.identityKeyPath) ?? ""
        self.identityKeyBookmark = UserDefaults.standard.data(forKey: Self.Keys.identityKeyBookmark)
        self.localAccessBookmark = UserDefaults.standard.data(forKey: Self.Keys.localAccessBookmark)

        let accountKey = Self.accountKey(username: storedUsername, server: storedServer)
        let storedPass = (try? KeychainHelper.shared.getPassword(service: Self.serviceName, account: accountKey)) ?? ""
        self.passphrase = storedPass
    }

    func reloadPassphrase() {
        let accountKey = Self.accountKey(username: username, server: serverAddress)
        let storedPass = (try? KeychainHelper.shared.getPassword(service: Self.serviceName, account: accountKey)) ?? ""
        self.passphrase = storedPass
    }

    static func accountKey(username: String, server: String) -> String {
        return "\(username)@\(server)"
    }

    // MARK: - Identity key handling

    func updateIdentityKey(url: URL) {
        // If user selected a public key, automatically switch to the corresponding private key next to it
        var chosenURL = url
        if chosenURL.path.hasSuffix(".pub") {
            let withoutPub = chosenURL.deletingPathExtension()
            chosenURL = withoutPub
        }
        identityKeyPath = chosenURL.path
        let bookmark = try? chosenURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        identityKeyBookmark = bookmark
    }

    func identityFileURL() -> URL? {
        guard let data = identityKeyBookmark else { return nil }
        var isStale = false
        let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &isStale)
        return url
    }

    func clearIdentityKey() {
        identityKeyPath = ""
        identityKeyBookmark = nil
    }

    // MARK: - Local filesystem access (security-scoped)
    private var localAccessBookmark: Data? {
        didSet { UserDefaults.standard.set(localAccessBookmark, forKey: Self.Keys.localAccessBookmark) }
    }

    func updateLocalAccess(url: URL) {
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        localAccessBookmark = bookmark
    }

    func bookmarkedLocalURL() -> URL? {
        guard let data = localAccessBookmark else { return nil }
        var isStale = false
        let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &isStale)
        return url
    }
}



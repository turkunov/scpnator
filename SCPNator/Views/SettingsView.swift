import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @State private var server: String = SettingsStore.shared.serverAddress
    @State private var username: String = SettingsStore.shared.username
    @State private var baseDir: String = SettingsStore.shared.baseDirectory
    @State private var passphrase: String = SettingsStore.shared.passphrase
    @State private var identityKeyPath: String = SettingsStore.shared.identityKeyPath

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Server Address", text: $server)
                TextField("Username", text: $username)
                TextField("Base Directory", text: $baseDir)
                SecureField("SSH Passphrase", text: $passphrase)
                HStack {
                    TextField("Identity Key (optional)", text: $identityKeyPath)
                        .disabled(true)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.title = "Select SSH private key"
                        panel.showsHiddenFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        if #available(macOS 12.0, *) {
                            panel.allowedContentTypes = [UTType.data]
                        } else {
                            panel.allowedFileTypes = nil
                        }
                        panel.allowsOtherFileTypes = true
                        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
                        if panel.runModal() == .OK, let url = panel.url {
                            SettingsStore.shared.updateIdentityKey(url: url)
                            identityKeyPath = url.path
                        }
                    }
                    Button("Clear") {
                        SettingsStore.shared.clearIdentityKey()
                        identityKeyPath = ""
                    }
                }
            }
            HStack {
                Spacer()
                Button("Grant Home Access…") {
                    let panel = NSOpenPanel()
                    panel.title = "Allow SCPNator to access your Home/Downloads"
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
                    if panel.runModal() == .OK, let url = panel.url {
                        SettingsStore.shared.updateLocalAccess(url: url)
                    }
                }
                Button("Save") {
                    SettingsStore.shared.serverAddress = server
                    SettingsStore.shared.username = username
                    SettingsStore.shared.baseDirectory = baseDir
                    SettingsStore.shared.passphrase = passphrase
                    SettingsStore.shared.identityKeyPath = identityKeyPath
                    viewModel.currentPath = baseDir
                    Task { await viewModel.refresh() }
                }
            }
        }
        .padding()
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView().environmentObject(AppViewModel())
    }
}



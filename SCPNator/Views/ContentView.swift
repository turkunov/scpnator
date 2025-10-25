import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                fileList
                Divider()
                localPanel
                Divider()
                transferSidebar
                    .frame(width: 280)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(viewModel)
                .frame(width: 520, height: 320)
        }
        .task { await viewModel.refresh() }
    }

    private var toolbar: some View {
        HStack {
            Spacer()
            Button("Settings") { showSettings = true }
        }
        .padding(8)
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: { Task { await viewModel.refresh() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                Button(action: { Task { await viewModel.goUp() } }) {
                    Image(systemName: "chevron.up")
                }
                Text(viewModel.currentPath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if viewModel.isLoading { ProgressView() }
            }
            .padding(8)
            if viewModel.isLoading {
                ProgressView("Loading...")
                    .padding()
            }
            List(selection: Binding(get: { viewModel.selection as Set<String> }, set: { viewModel.selection = $0 })) {
                ForEach(viewModel.items) { item in
                    HStack {
                        Image(systemName: iconName(for: item))
                        Text(item.name)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { Task { await viewModel.navigateInto(item) } }
                    .tag(item.id)
                    .onDrag {
                        let selected: [RemoteItem]
                        if viewModel.selection.contains(item.id) && !viewModel.selection.isEmpty {
                            selected = viewModel.items.filter { viewModel.selection.contains($0.id) }
                        } else {
                            selected = [item]
                        }
                        let dicts: [[String: Any]] = selected.map { ["name": $0.name, "dir": ($0.kind == .directory)] }
                        let payload = try? JSONSerialization.data(withJSONObject: ["items": dicts], options: [])
                        let provider = NSItemProvider()
                        if let payload {
                            provider.registerDataRepresentation(forTypeIdentifier: UTType.json.identifier, visibility: .all) { completion in
                                completion(payload, nil)
                                return nil
                            }
                        }
                        return provider
                    }
                }
            }
            .onDrop(of: [UTType.json, UTType.fileURL, UTType.url], isTargeted: nil) { providers in
                Task {
                    var urls: [URL] = []
                    for provider in providers {
                        if provider.hasItemConformingToTypeIdentifier(UTType.json.identifier) {
                            let list: [URL]? = await withCheckedContinuation { (cont: CheckedContinuation<[URL]?, Never>) in
                                provider.loadDataRepresentation(forTypeIdentifier: UTType.json.identifier) { data, _ in
                                    if let data,
                                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                       let arr = obj["paths"] as? [String] {
                                        cont.resume(returning: arr.map { URL(fileURLWithPath: $0) })
                                    } else {
                                        cont.resume(returning: nil)
                                    }
                                }
                            }
                            if let list { urls.append(contentsOf: list) }
                        } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                            // Try to load actual file URL
                            let u: URL? = await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
                                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                                    cont.resume(returning: data as? URL)
                                }
                            }
                            if let u { urls.append(u) }
                        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                            let u: URL? = await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
                                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { data, _ in
                                    cont.resume(returning: data as? URL)
                                }
                            }
                            if let u { urls.append(u) }
                        }
                    }
                    await viewModel.uploadLocalURLs(urls)
                }
                return true
            }
        }
    }

    private var localPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: { viewModel.goUpLocal() }) {
                    Image(systemName: "chevron.up")
                }
                Text(viewModel.localCurrentURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(8)
            List(selection: Binding(get: { viewModel.localSelection as Set<String> }, set: { viewModel.localSelection = $0 })) {
                ForEach(viewModel.localItems) { item in
                    HStack {
                        Image(systemName: item.isDirectory ? "folder" : "doc")
                        Text(item.name)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { viewModel.navigateIntoLocal(item) }
                    .tag(item.id)
                    .onDrag {
                        // If multi-selected, send a JSON list of file paths for robustness
                        let selectedIds = viewModel.localSelection.isEmpty ? [item.id] : Array(viewModel.localSelection)
                        let urls = viewModel.localItems.filter { selectedIds.contains($0.id) }.map { $0.url }
                        let provider = NSItemProvider()
                        let paths = urls.map { $0.path }
                        let payload = try? JSONSerialization.data(withJSONObject: ["paths": paths], options: [])
                        if let payload {
                            provider.registerDataRepresentation(forTypeIdentifier: UTType.json.identifier, visibility: .all) { completion in
                                completion(payload, nil)
                                return nil
                            }
                        }
                        return provider
                    }
                }
            }
            .onDrop(of: [UTType.json, UTType.text], isTargeted: nil) { providers in
                Task {
                    var dropped: [RemoteItem] = []
                    for provider in providers {
                        if provider.hasItemConformingToTypeIdentifier(UTType.json.identifier) {
                            let itemsFromJson: [RemoteItem] = await withCheckedContinuation { cont in
                                provider.loadDataRepresentation(forTypeIdentifier: UTType.json.identifier) { data, _ in
                                    if let data,
                                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                       let arr = obj["items"] as? [[String: Any]] {
                                        let mapped: [RemoteItem] = arr.compactMap { d in
                                            guard let name = d["name"] as? String else { return nil }
                                            let isDir = (d["dir"] as? Bool) ?? false
                                            return RemoteItem(name: name, kind: isDir ? .directory : .file, relativePath: "")
                                        }
                                        cont.resume(returning: mapped)
                                    } else { cont.resume(returning: []) }
                                }
                            }
                            dropped.append(contentsOf: itemsFromJson)
                        } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                            let name: String = await withCheckedContinuation { cont in
                                provider.loadDataRepresentation(forTypeIdentifier: UTType.text.identifier) { data, _ in
                                    if let data, let s = String(data: data, encoding: .utf8) { cont.resume(returning: s) }
                                    else { cont.resume(returning: "") }
                                }
                            }
                            if !name.isEmpty { dropped.append(RemoteItem(name: name, kind: .file, relativePath: "")) }
                        }
                    }
                    await viewModel.downloadRemoteItems(dropped)
                }
                return true
            }
        }
        .onAppear { Task { await viewModel.initializeLocalDownloadsIfNeeded() } }
        .frame(minWidth: 280)
    }

    private var transferSidebar: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Transfers")
                    .font(.headline)
                Spacer()
                if viewModel.isTransferring { ProgressView() }
            }
            .padding([.top, .horizontal])
            List(viewModel.transferStatuses) { status in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: iconName(for: status.item))
                        Text(status.item.name)
                            .fontWeight(.medium)
                        Spacer()
                        Text(statusLabel(status.state))
                            .foregroundColor(color(for: status.state))
                    }
                    ProgressView(value: progressValue(for: status.state))
                    if !status.message.isEmpty {
                        Text(status.message)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func iconName(for item: RemoteItem) -> String {
        switch item.kind {
        case .directory: return "folder"
        case .file: return "doc"
        case .symlink: return "link"
        case .other: return "questionmark.folder"
        }
    }

    private func statusLabel(_ state: TransferItemStatus.State) -> String {
        switch state {
        case .pending: return "Pending"
        case .running: return "Running"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        }
    }

    private func color(for state: TransferItemStatus.State) -> Color {
        switch state {
        case .pending: return .secondary
        case .running: return .blue
        case .succeeded: return .green
        case .failed: return .red
        }
    }

    private func progressValue(for state: TransferItemStatus.State) -> Double {
        switch state {
        case .pending: return 0
        case .running: return 0.5
        case .succeeded: return 1
        case .failed: return 1
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView().environmentObject(AppViewModel())
    }
}



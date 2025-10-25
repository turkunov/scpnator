import Foundation

enum RemoteItemKind: String, Codable {
    case file
    case directory
    case symlink
    case other
}

struct RemoteItem: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let kind: RemoteItemKind
    let relativePath: String

    init(name: String, kind: RemoteItemKind, relativePath: String) {
        self.id = name
        self.name = name
        self.kind = kind
        self.relativePath = relativePath
    }
}

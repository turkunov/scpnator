import Foundation

final class LocalBrowserService {
    static let shared = LocalBrowserService()
    private init() {}

    func listDirectory(url: URL) throws -> [LocalItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .contentModificationDateKey]
        let contents = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        let items: [LocalItem] = contents.compactMap { child in
            let resourceValues = try? child.resourceValues(forKeys: Set(keys))
            if resourceValues?.isHidden == true { return nil }
            let isDir = (resourceValues?.isDirectory ?? false)
            return LocalItem(url: child, isDirectory: isDir)
        }
        return items.sorted { a, b in
            let aDate = (try? a.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate > bDate
        }
    }
}



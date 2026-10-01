import Foundation

/// The app used to be GhostHerdr (dev.ghostherdr.GhostHerdr). On the first
/// launch as bigtty, copies over what the old name kept: settings and window
/// frames, the Application Support folder (pane state, extensions), and the
/// browser's cookies and site data. Copies, so an old copy still works.
enum Migration {
    private static let oldID = "dev.ghostherdr.GhostHerdr"
    private static let doneKey = "migratedFromGhostHerdr"

    static func run() {
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != nil, !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        if let old = defaults.persistentDomain(forName: oldID) {
            for (key, value) in old where defaults.object(forKey: renamed(key)) == nil {
                defaults.set(key == "terminalTheme" && value as? String == "ghostherdr" ? "bigtty" : value, forKey: renamed(key))
            }
        }

        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let newID = Bundle.main.bundleIdentifier!
        for (from, to) in [
            ("Application Support/GhostHerdr", "Application Support/bigtty"),
            ("WebKit/\(oldID)", "WebKit/\(newID)"),
            ("HTTPStorages/\(oldID)", "HTTPStorages/\(newID)"),
            ("HTTPStorages/\(oldID).binarycookies", "HTTPStorages/\(newID).binarycookies"),
        ] {
            copy(library.appendingPathComponent(from), to: library.appendingPathComponent(to))
        }
    }

    /// Window frame names carried the old name ("NSWindow Frame GhostHerdrMain").
    private static func renamed(_ key: String) -> String {
        key.replacingOccurrences(of: "GhostHerdrMain", with: "BigttyMain")
            .replacingOccurrences(of: "GhostHerdr.space.", with: "bigtty.space.")
    }

    /// Copies files and folders, skipping sockets (the old control socket).
    private static func copy(_ from: URL, to: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: from.path, isDirectory: &isDir), !fm.fileExists(atPath: to.path) else { return }
        guard isDir.boolValue else { try? fm.copyItem(at: from, to: to); return }
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] {
            let item = from.appendingPathComponent(name)
            if (try? item.resourceValues(forKeys: [.fileResourceTypeKey]))?.fileResourceType == .socket { continue }
            copy(item, to: to.appendingPathComponent(name))
        }
    }
}

import AppKit
import UniformTypeIdentifiers

/// Images on the clipboard, turned into files a terminal app can open.
enum ImagePaste {
    struct Image: Sendable {
        let data: Data
        let name: String
    }

    /// The clipboard's image, if it holds one and no text: raw image data
    /// (a screenshot) as PNG, or a copied image file as is. Text wins, so
    /// ordinary pastes never change.
    @MainActor
    static func clipboardImage(_ pasteboard: NSPasteboard = .general) -> Image? {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if let file = files.first {
            // Only one image file copied in Finder; anything else pastes as paths.
            guard files.count == 1, let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
                  let data = try? Data(contentsOf: file) else { return nil }
            return Image(data: data, name: file.lastPathComponent)
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty { return nil }
        guard let raw = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: raw),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: Date())
        return Image(data: png, name: "Pasted \(stamp).png")
    }

    /// Writes the image where `runner` runs (this Mac, or over SSH) and
    /// returns its path there. Blocks: call off the main thread.
    static func stage(_ image: Image, runner: CommandRunner) -> String? {
        let name = image.name.replacingOccurrences(of: "/", with: "-")
        guard let ssh = runner.ssh else {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bigtty Pastes", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            do { try image.data.write(to: url) } catch { return nil }
            return url.path
        }
        // A private folder under the remote /tmp, then the file itself.
        let script = "umask 077; d=\"${TMPDIR:-/tmp}/bigtty-pastes-$(id -u)\"; mkdir -p \"$d\" && cat > \"$d/$1\" && printf %s \"$d/$1\""
        let command = ["sh", "-c", script, "sh", name].map(SSHTunnel.shellQuote).joined(separator: " ")
        guard let result = SSHTunnel.runSSH(ssh, remoteCommand: command, input: image.data, okStatuses: [0]) else { return nil }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}

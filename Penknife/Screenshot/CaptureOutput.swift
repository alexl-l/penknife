import AppKit

/// What Copy, Copy Text and Save do with a finished image (SS-46, SS-46b, SS-48), shared by the
/// editor and the pinned screenshots (R-40).
enum CaptureOutput {
    static func png(_ image: CGImage, scale: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return rep.representation(using: .png, properties: [:])
    }

    static func copy(_ png: Data) {
        if ScreenshotModule.copiesFile {
            // Also as a file, so ⌘V in a Finder folder creates it; elsewhere it pastes as the image.
            PastableImage.copy(png, named: PastableImage.timestampName { String(localized: "Screenshot \($0) at \($1)") })
        } else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
        }
    }

    /// Writes the PNG into the save folder; false (with an alert) when it couldn't.
    static func save(_ png: Data) -> Bool {
        let folder = ScreenshotModule.folder
        let url = CaptureGeometry.saveURL(folder: folder, date: .now) { FileManager.default.fileExists(atPath: $0.path) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            return true
        } catch {
            HUD.shared.show(String(localized: "Couldn't save the screenshot"), detail: folder.lastPathComponent,
                            symbol: "exclamationmark.triangle.fill", kind: .error, category: .screenshot)
            return false
        }
    }

    /// Reads the image's text on the Mac and puts it on the clipboard; false (with an alert)
    /// when there was none.
    static func copyText(_ image: CGImage) async -> Bool {
        guard let text = await TextReader.text(in: image) else {
            HUD.shared.show(String(localized: "No text found"), detail: String(localized: "Select an area with text"),
                            symbol: "text.viewfinder", kind: .error, category: .screenshot)
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }
}

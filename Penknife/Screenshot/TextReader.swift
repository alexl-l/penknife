import CoreGraphics
import Vision

/// On-device text recognition for Copy Text (R-36). No network (SS-06): Vision runs locally.
nonisolated enum TextReader {
    /// The lines found, top to bottom, or nil when there is no text.
    static func text(in image: CGImage) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                return nil
            }
            return join(request.results ?? [])
        }.value
    }

    /// Lines in reading order: rows top to bottom (Vision's origin is bottom-left); pieces on the
    /// same row, left to right, joined with a space.
    static func join(_ observations: [VNRecognizedTextObservation]) -> String? {
        let pieces = observations
            .compactMap { o in o.topCandidates(1).first.map { (box: o.boundingBox, text: $0.string) } }
            .sorted { $0.box.midY > $1.box.midY }
        var rows: [[(box: CGRect, text: String)]] = []
        for piece in pieces {
            if let last = rows.last?.last, abs(last.box.midY - piece.box.midY) < min(last.box.height, piece.box.height) / 2 {
                rows[rows.count - 1].append(piece)
            } else {
                rows.append([piece])
            }
        }
        let text = rows
            .map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

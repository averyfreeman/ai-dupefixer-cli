import Foundation
import AppKit
import CoreGraphics
import ImageIO
import PDFKit
import Vision

final class LocalContentAnalyzer {
    private let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp"]
    private let documentExtensions: Set<String> = ["pdf", "docx", "pptx", "xlsx", "txt", "md", "rtf"]

    func isEligible(_ file: DiscoveredFile) -> Bool {
        file.isImage || file.isDocument || imageExtensions.contains(file.fileExtension) || documentExtensions.contains(file.fileExtension)
    }

    func analyze(_ file: DiscoveredFile) throws -> FileFingerprint {
        if file.isImage || imageExtensions.contains(file.fileExtension) {
            let image = try loadImage(URL(fileURLWithPath: file.path))
            let digest = averageHash(image)
            let text = try recognizeText(in: image)
            return FileFingerprint(partialSHA256: nil, sha256: nil, imageDigest: digest, extractedText: text.isEmpty ? nil : text)
        }

        let text: String
        switch file.fileExtension {
        case "pdf":
            text = try extractPDFText(URL(fileURLWithPath: file.path))
        case "docx":
            text = try extractArchiveText(URL(fileURLWithPath: file.path), entries: ["word/document.xml", "word/header*.xml", "word/footer*.xml"])
        case "pptx":
            text = try extractArchiveText(URL(fileURLWithPath: file.path), entries: ["ppt/slides/*.xml", "ppt/notesSlides/*.xml"])
        case "xlsx":
            text = try extractArchiveText(URL(fileURLWithPath: file.path), entries: ["xl/sharedStrings.xml", "xl/worksheets/*.xml"])
        default:
            text = (try? String(contentsOf: URL(fileURLWithPath: file.path), encoding: .utf8)) ?? ""
        }
        return FileFingerprint(partialSHA256: nil, sha256: nil, imageDigest: nil, extractedText: text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
    }

    func previewDataURL(for file: DiscoveredFile) throws -> String {
        let data = try previewData(for: file)
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    func previewData(for file: DiscoveredFile) throws -> Data {
        let image = try loadImage(URL(fileURLWithPath: file.path))
        let thumbnail = image.resized(maxDimension: 768)
        let rep = NSBitmapImageRep(cgImage: thumbnail)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else {
            throw DupeFixerError.unsupported("unable to encode image preview")
        }
        return data
    }

    private func loadImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 768,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary) else {
            throw DupeFixerError.unsupported("unable to decode image \(url.lastPathComponent)")
        }
        return image
    }

    private func averageHash(_ image: CGImage) -> String {
        let width = 16
        let height = 16
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return "" }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let average = UInt8(pixels.reduce(0) { $0 + Int($1) } / max(pixels.count, 1))
        return pixels.map { $0 >= average ? "1" : "0" }.joined()
    }

    private func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private func extractPDFText(_ url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else { throw DupeFixerError.unsupported("unable to open PDF \(url.lastPathComponent)") }
        var text = document.string ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 32 {
            var recognized: [String] = []
            for index in 0..<min(document.pageCount, 6) {
                guard let page = document.page(at: index) else { continue }
                let image = page.thumbnail(of: CGSize(width: 1200, height: 1200), for: .mediaBox)
                var rect = CGRect(origin: .zero, size: image.size)
                if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil), let pageText = try? recognizeText(in: cgImage) {
                    recognized.append(pageText)
                }
            }
            text = [text, recognized.joined(separator: "\n")].joined(separator: "\n")
        }
        return text
    }

    private func extractArchiveText(_ url: URL, entries: [String]) throws -> String {
        var chunks: [String] = []
        for entry in entries {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", url.path, entry]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0, let value = String(data: data, encoding: .utf8), !value.isEmpty {
                    chunks.append(value)
                }
            } catch {
                throw DupeFixerError.unsupported("unzip is unavailable for \(url.lastPathComponent)")
            }
        }
        return chunks.map(Self.stripXML).joined(separator: "\n")
    }

    private static func stripXML(_ value: String) -> String {
        var result = value.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'"]
        for (entity, replacement) in entities { result = result.replacingOccurrences(of: entity, with: replacement) }
        return result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}

private extension CGImage {
    func resized(maxDimension: CGFloat) -> CGImage {
        let scale = min(1, maxDimension / CGFloat(max(width, height)))
        let width = max(1, Int(CGFloat(self.width) * scale))
        let height = max(1, Int(CGFloat(self.height) * scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return self }
        context.interpolationQuality = .medium
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? self
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

import Foundation
import PDFKit
import CoreGraphics
import MaiCore

/// Renders PDF pages to 200 dpi grayscale bitmaps and runs MaiCore's optical music recognition.
enum PDFScoreReader {
    static func read(url: URL, progress: (Int, Double) -> Void) throws -> Score {
        guard let doc = PDFDocument(url: url) else { throw AppError.message("The PDF could not be opened.") }
        guard doc.pageCount > 0 else { throw AppError.message("The PDF has no pages.") }
        var pages: [GrayImage] = []
        let count = min(doc.pageCount, 40)
        for i in 0..<count {
            progress(i + 1, Double(i) / Double(count))
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            let scale: CGFloat = 200.0 / 72.0
            let w = Int(box.width * scale), h = Int(box.height * scale)
            guard w > 100, h > 100, w * h < 60_000_000 else { continue }
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .mediaBox, to: ctx)
            guard let raw = ctx.data else { continue }
            let ptr = raw.bindMemory(to: UInt8.self, capacity: w * h)
            pages.append(GrayImage(width: w, height: h, pixels: Array(UnsafeBufferPointer(start: ptr, count: w * h))))
        }
        let title = url.deletingPathExtension().lastPathComponent
        let result = OMR.recognize(pages: pages, title: title) { p, f in progress(p, f) }
        guard result.notes > 0 else {
            throw AppError.message("No notes could be recognised in this PDF. OMR works best with clean, printed (engraved) scores. If you have the score as MusicXML (e.g. exported from MuseScore or SmartScore), import that instead for exact results.")
        }
        return result.score
    }
}

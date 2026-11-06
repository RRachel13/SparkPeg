import Foundation
import CoreGraphics
import Vision

enum ScreenTextRecognition {
    static func recognize(_ image: CGImage, size: CGSize) throws -> [TextGlyph] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.004
        try VNImageRequestHandler(cgImage: recognitionImage(image)).perform([request])

        let topToBottom = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        var rows: [[VNRecognizedTextObservation]] = []
        for observation in topToBottom {
            if let reference = rows.last?.first,
               abs(reference.boundingBox.midY - observation.boundingBox.midY)
                < min(reference.boundingBox.height, observation.boundingBox.height) * 0.5 {
                rows[rows.count - 1].append(observation)
            } else {
                rows.append([observation])
            }
        }
        let observations = rows.flatMap { $0.sorted { $0.boundingBox.minX < $1.boundingBox.minX } }
        var glyphs: [TextGlyph] = []
        for (line, observation) in observations.enumerated() {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence > 0.15,
                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let string = candidate.string
            let indices = Array(string.indices)
            var boxes: [CGRect] = []
            for (offset, index) in indices.enumerated() {
                let end = string.index(after: index)
                let fallback = CGRect(x: observation.boundingBox.minX + observation.boundingBox.width * CGFloat(offset) / CGFloat(indices.count),
                                      y: observation.boundingBox.minY,
                                      width: observation.boundingBox.width / CGFloat(indices.count),
                                      height: observation.boundingBox.height)
                if let box = (try? candidate.boundingBox(for: index..<end))?.boundingBox, !box.isEmpty, !box.isNull {
                    boxes.append(box)
                } else {
                    boxes.append(fallback)
                }
            }
            // Accurate Vision often returns the same word/line box for each
            // character. Split those runs, so selecting part of a word or a
            // Chinese line still produces distinct highlights and text.
            var start = 0
            while start < boxes.count {
                var end = start + 1
                while end < boxes.count && approximatelyEqual(boxes[start], boxes[end]) { end += 1 }
                let box = boxes[start]
                let weights = (start..<end).map { weight(string[indices[$0]]) }
                let total = weights.reduce(0, +)
                var x = box.minX
                for offset in start..<end {
                    let width = box.width * weights[offset - start] / total
                    boxes[offset] = CGRect(x: x, y: box.minY, width: width, height: box.height)
                    x += width
                }
                start = end
            }
            for (offset, index) in indices.enumerated() {
                var box = boxes[offset]
                if string[index].isWhitespace,
                   let before = (0..<offset).last(where: { !string[indices[$0]].isWhitespace }),
                   let after = ((offset + 1)..<indices.count).first(where: { !string[indices[$0]].isWhitespace }),
                   boxes[after].minX > boxes[before].maxX {
                    box = CGRect(x: boxes[before].maxX, y: observation.boundingBox.minY,
                                 width: boxes[after].minX - boxes[before].maxX,
                                 height: observation.boundingBox.height)
                }
                let rect = CGRect(x: box.minX * size.width, y: box.minY * size.height,
                                  width: max(1, box.width * size.width), height: max(1, box.height * size.height))
                    .intersection(CGRect(origin: .zero, size: size))
                guard !rect.isEmpty, !rect.isNull else { continue }
                glyphs.append(TextGlyph(id: glyphs.count, line: line, text: String(string[index]),
                    rect: rect))
            }
        }
        return glyphs
    }

    private static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.0001 && abs(a.minY - b.minY) < 0.0001
            && abs(a.width - b.width) < 0.0001 && abs(a.height - b.height) < 0.0001
    }

    static func recognitionImage(_ image: CGImage) -> CGImage {
        let maxDimension: CGFloat = 2400
        let ratio = min(1, maxDimension / CGFloat(max(image.width, image.height)))
        guard ratio < 1,
              let context = CGContext(data: nil, width: max(1, Int(CGFloat(image.width) * ratio)),
                  height: max(1, Int(CGFloat(image.height) * ratio)), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        return context.makeImage() ?? image
    }

    private static func weight(_ character: Character) -> CGFloat {
        if character.isWhitespace { return 0.4 }
        if "ilI.,:;'!|".contains(character) { return 0.35 }
        if "MWmw@".contains(character) { return 0.9 }
        return character.isASCII ? 0.6 : 1
    }
}

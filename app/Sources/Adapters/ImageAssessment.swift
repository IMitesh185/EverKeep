import CoreGraphics
import EverKeepCore
import Foundation
import ImageIO
import UIKit
import Vision

struct ImageDocument {
    let source: CGImageSource
    let image: CGImage
    let typeIdentifier: String
    let properties: [String: Any]

    init(data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source),
              let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ),
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw AdapterError.imageFailed("a complete single-frame image is required")
        }
        self.source = source
        self.image = image
        self.typeIdentifier = type as String
        self.properties = properties
    }

    var isHDR: Bool {
        image.bitsPerComponent > 8 || image.colorSpace?.isWideGamutRGB == true
            || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
    }

    var hasAuxiliaryData: Bool {
        [kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypePortraitEffectsMatte]
            .contains { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil }
    }

    var hasTransparency: Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: return true
        default: return false
        }
    }

    func rendered(maxSide: Int) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AdapterError.imageFailed("the oriented image could not be decoded")
        }
        return image
    }
}

enum ImageAssessment {
    static func uprightImage(_ image: UIImage) throws -> CGImage {
        guard image.size.width > 0, image.size.height > 0 else {
            throw AdapterError.imageFailed("Photos returned an empty preview")
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let result = rendered.cgImage else { throw AdapterError.imageFailed("the Photos preview could not be decoded") }
        return result
    }

    static func score(_ before: CGImage, _ after: CGImage, maxSide: Int) throws -> Double {
        let scale = min(1, Double(maxSide) / Double(max(before.width, before.height)))
        let width = max(8, Int((Double(before.width) * scale).rounded()))
        let height = max(8, Int((Double(before.height) * scale).rounded()))
        let left = try pixels(before, width: width, height: height)
        let right = try pixels(after, width: width, height: height)
        var scores: [Double] = []
        for channel in 0..<4 {
            let a = stride(from: channel, to: left.count, by: 4).map { left[$0] }
            let b = stride(from: channel, to: right.count, by: 4).map { right[$0] }
            if a == b {
                scores.append(1)
                continue
            }
            guard let frameA = LumaFrame(width: width, height: height, pixels: a),
                  let frameB = LumaFrame(width: width, height: height, pixels: b),
                  let value = SSIM.compare(frameA, frameB), value.isFinite else {
                throw AdapterError.imageFailed("picture similarity could not be measured")
            }
            scores.append(max(-1, min(1, value)))
        }
        guard let minimum = scores.min() else { throw AdapterError.imageFailed("no colour channels were compared") }
        return minimum
    }

    static func hints(images: [CGImage], measureMotion: Bool, hasTransparency: Bool = false) throws -> ContentHints {
        guard !images.isEmpty else { throw AdapterError.imageFailed("no analysis frames were available") }
        var hints = ContentHints(hasTransparency: hasTransparency)
        for image in images {
            try Task.checkCancellation()
            let text = VNDetectTextRectanglesRequest()
            let faces = VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([text, faces])
            hints.containsText = hints.containsText || !(text.results ?? []).isEmpty
            hints.containsFaces = hints.containsFaces || !(faces.results ?? []).isEmpty
        }
        if measureMotion, images.count > 1 {
            var minimum = 1.0
            for index in 1..<images.count {
                minimum = min(minimum, try score(images[index - 1], images[index], maxSide: 256))
            }
            hints.motion = minimum < 0.9 ? .high : .low
        }
        return hints
    }

    static func details(_ before: CGImage, _ after: CGImage) throws -> DetailMetrics {
        let sourceText = VNRecognizeTextRequest()
        let candidateText = VNRecognizeTextRequest()
        for request in [sourceText, candidateText] {
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.automaticallyDetectsLanguage = true
        }
        let sourceFaces = VNDetectFaceRectanglesRequest()
        let candidateFaces = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: before, options: [:]).perform([sourceText, sourceFaces])
        try VNImageRequestHandler(cgImage: after, options: [:]).perform([candidateText, candidateFaces])
        let text = sourceText.results ?? []
        let faces = sourceFaces.results ?? []
        let beforeWords = try words(text)
        let afterWords = try words(candidateText.results ?? [])
        var result = DetailMetrics(
            framesChecked: 1, textMatches: beforeWords == afterWords,
            textRegions: text.count, faceRegions: faces.count
        )
        for observation in text {
            let value = try regionScore(before, after, box: observation.boundingBox)
            result.minTextSSIM = min(result.minTextSSIM ?? 1, value)
        }
        for observation in faces {
            let value = try regionScore(before, after, box: observation.boundingBox)
            result.minFaceSSIM = min(result.minFaceSSIM ?? 1, value)
        }
        if (candidateFaces.results ?? []).count != faces.count, !faces.isEmpty {
            result.minFaceSSIM = 0
        }
        return result
    }

    static func metrics(_ scores: [Double]) throws -> QualityMetrics {
        guard let minimum = scores.min(), scores.allSatisfy({ $0.isFinite }) else {
            throw AdapterError.imageFailed("no valid similarity samples were available")
        }
        return QualityMetrics(
            meanSSIM: scores.reduce(0, +) / Double(scores.count),
            minSSIM: minimum, framesCompared: scores.count
        )
    }

    static func merge(_ left: DetailMetrics, _ right: DetailMetrics) -> DetailMetrics {
        DetailMetrics(
            framesChecked: left.framesChecked + right.framesChecked,
            textMatches: left.textMatches && right.textMatches,
            textRegions: left.textRegions + right.textRegions,
            faceRegions: left.faceRegions + right.faceRegions,
            minTextSSIM: minimum(left.minTextSSIM, right.minTextSSIM),
            minFaceSSIM: minimum(left.minFaceSSIM, right.minFaceSSIM)
        )
    }

    private static func minimum(_ left: Double?, _ right: Double?) -> Double? {
        switch (left, right) {
        case (.some(let a), .some(let b)): return min(a, b)
        case (.some(let a), .none): return a
        case (.none, .some(let b)): return b
        case (.none, .none): return nil
        }
    }

    private static func words(_ observations: [VNRecognizedTextObservation]) throws -> [String] {
        try observations.map { observation in
            guard let text = observation.topCandidates(1).first else {
                throw AdapterError.imageFailed("detected text could not be read reliably")
            }
            return text.string
        }.sorted()
    }

    private static func regionScore(_ before: CGImage, _ after: CGImage, box: CGRect) throws -> Double {
        func crop(_ image: CGImage) -> CGImage? {
            let rect = CGRect(
                x: box.minX * CGFloat(image.width),
                y: (1 - box.maxY) * CGFloat(image.height),
                width: box.width * CGFloat(image.width),
                height: box.height * CGFloat(image.height)
            ).integral.intersection(CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
            guard rect.width >= 8, rect.height >= 8 else { return nil }
            return image.cropping(to: rect)
        }
        guard let a = crop(before), let b = crop(after) else {
            throw AdapterError.imageFailed("a text or face region was too small to verify")
        }
        return try score(a, b, maxSide: 1024)
    }

    private static func pixels(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard drawn else { throw AdapterError.imageFailed("the comparison bitmap could not be created") }
        return bytes
    }
}

import CoreGraphics
import CoreText
import Foundation
import ImageIO

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift make_photo.swift <output.jpg>")
}

let width = 1600
let height = 1200
var bytes = [UInt8](repeating: 255, count: width * height * 4)
var seed: UInt32 = 12345
for y in 0..<height {
    for x in 0..<width {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let noise = Int(seed >> 24) % 65 - 32
        let base = 60 + x * 100 / width + y * 50 / height
        let offset = (y * width + x) * 4
        bytes[offset] = UInt8(clamping: base + noise)
        bytes[offset + 1] = UInt8(clamping: base + noise + 15)
        bytes[offset + 2] = UInt8(clamping: base + noise + 30)
    }
}

let image = bytes.withUnsafeMutableBytes { buffer -> CGImage? in
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: buffer.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
          ) else { return nil }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 60, y: 920, width: 1480, height: 200))
    context.textPosition = CGPoint(x: 100, y: 990)
    let text = NSAttributedString(string: "EverKeep demo - 12345", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 64, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
    ])
    CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), context)
    return context.makeImage()
}

guard let image,
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, "public.jpeg" as CFString, 1, nil
      ) else { fatalError("Could not create the synthetic photo") }
CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write the synthetic photo") }
print("Created synthetic photo: \(CommandLine.arguments[1])")

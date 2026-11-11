import Foundation

/// An 8-bit luma plane, row-major.
public struct LumaFrame: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init?(width: Int, height: Int, pixels: [UInt8]) {
        guard width > 0, height > 0, width <= Int.max / height, pixels.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

public enum SSIM {
    /// Mean structural similarity over non-overlapping blocks. Returns nil if the frames cannot be compared.
    public static func compare(_ a: LumaFrame, _ b: LumaFrame, block: Int = 8) -> Double? {
        guard a.width == b.width, a.height == b.height, block > 0,
              a.width >= block, a.height >= block
        else { return nil }

        let c1 = 6.5025   // (0.01 * 255)^2
        let c2 = 58.5225  // (0.03 * 255)^2
        var total = 0.0
        var count = 0

        var y = 0
        while y < a.height {
            let blockHeight = min(block, a.height - y)
            var x = 0
            while x < a.width {
                let blockWidth = min(block, a.width - x)
                let n = Double(blockWidth * blockHeight)
                var sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0
                for j in 0..<blockHeight {
                    let row = (y + j) * a.width + x
                    for i in 0..<blockWidth {
                        let p = Double(a.pixels[row + i])
                        let q = Double(b.pixels[row + i])
                        sumA += p
                        sumB += q
                        sumAA += p * p
                        sumBB += q * q
                        sumAB += p * q
                    }
                }
                let meanA = sumA / n
                let meanB = sumB / n
                let varA = sumAA / n - meanA * meanA
                let varB = sumBB / n - meanB * meanB
                let covariance = sumAB / n - meanA * meanB
                let numerator = (2 * meanA * meanB + c1) * (2 * covariance + c2)
                let denominator = (meanA * meanA + meanB * meanB + c1) * (varA + varB + c2)
                total += numerator / denominator
                count += 1
                x += block
            }
            y += block
        }
        return count > 0 ? total / Double(count) : nil
    }
}

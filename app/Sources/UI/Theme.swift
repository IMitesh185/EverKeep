import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Everkeep's palette: warm ivory, champagne, honey amber and muted gold, with dark charcoal type.
/// One quiet sage is used for "checked" and nothing else. There are no category colours.
enum EK {
    static let ivory50 = Color(hex: 0xFFFCF6)
    static let ivory100 = Color(hex: 0xFBF6EA)
    static let ivory200 = Color(hex: 0xF5EDDB)
    static let champagne300 = Color(hex: 0xE8D5AC)
    static let champagne400 = Color(hex: 0xDCC38F)
    static let honey300 = Color(hex: 0xEFCB7C)
    static let honey400 = Color(hex: 0xE5B552)
    static let honey500 = Color(hex: 0xD8A13A)
    static let honey600 = Color(hex: 0xB98425)
    static let honey700 = Color(hex: 0x8F6417)
    static let gold400 = Color(hex: 0xCBAA72)
    static let ink900 = Color(hex: 0x1F1D1A)
    static let ink800 = Color(hex: 0x2B2824)
    static let ink700 = Color(hex: 0x3B3731)
    static let ink600 = Color(hex: 0x55504A)
    static let sage500 = Color(hex: 0x7E9674)
    static let sage700 = Color(hex: 0x4C6347)
    static let shadow = Color(hex: 0x3A260A)
    static let scrim = Color(hex: 0x2E200C)

    static let glassEdge = LinearGradient(
        colors: [Color.white.opacity(0.95), Color.white.opacity(0.12), Color(hex: 0xEFCB7C).opacity(0.45)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let honeyFill = LinearGradient(
        colors: [Color(hex: 0xF3D285), Color(hex: 0xE2AE48), Color(hex: 0xD9A13A)],
        startPoint: .top,
        endPoint: .bottom
    )
}

extension Font {
    /// New York on iPhone. The HTML preview uses Instrument Serif as a stand-in for it.
    static func ekSerif(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .serif)
    }
}

extension Text {
    func ekEyebrow() -> some View {
        self.font(.system(size: 11, weight: .semibold))
            .tracking(1.3)
            .textCase(.uppercase)
            .foregroundStyle(EK.ink600)
    }
}

extension View {
    /// Translucent ivory glass: the material blurs whatever memory is behind it, the tint keeps type readable.
    func ekGlass<S: InsettableShape>(_ shape: S, tint: Double = 0.62) -> some View {
        self
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(EK.ivory100.opacity(tint))
                }
            }
            .overlay { shape.strokeBorder(EK.glassEdge, lineWidth: 1) }
            .shadow(color: EK.shadow.opacity(0.32), radius: 26, x: 0, y: 16)
    }
}

/// The one primary action: honey amber with a muted gold rim.
struct HoneyButtonStyle: ButtonStyle {
    var height: CGFloat = 58

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        HoneyLabel(configuration: configuration, height: height)
    }

    private struct HoneyLabel: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isEnabled ? EK.ink900 : EK.ink600)
                .frame(maxWidth: .infinity, minHeight: height)
                .background { fill }
                .clipShape(Capsule())
                .overlay { Capsule().strokeBorder(rim, lineWidth: 1) }
                .shadow(color: isEnabled ? EK.honey600.opacity(0.45) : Color.clear, radius: 14, x: 0, y: 10)
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .brightness(configuration.isPressed ? -0.04 : 0)
                .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
        }

        @ViewBuilder private var fill: some View {
            if isEnabled {
                Capsule().fill(EK.honeyFill)
            } else {
                Capsule().fill(EK.ivory50.opacity(0.5))
            }
        }

        private var rim: Color {
            isEnabled ? EK.honey600.opacity(0.55) : EK.ink900.opacity(0.14)
        }
    }
}

/// A round glass control, used for back and close.
struct RoundGlassButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(EK.ink900)
                .frame(width: 44, height: 44)
                .ekGlass(Circle(), tint: 0.55)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Fine film grain, tiled and blended over everything behind it.
enum Grain {
    static let image: UIImage? = {
        let rect = CGRect(x: 0, y: 0, width: 192, height: 192)
        guard let noise = CIFilter.randomGenerator().outputImage?.cropped(to: rect) else { return nil }
        let mono = CIFilter.colorControls()
        mono.inputImage = noise
        mono.saturation = 0
        mono.contrast = 1.2
        guard let output = mono.outputImage, let cgImage = CIContext().createCGImage(output, from: rect) else { return nil }
        return UIImage(cgImage: cgImage)
    }()
}

struct GrainOverlay: View {
    var body: some View {
        if let image = Grain.image {
            Image(uiImage: image)
                .resizable(resizingMode: .tile)
                .blendMode(.overlay)
                .opacity(0.3)
                .allowsHitTesting(false)
        }
    }
}

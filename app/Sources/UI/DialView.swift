import QuartzCore
import SwiftUI
import UIKit

/// The dial's single source of truth: a position measured in categories, 0 for Photos up to 3 for Screenshots.
/// A finger sets it directly. A release hands it to a spring that settles on a detent, like a physical control.
final class DialPhysics: NSObject, ObservableObject {
    @Published private(set) var position: Double = 0

    private var velocity: Double = 0
    private var target: Double = 0
    private var link: CADisplayLink?
    private var lastTime: CFTimeInterval = 0

    var selectedIndex: Int {
        let last = LibraryCategory.allCases.count - 1
        return min(max(Int(position.rounded()), 0), last)
    }

    /// Follows a finger: no spring, no inertia.
    func place(_ value: Double) {
        stop()
        position = value
        target = value
    }

    func settle(on index: Int, velocity startVelocity: Double) {
        let last = LibraryCategory.allCases.count - 1
        target = Double(min(max(index, 0), last))
        velocity = startVelocity
        if UIAccessibility.isReduceMotionEnabled {
            stop()
            position = target
            return
        }
        lastTime = CACurrentMediaTime()
        guard link == nil else { return }
        let display = CADisplayLink(target: self, selector: #selector(step(_:)))
        display.add(to: .main, forMode: .common)
        link = display
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ display: CADisplayLink) {
        let now = display.timestamp
        let dt = min(0.034, max(0.001, now - lastTime))
        lastTime = now
        let stiffness = 200.0
        let damping = 2 * 0.84 * stiffness.squareRoot()
        // Two sub-steps keep the spring stable on a slow frame.
        for _ in 0..<2 {
            velocity += (-stiffness * (position - target) - damping * velocity) * dt / 2
            position += velocity * dt / 2
        }
        if abs(position - target) < 0.0006 && abs(velocity) < 0.01 {
            position = target
            velocity = 0
            stop()
        }
    }

    deinit {
        link?.invalidate()
    }
}

/// End stops give a little, and the dial hangs on each detent as it passes.
private enum DialMath {
    static func rubber(_ value: Double, last: Int) -> Double {
        let end = Double(last)
        if value < 0 { return value * 0.32 }
        if value > end { return end + (value - end) * 0.32 }
        return value
    }

    static func sticky(_ value: Double) -> Double {
        let nearest = value.rounded()
        let delta = value - nearest
        let sign: Double = delta < 0 ? -1 : 1
        return nearest + sign * pow(abs(delta) * 2, 1.5) / 2
    }
}

private struct DownTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The primary control: a champagne bezel with a knurled edge, a glass face, an engraved scale, and four
/// categories. The selected one sits under the gold index, its neighbours are partly in view.
struct DialView: View {
    @ObservedObject var physics: DialPhysics
    let diameter: CGFloat
    let onSelect: (LibraryCategory) -> Void

    @State private var drag: DragState?
    @State private var clicking = false
    @State private var feedback = UISelectionFeedbackGenerator()

    private struct DragSample {
        var time: CFTimeInterval
        var value: Double
    }

    private struct DragState {
        var lastAngle: Double
        var raw: Double
        var start: CGPoint
        var startTime: CFTimeInterval
        var moved: Bool
        var samples: [DragSample]
    }

    private let degreesPerCategory = 45.0
    private var count: Int { LibraryCategory.allCases.count }
    private var unit: CGFloat { diameter / 640 }
    private var faceRadius: CGFloat { diameter / 2 - 15 * unit }

    var body: some View {
        let rotation = Angle.degrees(-degreesPerCategory * physics.position)
        ZStack {
            rim
            knurl.rotationEffect(rotation)
            face
            glow
            scale.rotationEffect(rotation)
            sheen
            nib
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(dragGesture)
        .onChange(of: physics.selectedIndex) { index in
            feedback.selectionChanged()
            click()
            onSelect(LibraryCategory.allCases[index])
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Category")
        .accessibilityValue(LibraryCategory.allCases[physics.selectedIndex].title)
        .accessibilityHint("Swipe up or down to change the category")
        .accessibilityIdentifier("dial")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: physics.settle(on: physics.selectedIndex + 1, velocity: 0)
            case .decrement: physics.settle(on: physics.selectedIndex - 1, velocity: 0)
            @unknown default: break
            }
        }
    }

    // MARK: Parts

    private static let rimStops: [Gradient.Stop] = [
        Gradient.Stop(color: Color(hex: 0xF1E3BF), location: 0),
        Gradient.Stop(color: Color(hex: 0xFFF8E4), location: 0.09),
        Gradient.Stop(color: Color(hex: 0xCDB07A), location: 0.18),
        Gradient.Stop(color: Color(hex: 0xF7EBCB), location: 0.28),
        Gradient.Stop(color: Color(hex: 0xBB9A62), location: 0.38),
        Gradient.Stop(color: Color(hex: 0xF2E3BD), location: 0.5),
        Gradient.Stop(color: Color(hex: 0xC9AB74), location: 0.61),
        Gradient.Stop(color: Color(hex: 0xFFF6DC), location: 0.72),
        Gradient.Stop(color: Color(hex: 0xBE9F69), location: 0.84),
        Gradient.Stop(color: Color(hex: 0xF1E3BF), location: 1)
    ]

    private var rim: some View {
        Circle()
            .fill(AngularGradient(gradient: Gradient(stops: DialView.rimStops), center: .center, angle: .degrees(70)))
            .overlay { Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1.5) }
            .shadow(color: EK.shadow.opacity(0.3), radius: 30, x: 0, y: 20)
            .frame(width: diameter, height: diameter)
    }

    private var knurl: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = size.width / 2 - 2 * unit
            let inner = outer - 9 * unit
            for index in 0..<120 {
                let radians = Double(index) * 3 * Double.pi / 180
                var path = Path()
                path.move(to: edgePoint(center, radians, inner))
                path.addLine(to: edgePoint(center, radians, outer))
                context.stroke(path, with: .color(Color(hex: 0x46300C).opacity(0.5)), lineWidth: 1.6)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private var face: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().fill(EK.ivory100.opacity(0.6))
            // Fine concentric lines, like spun metal.
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                var radius = 5 * unit
                while radius < size.width / 2 {
                    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    context.stroke(Path(ellipseIn: rect), with: .color(Color.white.opacity(0.16)), lineWidth: 1)
                    radius += 5 * unit
                }
            }
            Circle().strokeBorder(Color(hex: 0x785418).opacity(0.28), lineWidth: 1)
            Circle().strokeBorder(
                LinearGradient(colors: [Color.white.opacity(0.9), Color.white.opacity(0)], startPoint: .top, endPoint: .center),
                lineWidth: 2.5
            )
        }
        .frame(width: faceRadius * 2, height: faceRadius * 2)
    }

    /// A warm spot of light behind the selected category.
    private var glow: some View {
        Ellipse()
            .fill(RadialGradient(
                colors: [Color(hex: 0xFFE9AC).opacity(0.95), Color(hex: 0xFFE9AC).opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: 84 * unit
            ))
            .frame(width: 168 * unit, height: 112 * unit)
            .blur(radius: 5)
            .offset(y: -(faceRadius - 86 * unit))
            .allowsHitTesting(false)
    }

    private var scale: some View {
        ZStack {
            ticks
            ForEach(LibraryCategory.allCases) { category in
                label(for: category)
                    .offset(y: -(faceRadius - 81.5 * unit))
                    .frame(width: diameter, height: diameter)
                    .rotationEffect(.degrees(Double(category.rawValue) * degreesPerCategory))
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private var ticks: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for index in 0..<72 {
                let major = index % 9 == 0
                let outer = faceRadius - (major ? 35 : 37) * unit
                let inner = faceRadius - (major ? 52 : 44) * unit
                let radians = Double(index) * 5 * Double.pi / 180
                var path = Path()
                path.move(to: edgePoint(center, radians, inner))
                path.addLine(to: edgePoint(center, radians, outer))
                context.stroke(
                    path,
                    with: .color(Color(hex: 0x3C280A).opacity(major ? 0.78 : 0.42)),
                    lineWidth: (major ? 2 : 1.2) * unit
                )
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func label(for category: LibraryCategory) -> some View {
        let focus = max(0, min(1, 1 - abs(physics.position - Double(category.rawValue))))
        return VStack(spacing: 9 * unit) {
            Image(systemName: category.symbol)
                .font(.system(size: 21 * unit, weight: .regular))
                .foregroundStyle(EK.ink900.opacity(0.62 + 0.38 * focus))
                .frame(width: 28 * unit, height: 28 * unit)
                .background { lens(focus: focus) }
            Text(category.title)
                .font(.system(size: 12 * unit, weight: .semibold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(EK.ink900.opacity(0.62 + 0.38 * focus))
                .fixedSize()
        }
        .opacity(0.46 + 0.54 * focus)
        .scaleEffect(0.86 + 0.14 * focus)
    }

    /// A honey bead that lights up behind the selected icon.
    private func lens(focus: Double) -> some View {
        Circle()
            .fill(RadialGradient(
                colors: [Color(hex: 0xFFF4CF), Color(hex: 0xEDC873), Color(hex: 0xD9A23B)],
                center: UnitPoint(x: 0.36, y: 0.26),
                startRadius: 0,
                endRadius: 40 * unit
            ))
            .overlay { Circle().strokeBorder(EK.honey600.opacity(0.4), lineWidth: 1) }
            .shadow(color: EK.honey600.opacity(0.5), radius: 8, x: 0, y: 6)
            .frame(width: 52 * unit, height: 52 * unit)
            .opacity(focus)
            .scaleEffect(0.7 + 0.3 * focus)
    }

    private var sheen: some View {
        Circle()
            .fill(RadialGradient(
                colors: [Color.white.opacity(0.5), Color.white.opacity(0)],
                center: UnitPoint(x: 0.3, y: 0),
                startRadius: 0,
                endRadius: diameter * 0.5
            ))
            .padding(15 * unit)
            .frame(width: diameter, height: diameter)
            .allowsHitTesting(false)
    }

    /// The gold index. It dips a little each time the dial passes a detent.
    private var nib: some View {
        VStack(spacing: 0) {
            DownTriangle()
                .fill(LinearGradient(colors: [Color(hex: 0xF5D78C), Color(hex: 0xD29A33)], startPoint: .top, endPoint: .bottom))
                .frame(width: 16 * unit, height: 11 * unit)
                .shadow(color: Color.white.opacity(0.7), radius: 0, x: 0, y: 1)
                .offset(y: clicking ? 2 : 0)
                .padding(.top, 5 * unit)
            Spacer(minLength: 0)
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }

    private func edgePoint(_ center: CGPoint, _ radians: Double, _ radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + CGFloat(sin(radians)) * radius, y: center.y - CGFloat(cos(radians)) * radius)
    }

    private func click() {
        clicking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { clicking = false }
    }

    // MARK: Touch

    private func angleOf(_ point: CGPoint) -> Double {
        let dx = Double(point.x - diameter / 2)
        let dy = Double(diameter / 2 - point.y)
        return atan2(dx, dy) * 180 / Double.pi
    }

    /// The category under a tap, if the tap landed on one of the labels.
    private func categoryAt(_ point: CGPoint) -> LibraryCategory? {
        let dx = point.x - diameter / 2
        let dy = point.y - diameter / 2
        guard hypot(dx, dy) > faceRadius * 0.6 else { return nil }
        let exact = angleOf(point) / degreesPerCategory + physics.position
        let index = Int(exact.rounded())
        guard abs(exact - Double(index)) < 0.5, index >= 0, index < count else { return nil }
        return LibraryCategory.allCases[index]
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let current = angleOf(value.location)
                if drag == nil {
                    physics.stop()
                    feedback.prepare()
                    let now = CACurrentMediaTime()
                    drag = DragState(
                        lastAngle: angleOf(value.startLocation),
                        raw: physics.position,
                        start: value.startLocation,
                        startTime: now,
                        moved: false,
                        samples: [DragSample(time: now, value: physics.position)]
                    )
                }
                guard var state = drag else { return }
                var delta = current - state.lastAngle
                if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
                state.lastAngle = current
                state.raw -= delta / degreesPerCategory
                if !state.moved, hypot(value.location.x - state.start.x, value.location.y - state.start.y) > 6 {
                    state.moved = true
                }
                let now = CACurrentMediaTime()
                state.samples.append(DragSample(time: now, value: state.raw))
                while state.samples.count > 2, now - state.samples[0].time > 0.1 {
                    state.samples.removeFirst()
                }
                drag = state
                physics.place(DialMath.sticky(DialMath.rubber(state.raw, last: count - 1)))
            }
            .onEnded { value in
                guard let state = drag else { return }
                drag = nil
                if !state.moved, CACurrentMediaTime() - state.startTime < 0.45, let tapped = categoryAt(value.location) {
                    physics.settle(on: tapped.rawValue, velocity: 0)
                    return
                }
                guard let first = state.samples.first, let last = state.samples.last else { return }
                let seconds = max(0.016, last.time - first.time)
                let speed = min(max((last.value - first.value) / seconds, -10), 10)
                let projected = Int((state.raw + speed * 0.24).rounded())
                physics.settle(on: min(max(projected, 0), count - 1), velocity: speed)
            }
    }
}

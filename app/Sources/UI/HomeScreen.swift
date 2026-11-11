import EverKeepCore
import SwiftUI

/// The main screen. Only the selected category, what it uses, what could be saved, and one action.
struct HomeScreen: View {
    @ObservedObject var physics: DialPhysics
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let diameter = size.width * 1.63
            let visible = min(max(size.height * 0.31, 220), 290)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    Spacer(minLength: 70)
                    HomePanel()
                        .padding(.horizontal, 16)
                        .padding(.bottom, visible + 28)
                }
                .frame(width: size.width, height: size.height)
                DialView(physics: physics, diameter: diameter, onSelect: { model.select($0) })
                    .position(x: size.width / 2, y: size.height - visible + diameter / 2)
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .onAppear { physics.place(Double(model.category.rawValue)) }
    }
}

struct HomePanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let category = model.category
        let stats = model.stats[category] ?? CategoryStats()
        let nothing = stats.itemCount == 0 || (stats.isComplete && stats.reviewableCount == 0)
        let enabled = stats.reviewableCount > 0
        VStack(alignment: .leading, spacing: 0) {
            Text(category.title)
                .font(.ekSerif(60))
                .tracking(-0.7)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(EK.ink900)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("categoryName")
                .id(category)
                .transition(.opacity.combined(with: .offset(x: 0, y: 10)))
            Rectangle()
                .fill(EK.ink900.opacity(0.14))
                .frame(height: 1)
                .padding(.top, 10)
            HStack(alignment: .top, spacing: 18) {
                MetricView(title: "Storage consumed", value: used(stats), highlight: false, identifier: "usedValue")
                MetricView(title: "Potential savings", value: savings(stats), highlight: true, identifier: "savingsValue")
            }
            .padding(.top, 14)
            .id(category)
            .transition(.opacity.combined(with: .offset(x: 0, y: 10)))
            Button {
                model.openReview()
            } label: {
                HStack(spacing: 10) {
                    Text(nothing ? "Nothing to preserve" : (enabled ? "Review & preserve" : "Measuring…"))
                    if enabled { Image(systemName: "arrow.right").font(.system(size: 16, weight: .semibold)) }
                }
            }
            .buttonStyle(HoneyButtonStyle())
            .disabled(!enabled)
            .padding(.top, 18)
            .accessibilityIdentifier("reviewButton")
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .ekGlass(RoundedRectangle(cornerRadius: 36, style: .continuous), tint: 0.74)
    }

    private func used(_ stats: CategoryStats) -> MetricView.Value {
        if stats.itemCount > 0 && stats.usedBytes == 0 && stats.isComplete { return .unknown }
        return .amount(stats.usedBytes, approximate: false, measuring: !stats.isComplete)
    }

    private func savings(_ stats: CategoryStats) -> MetricView.Value {
        if stats.potentialBytes > 0 || !stats.isComplete {
            return .amount(stats.potentialBytes, approximate: true, measuring: !stats.isComplete)
        }
        return .none
    }
}

/// One number in serif with its unit beside it. Estimates carry a leading "~", unknowns a dash,
/// and numbers that are still being measured breathe.
struct MetricView: View {
    enum Value: Equatable {
        case amount(Int64, approximate: Bool, measuring: Bool)
        case none
        case unknown
    }

    let title: String
    let value: Value
    let highlight: Bool
    let identifier: String

    @State private var pulse = false

    private var measuring: Bool {
        if case .amount(_, _, let isMeasuring) = value { return isMeasuring }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).ekEyebrow()
            content
                .opacity(measuring && pulse ? 0.45 : 1)
                .animation(measuring ? Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil, value: pulse)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
        .onAppear { pulse = true }
    }

    @ViewBuilder private var content: some View {
        switch value {
        case .amount(let bytes, let approximate, _):
            amountText(bytes, approximate: approximate)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .background(alignment: .bottom) {
                    if highlight {
                        Rectangle().fill(EK.honey400.opacity(0.5)).frame(height: 9).offset(y: -4)
                    }
                }
        case .none:
            Text("None").font(.ekSerif(28)).foregroundStyle(EK.ink600).frame(minHeight: 48, alignment: .leading)
        case .unknown:
            Text("—").font(.ekSerif(34)).foregroundStyle(EK.ink600).frame(minHeight: 48, alignment: .leading)
        }
    }

    private func amountText(_ bytes: Int64, approximate: Bool) -> Text {
        let parts = Amounts.parts(bytes)
        let tilde = Text(approximate ? "~" : "").font(.ekSerif(44)).foregroundColor(EK.ink600)
        let number = Text(parts.number).font(.ekSerif(44)).foregroundColor(EK.ink900)
        let unit = Text(" \(parts.unit)").font(.system(size: 17, weight: .medium)).foregroundColor(EK.ink600)
        return tilde + number + unit
    }
}

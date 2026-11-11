import SwiftUI
import UIKit

/// The whole experience: one faded memory behind everything, one screen in front, and the dial as the only navigation.
struct ExperienceRoot: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var physics = DialPhysics()

    var body: some View {
        ZStack {
            MemoryBackground(physics: physics, veil: veil)
            screen
            SheetHost()
        }
        .preferredColorScheme(.light)
        .animation(.easeInOut(duration: 0.5), value: model.screen)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Coming back from Settings after allowing access.
            if model.screen == .noAccess { model.launch { await model.start() } }
        }
    }

    /// Review and Done sit over a calmer, more ivory memory.
    private var veil: Double {
        switch model.screen {
        case .review, .done: return 0.4
        default: return 0
        }
    }

    @ViewBuilder private var screen: some View {
        switch model.screen {
        case .launching:
            Color.clear
        case .welcome:
            CardScreen(.bottom) { WelcomeCard() }
        case .scanning, .working:
            CardScreen(.middle) { ProgressCard() }
        case .noAccess:
            CardScreen(.bottom) { NoAccessCard() }
        case .dial:
            HomeScreen(physics: physics)
        case .review:
            ReviewScreen()
        case .done:
            CardScreen(.bottom) { DoneCard() }
        }
    }
}

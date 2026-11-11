import SwiftUI

@main
struct EverKeepApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if AppModel.usesClassicInterface {
                    ClassicRootView()
                } else {
                    ExperienceRoot()
                }
            }
            .environmentObject(model)
            .task { await model.start() }
        }
    }
}

import Photos
import SwiftUI

@main
struct SpikeApp: App {
    var body: some Scene {
        WindowGroup { CensusView() }
    }
}

struct CensusView: View {
    @State private var report = "Tap Run census."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("E1: Photos census (read-only)").font(.headline)
            Button("Run census") {
                Task {
                    _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                    report = Census.report()
                }
            }
            .buttonStyle(.borderedProminent)
            ScrollView {
                Text(report)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding()
    }
}

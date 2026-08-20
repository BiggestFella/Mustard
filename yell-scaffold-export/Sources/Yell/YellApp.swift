import SwiftUI
import YellKit

@main
struct YellApp: App {
    var body: some Scene {
        MenuBarExtra(YellKit.productName, systemImage: "megaphone.fill") {
            VStack(alignment: .leading, spacing: 8) {
                Text(YellKit.tagline)
                    .font(.headline)
                Text("Skeleton app — Phase 1 lifts dictation from Mustard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

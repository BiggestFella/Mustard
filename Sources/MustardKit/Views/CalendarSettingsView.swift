import SwiftUI

/// GOOGLE CALENDAR OAuth connection, extracted from SourceSettingsView so the
/// Settings screen can order it as its own section. Credentials live in the
/// Keychain (KeychainTokenStore), never UserDefaults.
struct CalendarSettingsView: View {
    @Environment(GoogleCalendarService.self) private var calendar
    @State private var gcalClientId = ""
    @State private var gcalClientSecret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("GOOGLE CALENDAR")
                    .font(Theme.Fonts.sectionHeader).tracking(0.06)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                if case .connected = calendar.state {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Palette.done)
                }
            }

            switch calendar.state {
            case .disconnected, .failed:
                TextField("OAuth Client ID", text: $gcalClientId)
                    .textFieldStyle(.roundedBorder).font(Theme.Fonts.meta)
                SecureField("OAuth Client Secret", text: $gcalClientSecret)
                    .textFieldStyle(.roundedBorder).font(Theme.Fonts.meta)
                if case .failed(let msg) = calendar.state {
                    Text(msg).font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.error)
                }
                Button("Connect") {
                    Task {
                        await calendar.connect(
                            credentials: .init(clientId: gcalClientId, clientSecret: gcalClientSecret))
                    }
                }
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.accent)
                .buttonStyle(.plain)
                .disabled(gcalClientId.isEmpty || gcalClientSecret.isEmpty)

            case .connecting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Google… approve in your browser.")
                        .font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.textTertiary)
                }

            case .connected:
                if let synced = calendar.lastSynced {
                    Text("Last synced \(synced.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.textTertiary)
                }
                HStack(spacing: 14) {
                    Button("Refresh now") { Task { await calendar.fetch() } }
                        .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.accent).buttonStyle(.plain)
                    Button("Disconnect", role: .destructive) { calendar.disconnect() }
                        .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.error).buttonStyle(.plain)
                }
            }
        }
        .onAppear {
            if let creds = calendar.savedCredentials() {
                gcalClientId = creds.clientId
                gcalClientSecret = creds.clientSecret
            }
        }
    }
}

import SwiftUI

/// GMAIL inbox connection + polling config (ADR-0012). Credentials live in the
/// Keychain (its own service, separate from Calendar); non-secret settings in
/// `GmailSettingsStore`. Sending/archiving never happens from here — those are
/// explicit per-card actions in the Agent console.
struct GmailSettingsView: View {
    @Environment(GmailService.self) private var gmail
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var settings = GmailSettingsStore.load()
    @State private var labels: [GmailLabel] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("GMAIL")
                    .font(Theme.Fonts.sectionHeader).tracking(0.06)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                if case .connected = gmail.state {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Palette.done)
                }
            }

            switch gmail.state {
            case .disconnected, .failed:
                TextField("OAuth Client ID", text: $clientId)
                    .textFieldStyle(.roundedBorder).font(Theme.Fonts.meta)
                SecureField("OAuth Client Secret", text: $clientSecret)
                    .textFieldStyle(.roundedBorder).font(Theme.Fonts.meta)
                if case .failed(let msg) = gmail.state {
                    Text(msg).font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.error)
                }
                Button("Connect") {
                    Task {
                        await gmail.connect(
                            credentials: .init(clientId: clientId, clientSecret: clientSecret))
                    }
                }
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.accent)
                .buttonStyle(.plain)
                .disabled(clientId.isEmpty || clientSecret.isEmpty)

            case .connecting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Google… approve in your browser.")
                        .font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.textTertiary)
                }

            case .connected:
                Toggle("Poll inbox for new mail", isOn: $settings.enabled)
                    .font(Theme.Fonts.meta)
                    .toggleStyle(.switch).controlSize(.small)
                HStack(spacing: 8) {
                    Text("Label").font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textSecondary)
                    Picker("", selection: $settings.labelId) {
                        if !labels.contains(where: { $0.id == settings.labelId }) {
                            Text(settings.labelId).tag(settings.labelId)
                        }
                        ForEach(labels, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                    Stepper(value: $settings.pollIntervalMinutes, in: 1...60, step: 1) {
                        Text("Every \(Int(settings.pollIntervalMinutes)) min")
                            .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                HStack(spacing: 14) {
                    Button("Poll now") {
                        Task {
                            await gmail.poll(projects: GmailTriage.routes(
                                from: SourceSettingsStore.loadOrMigrate()))
                        }
                    }
                    .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.accent).buttonStyle(.plain)
                    Button("Disconnect", role: .destructive) { gmail.disconnect() }
                        .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.error).buttonStyle(.plain)
                }
                if let summary = gmail.lastPollSummary {
                    Text(summary).font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.textTertiary)
                }
            }
        }
        .onAppear {
            if let creds = gmail.savedCredentials() {
                clientId = creds.clientId
                clientSecret = creds.clientSecret
            }
            settings = GmailSettingsStore.load()
        }
        .onChange(of: settings) { GmailSettingsStore.save(settings) }
        .task(id: gmail.state == .connected) {
            if gmail.state == .connected { labels = await gmail.labels() }
        }
    }
}

import SwiftData
import SwiftUI

@main
struct LineyApp: App {
    @AppStorage("liney.hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            RootView(hasCompletedOnboarding: $hasCompletedOnboarding)
                .tint(.lineyAqua)
        }
        .modelContainer(for: [JournalEntry.self, EntryBlock.self])
    }
}

private struct RootView: View {
    @Binding var hasCompletedOnboarding: Bool

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                TimelineShellView()
            } else {
                OnboardingView {
                    hasCompletedOnboarding = true
                }
            }
        }
    }
}

private struct OnboardingView: View {
    let startWriting: () -> Void
    @State private var placeholderAction: PlaceholderAction?

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 28) {
                        Spacer()

                        Image(systemName: "book.closed")
                            .font(.system(size: 56, weight: .regular))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)

                        VStack(spacing: 12) {
                            Text("Liney")
                                .font(.largeTitle.bold())

                            Text("A light journal for words and photos.")
                                .font(.title3)
                                .foregroundStyle(.secondary)

                            Text("Your journal stays on this device. No account, no server, no ads, and no analytics.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        VStack(spacing: 12) {
                            Button(action: startWriting) {
                                Label("Start Writing", systemImage: "square.and.pencil")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                placeholderAction = .importJournal
                            } label: {
                                Label("Import Journal", systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }

                        Spacer()
                    }
                    .padding(32)
                    .frame(maxWidth: 440)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                }
            }
            .navigationTitle("Liney")
            .navigationBarTitleDisplayMode(.inline)
            .alert(item: $placeholderAction) { action in
                action.alert
            }
        }
    }
}

enum PlaceholderAction: String, Identifiable {
    case importJournal
    case exportJournal
    case settings

    var id: String { rawValue }

    var alert: Alert {
        switch self {
        case .importJournal:
            Alert(
                title: Text("Import Journal"),
                message: Text("Day One import will be added in a later MVP slice."),
                dismissButton: .default(Text("OK"))
            )
        case .exportJournal:
            Alert(
                title: Text("Export Journal"),
                message: Text("Markdown export will be added in a later MVP slice."),
                dismissButton: .default(Text("OK"))
            )
        case .settings:
            Alert(
                title: Text("Settings"),
                message: Text("Settings will be added in a later MVP slice."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

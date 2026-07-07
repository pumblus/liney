import LocalAuthentication
import SwiftData
import SwiftUI

@main
struct LineyApp: App {
    @AppStorage("liney.hasCompletedOnboarding") private var hasCompletedOnboarding = false

    init() {
        JournalExporter().deleteTemporaryExports()
    }

    var body: some Scene {
        WindowGroup {
            RootView(hasCompletedOnboarding: $hasCompletedOnboarding)
                .tint(.lineyAqua)
        }
        .modelContainer(for: [JournalEntry.self, EntryBlock.self, EntryPhoto.self])
    }
}

private struct RootView: View {
    @Binding var hasCompletedOnboarding: Bool
    @AppStorage("liney.requiresAppLock") private var requiresAppLock = false
    @StateObject private var appLock = AppLockModel()

    var body: some View {
        AppLockGate(requiresAppLock: $requiresAppLock, appLock: appLock) {
            if hasCompletedOnboarding {
                TimelineShellView(requiresAppLock: $requiresAppLock, appLock: appLock)
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
    @State private var isImportingJournal = false

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
                                isImportingJournal = true
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
            .background {
                ImportJournalFlow(isPresented: $isImportingJournal, onFinished: startWriting)
            }
        }
    }
}

protocol AppAuthenticating {
    func authenticate(reason: String) async -> Bool
}

struct LocalAuthenticator: AppAuthenticating {
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

@MainActor
final class AppLockModel: ObservableObject {
    @Published private(set) var isLocked = true
    @Published private(set) var isSnapshotCovered = true
    @Published private(set) var isAuthenticating = false

    private let authenticator: AppAuthenticating

    init(authenticator: AppAuthenticating = LocalAuthenticator()) {
        self.authenticator = authenticator
    }

    var hidesJournalContent: Bool {
        isLocked || isSnapshotCovered
    }

    func unlockIfNeeded(requiresLock: Bool) async {
        guard requiresLock else {
            disableLock()
            return
        }
        isSnapshotCovered = false
        guard isLocked, !isAuthenticating else { return }
        _ = await authenticate(reason: String(localized: "Unlock Liney to view your journal."))
    }

    func unlock(requiresLock: Bool) async {
        guard requiresLock else {
            disableLock()
            return
        }
        isLocked = true
        isSnapshotCovered = false
        guard !isAuthenticating else { return }
        _ = await authenticate(reason: String(localized: "Unlock Liney to view your journal."))
    }

    func protectSnapshot(requiresLock: Bool) {
        guard requiresLock else {
            disableLock()
            return
        }
        isLocked = true
        isSnapshotCovered = true
    }

    func authenticateForExport(requiresLock: Bool) async -> Bool {
        guard requiresLock else {
            disableLock()
            return true
        }
        guard !isAuthenticating else { return false }
        return await authenticate(reason: String(localized: "Authenticate to export your journal."))
    }

    func authenticateToEnable() async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let success = await authenticator.authenticate(
            reason: String(localized: "Authenticate to require Face ID for Liney.")
        )
        if success {
            isLocked = false
            isSnapshotCovered = false
        }
        return success
    }

    func disableLock() {
        isLocked = false
        isSnapshotCovered = false
    }

    private func authenticate(reason: String) async -> Bool {
        isAuthenticating = true
        defer { isAuthenticating = false }

        let success = await authenticator.authenticate(reason: reason)
        isLocked = !success
        isSnapshotCovered = false
        return success
    }
}

struct AppLockGate<Content: View>: View {
    @Binding private var requiresAppLock: Bool
    @ObservedObject private var appLock: AppLockModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasMountedUnlockedContent = false
    private let content: () -> Content

    init(
        requiresAppLock: Binding<Bool>,
        appLock: AppLockModel,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self._requiresAppLock = requiresAppLock
        self._appLock = ObservedObject(wrappedValue: appLock)
        self.content = content
    }

    var body: some View {
        Group {
            if shouldMountContent {
                content()
                    .privacySensitive(requiresAppLock)
                    .disabled(shouldHideContent)
                    .accessibilityHidden(shouldHideContent)
                    .overlay {
                        if shouldHideContent {
                            lockCover
                        }
                    }
            } else {
                lockCover
            }
        }
        .onAppear {
            rememberUnlockedContent()
            Task {
                await appLock.unlockIfNeeded(requiresLock: requiresAppLock)
            }
        }
        .onChange(of: shouldHideContent) { _, _ in
            rememberUnlockedContent()
        }
        .onChange(of: requiresAppLock) { _, requiresAppLock in
            if requiresAppLock {
                Task {
                    await appLock.unlockIfNeeded(requiresLock: true)
                }
            } else {
                appLock.disableLock()
            }
        }
        .onChange(of: scenePhase) { _, scenePhase in
            switch scenePhase {
            case .active:
                Task {
                    await appLock.unlockIfNeeded(requiresLock: requiresAppLock)
                }
            case .background, .inactive:
                appLock.protectSnapshot(requiresLock: requiresAppLock)
            @unknown default:
                break
            }
        }
    }

    private var shouldHideContent: Bool {
        requiresAppLock && appLock.hidesJournalContent
    }

    private var shouldMountContent: Bool {
        !shouldHideContent || hasMountedUnlockedContent
    }

    private var lockCover: some View {
        LockedJournalView(isAuthenticating: appLock.isAuthenticating) {
            Task {
                await appLock.unlock(requiresLock: requiresAppLock)
            }
        }
    }

    private func rememberUnlockedContent() {
        if !shouldHideContent {
            hasMountedUnlockedContent = true
        }
    }
}

private struct LockedJournalView: View {
    let isAuthenticating: Bool
    let unlock: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Liney Locked")
                    .font(.title2.bold())

                Text("Unlock to view your private journal.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: unlock) {
                Label("Unlock", systemImage: "lock.open")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAuthenticating)

            if isAuthenticating {
                ProgressView()
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

struct SettingsView: View {
    @Binding var requiresAppLock: Bool
    @ObservedObject var appLock: AppLockModel
    @Environment(\.dismiss) private var dismiss
    @State private var alert: SettingsAlert?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: appLockBinding) {
                        Label("Require Face ID", systemImage: "faceid")
                    }
                    .disabled(appLock.isAuthenticating)
                } footer: {
                    Text("Use Face ID, Touch ID, or your device passcode to protect Liney.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert(item: $alert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private var appLockBinding: Binding<Bool> {
        Binding(
            get: { requiresAppLock },
            set: { newValue in
                if newValue {
                    Task {
                        if await appLock.authenticateToEnable() {
                            requiresAppLock = true
                        } else {
                            alert = SettingsAlert(
                                title: String(localized: "Could Not Enable App Lock"),
                                message: String(localized: "Face ID or device passcode authentication was not completed.")
                            )
                        }
                    }
                } else {
                    requiresAppLock = false
                    appLock.disableLock()
                }
            }
        )
    }
}

private struct SettingsAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

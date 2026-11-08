import SwiftUI

struct PasskeySettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var passkeys: [AccountPasskey] = []
    @State private var isLoading = true
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var pendingDeletion: AccountPasskey?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Sign in using Face ID, Touch ID, or your device passcode. Your password still works too.")
                    .font(AppTypography.rowSubtitle)
                    .foregroundStyle(AppTheme.softText)

                NightPanel(cornerRadius: AppLayout.panelRadius, padding: 18) {
                    VStack(alignment: .leading, spacing: 18) {
                        if isLoading {
                            ProgressView("Loading passkeys…").tint(.white)
                        } else if passkeys.isEmpty {
                            Text("You haven't added a passkey yet.")
                                .foregroundStyle(AppTheme.softText)
                        } else {
                            ForEach(passkeys) { passkey in
                                HStack(spacing: 12) {
                                    Image(systemName: "person.badge.key.fill")
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(passkey.displayName).font(AppTypography.rowTitle)
                                        Text("Added \(passkey.created_at.formatted(date: .abbreviated, time: .omitted))")
                                            .font(AppTypography.rowSubtitle)
                                            .foregroundStyle(AppTheme.softText)
                                    }
                                    Spacer()
                                    Button(role: .destructive) { pendingDeletion = passkey } label: {
                                        Image(systemName: "trash")
                                    }
                                    .accessibilityLabel("Remove \(passkey.displayName)")
                                    .disabled(isBusy)
                                }
                                .foregroundStyle(.white)
                            }
                        }

                        Button {
                            Task { await addPasskey() }
                        } label: {
                            Label(isBusy ? "Please wait…" : "Add a Passkey", systemImage: "plus")
                                .frame(maxWidth: .infinity).frame(height: 48)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(isBusy || isLoading)
                    }
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(Color(hex: "#F2B0A7"))
                }
                if let successMessage {
                    Text(successMessage).foregroundStyle(AppTheme.softText)
                }
            }
            .padding(AppLayout.screenPadding)
        }
        .background(AmbientBackground())
        .appSecondaryPageNavigation(title: "Passkeys")
        .task { await reload() }
        .confirmationDialog("Remove this passkey?", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible) {
            if let passkey = pendingDeletion {
                Button("Remove Passkey", role: .destructive) {
                    Task { await removePasskey(passkey) }
                }
            }
        } message: {
            Text("You can still sign in with your username or email and password.")
        }
    }

    private func reload() async {
        defer { isLoading = false }
        do { passkeys = try await store.listPasskeys() }
        catch { errorMessage = error.localizedDescription }
    }

    private func addPasskey() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        successMessage = nil
        defer { isBusy = false }
        do {
            try await store.registerPasskey()
            successMessage = "Passkey added. You can use it the next time you sign in."
            await reload()
        } catch PasskeyError.cancelled {
        } catch { errorMessage = error.localizedDescription }
    }

    private func removePasskey(_ passkey: AccountPasskey) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        successMessage = nil
        defer { isBusy = false; pendingDeletion = nil }
        do {
            try await store.deletePasskey(id: passkey.id)
            passkeys.removeAll { $0.id == passkey.id }
            successMessage = "Passkey removed."
        } catch { errorMessage = error.localizedDescription }
    }
}

import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Shared by People and onboarding so invitations never require an existing friend.
struct SocialInviteActions: View {
    @Environment(AppStore.self) private var store
    @State private var isSharing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { isSharing = true } label: {
                    Label("Invite friends", systemImage: "qrcode")
                        .font(AppTypography.button)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.glass)
                .tint(.white)
                .accessibilityIdentifier("friends.invite.share")

                Button {
                    store.isSocialInvitePresented = true
                } label: {
                    Label("Use code", systemImage: "link")
                        .font(AppTypography.button)
                        .frame(minHeight: 48)
                }
                .buttonStyle(.glass)
                .tint(.white)
                .accessibilityIdentifier("friends.invite.redeem")
            }
            if store.pendingSocialInviteCode != nil {
                Button {
                    store.isSocialInvitePresented = true
                } label: {
                    Label("Continue your invite", systemImage: "person.crop.circle.badge.plus")
                        .font(AppTypography.button)
                }
                .foregroundStyle(.white)
            }
        }
        .sheet(isPresented: $isSharing) {
            ShareSocialInviteView()
                .presentationDetents([.large])
                .appSheetDragHandle()
        }
        #if DEBUG
        .task {
            if store.isLayoutPreview, ProcessInfo.processInfo.arguments.contains("--social-invite-preview") {
                isSharing = true
            }
        }
        #endif
    }
}

struct ShareSocialInviteView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var groupID: UUID? = nil
    @State private var invite: SocialInvite?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text(groupID == nil ? "Get your friends on Out Again" : "Bring your friends into the group")
                            .font(AppTypography.sheetTitle)
                        Text("Share your drinks. Keep up with each other’s nights.")
                            .font(AppTypography.rowSubtitle)
                            .foregroundStyle(AppTheme.softText)
                    }
                    .multilineTextAlignment(.center)
                    if let invite {
                        if let qr = InviteQRCode.image(for: invite.url) {
                            Image(uiImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 236)
                                .padding(20)
                                .background(.white, in: RoundedRectangle(cornerRadius: 28))
                                .accessibilityLabel("Invite QR code for \(invite.inviterName)")
                        }
                        VStack(spacing: 4) {
                            Text(invite.inviterName).font(AppTypography.rowTitle)
                            Text("@\(invite.inviterUsername)")
                                .font(AppTypography.rowSubtitle)
                                .foregroundStyle(AppTheme.softText)
                            if let name = invite.groupName, !name.isEmpty {
                                Text(name).font(AppTypography.button)
                            }
                        }
                        ShareLink(item: invite.url,
                                  subject: Text("Join me on Out Again"),
                                  message: Text("Post what you’re drinking with me on Out Again.")) {
                            Label("Share invite", systemImage: "square.and.arrow.up")
                                .font(AppTypography.button)
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("friends.invite.share-link")
                        Button {
                            UIPasteboard.general.string = invite.url.absoluteString
                            copied = true
                        } label: {
                            Label(copied ? "Link copied" : "Copy invite link", systemImage: copied ? "checkmark" : "link")
                                .font(AppTypography.button)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.glass)
                        Text("Invite expires \(invite.expiresAt.formatted(date: .abbreviated, time: .omitted)). Friends can open the link again after installing, or paste it in People → Use code.")
                            .font(AppTypography.footnote)
                            .foregroundStyle(AppTheme.softText)
                            .multilineTextAlignment(.center)
                    } else if isLoading {
                        ProgressView("Creating your invite…").padding(40)
                    } else if let errorMessage {
                        Text(errorMessage).foregroundStyle(AppTheme.softText)
                        Button("Try again") { Task { await loadInvite() } }.buttonStyle(.glass)
                    }
                }
                .padding(24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .background(AmbientBackground())
            .navigationTitle("Invite friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .task { await loadInvite() }
    }

    private func loadInvite() async {
        guard !isLoading, invite == nil, let accountID = store.viewer?.id else { return }
        #if DEBUG
        if store.isLayoutPreview, ProcessInfo.processInfo.arguments.contains("--social-invite-preview") {
            invite = SocialInvite(token: "0123456789abcdef0123456789abcdef", inviterID: accountID,
                                  inviterName: "Preview User", inviterUsername: "preview",
                                  groupID: groupID, groupName: nil, expiresAt: .now.addingTimeInterval(2_592_000))
            return
        }
        #endif
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await store.backend.createSocialInvite(groupID: groupID)
            guard !Task.isCancelled, store.viewer?.id == accountID else { return }
            invite = result
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription.lowercased().contains("night has ended")
                ? "This group’s night has ended. Create a new group for tonight."
                : "Couldn’t create an invite. Check your connection and try again."
        }
    }
}

struct RedeemSocialInviteView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var invite: SocialInvite?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var acceptance: SocialInviteAcceptance?
    @State private var requestID = UUID()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let acceptance {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48)).foregroundStyle(.green)
                        Text(acceptance.friendshipStatus == "accepted" ? "You’re connected" : "Friend request sent")
                            .font(AppTypography.sheetTitle)
                        Text(acceptance.groupID == nil
                             ? "You’ll see each other’s posts once you’re friends."
                             : "You’ve joined the group. Members’ posts stay friends-only, so add each other to see them.")
                            .font(AppTypography.body).foregroundStyle(AppTheme.softText)
                        Button("Done") { dismiss() }.buttonStyle(.glassProminent)
                    } else {
                        Text("Join your friends")
                            .font(AppTypography.sheetTitle)
                        Text("Paste an Out Again invite link or code.")
                            .font(AppTypography.rowSubtitle).foregroundStyle(AppTheme.softText)
                        TextField("Invite link or code", text: $input, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(AppTypography.body)
                            .padding(16)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                            .accessibilityIdentifier("friends.invite.code")
                            .onChange(of: input) { _, _ in invite = nil; errorMessage = nil }
                        if let invite {
                            NightPanel(cornerRadius: 28, padding: 20) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(invite.inviterName).font(AppTypography.rowTitle)
                                    Text("@\(invite.inviterUsername)").foregroundStyle(AppTheme.softText)
                                    if let name = invite.groupName {
                                        Text(name.isEmpty ? "Join their group" : "Join \(name)").font(AppTypography.button)
                                    }
                                    Text(invite.groupID == nil
                                         ? "Accepting sends a friend request, or accepts one they already sent you."
                                         : "Accepting joins this group and sends its creator a friend request. Only friends can see each other’s posts.")
                                        .font(AppTypography.rowSubtitle).foregroundStyle(AppTheme.softText)
                                    if invite.inviterID == store.viewer?.id {
                                        Text("This is your invite. Share it with a friend.")
                                            .font(AppTypography.button)
                                    }
                                }
                            }
                            Button { Task { await acceptInvite() } } label: {
                                HStack {
                                    if isWorking { ProgressView() }
                                    Text(invite.groupID == nil ? "Accept invite" : "Join group")
                                }.frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(isWorking || store.viewer == nil || invite.inviterID == store.viewer?.id)
                            .accessibilityIdentifier("friends.invite.accept")
                        } else {
                            Button { Task { await resolveInvite() } } label: {
                                HStack {
                                    if isWorking { ProgressView() }
                                    Text("Find invite")
                                }.frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(isWorking || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if let errorMessage {
                            Text(errorMessage).font(AppTypography.rowSubtitle).foregroundStyle(AppTheme.softText)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .background(AmbientBackground())
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .task(id: store.pendingSocialInviteCode) {
            if let code = store.pendingSocialInviteCode {
                acceptance = nil
                invite = nil
                input = code
                await resolveInvite()
            }
        }
    }

    private func resolveInvite() async {
        guard let accountID = store.viewer?.id else { return }
        guard let code = SocialInviteCode.normalized(input) else {
            errorMessage = "That doesn’t look like an Out Again invite. Paste the full link your friend shared."
            return
        }
        let operation = UUID()
        requestID = operation
        isWorking = true
        errorMessage = nil
        defer { if requestID == operation { isWorking = false } }
        do {
            let result = try await store.backend.resolveSocialInvite(token: code)
            guard !Task.isCancelled, requestID == operation, store.viewer?.id == accountID,
                  code == SocialInviteCode.normalized(input) else { return }
            invite = result
        } catch {
            guard !Task.isCancelled, requestID == operation, store.viewer?.id == accountID,
                  code == SocialInviteCode.normalized(input) else { return }
            errorMessage = "This invite may have expired or is no longer available. Check your connection or ask your friend for a new link."
        }
    }

    private func acceptInvite() async {
        guard !isWorking, let invite, let accountID = store.viewer?.id else { return }
        let operation = UUID()
        requestID = operation
        isWorking = true
        errorMessage = nil
        defer { if requestID == operation { isWorking = false } }
        do {
            let result = try await store.backend.acceptSocialInvite(token: invite.token)
            guard !Task.isCancelled, requestID == operation, store.viewer?.id == accountID,
                  invite.token == SocialInviteCode.normalized(input) else { return }
            acceptance = result
            store.clearPendingSocialInvite(matching: invite.token)
            await store.refreshAppData(silenceErrors: true)
            await store.syncGroupsFromBackend()
        } catch {
            guard !Task.isCancelled else { return }
            guard requestID == operation, store.viewer?.id == accountID,
                  invite.token == SocialInviteCode.normalized(input) else { return }
            errorMessage = "Couldn’t accept this invite. Please try again."
        }
    }
}

private enum InviteQRCode {
    static func image(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

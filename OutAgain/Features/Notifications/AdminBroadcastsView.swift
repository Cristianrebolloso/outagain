import SwiftUI

enum AdminBroadcastSection: Hashable {
    case all
    case maintenance
    case notifications

    var title: String {
        switch self {
        case .all:
            return "Broadcasts"
        case .maintenance:
            return "Maintenance"
        case .notifications:
            return "Notifications"
        }
    }

    var symbol: String {
        switch self {
        case .all:
            return "megaphone.fill"
        case .maintenance:
            return "wrench.and.screwdriver.fill"
        case .notifications:
            return "bell.badge.fill"
        }
    }

    var showsMaintenance: Bool {
        self == .all || self == .maintenance
    }

    var showsNotifications: Bool {
        self == .all || self == .notifications
    }
}

struct AdminBroadcastsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    let section: AdminBroadcastSection

    @State private var maintenanceEnabled = false
    @State private var maintenanceTitle = ""
    @State private var maintenanceMessage = ""
    @State private var announcementTitle = ""
    @State private var announcementMessage = ""
    @State private var announcementAudience: AppAnnouncementAudience = .all
    @State private var announcementDelivery: AppAnnouncementDelivery = .inApp
    @State private var announcementRequestID = UUID()
    @State private var targetUsernames = ""
    @State private var isSavingMaintenance = false
    @State private var isSendingAnnouncement = false
    @State private var removingAnnouncementIDs: Set<UUID> = []
    @State private var status: AdminBroadcastStatus?
    @State private var isConfirmingSendAnnouncement = false
    @State private var announcementPendingRemoval: AdminAppAnnouncement?
    @FocusState private var focusedField: AdminBroadcastField?

    init(section: AdminBroadcastSection = .all) {
        self.section = section
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !store.isDuoDevice { header }

                if let status {
                    statusBanner(status)
                }

                if section.showsMaintenance {
                    maintenancePanel
                }

                if section.showsNotifications {
                    announcementPanel
                    latestAnnouncementsPanel
                }
            }
            .padding(.horizontal, AppLayout.screenPadding)
            .padding(.top, store.isDuoDevice ? AppLayout.secondaryPageTopPadding : 12)
            .padding(.bottom, AppLayout.tabBarClearance)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.always, axes: .vertical)
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .modifier(DuoPageHeader(title: section.title))
        .background {
            AmbientBackground()
                .ignoresSafeArea()
        }
        .glassPullToRefresh {
            await refreshAdminData()
        }
        .task {
            await refreshAdminData()
        }
        .onChange(of: [announcementTitle, announcementMessage, targetUsernames, announcementAudience.rawValue, announcementDelivery.rawValue]) { _, _ in
            announcementRequestID = UUID()
        }
        .onChange(of: store.appConfig) { _, _ in
            guard !isSavingMaintenance else { return }
            syncMaintenanceDraftsFromStore()
        }
        .task(id: store.adminTabSelectionTrigger) {
            guard store.selectedTab == .admin,
                  store.adminTabSelectionTrigger > 0
            else { return }

            await refreshAdminData()
        }
        .task(id: store.activityTabSelectionTrigger) {
            guard store.selectedTab == .activity,
                  store.isViewerAdmin,
                  store.activityTabSelectionTrigger > 0
            else { return }

            await refreshAdminData()
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()

                Button("Done") {
                    focusedField = nil
                }
                .font(AppTypography.button)
            }
        }
        .alert(
            "Send this notification?",
            isPresented: $isConfirmingSendAnnouncement,
            actions: {
            Button("Send Notification") {
                Task { await sendAnnouncement() }
            }
            Button("Cancel", role: .cancel) {}
                .tint(.blue)
        }, message: {
            Text("This sends \"\(trimmedAnnouncementTitle)\" to \(announcementAudienceConfirmationText). \(announcementDelivery.explanation)\(announcementDelivery.includesPush ? " Push notifications cannot be recalled once sent." : "")")
        })
        .alert(
            "Remove this notification?",
            isPresented: announcementRemovalConfirmationBinding,
            presenting: announcementPendingRemoval
        ) { announcement in
            Button("Remove Notification", role: .destructive) {
                announcementPendingRemoval = nil
                Task { await removeAnnouncement(announcement) }
            }
            Button("Cancel", role: .cancel) {
                announcementPendingRemoval = nil
            }
            .tint(.blue)
        } message: { announcement in
            Text("This removes the in-app pop-up for \"\(announcement.title)\".\(announcement.delivery.includesPush ? " Push notifications already sent to phones cannot be recalled." : "")")
        }
    }

    private func refreshAdminData() async {
        if section.showsMaintenance {
            await store.refreshAppConfigOnly()
        }

        if section.showsNotifications {
            await store.loadAdminAppAnnouncements()
        }

        syncMaintenanceDraftsFromStore()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(section.title)
                .font(AppTypography.pageTitle)
                .foregroundStyle(.white)

            Spacer()

            Label("@admin", systemImage: section.symbol)
                .font(AppTypography.caption2Emphasis)
                .foregroundStyle(AppTheme.softText)
                .labelStyle(.titleAndIcon)
        }
    }

    private var maintenancePanel: some View {
        NightPanel(cornerRadius: AppLayout.panelRadius, padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    panelIcon("wrench.and.screwdriver.fill")

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Maintenance Mode")
                            .font(AppTypography.sectionTitle)
                            .foregroundStyle(.white)
                        Text(maintenanceEnabled ? "On for non-admin users" : "Off")
                            .font(AppTypography.rowSubtitle)
                            .foregroundStyle(maintenanceEnabled ? Color(hex: "#FFD166") : AppTheme.softText)
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { maintenanceEnabled },
                        set: { newValue in
                            // Flip locally for instant UI feedback, then push the
                            // change to the backend. The custom Binding setter
                            // only fires on user interaction, so store-driven
                            // syncs (via syncMaintenanceDraftsFromStore) don't
                            // re-trigger a save.
                            maintenanceEnabled = newValue
                            Task { await applyMaintenanceToggle(to: newValue) }
                        }
                    ))
                        .labelsHidden()
                        .tint(accent)
                        .disabled(isSavingMaintenance)
                }

                adminTextField("Screen title", text: $maintenanceTitle, field: .maintenanceTitle)
                adminTextEditor("Screen message", text: $maintenanceMessage, field: .maintenanceMessage, minHeight: 112)

                Button {
                    Task { await saveMaintenance() }
                } label: {
                    actionLabel(
                        title: isSavingMaintenance ? "Saving" : "Save Maintenance",
                        symbol: "checkmark.circle.fill",
                        isLoading: isSavingMaintenance
                    )
                }
                .buttonStyle(.glassProminent)
                .tint(accent)
                .disabled(!canSaveMaintenance)
                .opacity(canSaveMaintenance ? 1 : 0.55)
            }
        }
    }

    private var announcementPanel: some View {
        NightPanel(cornerRadius: AppLayout.panelRadius, padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    panelIcon("bell.badge.fill")

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Custom Announcement")
                            .font(AppTypography.sectionTitle)
                            .foregroundStyle(.white)
                        Text(announcementAudience.adminSummary)
                            .font(AppTypography.rowSubtitle)
                            .foregroundStyle(AppTheme.softText)
                    }
                }

                Picker("Delivery", selection: $announcementDelivery) {
                    ForEach(AppAnnouncementDelivery.allCases) { delivery in
                        Text(delivery.title).tag(delivery)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("admin.announcement.delivery")

                Text(announcementDelivery.explanation)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppTheme.softText)

                audienceSelector

                if announcementAudience == .selected {
                    adminTextField("Usernames, e.g. @cristian, @maddie", text: $targetUsernames, field: .announcementTargets)
                }

                adminTextField("Notification title", text: $announcementTitle, field: .announcementTitle)
                adminTextEditor("Notification message", text: $announcementMessage, field: .announcementMessage, minHeight: 132)

                if announcementDelivery.includesPush {
                    Text("Title: \(trimmedAnnouncementTitle.unicodeScalars.count)/100 · Message: \(trimmedAnnouncementMessage.unicodeScalars.count)/500")
                        .font(AppTypography.caption)
                        .foregroundStyle(pushTextWithinLimits ? AppTheme.softText : Color(hex: "#FF6B6B"))
                }

                Button {
                    focusedField = nil
                    isConfirmingSendAnnouncement = true
                } label: {
                    actionLabel(
                        title: isSendingAnnouncement ? "Sending" : "Send Notification",
                        symbol: "paperplane.fill",
                        isLoading: isSendingAnnouncement
                    )
                }
                .buttonStyle(.glassProminent)
                .tint(accent)
                .disabled(!canSendAnnouncement)
                .opacity(canSendAnnouncement ? 1 : 0.55)
            }
            .disabled(isSendingAnnouncement)
        }
    }

    private var audienceSelector: some View {
        Picker("Notification audience", selection: $announcementAudience) {
            ForEach(AppAnnouncementAudience.allCases) { audience in
                Text(audience.title)
                    .tag(audience)
            }
        }
        .pickerStyle(.segmented)
        .tint(accent)
    }

    private var latestAnnouncementsPanel: some View {
        NightPanel(cornerRadius: AppLayout.panelRadius, padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    panelIcon("clock.arrow.circlepath")

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Latest Notifications")
                            .font(AppTypography.sectionTitle)
                            .foregroundStyle(.white)
                        Text("Delivery history and active in-app pop-ups")
                            .font(AppTypography.rowSubtitle)
                            .foregroundStyle(AppTheme.softText)
                    }

                    Spacer()

                    if store.isLoadingAdminAppAnnouncements {
                        ProgressView()
                            .tint(accent)
                    } else {
                        Button {
                            Task { await store.loadAdminAppAnnouncements() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Refresh latest notifications")
                    }
                }

                if store.adminAppAnnouncements.isEmpty {
                    Text("No app-wide notifications yet.")
                        .font(AppTypography.rowSubtitle)
                        .foregroundStyle(AppTheme.softText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 10) {
                        ForEach(store.adminAppAnnouncements) { announcement in
                            latestAnnouncementRow(announcement)
                        }
                    }
                }
            }
        }
    }

    private func latestAnnouncementRow(_ announcement: AdminAppAnnouncement) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(announcement.title)
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Text("\(announcement.delivery.title) · \(announcement.audienceDescription)")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppTheme.softText)
                        .lineLimit(2)
                }

                Spacer()

                Text(announcement.delivery == .push ? "Push" : (announcement.isActive ? "Active" : "Removed"))
                    .font(AppTypography.caption2Emphasis)
                    .foregroundStyle(announcement.isActive ? AppTheme.activeGreen : AppTheme.softText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.06), in: Capsule())
            }

            Text(announcement.message)
                .font(AppTypography.rowSubtitle)
                .foregroundStyle(AppTheme.softText)
                .lineLimit(3)

            if announcement.delivery.includesPush {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(announcement.pushRecipientCount) accounts queued · \(announcement.pushAcceptedCount) devices accepted by Apple")
                    Text("\(announcement.pushPendingCount) pending · \(announcement.pushSkippedCount) skipped · \(announcement.pushFailureCount) failed")
                }
                .font(AppTypography.caption)
                .foregroundStyle(AppTheme.softText)
            }

            HStack(spacing: 10) {
                Text("\(announcement.recipientCount) recipients")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppTheme.softText)

                Text(announcement.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppTheme.softText)

                Spacer()

                if announcement.isActive && announcement.delivery.includesInApp {
                    Button {
                        announcementPendingRemoval = announcement
                    } label: {
                        if removingAnnouncementIDs.contains(announcement.id) {
                            ProgressView()
                                .tint(Color(hex: "#FF6B6B"))
                                .controlSize(.small)
                        } else {
                            Label("Remove", systemImage: "xmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .font(AppTypography.metadataEmphasis)
                    .buttonStyle(.glass)
                    .foregroundStyle(Color(hex: "#FF6B6B"))
                    .disabled(removingAnnouncementIDs.contains(announcement.id))
                }
            }
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppTheme.line, lineWidth: 1)
        )
    }

    private func panelIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(accent)
            .frame(width: 42, height: 42)
            .primaryGlass(in: .circle)
            .accessibilityHidden(true)
    }

    private func adminTextField(_ placeholder: String, text: Binding<String>, field: AdminBroadcastField) -> some View {
        TextField(placeholder, text: text)
            .font(AppTypography.formInput)
            .foregroundStyle(.white)
            .textInputAutocapitalization(.sentences)
            .autocorrectionDisabled(false)
            .focused($focusedField, equals: field)
            .submitLabel(.done)
            .onSubmit {
                focusedField = nil
            }
            .padding(14)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(AppTheme.line, lineWidth: 1)
            )
    }

    private func adminTextEditor(_ placeholder: String, text: Binding<String>, field: AdminBroadcastField, minHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(AppTypography.formInput)
                    .foregroundStyle(AppTheme.softText.opacity(0.72))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }

            TextEditor(text: text)
                .font(AppTypography.formInput)
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: minHeight)
                .focused($focusedField, equals: field)
        }
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppTheme.line, lineWidth: 1)
        )
    }

    private func actionLabel(title: String, symbol: String, isLoading: Bool) -> some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .tint(.white)
                    .controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
            }

            Text(title)
                .font(AppTypography.button)
        }
        .frame(maxWidth: .infinity)
    }

    private func statusBanner(_ status: AdminBroadcastStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: status.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(status.tint)

            Text(status.message)
                .font(AppTypography.footnoteMedium)
                .foregroundStyle(AppTheme.softText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(status.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(status.tint.opacity(0.22), lineWidth: 1)
        )
    }

    private var canSaveMaintenance: Bool {
        !isSavingMaintenance
            && !trimmedMaintenanceTitle.isEmpty
            && !trimmedMaintenanceMessage.isEmpty
    }

    private var canSendAnnouncement: Bool {
        !isSendingAnnouncement
            && !trimmedAnnouncementTitle.isEmpty
            && !trimmedAnnouncementMessage.isEmpty
            && (!announcementDelivery.includesPush || pushTextWithinLimits)
            && (announcementAudience != .selected || !parsedTargetUsernames.isEmpty)
    }

    private var pushTextWithinLimits: Bool {
        trimmedAnnouncementTitle.unicodeScalars.count <= 100
            && trimmedAnnouncementMessage.unicodeScalars.count <= 500
    }

    private var trimmedMaintenanceTitle: String {
        maintenanceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedMaintenanceMessage: String {
        maintenanceMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAnnouncementTitle: String {
        announcementTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAnnouncementMessage: String {
        announcementMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedTargetUsernames: [String] {
        targetUsernames
            .split { character in
                character == "," || character == " " || character == "\n" || character == "\t"
            }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "@")).lowercased() }
            .filter { !$0.isEmpty }
    }

    private var announcementAudienceConfirmationText: String {
        switch announcementAudience {
        case .all:
            return "all users"
        case .verified:
            return "verified users"
        case .selected:
            let count = parsedTargetUsernames.count
            return "\(count) selected \(count == 1 ? "user" : "users")"
        }
    }

    private var announcementRemovalConfirmationBinding: Binding<Bool> {
        Binding {
            announcementPendingRemoval != nil
        } set: { isPresented in
            if !isPresented {
                announcementPendingRemoval = nil
            }
        }
    }

    private func syncMaintenanceDraftsFromStore() {
        maintenanceEnabled = store.isMaintenanceModeActive
        maintenanceTitle = store.maintenanceTitle
        maintenanceMessage = store.maintenanceMessage
    }

    private func saveMaintenance() async {
        guard canSaveMaintenance else { return }

        focusedField = nil
        isSavingMaintenance = true
        status = nil
        defer { isSavingMaintenance = false }

        do {
            try await store.saveMaintenanceMode(
                enabled: maintenanceEnabled,
                title: trimmedMaintenanceTitle,
                message: trimmedMaintenanceMessage
            )
            syncMaintenanceDraftsFromStore()
            status = .success(maintenanceEnabled ? "Maintenance mode is on." : "Maintenance mode is off.")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    /// Pushes a toggle-driven enable/disable to the backend immediately,
    /// reusing whatever title/message are currently in the drafts (falling
    /// back to the stored values if the drafts haven't been seeded yet).
    /// Restores the toggle to the previous state if the save fails so the
    /// UI never lies about the real backend state.
    private func applyMaintenanceToggle(to enabled: Bool) async {
        focusedField = nil

        let titleToUse = trimmedMaintenanceTitle.isEmpty ? store.maintenanceTitle : trimmedMaintenanceTitle
        let messageToUse = trimmedMaintenanceMessage.isEmpty ? store.maintenanceMessage : trimmedMaintenanceMessage

        isSavingMaintenance = true
        status = nil
        defer { isSavingMaintenance = false }

        do {
            try await store.saveMaintenanceMode(
                enabled: enabled,
                title: titleToUse,
                message: messageToUse
            )
            syncMaintenanceDraftsFromStore()
            status = .success(enabled ? "Maintenance mode is on." : "Maintenance mode is off.")
        } catch {
            // Snap the toggle back so it reflects the real backend state.
            maintenanceEnabled = !enabled
            status = .failure(error.localizedDescription)
        }
    }

    private func sendAnnouncement() async {
        guard canSendAnnouncement else { return }

        focusedField = nil
        isSendingAnnouncement = true
        status = nil
        defer { isSendingAnnouncement = false }

        do {
            try await store.sendAppWideAnnouncement(
                requestID: announcementRequestID,
                title: trimmedAnnouncementTitle,
                message: trimmedAnnouncementMessage,
                audience: announcementAudience,
                targetUsernames: parsedTargetUsernames,
                delivery: announcementDelivery
            )
            announcementTitle = ""
            announcementMessage = ""
            targetUsernames = ""
            status = .success(announcementDelivery.includesPush
                ? "Announcement queued. Refresh the history to check push results."
                : "In-app notification sent.")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func removeAnnouncement(_ announcement: AdminAppAnnouncement) async {
        guard !removingAnnouncementIDs.contains(announcement.id) else { return }

        removingAnnouncementIDs.insert(announcement.id)
        status = nil
        defer { removingAnnouncementIDs.remove(announcement.id) }

        do {
            try await store.deactivateAdminAppAnnouncement(announcement)
            status = .success("In-app notification removed.")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }
}

private enum AdminBroadcastField: Hashable {
    case maintenanceTitle
    case maintenanceMessage
    case announcementTitle
    case announcementMessage
    case announcementTargets
}

private enum AdminBroadcastStatus: Equatable {
    case success(String)
    case failure(String)

    var message: String {
        switch self {
        case .success(let message), .failure(let message):
            return message
        }
    }

    var symbol: String {
        switch self {
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success:
            return AppTheme.activeGreen
        case .failure:
            return Color(hex: "#FF6B6B")
        }
    }
}

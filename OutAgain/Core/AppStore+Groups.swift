import Foundation

extension AppStore {

    // MARK: - Derived group data

    /// All posts by members of a given group that fall within the tonight window,
    /// sorted newest-first. Source of truth for the group feed and aggregate count.
    func groupPosts(for group: NightGroup) -> [MomentPost] {
        let memberSet = Set(group.memberIDs)
        return sortPostsByRecency(
            tonightActivitySourcePosts.filter { memberSet.contains($0.author.id) }
        )
    }

    func groupPostCount(for group: NightGroup) -> Int {
        groupPosts(for: group).count
    }

    func groupLastPostedAt(for group: NightGroup) -> Date? {
        groupPosts(for: group).first?.createdAt
    }

    /// Resolved member profiles sorted by tonight post count, highest first.
    /// Ties preserve the original memberIDs order (creator first among equals).
    func groupMembers(for group: NightGroup) -> [UserProfile] {
        let allKnown: [UserProfile] = [viewerIdentity] + friends
        let resolved = group.memberIDs.compactMap { id in
            allKnown.first(where: { $0.id == id })
        }
        let tonightPosts = groupPosts(for: group)
        return resolved.sorted { a, b in
            let aCount = tonightPosts.filter { $0.author.id == a.id }.count
            let bCount = tonightPosts.filter { $0.author.id == b.id }.count
            return aCount > bCount
        }
    }

    // MARK: - Mutations (optimistic + backend sync)

    /// Creates a group optimistically on the local store, then persists to
    /// the backend. On failure the group is removed and the error is surfaced.
    func createGroup(name: String, friendIDs: [UUID]) {
        guard let viewerID = viewer?.id else { return }
        let group = NightGroup(
            id: UUID(),
            name: name,
            creatorID: viewerID,
            memberIDs: [viewerID] + friendIDs,
            createdAt: .now
        )
        nightGroups.append(group)

        let creator = viewerIdentity
        Task {
            do {
                try await backend.createNightGroup(group)
                // Notify every member except the creator. The server's existing
                // APNs dispatch trigger fires on each inserted notification row,
                // so this single REST insert is all that's needed to deliver
                // the push to all added members.
                let recipientIDs = friendIDs.filter { $0 != viewerID }
                if !recipientIDs.isEmpty {
                    do {
                        try await backend.insertGroupNotifications(
                            group: group,
                            recipientIDs: recipientIDs,
                            creator: creator
                        )
                    } catch {
                        await MainActor.run {
                            socialErrorMessage = "Group created, but member notifications couldn't be sent."
                        }
                    }
                }
                await syncGroupsFromBackend()
            } catch {
                // Roll back the optimistic insert on failure.
                await MainActor.run {
                    nightGroups.removeAll { $0.id == group.id }
                    socialErrorMessage = "Couldn't create the group. Please try again."
                }
            }
        }
    }

    /// Saves edits (name + members) optimistically and syncs to backend.
    ///
    /// Routing logic:
    /// - If member_ids changed (new friends added): uses the `updateNightGroup`
    ///   RPC. The backend preserves existing members and rejects direct rewrites.
    /// - If only the name changed: uses `renameNightGroup` (name-only payload) to
    ///   keep the write surface minimal and avoid touching member_ids unnecessarily.
    ///
    /// After a successful write, `syncGroupsFromBackend` pulls the confirmed
    /// server value so the updated state propagates to all members immediately
    /// rather than waiting for the next background bootstrap.
    func saveGroupEdits(_ updated: NightGroup) async -> Bool {
        guard let idx = nightGroups.firstIndex(where: { $0.id == updated.id }) else { return false }
        let previous = nightGroups[idx]
        let membersChanged = Set(updated.memberIDs) != Set(previous.memberIDs)
        let addedMemberIDs = updated.memberIDs.filter { !previous.memberIDs.contains($0) }
        nightGroups[idx] = updated

        do {
            if membersChanged {
                try await backend.updateNightGroup(updated)
                let recipientIDs = addedMemberIDs.filter { $0 != viewerIdentity.id }
                if !recipientIDs.isEmpty {
                    do {
                        try await backend.insertGroupNotifications(
                            group: updated,
                            recipientIDs: recipientIDs,
                            creator: viewerIdentity
                        )
                    } catch {
                        socialErrorMessage = "Group updated, but new-member notifications couldn't be sent."
                    }
                }
            } else {
                try await backend.renameNightGroup(id: updated.id, name: updated.name)
            }
            // Pull the confirmed server state so all members see the change.
            await syncGroupsFromBackend()
            return true
        } catch {
            // Roll back on failure.
            if let rollbackIdx = nightGroups.firstIndex(where: { $0.id == updated.id }) {
                nightGroups[rollbackIdx] = previous
            }
            socialErrorMessage = "Couldn't save group changes. Please try again."
            return false
        }
    }

    /// Removes a group optimistically and deletes from backend.
    /// Non-creator members cannot delete (RLS enforces this on the backend;
    /// the UI should hide the trash button for non-creators).
    func deleteGroup(_ groupID: UUID) {
        let removed = nightGroups.first(where: { $0.id == groupID })
        nightGroups.removeAll { $0.id == groupID }
        if activeGroupID == groupID { activeGroupID = nil }

        Task {
            do {
                try await backend.deleteNightGroup(id: groupID)
                await syncGroupsFromBackend()
            } catch {
                await MainActor.run {
                    // Roll back on failure.
                    if let group = removed {
                        nightGroups.append(group)
                    }
                    socialErrorMessage = "Couldn't delete the group. Please try again."
                }
            }
        }
    }

    // MARK: - Backend sync (called from bootstrap)

    /// Fetches all tonight's groups from the backend and merges them into the
    /// local store. Called as part of `loadAppData` so every member sees groups
    /// created by others without needing a separate tap or refresh.
    /// Existing local groups that are no longer in the backend response are
    /// purged so deleted groups propagate to all members.
    func syncGroupsFromBackend() async {
        let window = Self.tonightWindow(reference: .now)
        do {
            let fetched = try await backend.fetchNightGroups(createdAfter: window.lowerBound)
            await MainActor.run {
                // Replace the whole local set with the authoritative backend list.
                // Groups the viewer is a member of are all present in `fetched`
                // thanks to the RLS `any(member_ids)` select policy.
                nightGroups = fetched
            }
        } catch {
            // Non-fatal: if the fetch fails, the viewer keeps whatever groups
            // they already have locally. The next bootstrap or foreground refresh
            // will try again.
        }
    }
}

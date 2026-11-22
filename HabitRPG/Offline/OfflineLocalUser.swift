//
//  OfflineLocalUser.swift
//  Habitica
//
//  Ensures a local player exists in standalone mode, so the app never
//  needs a server login on first launch. Realm is the single source of
//  truth: the user row is created by UserLocalRepository inside the
//  database framework, and only a local marker key is stored in the
//  authentication storage (no real API token exists offline).
//

import Foundation
import Habitica_Database

final class OfflineLocalUser {

    static let shared = OfflineLocalUser()

    private init() {}

    func ensureLocalUser() {
        guard OfflineState.shared.isStandalone else {
            return
        }
        let userID = AuthenticationManager.shared.currentUserId ?? "offline-\(UUID().uuidString.lowercased())"
        UserLocalRepository().createLocalUser(userID: userID, displayName: "Adventurer")
        if AuthenticationManager.shared.currentUserKey?.isEmpty != false {
            AuthenticationManager.shared.setAuthentication(userId: userID, key: "offline-local")
        } else if AuthenticationManager.shared.currentUserId == nil {
            AuthenticationManager.shared.currentUserId = userID
        }
    }
}

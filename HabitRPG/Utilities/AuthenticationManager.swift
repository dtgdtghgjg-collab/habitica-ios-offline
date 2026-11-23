//
//  AuthenticationManager.swift
//  Habitica
//
//  Created by Phillip on 29.08.17.
//  Copyright © 2017 HabitRPG Inc. All rights reserved.
//

import Foundation
import ReactiveSwift

class AuthenticationManager {

    func initialize(withStorage storage: AuthenticationStorage) {
        // Fully offline: always set to offline-local user
        currentUserId = "offline-local"
        currentUserKey = "offline-local"
    }
    
    static let shared = AuthenticationManager()
    var storage: AuthenticationStorage?

    var currentUserId: String? {
        get {
            return storage?.userID ?? "offline-local"
        }
        
        set(newValue) {
            storage?.userID = newValue
            currentUserIDProperty.value = newValue
            UserDefaults.standard.set(newValue, forKey: "currentUserId")
        }
    }

    var currentUserIDProperty = MutableProperty<String?>(nil)

    var currentUserKey: String? {
        get {
            return storage?.apiKey ?? "offline-local"
        }
        
        set(newValue) {
            storage?.apiKey = newValue
        }
    }

    private init() {
        currentUserIDProperty.value = currentUserId
    }

    func hasAuthentication() -> Bool {
        // Fully offline: always returns true since we have a local user
        return true
    }

    func setAuthentication(userId: String, key: String) {
        currentUserId = userId
        currentUserKey = key
    }

    func clearAuthenticationForAllUsers() {
        currentUserId = "offline-local"
        currentUserKey = "offline-local"
    }

    func clearAuthentication(userId: String) {
        // Will be used once we support multiple users
        clearAuthenticationForAllUsers()
    }
}

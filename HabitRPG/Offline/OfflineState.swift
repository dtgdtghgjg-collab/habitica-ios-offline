//
//  OfflineState.swift
//  Habitica
//
//  Shared, observable offline status used by repositories and the UI.
//

import Foundation
import ReactiveSwift
import Habitica_Database

final class OfflineState {

    static let shared = OfflineState()

    private static let developerModeKey = "offlineDeveloperMode_v1"

    private let pendingRepository = PendingOperationRepository()
    private let disposable = ScopedDisposable(CompositeDisposable())

    let isOnline: Property<Bool>
    let pendingCount = MutableProperty<Int>(0)
    let isSyncing = MutableProperty<Bool>(false)
    let lastSyncDate = MutableProperty<Date?>(nil)

    var isOffline: Bool {
        return !NetworkMonitor.shared.isOnlineNow
    }

    /// Fully offline: the app never sends a write to the server and never lets a
    /// server response overwrite Realm. Realm is the single source of truth.
    /// Standalone mode cannot be switched off.
    var isStandalone: Bool {
        return true
    }

    /// Developer mode (Settings): shows the Developer section with the
    /// standalone toggle, privacy reset and content reseed. Off by default.
    var isDeveloperMode: Bool {
        get { UserDefaults.standard.bool(forKey: Self.developerModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.developerModeKey) }
    }

    var hasPendingChanges: Bool {
        return pendingCount.value > 0
    }

    var currentUserID: String? {
        return AuthenticationManager.shared.currentUserId
    }

    private init() {
        isOnline = NetworkMonitor.shared.isOnline

        disposable.inner.add(isOnline.producer
            .skipRepeats()
            .startWithValues { [weak self] _ in
                self?.refreshPendingCount()
            })

        disposable.inner.add(NotificationCenter.default.reactive
            .notifications(forName: PendingOperationRepository.didChangeNotification)
            .observeValues { [weak self] _ in
                self?.refreshPendingCount()
            })

        disposable.inner.add(AuthenticationManager.shared.currentUserIDProperty.producer
            .skipRepeats()
            .startWithValues { [weak self] _ in
                self?.refreshPendingCount()
            })

        refreshPendingCount()
    }

    // Fully offline: standalone mode cannot be switched off, so there is no setter for it.

    func refreshPendingCount() {
        guard let userID = currentUserID else {
            pendingCount.value = 0
            return
        }
        if isStandalone {
            pendingCount.value = 0
            return
        }
        pendingCount.value = pendingRepository.pendingCount(userID: userID)
    }
}

//
//  NetworkMonitor.swift
//  Habitica
//
//  Thin wrapper around NWPathMonitor so the rest of the app can ask one
//  question: are we online right now?
//

import Foundation
import Network
import ReactiveSwift

final class NetworkMonitor {

    static let shared = NetworkMonitor()

    /// Posted on the main queue whenever connectivity changes.
    static let connectivityChangedNotification = Notification.Name("NetworkMonitorConnectivityChanged")

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.habitrpg.ios.network-monitor")
    private let onlineProperty: MutableProperty<Bool>
    let isOnline: Property<Bool>

    private init() {
        // Assume online until the first path update arrives, so a slow
        // monitor never blocks a call the user just triggered.
        let property = MutableProperty(true)
        onlineProperty = property
        isOnline = Property(property)
        monitor.pathUpdateHandler = { [weak self] path in
            let isOnline = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }
                if self.onlineProperty.value != isOnline {
                    self.onlineProperty.value = isOnline
                    NotificationCenter.default.post(name: Self.connectivityChangedNotification, object: nil)
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    var isOnlineNow: Bool {
        return onlineProperty.value
    }

    /// Called when a request failed with a connection error, so the UI reacts
    /// before NWPathMonitor notices the change.
    func reportConnectionFailure() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.onlineProperty.value else {
                return
            }
            self.onlineProperty.value = false
            NotificationCenter.default.post(name: Self.connectivityChangedNotification, object: nil)
        }
    }
}

extension NSError {
    /// Connection level failures that mean "the request never reached the
    /// server", as opposed to an HTTP error the server did return.
    var isConnectionError: Bool {
        return [NSURLErrorNotConnectedToInternet,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorCannotFindHost,
                NSURLErrorTimedOut,
                NSURLErrorDNSLookupFailed,
                NSURLErrorDataNotAllowed,
                NSURLErrorInternationalRoamingOff].contains(code)
    }
}

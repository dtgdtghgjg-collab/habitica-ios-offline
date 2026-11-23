//
//  AppDelegate.swift
//  Habitica
//
//  Created by Phillip on 11.08.17.
//  Copyright © 2017 HabitRPG Inc. All rights reserved.
//

import UIKit
import Habitica_Models
import RealmSwift
import ReactiveSwift
import Firebase
import SwiftyStoreKit
import StoreKit
import UserNotifications
import FirebaseMessaging
import Down
import WidgetKit
import AppAuth
import AdServices
import iAd

class HabiticaAppDelegate: UIResponder, MessagingDelegate, UIApplicationDelegate {
    var window: UIWindow?
    var currentAuthorizationFlow: OIDExternalUserAgentSession?
    var isBeingTested = false
        
    var application: UIApplication?
    
    private let userRepository = UserRepository()
    private let contentRepository = ContentRepository()
    let taskRepository = TaskRepository()
    private let socialRepository = SocialRepository()
    internal let configRepository = ConfigRepository.shared
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Measurements.start(identifier: "didFinishLaunchingWithOptions")
        logger = RemoteLogger()
        self.application = application
        
        if !isBeingTested && !OfflineState.shared.isStandalone {
            setupLogging()
            setupAnalytics()
            setupPurchaseHandling()
            setupFirebase()
        }
        setupRouter()
        handleLaunchArgs()
        setupNetworkClient()
        setupDatabase()
        if OfflineState.shared.isStandalone {
            OfflineContentSeeder.shared.seedIfNeeded()
            OfflineLocalUser.shared.ensureLocalUser()
        }
        configureNotifications()
        setupInvalidCredentialsObserver()
        setupOfflineSupport()
        
        // Fully offline: there is no server session to become unauthorized,
        // so never log out or show a login screen. Just make sure the local
        // player still exists.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("userDidBecomeUnauthorized"),
            object: nil,
            queue: .main
        ) { _ in
            OfflineLocalUser.shared.ensureLocalUser()
        }
        KeyboardManager.shared.observeKeyboardNotifications()
        
        if let userInfo = launchOptions?[UIApplication.LaunchOptionsKey.remoteNotification] as? [AnyHashable: Any] {
            handlePushnotification(identifier: nil, userInfo: userInfo)
        }
        
        handleInitialLaunch()
        applySearchAdAttribution()
        Measurements.stop(identifier: "didFinishLaunchingWithOptions")
        return true
    }
    
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        URLContexts.forEach { context in
            RouterHandler.shared.handle(url: context.url)
        }
    }

    func handleLaunchArgs() {
        if ProcessInfo.processInfo.arguments.contains("UI_TESTING") {
            isBeingTested = true
            contentRepository.retrieveContent(force: true).observeCompleted {
            }
            UIView.setAnimationsEnabled(false)
            self.window?.layer.speed = 100
            AuthenticationManager.shared.initialize(withStorage: MemoryAuthenticationStorage())
        } else {
            AuthenticationManager.shared.initialize(withStorage: KeychainAuthenticationStorage())
        }
        let launchEnvironment = ProcessInfo.processInfo.environment
        if let userID = launchEnvironment["userid"] {
            AuthenticationManager.shared.currentUserId = userID
        }
        if let apiKey = launchEnvironment["apikey"] {
            AuthenticationManager.shared.currentUserKey = apiKey
        }
        
        // Fully offline: no STUB_DATA needed
        if let url = launchEnvironment["OPEN_URL"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: {
                RouterHandler.shared.handle(urlString: url)
            })
        }
    }
    
    func setupFirebase() {
        Messaging.messaging().delegate = self
        
        let userDefaults = UserDefaults.standard
        #if !targetEnvironment(macCatalyst)
        Crashlytics.crashlytics().setCustomValue(-(NSTimeZone.local.secondsFromGMT() / 60), forKey: "timezone_offset")
        Crashlytics.crashlytics().setCustomValue(LanguageHandler.getAppLanguage().code, forKey: "app_language")
        HabiticaAnalytics.shared.setUserProperty(key: "app_language", value: LanguageHandler.getAppLanguage().code)
        HabiticaAnalytics.shared.setUserProperty(key: "app_testing_level", value: configRepository.testingLevel.rawValue.lowercased())
        HabiticaAnalytics.shared.setUserProperty(key: "app_icon", value: UIApplication.shared.alternateIconName)
        HabiticaAnalytics.shared.setUserProperty(key: "launch_screen", value: userDefaults.string(forKey: "initialScreenURL"))
        #endif
    }
    
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        if let token = fcmToken {
            print("Received FCM Token: \(token)")
        }
    }
    
    func saveDeviceToken(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "PushNotificationDeviceToken")
    }
    
    func setupLogging() {
        let userID = AuthenticationManager.shared.currentUserId
        FirebaseApp.configure()
        (logger as? RemoteLogger)?.setUserID(userID)
        logger.isProduction = HabiticaAppDelegate.isRunningLive()
    }
    
    func setupAnalytics() {
        HabiticaAnalytics.shared.initialize()
    }
    
    func setupPurchaseHandling() {
        // Fully offline: no in-app purchases, no StoreKit.
    }

    func setupNetworkClient() {
        // Fully offline: no server client, no etags, no network error handler.
    }
    
    func updateServer() {
        // Fully offline: no server configuration needed.
    }
    
    private func setupOfflineSupport() {
        // Standalone: start the local cron engine so daily rollover runs
        // on launch, on foreground and while the app is open.
        if OfflineState.shared.isStandalone {
            OfflineCronEngine.shared.start()
        }
    }

    func setupDatabase() {
        var config = Realm.Configuration.defaultConfiguration
        config.deleteRealmIfMigrationNeeded = true
        if isBeingTested {
            // when running tests use a fresh in-memory database on each launch
            config.inMemoryIdentifier = String(Date().timeIntervalSince1970)
        } else {
            let fileUrl = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: "group.habitrpg.habitica")?
                .appendingPathComponent("habitica.realm")
            if let url = fileUrl {
                config.fileURL = url
            }
            logger.log("Realm stored at: \(config.fileURL?.absoluteString ?? "")")
        }
        Realm.Configuration.defaultConfiguration = config
    }
    
    func setupRouter() {
        RouterHandler.shared.register()
    }
    
    func setupInvalidCredentialsObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInvalidCredentials),
            name: .invalidCredentials,
            object: nil
        )
    }
    
    @objc
    private func handleInvalidCredentials() {
        // Fully offline: no server credentials exist, so there is nothing
        // to invalidate and no login screen to show.
        OfflineLocalUser.shared.ensureLocalUser()
    }
    
    func handleInitialLaunch() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "wasLaunchedBefore") {
            defaults.set(true, forKey: "wasLaunchedBefore")
            
            var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            components.hour = 9
            components.minute = 0
            let newDate = Calendar.current.date(from: components)
            
            defaults.set(true, forKey: "dailyReminderActive")
            defaults.set(newDate, forKey: "dailyReminderTime")
            defaults.set(true, forKey: "appBadgeActive")
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            
            rescheduleDailyReminder()
        }
        // Local daily rollover: check on every launch, not just the first one.
        performDailyRolloverIfNeeded()
    }

    /// Checks the last rollover date against the Habitica day boundary and
    /// runs the local daily rollover when a new day has started.
    private func performDailyRolloverIfNeeded() {
        OfflineCronEngine.shared.runIfNeeded()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Check for a new day when the player returns to the app.
        OfflineCronEngine.shared.runIfNeeded()
    }

    func retrieveTasks(_ completed: @escaping ((Bool) -> Void)) {
        taskRepository.retrieveTasks().observeResult { (result) in
            switch result {
            case .success:
                completed(true)
            case .failure:
                completed(false)
            }
        }
    }
    
    func scoreTask(_ taskId: String, direction: TaskScoringDirection, completed: @escaping (() -> Void)) {
        if let task = taskRepository.getEditableTask(id: taskId) {
            taskRepository.score(task: task, direction: direction).observeCompleted {
                completed()
            }
        } else {
            completed()
        }
    }
    
    func acceptQuestInvitation(_ completed: @escaping ((Bool) -> Void)) {
        userRepository.getUser().take(first: 1)
            .map({ (user) -> String? in
                return user.party?.id
            })
            .skipNil()
            .flatMap(.latest) {[weak self] (partyID) in
                return self?.socialRepository.acceptQuestInvitation(groupID: partyID) ?? Signal.empty
            }.on(failed: { _ in
                completed(false)
            }, value: { _ in
                completed(true)
            }).start()
    }
    
    func rejectQuestInvitation(_ completed: @escaping ((Bool) -> Void)) {
        userRepository.getUser().take(first: 1)
            .map({ (user) -> String? in
                return user.party?.id
            })
            .skipNil()
            .flatMap(.latest) {[weak self] (partyID) in
                return self?.socialRepository.rejectQuestInvitation(groupID: partyID) ?? Signal.empty
            }.on(failed: { _ in
                completed(false)
            }, value: { _ in
                completed(true)
            }).start()
    }
    
    func sendPrivateMessage(toUserID: String, message: String, completed: @escaping ((Bool) -> Void)) {
        socialRepository.post(inboxMessage: message, toUserID: toUserID).observeResult({ (result) in
            switch result {
            case .success:
                completed(true)
            case .failure:
                completed(false)
            }
        })
    }
    
    func displayNotificationInApp(text: String) {
        ToastManager.show(text: text, color: .purple)
        UINotificationFeedbackGenerator.oneShotNotificationOccurred(.success)
    }
    
    func displayNotificationInApp(title: String, text: String) {
        ToastManager.show(text: "\(title)\n\(text)", color: .purple)
        UINotificationFeedbackGenerator.oneShotNotificationOccurred(.success)
    }
    
    static func isRunningLive() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let isRunningTestFlightBeta  = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        let hasEmbeddedMobileProvision = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
        if isRunningTestFlightBeta || hasEmbeddedMobileProvision {
            return false
        } else {
            return true
        }
        #endif
    }
    
    func applySearchAdAttribution() {
        // Fully offline: no search-ad attribution and no network call.
    }
    
    private func handleCampaign(_ data: [String: Any]) {
        guard let campaignId = data["campaignId"] as? Int else {
            return
        }

        var analyticsData = [String: Any]()
        analyticsData["attribution"] = data["iad-attribution"]
        analyticsData["campaignID"] = campaignId
        analyticsData["campaignName"] = data["iad-campaign-name"]
        analyticsData["purchaseDate"] = data["iad-purchase-date"]
        analyticsData["conversionDate"] = data["iad-conversion-date"]
        analyticsData["conversionType"] = data["iad-conversion-type"]
        analyticsData["clickDate"] = data["iad-click-date"]
        analyticsData["keyword"] = data["iad-keyword"]
        analyticsData["keywordMatchtype"] = data["iad-keyword-matchtype"]

        UserDefaults.standard.set(true, forKey: "userWasAttributed")
        UserDefaults.standard.set(data["iad-attribution"], forKey: "pendingAttribution_clickedSearchAd")
        UserDefaults.standard.set(data["iad-campaign-name"], forKey: "pendingAttribution_searchAdName")
        UserDefaults.standard.set(data["iad-conversion-date"], forKey: "pendingAttribution_searchAdConversionDate")
    }
    
    static func isRunningScreenshots() -> Bool {
        #if !targetEnvironment(simulator)
        return false
        #else
        return UserDefaults.standard.bool(forKey: "FASTLANE_SNAPSHOT")
        #endif
    }
    
    func messaging(_ messaging: MessagingDelegate, didReceiveRegistrationToken fcmToken: String) {
        logger.log("Firebase registration token: \(fcmToken)")
        let dataDict: [String: String] = ["token": fcmToken]
        NotificationCenter.default.post(name: Notification.Name("FCMToken"), object: nil, userInfo: dataDict)
    }
    
    func displayInAppNotification(taskID: String, text: String) {
        let alertController = HabiticaAlertController(title: L10n.taskReminder, message: text)
        alertController.addAction(title: L10n.complete, style: .default, isMainAction: true, closeOnTap: true, identifier: nil) {[weak self] _ in
            self?.scoreTask(taskID, direction: .up) {}
        }
        alertController.addCloseAction()
        alertController.enqueue()
        UINotificationFeedbackGenerator.oneShotNotificationOccurred(.warning)
    }
}
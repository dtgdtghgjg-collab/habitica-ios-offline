//
//  UserRepository.swift
//  Habitica
//
//  Created by Phillip Thelen on 07.03.18.
//  Copyright © 2018 HabitRPG Inc. All rights reserved.
//

import Foundation
import Habitica_Models
import Habitica_Database
import ReactiveSwift
import WidgetKit

// swiftlint:disable:next type_body_length
class UserRepository: BaseRepository<UserLocalRepository> {
    
    var lastPushDeviceSync: Date?
    var lastClassSelection: Date?
    var taskRepository = TaskRepository()
    
    func retrieveUser(withTasks: Bool = true, forced: Bool = false) -> Signal<UserProtocol?, Never> {
        // Fully offline: user comes from Realm only, never from the server.
        return Signal<UserProtocol?, Never> { observer, _ in
            observer.send(value: self.localRepository.getUserAsync(self.currentUserId ?? ""))
            observer.sendCompleted()
        }
    }
    
    func syncUserStats() -> Signal<UserProtocol?, Never> {
        // Fully offline: stats come from Realm only.
        return Signal<UserProtocol?, Never> { observer, _ in
            observer.send(value: self.localRepository.getUserAsync(self.currentUserId ?? ""))
            observer.sendCompleted()
        }
    }
    
    func getUser() -> SignalProducer<UserProtocol, ReactiveSwiftRealmError> {
        return currentUserIDProducer.skipNil().flatMap(.latest) {[weak self] (userID) in
            return self?.localRepository.getUser(userID) ?? SignalProducer.empty
        }
    }
    
    func allocate(attributePoint: String) -> Signal<StatsProtocol?, Never> {
        // Fully offline: points are allocated locally only.
        Self.allocatePointsLocally(attribute: attributePoint)
        return Signal<StatsProtocol?, Never> { observer, _ in
            observer.send(value: localRepository.getUserAsync(currentUserId ?? "")?.stats)
            observer.sendCompleted()
        }
    }

    func bulkAllocate(strength: Int, intelligence: Int, constitution: Int, perception: Int) -> Signal<StatsProtocol?, Never> {
        // Fully offline: points are allocated locally only.
        Self.allocatePointsLocally(strength: strength,
                                   intelligence: intelligence,
                                   constitution: constitution,
                                   perception: perception)
        return Signal<StatsProtocol?, Never> { observer, _ in
            observer.send(value: localRepository.getUserAsync(currentUserId ?? "")?.stats)
            observer.sendCompleted()
        }
    }

    /// Distributes unallocated points locally. The absolute stat values are
    /// stored, so the caller's deltas are applied to the current Realm values.
    private static func allocatePointsLocally(strength: Int = 0,
                                              intelligence: Int = 0,
                                              constitution: Int = 0,
                                              perception: Int = 0,
                                              attribute: String? = nil) {
        guard let userID = OfflineState.shared.currentUserID else {
            return
        }
        let mutationRepository = OfflineMutationRepository()
        let userLocalRepository = UserLocalRepository()
        guard let user = userLocalRepository.getUserAsync(userID),
              let stats = user.stats else {
            return
        }
        var newStrength = stats.strength + strength
        var newIntelligence = stats.intelligence + intelligence
        var newConstitution = stats.constitution + constitution
        var newPerception = stats.perception + perception
        switch attribute {
        case "str":
            newStrength += 1
        case "int":
            newIntelligence += 1
        case "con":
            newConstitution += 1
        case "per":
            newPerception += 1
        default:
            break
        }
        let spent = strength + intelligence + constitution + perception
            + (attribute == nil ? 0 : 1)
        let remaining = max(0, stats.points - spent)
        OfflineProfile.shared.allocate(userID: userID,
                                       strength: newStrength,
                                       intelligence: newIntelligence,
                                       constitution: newConstitution,
                                       perception: newPerception,
                                       points: remaining)
    }
    
    func hasUserData() -> Bool {
        if let userId = self.currentUserId {
            return localRepository.hasUserData(id: userId)
        } else {
            return false
        }
    }
    
    func useSkill(skill: SkillProtocol, targetId: String? = nil) -> Signal<SkillResponseProtocol?, Never> {
        // Fully offline: no server skills.
        return Signal.empty
    }
    
    func useTransformationItem(item: SpecialItemProtocol, targetId: String) -> Signal<UserProtocol?, Never> {
        // Fully offline: transformation applies locally only.
        localRepository.usedTransformationItem(userID: currentUserId ?? "", key: item.key ?? "")
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now()+1) {
            ToastManager.show(text: L10n.Skills.usedTransformationItem(item.text ?? ""), color: .gray)
        }
        return Signal<UserProtocol?, Never> { observer, _ in
            observer.send(value: self.localRepository.getUserAsync(self.currentUserId ?? ""))
            observer.sendCompleted()
        }
    }
    
    func useDebuffItem(key: String) -> Signal<UserProtocol?, Never> {
        // Fully offline: debuff applies locally only.
        return Signal<UserProtocol?, Never> { observer, _ in
            observer.send(value: self.localRepository.getUserAsync(self.currentUserId ?? ""))
            observer.sendCompleted()
        }
    }
    
    func runCron(checklistItems: [(TaskProtocol, ChecklistItemProtocol)], tasks: [TaskProtocol]) {
        guard !UserManager.shared.isLoggingOut else {
            return
        }
        // Fully offline: the local rollover already happened, there is no
        // server cron to run; enqueueCron() is a no-op there.
        OfflineSyncEngine.shared.enqueueCron()
    }
    
    func updateUser(_ updateDict: [String: Encodable?]) -> Signal<UserProtocol?, Never> {
        // Fully offline: updates apply locally only.
        applyUserUpdateLocally(updateDict)
        return Signal<UserProtocol?, Never> { observer, _ in
            observer.send(value: localRepository.getUserAsync(currentUserId ?? ""))
            observer.sendCompleted()
        }
    }
    
    func updateUser(key: String, value: Encodable?) -> Signal<UserProtocol?, Never> {
        return updateUser([key: value])
    }
    
    func updateDayStartTime(_ time: Int) -> Signal<UserProtocol?, Never> {
        // Fully offline: day start is stored locally only.
        if let userID = OfflineState.shared.currentUserID {
            OfflineMutationRepository().updateDayStart(userID: userID, dayStart: time)
        }
        return Signal<UserProtocol?, Never> { observer, _ in
            observer.send(value: self.localRepository.getUserAsync(self.currentUserId ?? ""))
            observer.sendCompleted()
        }
    }
    
    func sleep() -> Signal<EmptyResponseProtocol?, Never> {
        // Fully offline: sleep toggles locally only.
        if let userID = currentUserId {
            localRepository.toggleSleep(userID)
        }
        return Signal.empty
    }
    
    private func updateAuth(response: LoginResponseProtocol?) {
        if let response = response {
            if response.id?.isEmpty == false {
                AuthenticationManager.shared.currentUserId = response.id
            }
            if response.apiToken?.isEmpty == false {
                AuthenticationManager.shared.currentUserKey = response.apiToken
            }
        }
    }
    
    func login(username: String, password: String) -> Signal<LoginResponseProtocol?, Never> {
        // Fully offline: always the local player, never a server login.
        OfflineLocalUser.shared.ensureLocalUser()
        let response = APILoginResponse()
        response.id = OfflineState.shared.currentUserID
        response.apiToken = "offline-local"
        response.newUser = false
        updateAuth(response: response)
        return Signal<LoginResponseProtocol?, Never> { observer, _ in
            observer.send(value: response)
            observer.sendCompleted()
        }
    }
    
    func register(username: String, password: String, confirmPassword: String, email: String) -> Signal<LoginResponseProtocol?, Never> {
        // Fully offline: registration just ensures the local player exists.
        OfflineLocalUser.shared.ensureLocalUser()
        if let userID = OfflineState.shared.currentUserID, !username.isEmpty {
            OfflineProfile.shared.updateProfile(userID: userID, name: username, blurb: nil)
        }
        let response = APILoginResponse()
        response.id = OfflineState.shared.currentUserID
        response.apiToken = "offline-local"
        response.newUser = true
        updateAuth(response: response)
        return Signal<LoginResponseProtocol?, Never> { observer, _ in
            observer.send(value: response)
            observer.sendCompleted()
        }
    }
    
    func login(userID: String, network: String, accessToken: String, allowRegister: Bool) -> Signal<LoginResponseProtocol?, Never> {
        // Fully offline: social login is removed, always the local player.
        OfflineLocalUser.shared.ensureLocalUser()
        let response = APILoginResponse()
        response.id = OfflineState.shared.currentUserID
        response.apiToken = "offline-local"
        response.newUser = allowRegister
        updateAuth(response: response)
        return Signal<LoginResponseProtocol?, Never> { observer, _ in
            observer.send(value: response)
            observer.sendCompleted()
        }
    }
    
    func loginApple(identityToken: String, name: String, email: String, allowRegister: Bool) -> Signal<LoginResponseProtocol?, Never> {
        // Fully offline: Apple sign-in is removed, always the local player.
        OfflineLocalUser.shared.ensureLocalUser()
        if let userID = OfflineState.shared.currentUserID, !name.isEmpty {
            OfflineProfile.shared.updateProfile(userID: userID, name: name, blurb: nil)
        }
        let response = APILoginResponse()
        response.id = OfflineState.shared.currentUserID
        response.apiToken = "offline-local"
        response.newUser = allowRegister
        updateAuth(response: response)
        return Signal<LoginResponseProtocol?, Never> { observer, _ in
            observer.send(value: response)
            observer.sendCompleted()
        }
    }
    
    func disconnectSocial(_ network: String) -> Signal<EmptyResponseProtocol?, Never> {
        // Fully offline: no social accounts to disconnect.
        return Signal.empty
    }
    
    func resetAccount(password: String) -> Signal<UserProtocol?, Never> {
        // Fully offline: no server account to reset.
        return Signal.empty
    }
    
    func deleteAccount(password: String, onLogoutComplete: (() -> Void)? = nil) -> Signal<HTTPURLResponse, Never> {
        // Fully offline: no server account to delete.
        return Signal.empty
    }
    
    func logoutAccount(completion: (() -> Void)? = nil) {
        // Fully offline: there is no account to log out of. Never wipe
        // the local Realm data or clear the local authentication.
        completion?()
    }

    // Fully offline: logout never clears the local database.
    
    func updateEmail(newEmail: String, password: String) -> Signal<UserProtocol, ReactiveSwiftRealmError> {
        // Fully offline: email is stored locally only.
        localRepository.updateCall { _ in
            if let user = self.localRepository.getUserAsync(self.currentUserId ?? ""),
               let local = user.authentication?.local {
                local.email = newEmail
            }
        }
        return Signal<UserProtocol, ReactiveSwiftRealmError> { observer, _ in
            if let user = self.localRepository.getUserAsync(self.currentUserId ?? "") {
                observer.send(value: user)
            }
            observer.sendCompleted()
        }
    }
    
    func updateUsername(newUsername: String, password: String? = nil) -> Signal<UserProtocol, ReactiveSwiftRealmError> {
        // Fully offline: username is stored locally only.
        if let userID = OfflineState.shared.currentUserID {
            OfflineProfile.shared.updateProfile(userID: userID, name: newUsername, blurb: nil)
            localRepository.updateCall { _ in
                if let user = self.localRepository.getUserAsync(userID) {
                    user.flags?.verifiedUsername = true
                }
            }
        }
        return Signal<UserProtocol, ReactiveSwiftRealmError> { observer, _ in
            if let user = self.localRepository.getUserAsync(self.currentUserId ?? "") {
                observer.send(value: user)
            }
            observer.sendCompleted()
        }
    }
    
    func verifyUsername(_ newUsername: String) -> Signal<VerifyUsernameResponse?, Never> {
        // Fully offline: username is validated locally only.
        let response = APIVerifyUsernameResponse()
        let isValid = newUsername.count >= 1 && newUsername.count <= 20
            && newUsername.range(of: "[^a-zA-Z0-9_-]", options: .regularExpression) == nil
        response.isUsable = isValid
        response.issues = isValid ? [] : ["Invalid username"]
        return Signal<VerifyUsernameResponse?, Never> { observer, _ in
            observer.send(value: response)
            observer.sendCompleted()
        }
    }
    
    func checkEmail(_ newEmail: String) -> Signal<CheckEmailResponse?, Never> {
        // Fully offline: email is validated locally only.
        let response = APICheckEmailResponse()
        response.email = newEmail
        response.valid = newEmail.isValidEmail()
        response.error = response.valid ? nil : L10n.Login.emailInvalid
        return Signal<CheckEmailResponse?, Never> { observer, _ in
            observer.send(value: response)
            observer.sendCompleted()
        }
    }
    
    func updatePassword(newPassword: String, password: String, confirmPassword: String) -> Signal<LoginResponseProtocol?, Never> {
        // Fully offline: no server password, keep the local player.
        let response = APILoginResponse()
        response.id = OfflineState.shared.currentUserID
        response.apiToken = "offline-local"
        return Signal<LoginResponseProtocol?, Never> { observer, _ in
            observer.send(value: response)
            observer.sendCompleted()
        }
    }
    
    func revive() -> Signal<UserProtocol?, Never> {
        // Fully offline: revive applies locally only.
        if let userID = OfflineState.shared.currentUserID {
            OfflineMutationRepository().revive(userID: userID)
        }
        return Signal<UserProtocol?, Never> { observer, _ in
            observer.send(value: self.localRepository.getUserAsync(self.currentUserId ?? ""))
            observer.sendCompleted()
        }
    }
    
    func getUserStyleWithOutfitFor(class habiticaClass: HabiticaClass, userID: String? = nil) -> SignalProducer<UserStyleProtocol, ReactiveSwiftRealmError> {
        return localRepository.getUserStyleWithOutfitFor(class: habiticaClass, userID: userID ?? currentUserId ?? "")
    }
    
    func getInAppRewards() -> SignalProducer<ReactiveResults<[InAppRewardProtocol]>, ReactiveSwiftRealmError> {
        return localRepository.getInAppRewards(userID: currentUserId ?? "")
    }
    
    func retrieveInAppRewards() -> Signal<[InAppRewardProtocol]?, Never> {
        // Fully offline: no server rewards.
        return Signal.empty
    }
    
    func buyCustomReward(reward: TaskProtocol) -> Signal<TaskResponseProtocol?, Never> {
        return taskRepository.score(task: reward, direction: .down)
    }

    func movePinnedItem(_ item: InAppRewardProtocol, toPosition: Int) -> Signal<[String]?, Never> {
        // Fully offline: no server pinned items.
        return Signal.empty
    }
    
    func disableClassSystem() -> Signal<UserProtocol?, Never> {
        if (lastClassSelection?.timeIntervalSinceNow ?? -3) > -2 {
            return Signal.empty
        }
        lastClassSelection = Date()
        // Fully offline: classes are disabled locally only.
        if let userID = OfflineState.shared.currentUserID {
            OfflineMutationRepository().disableClasses(userID: userID)
        }
        return Signal<UserProtocol?, Never> { observer, _ in
            observer.send(value: self.localRepository.getUserAsync(self.currentUserId ?? ""))
            observer.sendCompleted()
        }
    }
    
    func selectClass(_ habiticaClass: HabiticaClass? = nil) -> Signal<UserProtocol?, Never> {
        if (lastClassSelection?.timeIntervalSinceNow ?? -3) > -2 {
            return Signal.empty
        }
        lastClassSelection = Date()
        // Fully offline: class is selected locally only.
        if let userID = OfflineState.shared.currentUserID {
            OfflineMutationRepository().selectClass(userID: userID, habitClass: habiticaClass?.rawValue)
        }
        if let habiticaClass = habiticaClass {
            let viewController = HostingBottomSheetController(rootView: ClassConfirmationSheet(selectedClass: habiticaClass), prefersGrabberVisible: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                viewController.show()
            }
            UIApplication.requestReview()
        }
        return Signal<UserProtocol?, Never> { observer, _ in
            observer.send(value: self.localRepository.getUserAsync(self.currentUserId ?? ""))
            observer.sendCompleted()
        }
    }
    
    func reroll() -> Signal<UserProtocol?, Never> {
        // Fully offline: no server reroll.
        return Signal.empty
    }

    func rebirth() -> Signal<UserProtocol?, Never> {
        // Fully offline: no server rebirth.
        return Signal.empty
    }

    func sendPasswordResetEmail(email: String) -> Signal<EmptyResponseProtocol?, Never> {
        // Fully offline: no password reset email.
        return Signal.empty
    }
    
    func purchaseGems(receipt: [String: Any], recipient: String? = nil) -> Signal<HabiticaResponse<APIEmptyResponse>?, Never> {
        // Fully offline: no gem purchases.
        return Signal.empty
    }
    
    func sendGems(amount: Int, recipient: String) -> Signal<HabiticaResponse<APIEmptyResponse>?, Never> {
        // Fully offline: no gem sending.
        return Signal.empty
    }
    
    func purchaseNoRenewSubscription(identifier: String, receipt: [String: Any], recipient: String? = nil) -> Signal<EmptyResponseProtocol?, Never> {
        // Fully offline: no subscriptions.
        return Signal.empty
    }
    
    func subscribe(sku: String, receipt: String) -> Signal<UserProtocol?, Never> {
        // Fully offline: no subscriptions.
        return Signal.empty
    }
    
    @discardableResult
    func cancelSubscription() -> Signal<UserProtocol?, Never> {
        // Fully offline: no subscriptions.
        return Signal.empty
    }
    
    func getTags() -> SignalProducer<ReactiveResults<[TagProtocol]>, ReactiveSwiftRealmError> {
        return currentUserIDProducer.skipNil().flatMap(.latest, {[weak self] (userID) in
            return self?.localRepository.getTags(userID: userID) ?? SignalProducer.empty
        })
    }
    
    func retrieveInboxMessages(conversationID: String, page: Int) -> Signal<[InboxMessageProtocol]?, Never> {
        // Fully offline: no inbox from server.
        return Signal.empty
    }
    
    func retrieveGroupPlans() -> Signal<[GroupPlanProtocol]?, Never> {
        // Fully offline: no group plans from server.
        return Signal.empty
    }
    
    func getGroupPlans() -> SignalProducer<ReactiveResults<[GroupPlanProtocol]>, ReactiveSwiftRealmError> {
        return currentUserIDProducer.skipNil().flatMap(.latest, {[weak self] (userID) in
            return self?.localRepository.getGroupPlans(userID: userID) ?? SignalProducer.empty
        })
    }
    
    func retrieveInboxConversations() -> Signal<[InboxConversationProtocol]?, Never> {
        // Fully offline: no inbox from server.
        return Signal.empty
    }
    
    func registerPushDevice(user: UserProtocol) -> Signal<EmptyResponseProtocol?, Never> {
        // Fully offline: no push registration.
        return Signal.empty
    }
    
    func deregisterPushDevice() -> Signal<EmptyResponseProtocol?, Never> {
        // Fully offline: no push deregistration.
        return Signal.empty
    }
    
    func saveNotifications(_ notifications: [NotificationProtocol]?) {
        if let userID = currentUserId {
            localRepository.save(userID: userID, notifications: notifications)
        }
    }
    
    func getNotifications() -> SignalProducer<ReactiveResults<[NotificationProtocol]>, ReactiveSwiftRealmError> {
        return currentUserIDProducer.skipNil().flatMap(.latest, {[weak self] (userID) in
            return self?.localRepository.getNotifications(userID: userID) ?? SignalProducer.empty
        })
    }
    
    func getUnreadNotificationCount() -> SignalProducer<Int, ReactiveSwiftRealmError> {
        return currentUserIDProducer.skipNil().flatMap(.latest, {[weak self] (userID) in
            return self?.localRepository.getUnreadNotificationCount(userID: userID) ?? SignalProducer.empty
        })
    }
    
    func retrieveAchievements() -> Signal<[AchievementProtocol]?, Never> {
        // Fully offline: no server achievements.
        return Signal.empty
    }
    
    func getAchievements() -> SignalProducer<ReactiveResults<[AchievementProtocol]>, ReactiveSwiftRealmError> {
        return currentUserIDProducer.skipNil().flatMap(.latest, {[weak self] (userID) in
            return self?.localRepository.getAchievements(userID: userID) ?? SignalProducer.empty
        })
    }
    
    func readNotification(notification: NotificationProtocol) -> Signal<[NotificationProtocol]?, Never> {
        if !notification.isValid {
            return Signal.empty
        }
        // Fully offline: notifications are deleted locally only.
        localRepository.delete(object: notification)
        return Signal.empty
    }
    
    func readNotifications(notifications: [NotificationProtocol]) -> Signal<[NotificationProtocol]?, Never> {
        // Fully offline: notifications are deleted locally only.
        notifications.forEach { localRepository.delete(object: $0) }
        return Signal.empty
    }
    
    func createNotification(id: String, type: HabiticaNotificationType) -> NotificationProtocol {
        return localRepository.createNotification(userID: currentUserId ?? "", id: id, type: type)
    }
    
    private func handleUserUpdate() -> ((UserProtocol?) -> Void) {
        return {[weak self] updatedUser in
            if let userID = self?.currentUserId, let updatedUser = updatedUser {
                self?.localRepository.updateUser(id: userID, updateUser: updatedUser)
            }
        }
    }

    /// Applies the keys the offline code understands to Realm. Any other key
    /// (flags, push devices, ...) silently keeps its current value; the server
    /// never sees the update in standalone mode.
    private func applyUserUpdateLocally(_ updateDict: [String: Encodable?]) {
        guard let userID = OfflineState.shared.currentUserID else {
            return
        }
        var name: String?
        var blurb: String?
        var skin: String?
        var shirt: String?
        var size: String?
        var background: String?
        var chair: String?
        var hairColor: String?
        var hairBase: Int?
        var hairBangs: Int?
        var hairBeard: Int?
        var hairMustache: Int?
        var hairFlower: Int?
        var analyticsConsent: Bool?

        for (key, value) in updateDict {
            switch key {
            case "profile.name":
                name = value as? String
            case "profile.blurb":
                blurb = value as? String
            case "preferences.skin":
                skin = value as? String
            case "preferences.shirt":
                shirt = value as? String
            case "preferences.size":
                size = value as? String
            case "preferences.background":
                background = value as? String
            case "preferences.chair":
                chair = value as? String
            case "preferences.hair.color":
                hairColor = value as? String
            case "preferences.hair.base":
                hairBase = value as? Int
            case "preferences.hair.bangs":
                hairBangs = value as? Int
            case "preferences.hair.beard":
                hairBeard = value as? Int
            case "preferences.hair.mustache":
                hairMustache = value as? Int
            case "preferences.hair.flower":
                hairFlower = value as? Int
            case "preferences.analyticsConsent":
                analyticsConsent = value as? Bool
            default:
                break
            }
        }

        OfflineProfile.shared.updateAvatar(userID: userID,
                                           skin: skin,
                                           shirt: shirt,
                                           size: size,
                                           background: background,
                                           chair: chair,
                                           hairColor: hairColor,
                                           hairBase: hairBase,
                                           hairBangs: hairBangs,
                                           hairBeard: hairBeard,
                                           hairMustache: hairMustache,
                                           hairFlower: hairFlower)
        if name != nil || blurb != nil {
            OfflineProfile.shared.updateProfile(userID: userID, name: name, blurb: blurb)
        }
        if let analyticsConsent = analyticsConsent {
            OfflineProfile.shared.setAnalyticsConsent(userID: userID, consent: analyticsConsent)
        }
    }
}

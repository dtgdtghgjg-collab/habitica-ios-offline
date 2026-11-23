//
//  InventoryRepository.swift
//  Habitica
//
//  Created by Phillip on 25.08.17.
//  Copyright © 2017 HabitRPG Inc. All rights reserved.
//

import Foundation
import Habitica_Models
import Habitica_Database
import ReactiveSwift

class InventoryRepository: BaseRepository<InventoryLocalRepository> {

    let localUserRepository = UserLocalRepository()
    
    func getOwnedGear(userID: String? = nil) -> SignalProducer<ReactiveResults<[OwnedGearProtocol]>, ReactiveSwiftRealmError> {
        return currentUserIDProducer.skipNil().flatMap(.latest, {[weak self] (currentUserID) in
            return self?.localRepository.getOwnedGear(userID: userID ?? currentUserID) ?? SignalProducer.empty
        })
    }
    
    func getGear(predicate: NSPredicate? = nil) -> SignalProducer<ReactiveResults<[GearProtocol]>, ReactiveSwiftRealmError> {
        return localRepository.getGear(predicate: predicate)
    }
    
    func getGear(keys: [String]) -> SignalProducer<ReactiveResults<[GearProtocol]>, ReactiveSwiftRealmError> {
        return localRepository.getGear(predicate: NSPredicate(format: "key IN %@", keys))
    }
    
    func getOwnedItems(userID: String? = nil, itemType: String? = nil) -> SignalProducer<ReactiveResults<[OwnedItemProtocol]>, ReactiveSwiftRealmError> {
        return currentUserIDProducer.skipNil().flatMap(.latest, {[weak self] (currentUserID) in
            return self?.localRepository.getOwnedItems(userID: userID ?? currentUserID, itemType: itemType) ?? SignalProducer.empty
        })
    }
    
    // swiftlint:disable:next large_tuple
    func getItems(keys: [ItemType: [String]]) -> SignalProducer<(eggs: ReactiveResults<[EggProtocol]>,
                                                                 food: ReactiveResults<[FoodProtocol]>,
                                                                 hatchingPotions: ReactiveResults<[HatchingPotionProtocol]>,
                                                                 special: ReactiveResults<[SpecialItemProtocol]>,
                                                                 quests: ReactiveResults<[QuestProtocol]>), ReactiveSwiftRealmError> {
        return localRepository.getItems(keys: keys).map { items in
            return (eggs: items.0, food: items.1, hatchingPotions: items.2, special: items.3, quests: items.4)
        }
    }
    
    func getFood(keys: [String]) -> SignalProducer<ReactiveResults<[FoodProtocol]>, ReactiveSwiftRealmError> {
            return localRepository.getFood(keys: keys)
    }
    
    func getItems(type: ItemType) -> SignalProducer<ReactiveResults<[ItemProtocol]>, ReactiveSwiftRealmError> {
        return localRepository.getItems(type: type)
    }
    
    func getSpecialItems(keys: [String]) -> SignalProducer<ReactiveResults<[SpecialItemProtocol]>, ReactiveSwiftRealmError> {
        return localRepository.getSpecialItems(keys: keys)
    }
    
    func getQuest(key: String) -> SignalProducer<QuestProtocol?, ReactiveSwiftRealmError> {
        return localRepository.getQuest(key: key)
    }
    
    func getQuests(keys: [String]) -> SignalProducer<ReactiveResults<[QuestProtocol]>, ReactiveSwiftRealmError> {
        return localRepository.getQuests(keys: keys)
    }
    
    func sell(item: ItemProtocol) -> Signal<UserProtocol?, Never> {
        // Fully offline: items are sold locally only.
        let toastView = ToastView(goldDiff: item.value, background: .green, delay: 0.5)
        if let userID = OfflineState.shared.currentUserID {
            OfflineEconomyManager.shared.sellItem(userID: userID, key: item.key ?? "", value: item.value)
            ToastManager.show(toast: toastView)
        }
        return Signal<UserProtocol?, Never> { observer, _ in
            observer.send(value: nil)
            observer.sendCompleted()
        }
    }
    
    func hatchPet(egg: EggProtocol, potion: HatchingPotionProtocol) -> Signal<UserItemsProtocol?, Never> {
        return hatchPet(egg: egg.key, potion: potion.key)
    }
    
    func hatchPet(egg: String?, potion: String?) -> Signal<UserItemsProtocol?, Never> {
        if OfflineState.shared.isStandalone || OfflineState.shared.isOffline,
           let userID = OfflineState.shared.currentUserID,
           let egg = egg, let potion = potion {
            OfflineMutationRepository().hatchPet(userID: userID, egg: egg, potion: potion)
            if !OfflineState.shared.isStandalone {
                OfflineSyncEngine.shared.enqueueHatch(egg: egg, potion: potion)
            }
            StableRepository().getPets(keys: ["\(egg)-\(potion)"])
                .take(first: 1)
                .map({ result in
                    return result.value.first
                })
                .skipNil()
                .on(value: { pet in
                    let sheet = PetHatchedSheet(pet: pet) {
                        self.equip(type: "pet", key: pet.key ?? "").observeCompleted {}
                    }
                    let viewController = HostingBottomSheetController(rootView: sheet, prefersGrabberVisible: false)
                    viewController.show()
                }).start()
            return Signal<UserItemsProtocol?, Never> { observer, _ in
                observer.send(value: nil)
                observer.sendCompleted()
            }
        }
       let call = HatchPetCall(egg: egg ?? "", potion: potion ?? "")
        
        return call.objectSignal.on(value: { userItems in
            if let userItems = userItems, let userID = self.currentUserId {
                self.localUserRepository.updateUser(id: userID, userItems: userItems)
            }
            
            StableRepository().getPets(keys: ["\(egg ?? "")-\(potion ?? "")"])
                .take(first: 1)
                .map({ result in
                    return result.value.first
                })
                .skipNil()
                .on(value: { pet in
                    let sheet = PetHatchedSheet(pet: pet) {
                        self.equip(type: "pet", key: pet.key ?? "").observeCompleted {}
                    }
                    let viewController = HostingBottomSheetController(rootView: sheet, prefersGrabberVisible: false)
                    viewController.show()
                }).start()
        })
    }
    
    func inviteToQuest(quest: QuestProtocol) -> Signal<EmptyResponseProtocol?, Never> {
        // Fully offline: no server party quests.
        return Signal.empty
    }
    
    func equip(type: String, key: String) -> Signal<UserItemsProtocol?, Never> {
        // Fully offline: items are equipped locally only.
        if let userID = OfflineState.shared.currentUserID {
            OfflineMutationRepository().equip(userID: userID, type: type, key: key)
        }
        return Signal<UserItemsProtocol?, Never> { observer, _ in
            observer.send(value: nil)
            observer.sendCompleted()
        }
   }

    func buyObject(key: String, quantity: Int, price: Int, text: String, openArmoireView: Bool = true) -> Signal<BuyResponseProtocol?, Never> {
        // Fully offline: purchases are made with local gold only.
        guard let userID = OfflineState.shared.currentUserID else {
            return Signal.empty
        }
        let result = OfflineEconomyManager.shared.buyWithGold(userID: userID, key: key, quantity: quantity)
        return Self.offlineBuySignal(result: result, text: text, quantity: quantity)
    }
    
    func purchaseItem(purchaseType: String, key: String, value: Int, quantity: Int, text: String) -> Signal<UserProtocol?, Never> {
        // Fully offline: purchases are made with local gems only.
        guard let userID = OfflineState.shared.currentUserID else {
            return Signal.empty
        }
        let result = OfflineEconomyManager.shared.buyWithGems(userID: userID,
                                                              itemType: purchaseType,
                                                              key: key,
                                                              gemCost: value,
                                                              quantity: quantity)
        Self.showOfflinePurchaseToast(result: result, text: text, quantity: quantity)
        return Signal<UserProtocol?, Never> { observer, _ in
            observer.send(value: nil)
            observer.sendCompleted()
        }
    }
    
    func purchaseHourglassItem(purchaseType: String, key: String, text: String) -> Signal<UserProtocol?, Never> {
        // Fully offline: no hourglass purchases.
        return Signal.empty
    }
    
    func purchaseMysterySet(identifier: String, text: String) -> Signal<UserProtocol?, Never> {
        // Fully offline: no mystery set purchases.
        return Signal.empty
    }
    
    func openMysteryItem() -> Signal<GearProtocol?, Never> {
        // Fully offline: no server mystery items.
        return Signal.empty
    }
    
    func purchaseQuest(key: String, text: String) -> Signal<UserProtocol?, Never> {
        // Fully offline: quests are bought with local gold only.
        guard let userID = OfflineState.shared.currentUserID else {
            return Signal.empty
        }
        let result = OfflineEconomyManager.shared.buyWithGold(userID: userID, key: key)
        Self.showOfflinePurchaseToast(result: result, text: text, quantity: 1)
        return Signal<UserProtocol?, Never> { observer, _ in
            observer.send(value: nil)
            observer.sendCompleted()
        }
    }
    
    func togglePinnedItem(pinType: String, path: String) -> Signal<PinResponseProtocol?, Never> {
        // Fully offline: no server pinned items.
        return Signal.empty
    }
    
    func retrieveShopInventory(identifier: String) -> Signal<ShopProtocol?, Never> {
        // Fully offline: shops come from the bundled content only.
        return Signal.empty
    }
    
    func getShop(identifier: String) -> SignalProducer<ShopProtocol?, ReactiveSwiftRealmError> {
        return localRepository.getShop(identifier: identifier)
    }
    
    func getShops() -> SignalProducer<ReactiveResults<[ShopProtocol]>, ReactiveSwiftRealmError> {
        return localRepository.getShops()
    }
    
    func feed(pet: PetProtocol, food: FoodProtocol) -> Signal<HabiticaResponse<Int>?, Never> {
        feed(pet: pet, food: food.key ?? "")
    }
    
    func feed(pet: PetProtocol, food: String) -> Signal<HabiticaResponse<Int>?, Never> {
        if OfflineState.shared.isStandalone || OfflineState.shared.isOffline, let userID = OfflineState.shared.currentUserID {
            OfflineMutationRepository().feedPet(userID: userID, petKey: pet.key ?? "", food: food)
            if !OfflineState.shared.isStandalone {
                OfflineSyncEngine.shared.enqueueFeed(pet: pet.key ?? "", food: food)
            }
            if food == "Saddle" {
                let sheet = MountRaisedSheet(mount: pet) {
                    self.equip(type: "mount", key: pet.key ?? "").observeCompleted {}
                }
                let viewController = HostingBottomSheetController(rootView: sheet, prefersGrabberVisible: false)
                viewController.show()
            }
            return Signal<HabiticaResponse<Int>?, Never> { observer, _ in
                observer.send(value: nil)
                observer.sendCompleted()
            }
        }
       let call = FeedPetCall(pet: pet.key ?? "", food: food)
        
        if food == "Saddle" {
            call.httpResponseSignal.observeValues { response in
                if response.statusCode == 404 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: {
                        let alert = HabiticaAlertController(title: L10n.Inventory.noSaddleTile, message: L10n.Inventory.noSaddleDescription)
                        alert.addAction(title: L10n.Inventory.visitMarket, style: .default, isMainAction: true) {_ in
                            RouterHandler.shared.handle(urlString: "/inventory/market/food")
                        }
                        alert.addCloseAction()
                        alert.show()
                    })
                }
            }
        }
        
        return call.habiticaResponseSignal.on(value: {[weak self] response in
            if response?.data == -1 {
                StableLocalRepository().getMounts(keys: [pet.key ?? ""]).map { mounts in
                    return mounts.value.first?.text
                }.on(value: { _ in
                    let sheet = MountRaisedSheet(mount: pet) {
                        self?.equip(type: "mount", key: pet.key ?? "").observeCompleted {}
                    }
                    let viewController = HostingBottomSheetController(rootView: sheet, prefersGrabberVisible: false)
                    viewController.show()
                }).start()
            }
            if let userID = self?.currentUserId, let trained = response?.data {
                self?.localRepository.updatePetTrained(userID: userID, key: pet.key ?? "", trained: trained, consumedFood: food)
            }
        })
    }
    
    func getNewInAppReward() -> InAppRewardProtocol {
        return localRepository.getNewInAppReward()
    }
    
    func getLatestMysteryGear() -> SignalProducer<GearProtocol?, ReactiveSwiftRealmError> {
        return localRepository.getLatestMysteryGear()
    }
    
    func getLatestMysteryGearSet() -> SignalProducer<GearSetProtocol?, ReactiveSwiftRealmError> {
        return localRepository.getLatestMysteryGearSet()
    }
    
    func getCurrentTimeLimitedItems() -> SignalProducer<[ItemProtocol], ReactiveSwiftRealmError> {
        return localRepository.getCurrentTimeLimitedItems()
    }
    
    func getArmoireRemainingCount() -> SignalProducer<ReactiveResults<[GearProtocol]>, ReactiveSwiftRealmError> {
        return currentUserIDProducer.skipNil().flatMap(.latest, {[weak self] (currentUserID) in
            return self?.localRepository.getArmoireRemainingCount(userID: currentUserID) ?? SignalProducer.empty
        })
    }

    private static func showOfflinePurchaseToast(result: OfflinePurchaseResult, text: String, quantity: Int) {
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1) {
            if case .success = result {
                if quantity > 1 {
                    ToastManager.show(text: L10n.purchasedAmount(quantity, text), color: .green)
                } else {
                    ToastManager.show(text: L10n.purchased(text), color: .green)
                }
            } else {
                ToastManager.show(text: L10n.notEnoughGold, color: .red)
            }
        }
    }

    private static func offlineBuySignal(result: OfflinePurchaseResult, text: String, quantity: Int) -> Signal<BuyResponseProtocol?, Never> {
        showOfflinePurchaseToast(result: result, text: text, quantity: quantity)
        if case .success = result {
            UINotificationFeedbackGenerator.oneShotNotificationOccurred(.success)
        }
        return Signal<BuyResponseProtocol?, Never> { observer, _ in
            observer.send(value: nil)
            observer.sendCompleted()
        }
    }
}

//
//  OfflineEconomyManager.swift
//  Habitica
//
//  Handles purchases entirely on-device: validates the player's balance and
//  level, deducts the currency and adds the item straight into Realm.
//

import Foundation
import Habitica_Models
import Habitica_Database

public enum OfflinePurchaseResult {
    case success
    case insufficientGold
    case insufficientGems
    case lockedByLevel(requiredLevel: Int)
    case itemNotFound
}

final class OfflineEconomyManager {

    static let shared = OfflineEconomyManager()

    private let contentRepository = OfflineGameContentRepository()
    private let mutationRepository = OfflineMutationRepository()
    private let userLocalRepository = UserLocalRepository()

    private init() {}

    // MARK: - Gold purchases

    /// Buys equipment, an egg, hatching potion, food, quest scroll or armoire
    /// pull with gold. Realm is the single source of truth.
    func buyWithGold(userID: String, key: String, quantity: Int = 1) -> OfflinePurchaseResult {
        guard let user = userLocalRepository.getUserAsync(userID),
              let stats = user.stats else {
            return .itemNotFound
        }

        // Equipment
        if let gear = contentRepository.gear(key: key) {
            let price = gear.value
            guard stats.gold >= price else {
                return .insufficientGold
            }
            let level = user.stats?.level ?? 0
            guard level >= gear.requiredLevel else {
                return .lockedByLevel(requiredLevel: gear.requiredLevel)
            }
            mutationRepository.applyGold(userID: userID, gold: stats.gold - price)
            mutationRepository.addOwnedGear(userID: userID, key: key)
            mutationRepository.applyAchievements(userID: userID, purchasedEquipment: true)
            return .success
        }

        // Consumables / quest scrolls: lookup across the known item categories.
        for itemType in [ItemType.eggs, .hatchingPotions, .food, .quests, .special] {
            let catalog = contentRepository.itemCatalog(itemType.rawValue)
            if let item = catalog.first(where: { $0.key == key }) {
                let totalCost = item.value * Float(max(1, quantity))
                guard stats.gold >= totalCost else {
                    return .insufficientGold
                }
                mutationRepository.applyGold(userID: userID, gold: stats.gold - totalCost)
                mutationRepository.addOwnedItem(userID: userID,
                                                itemType: itemType.rawValue,
                                                key: key,
                                                quantity: max(1, quantity))
                return .success
            }
        }

        return .itemNotFound
    }

    // MARK: - Gem purchases

    /// Spends gems from the player's balance. 1 gem is 0.25 of `user.balance`.
    func spendGems(userID: String, gems: Int) -> OfflinePurchaseResult {
        guard let user = userLocalRepository.getUserAsync(userID) else {
            return .itemNotFound
        }
        let availableGems = Int((user.balance * 4.0).rounded(.down))
        guard availableGems >= gems else {
            return .insufficientGems
        }
        mutationRepository.spendGems(userID: userID, gems: gems)
        return .success
    }

    /// Grants gems locally (e.g. from debug tools, quest rewards or custom rules).
    func addGems(userID: String, gems: Int) {
        mutationRepository.addGems(userID: userID, gems: gems)
    }

    /// Buys an item for gems (customizations, special items, quests, backgrounds).
    func buyWithGems(userID: String,
                     itemType: String,
                     key: String,
                     gemCost: Int,
                     quantity: Int = 1) -> OfflinePurchaseResult {
        let result = spendGems(userID: userID, gems: gemCost * max(1, quantity))
        guard case .success = result else {
            return result
        }
        mutationRepository.addOwnedItem(userID: userID,
                                        itemType: itemType,
                                        key: key,
                                        quantity: max(1, quantity))
        return .success
    }

    // MARK: - Selling

    /// Sells a consumable back for gold. Gear is deliberately not sellable
    /// here: the server's sell op only accepts eggs, potions and food.
    func sellItem(userID: String, key: String, value: Float) {
        guard let user = userLocalRepository.getUserAsync(userID),
              let stats = user.stats else {
            return
        }
        for itemType in [ItemType.eggs, .hatchingPotions, .food] {
            let catalog = contentRepository.itemCatalog(itemType.rawValue)
            guard catalog.contains(where: { $0.key == key }) else {
                continue
            }
            mutationRepository.applyGold(userID: userID, gold: stats.gold + value)
            mutationRepository.removeOwnedItem(userID: userID, itemType: itemType.rawValue, key: key)
            return
        }
    }
}
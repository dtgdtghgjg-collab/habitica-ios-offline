//
//  OfflineAchievementManager.swift
//  Habitica
//
//  Unlocks achievements on-device. Realm is the source of truth, so no
//  server round-trip is needed in standalone mode.
//

import Foundation
import Habitica_Database

final class OfflineAchievementManager {

    static let shared = OfflineAchievementManager()

    private let mutationRepository = OfflineMutationRepository()

    private init() {}

    func record(userID: String,
                completedTask: Bool = false,
                createdTask: Bool = false,
                streakDelta: Int = 0,
                hatchedPet: Bool = false,
                fedPet: Bool = false,
                purchasedEquipment: Bool = false,
                streak: Int? = nil) {
        mutationRepository.applyAchievements(userID: userID,
                                             completedTask: completedTask,
                                             createdTask: createdTask,
                                             streakDelta: streakDelta,
                                             hatchedPet: hatchedPet,
                                             fedPet: fedPet,
                                             purchasedEquipment: purchasedEquipment,
                                             streak: streak)
    }
}
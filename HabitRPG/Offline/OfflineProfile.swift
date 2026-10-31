//
//  OfflineProfile.swift
//  Habitica
//
//  Local profile and avatar editing. Realm is the source of truth, so no
//  server round-trip is needed in standalone mode.
//

import Foundation
import Habitica_Database

final class OfflineProfile {

    static let shared = OfflineProfile()

    private let mutationRepository = OfflineMutationRepository()

    private init() {}

    /// Updates the display name and / or the description text.
    func updateProfile(userID: String, name: String?, blurb: String?) {
        mutationRepository.updateProfile(userID: userID, name: name, blurb: blurb)
    }

    /// Applies avatar changes. `nil` leaves a field untouched.
    func updateAvatar(userID: String,
                      skin: String? = nil,
                      shirt: String? = nil,
                      size: String? = nil,
                      background: String? = nil,
                      chair: String? = nil,
                      hairColor: String? = nil,
                      hairBase: Int? = nil,
                      hairBangs: Int? = nil,
                      hairBeard: Int? = nil,
                      hairMustache: Int? = nil,
                      hairFlower: Int? = nil) {
        mutationRepository.updatePreferences(userID: userID,
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
    }

    /// Writes stat allocation locally. The caller already validated the totals.
    func allocate(userID: String,
                  strength: Int,
                  intelligence: Int,
                  constitution: Int,
                  perception: Int,
                  points: Int) {
        mutationRepository.applyStatAllocation(userID: userID,
                                               strength: strength,
                                               intelligence: intelligence,
                                               constitution: constitution,
                                               perception: perception,
                                               points: points)
    }
}
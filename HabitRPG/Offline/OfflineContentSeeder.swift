//
//  OfflineContentSeeder.swift
//  Habitica
//
//  Seeds the bundled content catalogue into Realm on a clean standalone
//  launch, so shops, gear, quests, pets and drops exist without any
//  network request. The catalogue is a bundled JSON file that mirrors
//  the API content payload; it is decoded with the local content model
//  and saved through ContentLocalRepository.
//  The bundle file must be added to the Habitica target (see content.json
//  next to this file); if it is missing the seed is a no-op and the log
//  says so instead of crashing.
//

import Foundation
import Habitica_Database
import Habitica_Models

final class OfflineContentSeeder {

    static let shared = OfflineContentSeeder()

    private let contentRepository = ContentLocalRepository()
    private let gameRepository = OfflineGameContentRepository()

    private init() {}

    func seedIfNeeded(force: Bool = false) {
        guard OfflineState.shared.isStandalone else {
            return
        }
        if !force {
            guard gameRepository.dropTables().isEmpty else {
                return
            }
        }
        guard let url = Bundle.main.url(forResource: "content", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            logger.log("Offline content seed: bundled content.json not found or invalid")
            return
        }
        // Fully offline: decode the bundled content catalogue directly
        // into the local content repository. No API client is needed.
        contentRepository.save(contentData: data)
        let defaults = UserDefaults.standard
        defaults.set(Date(), forKey: "lastContentFetch")
        defaults.set(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, forKey: "lastContentFetchVersion")
        defaults.set(LanguageHandler.getAppLanguage().code, forKey: "lastContentAppLanguageCode")
        logger.log("Offline content seed: saved bundled catalogue")
    }
}
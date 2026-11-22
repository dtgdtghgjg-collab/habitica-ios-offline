//
//  OfflineContentSeeder.swift
//  Habitica
//
//  Seeds the bundled content catalogue into Realm on a clean standalone
//  launch, so shops, gear, quests, pets and drops exist without any
//  network request. The catalogue is the same payload the API returns;
//  it is decoded with APIContent and saved through ContentLocalRepository.
//  The bundle file must be added to the Habitica target (see content.json
//  next to this file); if it is missing the seed is a no-op and the log
//  says so instead of crashing.
//

import Foundation
import Habitica_API_Client
import Habitica_Database
import Habitica_Models

final class OfflineContentSeeder {

    static let shared = OfflineContentSeeder()

    private let contentRepository = ContentLocalRepository()
    private let gameRepository = OfflineGameContentRepository()

    private init() {}

    func seedIfNeeded() {
        guard OfflineState.shared.isStandalone else {
            return
        }
        guard gameRepository.dropTables().isEmpty else {
            return
        }
        guard let url = Bundle.main.url(forResource: "content", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let content = try? JSONDecoder().decode(APIContent.self, from: data) else {
            logger.log("Offline content seed: bundled content.json not found or invalid")
            return
        }
        contentRepository.save(content)
        let defaults = UserDefaults.standard
        defaults.set(Date(), forKey: "lastContentFetch")
        defaults.set(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, forKey: "lastContentFetchVersion")
        defaults.set(LanguageHandler.getAppLanguage().code, forKey: "lastContentAppLanguageCode")
        logger.log("Offline content seed: saved bundled catalogue")
    }
}

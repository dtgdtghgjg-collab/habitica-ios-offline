//
//  ContentRepository.swift
//  Habitica
//
//  Created by Phillip Thelen on 12.03.18.
//  Copyright © 2018 HabitRPG Inc. All rights reserved.
//

import Foundation
import Habitica_Database
import Habitica_Models
import ReactiveSwift

class ContentRepository: BaseRepository<ContentLocalRepository> {
    
    func retrieveContent(force: Bool = false) -> Signal<ContentProtocol?, Never> {
        // Fully offline: content comes from the bundled seed only.
        return Signal.empty
    }
    
    func retrieveWorldState(force: Bool = false) -> Signal<WorldStateProtocol?, Never> {
        // Fully offline: no server world state.
        return Signal.empty
    }
    
    func getWorldState() -> SignalProducer<WorldStateProtocol, ReactiveSwiftRealmError> {
        return localRepository.getWorldState()
    }
    
    func getFAQEntries(search searchText: String? = nil) -> SignalProducer<ReactiveResults<[FAQEntryProtocol]>, ReactiveSwiftRealmError> {
        return localRepository.getFAQEntries(search: searchText)
    }
    
    func getFAQEntry(index: Int) -> SignalProducer<FAQEntryProtocol, ReactiveSwiftRealmError> {
        return localRepository.getFAQEntry(index: index)
    }
    
    func getSkills(habitClass: String) -> SignalProducer<ReactiveResults<[SkillProtocol]>, ReactiveSwiftRealmError> {
        return localRepository.getSkills(habitClass: habitClass)
    }
    
    func retrieveHallOfContributors() -> Signal<[MemberProtocol]?, Never> {
        // Fully offline: no server hall of contributors.
        return Signal.empty
    }
    
    func retrieveHallOfPatrons() -> Signal<[MemberProtocol]?, Never> {
        // Fully offline: no server hall of patrons.
        return Signal.empty
    }
    
    func clearDatabase() {
        localRepository.clearDatabase()
        ImageManager.clearImageCache()
    }
}

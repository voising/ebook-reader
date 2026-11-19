import Foundation

// How each synced file absorbs a copy that another device saved at the same moment. Merges only ever
// add: something deleted on one device can come back after a true conflict, which beats losing work.

extension BookRecord: CloudMergeable {
    mutating func merge(_ other: BookRecord) {
        let known = Set(highlights.map(\.id))
        highlights += other.highlights.filter { !known.contains($0.id) }
        if (other.noteUpdatedAt ?? .distantPast) > (noteUpdatedAt ?? .distantPast) {
            note = other.note
            noteUpdatedAt = other.noteUpdatedAt
        }
        if other.updatedAt > updatedAt {
            position = other.position ?? position
            progress = other.progress
            updatedAt = other.updatedAt
        }
    }
}

extension LearnData: CloudMergeable {
    mutating func merge(_ other: LearnData) {
        var byID = Dictionary((cards ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var order = (cards ?? []).map(\.id)
        for card in other.cards ?? [] {
            if let mine = byID[card.id] {
                if (card.lastReviewed ?? .distantPast) > (mine.lastReviewed ?? .distantPast) { byID[card.id] = card }
            } else {
                byID[card.id] = card
                order.append(card.id)
            }
        }
        if !order.isEmpty { cards = order.compactMap { byID[$0] } }

        let attemptIDs = Set((attempts ?? []).map(\.id))
        let newAttempts = (other.attempts ?? []).filter { !attemptIDs.contains($0.id) }
        if !newAttempts.isEmpty { attempts = ((attempts ?? []) + newAttempts).sorted { $0.date < $1.date } }

        let seen = Set((reviews ?? []).map { "\($0.cardID)|\($0.date.timeIntervalSince1970)" })
        let newReviews = (other.reviews ?? []).filter { !seen.contains("\($0.cardID)|\($0.date.timeIntervalSince1970)") }
        if !newReviews.isEmpty { reviews = ((reviews ?? []) + newReviews).sorted { $0.date < $1.date } }

        if let theirs = other.maps { maps = (maps ?? [:]).merging(theirs) { mine, _ in mine } }
        if let theirs = other.primers { primers = (primers ?? [:]).merging(theirs) { mine, _ in mine } }
        chat = chat ?? other.chat
        updatedAt = max(updatedAt ?? .distantPast, other.updatedAt ?? .distantPast)
    }
}

extension LibraryLearnData: CloudMergeable {
    mutating func merge(_ other: LibraryLearnData) {
        if (other.linksUpdatedAt ?? .distantPast) > (linksUpdatedAt ?? .distantPast) {
            links = other.links
            linksUpdatedAt = other.linksUpdatedAt
        }
        chat = chat ?? other.chat
    }
}

extension WordFile: CloudMergeable {
    mutating func merge(_ other: WordFile) {
        for theirs in other.words {
            if let i = words.firstIndex(where: { $0.word.caseInsensitiveCompare(theirs.word) == .orderedSame }) {
                if words[i].definition == nil, theirs.definition != nil { words[i] = theirs }
            } else {
                words.append(theirs)
            }
        }
        words.sort { $0.addedAt > $1.addedAt }
    }
}

import Foundation

// How each synced file absorbs a copy that another device saved at the same moment. Merges only ever
// add: something deleted on one device can come back after a true conflict, which beats losing work.

extension BookRecord: CloudMergeable {
    mutating func merge(_ other: BookRecord) {
        mergeReadingHistory(other)
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

    mutating func mergeReadingHistory(_ other: BookRecord) {
        if readPassages != nil || other.readPassages != nil {
            readPassages = ReadPassage.recent((readPassages ?? []) + (other.readPassages ?? []))
        }
        lastReadAt = [lastReadAt, other.lastReadAt].compactMap { $0 }.max()
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
                if words[i].definition == nil, theirs.definition != nil {
                    let mine = words[i].review
                    words[i] = theirs
                    words[i].review = theirs.review ?? mine
                }
                // The copy reviewed more recently keeps its schedule.
                if let card = theirs.review, (card.lastReviewed ?? .distantPast) > (words[i].review?.lastReviewed ?? .distantPast) {
                    words[i].review = card
                }
            } else {
                words.append(theirs)
            }
        }
        words.sort { $0.addedAt > $1.addedAt }
        let seen = Set((reviews ?? []).map { "\($0.cardID)|\($0.date.timeIntervalSince1970)" })
        let new = (other.reviews ?? []).filter { !seen.contains("\($0.cardID)|\($0.date.timeIntervalSince1970)") }
        if !new.isEmpty { reviews = ((reviews ?? []) + new).sorted { $0.date < $1.date } }
    }
}

// MARK: - Saving without undoing another device

extension LearnData {
    /// The ids this device knew about at its last load or save.
    struct Known {
        var cards: Set<String> = []
        var attempts: Set<String> = []
    }

    var knownIDs: Known {
        Known(cards: Set((cards ?? []).map(\.id)), attempts: Set((attempts ?? []).map(\.id)))
    }

    /// Takes in what `disk` gained or lost since `known` was recorded, keeping everything made here.
    mutating func absorb(_ disk: LearnData, known: Known) {
        let diskCards = Dictionary((disk.cards ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var mine = (cards ?? []).filter { diskCards[$0.id] != nil || !known.cards.contains($0.id) }
        for i in mine.indices {
            // A card reviewed more recently on the other device keeps that schedule.
            if let theirs = diskCards[mine[i].id], (theirs.lastReviewed ?? .distantPast) > (mine[i].lastReviewed ?? .distantPast) {
                mine[i] = theirs
            }
        }
        let mineIDs = Set((cards ?? []).map(\.id))
        mine += (disk.cards ?? []).filter { !mineIDs.contains($0.id) && !known.cards.contains($0.id) }
        if cards != nil || !mine.isEmpty { cards = mine }

        let diskAttempts = Set((disk.attempts ?? []).map(\.id)), mineAttempts = Set((attempts ?? []).map(\.id))
        var kept = (attempts ?? []).filter { diskAttempts.contains($0.id) || !known.attempts.contains($0.id) }
        kept += (disk.attempts ?? []).filter { !mineAttempts.contains($0.id) && !known.attempts.contains($0.id) }
        if attempts != nil || !kept.isEmpty { attempts = kept.sorted { $0.date < $1.date } }

        let seen = Set((reviews ?? []).map { "\($0.cardID)|\($0.date.timeIntervalSince1970)" })
        let newReviews = (disk.reviews ?? []).filter { !seen.contains("\($0.cardID)|\($0.date.timeIntervalSince1970)") }
        if !newReviews.isEmpty { reviews = ((reviews ?? []) + newReviews).sorted { $0.date < $1.date } }

        if let theirs = disk.maps { maps = (maps ?? [:]).merging(theirs) { here, _ in here } }
        if let theirs = disk.primers { primers = (primers ?? [:]).merging(theirs) { here, _ in here } }
    }
}

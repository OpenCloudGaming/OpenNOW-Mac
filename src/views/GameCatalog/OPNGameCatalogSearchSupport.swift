import Foundation

@objc(OPNGameCatalogSearchSupport)
final class OPNGameCatalogSearchSupport: NSObject {
    @objc(normalizedString:)
    static func normalizedString(_ value: String?) -> String {
        let folded = (value ?? "").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        var normalized = ""
        normalized.reserveCapacity(folded.count)
        var previousWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                normalized.unicodeScalars.append(scalar)
                previousWasSpace = false
            } else if !previousWasSpace {
                normalized.append(" ")
                previousWasSpace = true
            }
        }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc(scoreForTitle:query:)
    static func score(forTitle title: String?, query: String?) -> Int {
        let normalizedQuery = normalizedString(query)
        if normalizedQuery.isEmpty { return 1 }
        let normalizedTitle = normalizedString(title)
        if normalizedTitle.isEmpty { return 0 }
        let queryTokens = tokens(normalizedQuery)
        let titleTokens = tokens(normalizedTitle)
        if queryTokens.isEmpty || titleTokens.isEmpty { return 0 }

        var score = 0
        if normalizedTitle == normalizedQuery {
            score += 1200
        } else if normalizedTitle.hasPrefix(normalizedQuery) {
            score += 850
        } else if normalizedTitle.contains(normalizedQuery) {
            score += 650
        }

        let titleAcronym = acronym(titleTokens)
        let queryAcronym = normalizedQuery.replacingOccurrences(of: " ", with: "")
        if queryAcronym.count > 1 && titleAcronym.hasPrefix(queryAcronym) { score += 420 }

        var tokenScore = 0
        for queryToken in queryTokens {
            let best = tokenScoreFor(queryToken: queryToken, titleTokens: titleTokens)
            if best <= 0 { return score >= 650 ? score : 0 }
            tokenScore += best
        }
        score += tokenScore
        score += max(0, 80 - normalizedTitle.count)
        return score
    }

    private static func tokens(_ normalized: String) -> [String] {
        if normalized.isEmpty { return [] }
        return normalized.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }

    private static func acronym(_ tokens: [String]) -> String {
        tokens.compactMap { $0.first }.map(String.init).joined()
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        if needle.isEmpty { return true }
        var needleIndex = needle.startIndex
        for character in haystack where needleIndex < needle.endIndex {
            if character == needle[needleIndex] {
                needleIndex = needle.index(after: needleIndex)
            }
        }
        return needleIndex == needle.endIndex
    }

    private static func editDistance(_ left: String, _ right: String, limit: Int) -> Int {
        let leftCharacters = Array(left)
        let rightCharacters = Array(right)
        if leftCharacters.isEmpty { return rightCharacters.count }
        if rightCharacters.isEmpty { return leftCharacters.count }
        if abs(leftCharacters.count - rightCharacters.count) > limit { return limit + 1 }

        var previous = Array(0...rightCharacters.count)
        var current = Array(repeating: 0, count: rightCharacters.count + 1)
        for leftIndex in 1...leftCharacters.count {
            current[0] = leftIndex
            var best = current[0]
            let leftCharacter = leftCharacters[leftIndex - 1]
            for rightIndex in 1...rightCharacters.count {
                let cost = leftCharacter == rightCharacters[rightIndex - 1] ? 0 : 1
                current[rightIndex] = min(current[rightIndex - 1] + 1, previous[rightIndex] + 1, previous[rightIndex - 1] + cost)
                best = min(best, current[rightIndex])
            }
            if best > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[rightCharacters.count]
    }

    private static func tokenScoreFor(queryToken: String, titleTokens: [String]) -> Int {
        var best = 0
        for titleToken in titleTokens {
            if titleToken == queryToken {
                best = max(best, 120)
            } else if titleToken.hasPrefix(queryToken) {
                best = max(best, 95 - min(20, titleToken.count - queryToken.count))
            } else if titleToken.contains(queryToken) {
                best = max(best, 70)
            } else if queryToken.count >= 3 && isSubsequence(queryToken, of: titleToken) {
                best = max(best, 48)
            }
            if queryToken.count >= 4 {
                let limit = queryToken.count <= 5 ? 1 : 2
                let distance = editDistance(queryToken, titleToken, limit: limit)
                if distance <= limit { best = max(best, 58 - distance * 12) }
            }
        }
        return best
    }
}

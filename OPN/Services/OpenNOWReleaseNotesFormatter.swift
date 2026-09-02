import Foundation

/// Structured form of a GitHub release body.
///
/// The bodies OpenNOW receives are release-please output: a version heading, `###` type
/// headings, and one bullet per commit ending in a link to the commit or pull request. The
/// links carry the same information as the short SHA in a tenth of the width, so the parser
/// lifts them out of the prose and the views render them as chips.
struct OpenNOWReleaseNotes: Equatable, Sendable {
    struct Entry: Equatable, Sendable, Identifiable {
        let id: String
        let text: String
        /// Inline markdown resolved once at parse time; rendering it per row would re-run the
        /// markdown parser on every scroll frame.
        let attributedText: AttributedString
        let commitShortSHA: String?
        let commitURL: URL?
        let pullRequest: Int?
        let pullRequestURL: URL?
        let author: String?
    }

    enum Kind: String, Equatable, Sendable {
        case features
        case fixes
        case performance
        case reverts
        case documentation
        case other
    }

    struct Section: Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        let kind: Kind
        let entries: [Entry]
        let paragraphs: [String]
    }

    let sections: [Section]
    let paragraphs: [String]
    let compareURL: URL?

    static let empty = OpenNOWReleaseNotes(sections: [], paragraphs: [], compareURL: nil)

    var isEmpty: Bool {
        sections.isEmpty && paragraphs.isEmpty
    }

    var entryCount: Int {
        sections.reduce(0) { $0 + $1.entries.count }
    }
}

/// Block-level markdown reader for release bodies.
///
/// Deliberately not a general markdown parser: it recognises the shapes release-please and the
/// GitHub "generate release notes" button emit, and everything it does not recognise survives as
/// plain paragraph text rather than being dropped. Inline syntax (bold, links) is left to
/// `attributedText(_:)`, which hands it to Foundation.
enum OpenNOWReleaseNotesFormatter {
    private static let fallbackSectionTitle = "Changes"

    static func parse(_ body: String) -> OpenNOWReleaseNotes {
        var sections: [DraftSection] = []
        var paragraphs: [String] = []
        var compareURL: URL?

        for rawLine in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if let heading = headingText(in: line) {
                if let versionLink = versionHeadingURL(in: heading) {
                    compareURL = compareURL ?? versionLink.url
                    continue
                }
                sections.append(DraftSection(title: cleanedHeading(heading)))
                continue
            }

            if let changelogURL = fullChangelogURL(in: line) {
                compareURL = compareURL ?? changelogURL
                continue
            }

            if let bullet = bulletText(in: line) {
                if sections.isEmpty { sections.append(DraftSection(title: fallbackSectionTitle)) }
                sections[sections.count - 1].entrySources.append(bullet)
                continue
            }

            let isContinuation = rawLine.hasPrefix("  ") || rawLine.hasPrefix("\t")
            if isContinuation, var section = sections.last, !section.entrySources.isEmpty {
                section.entrySources[section.entrySources.count - 1] += " " + line
                sections[sections.count - 1] = section
                continue
            }

            if sections.isEmpty {
                paragraphs.append(line)
            } else {
                sections[sections.count - 1].paragraphs.append(line)
            }
        }

        let builtSections = sections.enumerated().compactMap { index, draft -> OpenNOWReleaseNotes.Section? in
            guard !draft.entrySources.isEmpty || !draft.paragraphs.isEmpty else { return nil }
            let entries = draft.entrySources.enumerated().map { entryIndex, source in
                makeEntry(source: source, fallbackID: "\(index).\(entryIndex)")
            }
            return OpenNOWReleaseNotes.Section(
                id: "\(index).\(draft.title)",
                title: draft.title,
                kind: kind(for: draft.title),
                entries: entries,
                paragraphs: draft.paragraphs
            )
        }

        return OpenNOWReleaseNotes(sections: builtSections, paragraphs: paragraphs, compareURL: compareURL)
    }

    /// Inline markdown only. `interpretedSyntax` is the difference between rendering `**ci:**` as a
    /// bold run and rendering it as four literal asterisks; the plain-text fallback keeps a body
    /// with broken inline syntax readable instead of empty.
    static func attributedText(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let attributed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        return attributed
    }

    private struct DraftSection {
        let title: String
        var entrySources: [String] = []
        var paragraphs: [String] = []
    }

    private static func headingText(in line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let stripped = line.drop { $0 == "#" }
        guard stripped.hasPrefix(" ") else { return nil }
        let text = stripped.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func cleanedHeading(_ heading: String) -> String {
        var text = heading
        while text.hasPrefix("*") || text.hasPrefix("_") { text.removeFirst() }
        while text.hasSuffix("*") || text.hasSuffix("_") || text.hasSuffix(":") { text.removeLast() }
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? fallbackSectionTitle : cleaned
    }

    /// A release-please body opens with `## [0.2.0](compare-url) (date)`. That heading duplicates
    /// the version the modal already shows in its title, so it becomes the "full changelog" link
    /// rather than a section.
    private static func versionHeadingURL(in heading: String) -> (label: String, url: URL?)? {
        if let link = leadingLink(in: heading), isVersionLabel(link.label) {
            return (link.label, URL(string: link.url))
        }
        return isVersionLabel(heading) ? (heading, nil) : nil
    }

    private static func isVersionLabel(_ label: String) -> Bool {
        var text = label.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        guard let first = text.first, first.isNumber else { return false }
        return text.contains(".")
    }

    private static func leadingLink(in text: String) -> (label: String, url: String)? {
        guard text.hasPrefix("[") else { return nil }
        guard let labelEnd = text.firstIndex(of: "]") else { return nil }
        let afterLabel = text.index(after: labelEnd)
        guard afterLabel < text.endIndex, text[afterLabel] == "(" else { return nil }
        guard let urlEnd = text[afterLabel...].firstIndex(of: ")") else { return nil }
        let label = String(text[text.index(after: text.startIndex)..<labelEnd])
        let url = String(text[text.index(after: afterLabel)..<urlEnd])
        return (label, url)
    }

    private static func fullChangelogURL(in line: String) -> URL? {
        let lowercased = line.lowercased()
        guard lowercased.contains("full changelog") else { return nil }
        guard let separator = line.firstIndex(of: ":") else { return nil }
        let tail = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        if let link = leadingLink(in: tail) { return URL(string: link.url) }
        guard tail.hasPrefix("http") else { return nil }
        return URL(string: tail.components(separatedBy: .whitespaces)[0])
    }

    private static func bulletText(in line: String) -> String? {
        for marker in ["* ", "- ", "+ "] where line.hasPrefix(marker) {
            let text = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        guard let dot = line.firstIndex(of: "."), line[line.startIndex..<dot].allSatisfy(\.isNumber) else { return nil }
        let afterDot = line.index(after: dot)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        let text = line[line.index(after: afterDot)...].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func makeEntry(source: String, fallbackID: String) -> OpenNOWReleaseNotes.Entry {
        var text = source
        var commitShortSHA: String?
        var commitURL: URL?
        var pullRequest: Int?
        var pullRequestURL: URL?
        var author: String?

        if let attribution = strippedAttribution(from: text) {
            text = attribution.remainder
            author = attribution.author
            pullRequest = attribution.pullRequest
            pullRequestURL = attribution.url
        }

        while let link = strippedTrailingLink(from: text) {
            if let number = pullRequestNumber(in: link.label) {
                pullRequest = pullRequest ?? number
                pullRequestURL = pullRequestURL ?? URL(string: link.url)
            } else if isCommitHash(link.label) {
                commitShortSHA = commitShortSHA ?? String(link.label.prefix(7))
                commitURL = commitURL ?? URL(string: link.url)
            } else {
                break
            }
            text = link.remainder
        }

        let cleanedText = sentenceCased(text.trimmingCharacters(in: .whitespaces))
        return OpenNOWReleaseNotes.Entry(
            id: commitShortSHA ?? "\(fallbackID)",
            text: cleanedText,
            attributedText: attributedText(cleanedText),
            commitShortSHA: commitShortSHA,
            commitURL: commitURL,
            pullRequest: pullRequest,
            pullRequestURL: pullRequestURL,
            author: author
        )
    }

    /// Trailing `([b0b3b94](https://…/commit/b0b3b94…))` — the release-please commit reference, and
    /// the single biggest source of noise in the raw body.
    private static func strippedTrailingLink(from text: String) -> (label: String, url: String, remainder: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("))") else { return nil }
        guard let openRange = trimmed.range(of: "([", options: .backwards) else { return nil }
        let tail = trimmed[openRange.lowerBound...]
        guard let labelEnd = tail.range(of: "](") else { return nil }
        let label = String(tail[tail.index(tail.startIndex, offsetBy: 2)..<labelEnd.lowerBound])
        let url = String(tail[labelEnd.upperBound..<tail.index(tail.endIndex, offsetBy: -2)])
        guard !label.isEmpty, !url.isEmpty, !url.contains(" ") else { return nil }
        let remainder = String(trimmed[trimmed.startIndex..<openRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        return (label, url, remainder)
    }

    /// Trailing `by @user in https://…/pull/12` — the shape GitHub's own generated notes use.
    private static func strippedAttribution(from text: String) -> (author: String, pullRequest: Int?, url: URL?, remainder: String)? {
        guard let byRange = text.range(of: " by @", options: .backwards) else { return nil }
        let tail = text[byRange.upperBound...].trimmingCharacters(in: .whitespaces)
        let parts = tail.components(separatedBy: " in ")
        let author = parts[0].trimmingCharacters(in: .whitespaces)
        guard !author.isEmpty, author.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        let remainder = String(text[text.startIndex..<byRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard parts.count > 1 else { return (author, nil, nil, remainder) }
        let urlText = parts[1].trimmingCharacters(in: .whitespaces)
        guard urlText.hasPrefix("http") else { return (author, nil, nil, remainder) }
        let url = URL(string: urlText)
        let number = urlText.components(separatedBy: "/").last.flatMap(Int.init)
        return (author, number, url, remainder)
    }

    private static func pullRequestNumber(in label: String) -> Int? {
        guard label.hasPrefix("#") else { return nil }
        return Int(label.dropFirst())
    }

    private static func isCommitHash(_ label: String) -> Bool {
        label.count >= 6 && label.allSatisfy(\.isHexDigit)
    }

    /// Commit subjects are lowercase by convention; the notes read as prose, so the first letter is
    /// lifted. Bold scope prefixes (`**ci:** …`) start with punctuation and are left alone.
    private static func sentenceCased(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return text.replacingCharacters(in: text.startIndex...text.startIndex, with: first.uppercased())
    }

    private static func kind(for title: String) -> OpenNOWReleaseNotes.Kind {
        let lowercased = title.lowercased()
        if lowercased.contains("feature") { return .features }
        if lowercased.contains("fix") { return .fixes }
        if lowercased.contains("performance") { return .performance }
        if lowercased.contains("revert") { return .reverts }
        if lowercased.contains("doc") { return .documentation }
        return .other
    }
}

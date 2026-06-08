#import "OPNGameCatalogPrivate.h"

NSString *OPNStoreSearchNormalizedString(NSString *value) {
    NSString *folded = [[value ?: @"" stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch locale:NSLocale.currentLocale] lowercaseString];
    NSMutableString *normalized = [NSMutableString stringWithCapacity:folded.length];
    NSCharacterSet *alphanumeric = NSCharacterSet.alphanumericCharacterSet;
    BOOL previousWasSpace = YES;
    for (NSUInteger i = 0; i < folded.length; i++) {
        unichar c = [folded characterAtIndex:i];
        if ([alphanumeric characterIsMember:c]) {
            [normalized appendFormat:@"%C", c];
            previousWasSpace = NO;
        } else if (!previousWasSpace) {
            [normalized appendString:@" "];
            previousWasSpace = YES;
        }
    }
    return [normalized stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

NSArray<NSString *> *OPNStoreSearchTokens(NSString *normalized) {
    if (normalized.length == 0) return @[];
    NSArray<NSString *> *rawTokens = [normalized componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *token in rawTokens) {
        if (token.length > 0) [tokens addObject:token];
    }
    return tokens;
}

NSString *OPNStoreSearchAcronym(NSArray<NSString *> *tokens) {
    NSMutableString *acronym = [NSMutableString stringWithCapacity:tokens.count];
    for (NSString *token in tokens) {
        if (token.length > 0) [acronym appendString:[token substringToIndex:1]];
    }
    return acronym;
}

BOOL OPNStoreSearchIsSubsequence(NSString *needle, NSString *haystack) {
    if (needle.length == 0) return YES;
    NSUInteger needleIndex = 0;
    for (NSUInteger i = 0; i < haystack.length && needleIndex < needle.length; i++) {
        if ([needle characterAtIndex:needleIndex] == [haystack characterAtIndex:i]) needleIndex++;
    }
    return needleIndex == needle.length;
}

NSInteger OPNStoreSearchEditDistance(NSString *left, NSString *right, NSInteger limit) {
    NSUInteger leftLength = left.length;
    NSUInteger rightLength = right.length;
    if (leftLength == 0) return (NSInteger)rightLength;
    if (rightLength == 0) return (NSInteger)leftLength;
    if (llabs((long long)leftLength - (long long)rightLength) > limit) return limit + 1;

    std::vector<NSInteger> previous(rightLength + 1, 0);
    std::vector<NSInteger> current(rightLength + 1, 0);
    for (NSUInteger j = 0; j <= rightLength; j++) previous[j] = (NSInteger)j;
    for (NSUInteger i = 1; i <= leftLength; i++) {
        current[0] = (NSInteger)i;
        NSInteger best = current[0];
        unichar leftChar = [left characterAtIndex:i - 1];
        for (NSUInteger j = 1; j <= rightLength; j++) {
            NSInteger cost = leftChar == [right characterAtIndex:j - 1] ? 0 : 1;
            current[j] = MIN(MIN(current[j - 1] + 1, previous[j] + 1), previous[j - 1] + cost);
            best = MIN(best, current[j]);
        }
        if (best > limit) return limit + 1;
        std::swap(previous, current);
    }
    return previous[rightLength];
}

NSInteger OPNStoreSearchTokenScore(NSString *queryToken, NSArray<NSString *> *titleTokens) {
    NSInteger best = 0;
    for (NSString *titleToken in titleTokens) {
        if ([titleToken isEqualToString:queryToken]) best = MAX(best, 120);
        else if ([titleToken hasPrefix:queryToken]) best = MAX(best, 95 - (NSInteger)MIN((NSUInteger)20, titleToken.length - queryToken.length));
        else if ([titleToken containsString:queryToken]) best = MAX(best, 70);
        else if (queryToken.length >= 3 && OPNStoreSearchIsSubsequence(queryToken, titleToken)) best = MAX(best, 48);
        if (queryToken.length >= 4) {
            NSInteger limit = queryToken.length <= 5 ? 1 : 2;
            NSInteger distance = OPNStoreSearchEditDistance(queryToken, titleToken, limit);
            if (distance <= limit) best = MAX(best, 58 - distance * 12);
        }
    }
    return best;
}

NSInteger OPNStoreSearchScoreForTitle(NSString *title, NSString *query) {
    NSString *normalizedQuery = OPNStoreSearchNormalizedString(query);
    if (normalizedQuery.length == 0) return 1;
    NSString *normalizedTitle = OPNStoreSearchNormalizedString(title);
    if (normalizedTitle.length == 0) return 0;
    NSArray<NSString *> *queryTokens = OPNStoreSearchTokens(normalizedQuery);
    NSArray<NSString *> *titleTokens = OPNStoreSearchTokens(normalizedTitle);
    if (queryTokens.count == 0 || titleTokens.count == 0) return 0;

    NSInteger score = 0;
    if ([normalizedTitle isEqualToString:normalizedQuery]) score += 1200;
    else if ([normalizedTitle hasPrefix:normalizedQuery]) score += 850;
    else if ([normalizedTitle containsString:normalizedQuery]) score += 650;

    NSString *titleAcronym = OPNStoreSearchAcronym(titleTokens);
    NSString *queryAcronym = [normalizedQuery stringByReplacingOccurrencesOfString:@" " withString:@""];
    if (queryAcronym.length > 1 && [titleAcronym hasPrefix:queryAcronym]) score += 420;

    NSInteger tokenScore = 0;
    for (NSString *queryToken in queryTokens) {
        NSInteger best = OPNStoreSearchTokenScore(queryToken, titleTokens);
        if (best <= 0) return score >= 650 ? score : 0;
        tokenScore += best;
    }
    score += tokenScore;
    score += MAX(0, 80 - (NSInteger)normalizedTitle.length);
    return score;
}

std::vector<OPN::GameInfo> OPNStoreSearchFilteredGames(const std::vector<OPN::GameInfo> &games, NSString *query) {
    if (OPNStoreSearchNormalizedString(query).length == 0) return games;
    std::vector<std::pair<NSInteger, OPN::GameInfo>> scored;
    scored.reserve(games.size());
    for (const OPN::GameInfo &game : games) {
        NSInteger score = OPNStoreSearchScoreForTitle(OPNStoreString(game.title, @""), query);
        if (score > 0) scored.push_back({score, game});
    }
    std::stable_sort(scored.begin(), scored.end(), [](const auto &left, const auto &right) {
        return left.first > right.first;
    });
    std::vector<OPN::GameInfo> result;
    result.reserve(scored.size());
    for (const auto &entry : scored) result.push_back(entry.second);
    return result;
}

std::vector<OPN::PanelResult> OPNStoreSearchFilteredPanels(const std::vector<OPN::PanelResult> &panels, NSString *query) {
    if (OPNStoreSearchNormalizedString(query).length == 0) return panels;
    std::vector<OPN::PanelResult> filteredPanels;
    for (const OPN::PanelResult &panel : panels) {
        OPN::PanelResult filteredPanel = panel;
        filteredPanel.sections.clear();
        for (const OPN::PanelSection &section : panel.sections) {
            OPN::PanelSection filteredSection = section;
            filteredSection.games = OPNStoreSearchFilteredGames(section.games, query);
            if (!filteredSection.games.empty()) filteredPanel.sections.push_back(filteredSection);
        }
        if (!filteredPanel.sections.empty()) filteredPanels.push_back(filteredPanel);
    }
    return filteredPanels;
}

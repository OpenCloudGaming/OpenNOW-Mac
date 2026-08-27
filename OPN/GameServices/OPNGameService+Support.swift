//
//  OpenNOW
//

import AppKit
import Foundation


final class RecursiveCatalogPageFetcher: @unchecked Sendable {
    var action: (@Sendable (_ page: Int, _ cursor: String) -> Void)?
}

final class NSDictionaryBox: @unchecked Sendable {
    let value: NSDictionary

    init(_ value: NSDictionary) {
        self.value = value
    }
}

final class NSDictionaryArrayBox: @unchecked Sendable {
    let values: [NSDictionary]

    init(_ values: [NSDictionary]) {
        self.values = values
    }
}

//  How the keyboard-and-mouse home page lays out its catalog: Classic keeps the hero banner and
//  wide landscape tiles, Poster switches to rows of portrait box-art tiles.
//

import Foundation

enum OpenNOWHomeLayout {
    enum Mode: String, CaseIterable {
        case classic
        case poster

        var label: String {
            switch self {
            case .classic: "Classic"
            case .poster: "Poster"
            }
        }
    }

    static let modeKey = "OpenNOW.Interface.HomeLayout"
}

//  Owns the controller plumbing the Interface settings page reads to decide whether a pad is
//  attached and which glyph set to draw.
//
//  The page used to construct `ControllerInputRouter` and `GamepadUINavigator` itself, which put a
//  service's lifetime in a view's hands. It owns this instead, and this owns them.
//

import Combine
import Foundation

@MainActor
final class InterfaceSettingsViewModel: ObservableObject {
    let inputRouter: ControllerInputRouter
    let steamNavigator: GamepadUINavigator

    private var cancellables: Set<AnyCancellable> = []

    init(inputRouter: ControllerInputRouter = ControllerInputRouter(), steamNavigator: GamepadUINavigator = GamepadUINavigator()) {
        self.inputRouter = inputRouter
        self.steamNavigator = steamNavigator
        // Both are `ObservableObject`s in their own right. Republishing keeps the page redrawing on
        // a controller connecting or disconnecting, which is what the two `@StateObject`s did.
        inputRouter.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        steamNavigator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    var isAnyControllerConnected: Bool {
        inputRouter.isControllerConnected || steamNavigator.isSteamControllerConnected
    }

    var activeGlyphs: ControllerInputGlyphSet {
        inputRouter.isControllerConnected ? inputRouter.glyphs : steamNavigator.glyphs
    }
}

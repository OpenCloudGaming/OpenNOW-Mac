import SwiftUI

/// A controller command handed to a page that controller mode embeds but does not own.
///
/// Recordings and Settings are desktop views with their own selection state, so controller mode
/// cannot drive them by reaching into that state. Instead it publishes the command it received and
/// each page decides what the move means for it - a row in a list, a tab in a bar. `sequence`
/// makes repeats of the same command distinct, so holding a direction still registers each press.
struct ControllerPageCommand: Equatable {
    let command: ControllerInputCommand
    let sequence: Int
}

private struct ControllerPageCommandKey: EnvironmentKey {
    static let defaultValue: ControllerPageCommand? = nil
}

extension EnvironmentValues {
    /// Nil everywhere except inside controller mode's embedded pages, so the same views keep
    /// working unchanged on the desktop surface.
    var controllerPageCommand: ControllerPageCommand? {
        get { self[ControllerPageCommandKey.self] }
        set { self[ControllerPageCommandKey.self] = newValue }
    }
}

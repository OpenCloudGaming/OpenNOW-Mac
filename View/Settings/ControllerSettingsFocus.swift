//
//  ControllerSettingsFocus.swift
//  OpenNOW
//

import Combine
import SwiftUI

/// Makes the Settings pages operable from a pad.
///
/// The settings surface is built from a handful of reusable rows, so rather than annotating every
/// page, each row type opts in once with `controllerFocusable`. Rows report their vertical position
/// through a preference, which is what gives the pad a traversal order that always matches what is
/// on screen - including rows that appear and disappear as other settings change - without any page
/// having to declare one.
@MainActor
final class ControllerSettingsFocus: ObservableObject {
    @Published private(set) var focusedID: String?
    @Published private(set) var isActive = false
    /// The latest command aimed at the focused row. Rows act on it from their current render, so
    /// they always read live values.
    @Published private(set) var rowCommand: ControllerPageCommand?

    private var orderedIDs: [String] = []
    private var commandSequence = 0

    /// Sends a command to whichever row is focused.
    ///
    /// Deliberately not a stored per-row closure: a closure captured when the row appeared holds
    /// that render's values forever, so a toggle's `activate` kept writing `!staleIsOn` and stopped
    /// having any effect after the first press. Publishing the command instead lets the row handle
    /// it from its current body, where `isOn`/`value`/`selectedIndex` are live.
    func send(_ command: ControllerInputCommand) {
        guard focusedID != nil else { return }
        commandSequence += 1
        rowCommand = ControllerPageCommand(command: command, sequence: commandSequence)
    }

    /// Called with every row's measured position; the pad walks them top to bottom.
    func setOrder(_ entries: [ControllerFocusEntry]) {
        let ids = entries.sorted { $0.y < $1.y }.map(\.id)
        guard ids != orderedIDs else { return }
        orderedIDs = ids
        guard let focusedID, !ids.contains(focusedID) else { return }
        self.focusedID = ids.first
    }

    /// Controller mode drives this; on the desktop surface it stays off so no focus ring appears.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if !active { focusedID = nil }
    }

    func focus(_ id: String) {
        guard orderedIDs.contains(id) else { return }
        focusedID = id
    }

    @discardableResult
    func focusFirstIfNeeded() -> Bool {
        guard focusedID == nil, let first = orderedIDs.first else { return false }
        focusedID = first
        return true
    }

    func move(delta: Int) {
        guard !orderedIDs.isEmpty else { return }
        guard let focusedID, let current = orderedIDs.firstIndex(of: focusedID) else {
            self.focusedID = orderedIDs.first
            return
        }
        let next = min(max(current + delta, 0), orderedIDs.count - 1)
        self.focusedID = orderedIDs[next]
    }

}

struct ControllerFocusEntry: Equatable {
    let id: String
    let y: CGFloat
}

struct ControllerFocusOrderKey: PreferenceKey {
    static let defaultValue: [ControllerFocusEntry] = []

    static func reduce(value: inout [ControllerFocusEntry], nextValue: () -> [ControllerFocusEntry]) {
        value.append(contentsOf: nextValue())
    }
}

/// Coordinate space the row positions are measured in.
let controllerSettingsFocusSpace = "opn-settings-focus"

private struct ControllerSettingsFocusKey: EnvironmentKey {
    static let defaultValue: ControllerSettingsFocus? = nil
}

private struct ControllerFocusedRowKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private struct ControllerFocusActiveKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ControllerRowCommandKey: EnvironmentKey {
    static let defaultValue: ControllerPageCommand? = nil
}

extension EnvironmentValues {
    /// Optional on purpose. These rows are shared components - `SteamControllerMappingView` renders
    /// some of them from the stream surface, outside any Settings page - and an `@EnvironmentObject`
    /// traps when it is missing. A nil registry simply means "no pad focus here".
    var controllerSettingsFocus: ControllerSettingsFocus? {
        get { self[ControllerSettingsFocusKey.self] }
        set { self[ControllerSettingsFocusKey.self] = newValue }
    }

    /// The focused row, published as a plain value. `@Environment` holding the registry object does
    /// not subscribe to its `@Published` changes, so a ring driven straight off the object would
    /// never redraw; the owning view pushes the id down instead. Nil whenever pad focus is off.
    var controllerFocusedRowID: String? {
        get { self[ControllerFocusedRowKey.self] }
        set { self[ControllerFocusedRowKey.self] = newValue }
    }

    /// The latest command for the focused row, pushed down as a value so the row that handles it is
    /// the one currently rendered.
    var controllerRowCommand: ControllerPageCommand? {
        get { self[ControllerRowCommandKey.self] }
        set { self[ControllerRowCommandKey.self] = newValue }
    }

    /// Gates the position reporting. False on the desktop surface, where the measured order is
    /// collected and sorted on every scroll frame and then read by nothing.
    var controllerFocusActive: Bool {
        get { self[ControllerFocusActiveKey.self] }
        set { self[ControllerFocusActiveKey.self] = newValue }
    }
}

private struct ControllerFocusableModifier: ViewModifier {
    let id: String
    let activate: (() -> Void)?
    let adjust: ((Int) -> Void)?

    @Environment(\.controllerFocusedRowID) private var focusedRowID
    @Environment(\.controllerFocusActive) private var isActive
    @Environment(\.controllerRowCommand) private var rowCommand

    /// Completely inert until a pad is actually driving the page.
    ///
    /// This wraps shared settings rows, so anything it adds is added to every control on the
    /// desktop surface too - including an `.id()`, which hands the row explicit identity and is a
    /// blunt instrument to point at a live `Toggle` or `Slider` for no reason. When no controller
    /// is driving there is nothing to order, focus or scroll to, so the modifier adds nothing at
    /// all and those controls behave exactly as they did before pad support existed.
    @ViewBuilder func body(content: Content) -> some View {
        if isActive {
            content
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ControllerFocusOrderKey.self,
                            value: [ControllerFocusEntry(id: id, y: proxy.frame(in: .named(controllerSettingsFocusSpace)).minY)]
                        )
                    }
                }
                .openNowFocusRing(focusedRowID == id)
                .id(id)
                .onChange(of: rowCommand) { _, command in
                    guard let command, focusedRowID == id else { return }
                    handle(command.command)
                }
        } else {
            content
        }
    }

    private func handle(_ command: ControllerInputCommand) {
        switch command {
        case .confirm: activate?()
        case .move(.left): adjust?(-1)
        case .move(.right): adjust?(1)
        default: break
        }
    }
}

extension View {
    /// Opts a row into pad traversal. `adjust` is for rows that change value in place (sliders,
    /// option pickers); rows that only act on press leave it nil.
    ///
    /// `id` exists for the handful of call sites that address a row by name. Everything else should
    /// use the `ControllerFocusIdentity` overload: ordering comes from measured position, so the id
    /// only has to be unique - deriving it from display copy makes two same-titled rows collide and
    /// makes copy-editing a title silently drop focus.
    func controllerFocusable(id: String, activate: (() -> Void)? = nil, adjust: ((Int) -> Void)? = nil) -> some View {
        modifier(ControllerFocusableModifier(id: id, activate: activate, adjust: adjust))
    }

    func controllerFocusable(_ identity: ControllerFocusIdentity, activate: (() -> Void)? = nil, adjust: ((Int) -> Void)? = nil) -> some View {
        modifier(ControllerFocusableModifier(id: identity.id, activate: activate, adjust: adjust))
    }
}

/// A per-instance focus id, independent of the row's text.
///
/// Rows MUST hold this in `@State`, never a plain `let`: a stored property's default expression is
/// re-evaluated every time a SwiftUI view struct is built, so a `let` would mint a new id on every
/// render, and the `.id()` the modifier applies would tear the row's identity down and rebuild it
/// each pass - which loses its state and breaks interaction with the control inside.
struct ControllerFocusIdentity {
    let id: String

    init() { id = UUID().uuidString }
}

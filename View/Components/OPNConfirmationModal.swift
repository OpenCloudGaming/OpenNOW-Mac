import Combine
import SwiftUI

/// A footer action in an app-shell confirmation modal.
///
/// `role` decides the button style and the keyboard mapping; `handler` owns the outcome. A handler
/// clears the state that presented the modal (or sets `isPresented` false), which dismisses it —
/// the presenter does not force a dismissal ahead of the handler.
struct OPNConfirmationAction {
    enum Role {
        /// Neutral action, rightmost. Enter triggers it.
        case standard
        /// Action that destroys or discards. Carries the destructive tone, never the default.
        case destructive
        /// Dismissive action, left of the others. Escape triggers it.
        case cancel
    }

    let title: String
    let role: Role
    let handler: () -> Void

    init(_ title: String, role: Role = .standard, handler: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.handler = handler
    }
}

/// Window-level state for the app-shell confirmation modal. Mounted by `OPNConfirmationOverlay`
/// at the app root so a confirmation reaches every surface — including pages that live inside a
/// scroll view, where a page-local overlay would render inside the scrollable content.
@MainActor
final class OPNConfirmationPresentation: ObservableObject {
    static let shared = OPNConfirmationPresentation()

    struct Request {
        let eyebrow: String
        let title: String
        let message: String
        let actions: [OPNConfirmationAction]
    }

    @Published private(set) var request: Request?
    private var onDismiss: (() -> Void)?

    func present(_ request: Request, onDismiss: @escaping () -> Void) {
        self.request = request
        self.onDismiss = onDismiss
    }

    /// Clears the modal and asks whoever presented it to clear its own state. Safe to call when
    /// nothing is presented.
    func dismiss() {
        guard request != nil else { return }
        request = nil
        let dismissHandler = onDismiss
        onDismiss = nil
        dismissHandler?()
    }
}

/// The scrim and centered panel a confirmation draws, independent of who hosts it. A SwiftUI sheet
/// is a separate window, so a sheet hosts its own panel rather than the window-root overlay.
struct OPNConfirmationPanel: View {
    let eyebrow: String
    let title: String
    let message: String
    let actions: [OPNConfirmationAction]
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            OPNDesign.Surface.scrim
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
                .opnTransition(.opacity)

            GeometryReader { proxy in
                ZStack {
                    OPNConfirmationModal(
                        eyebrow: eyebrow,
                        title: title,
                        message: message,
                        actions: actions,
                        availableSize: proxy.size,
                        dismiss: dismiss
                    )
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .opnTransition(.scale(scale: 0.96).combined(with: .opacity))
        }
    }
}

/// Hosts the shared confirmation modal at the app root. The full-cover scrim sits behind the
/// centered panel; the scrim, close control, Escape, and `.cancel` all dismiss.
struct OPNConfirmationOverlay: View {
    @ObservedObject private var presentation = OPNConfirmationPresentation.shared

    var body: some View {
        ZStack {
            if let request = presentation.request {
                OPNConfirmationPanel(
                    eyebrow: request.eyebrow,
                    title: request.title,
                    message: request.message,
                    actions: request.actions,
                    dismiss: { presentation.dismiss() }
                )
            }
        }
        .opnMotion(OPNDesign.Motion.panel, value: presentation.request != nil)
    }
}

/// App-shell confirmation dialog following the modal spec: Panel background, 1px Stroke Regular,
/// 2px accent top bar, modal shadow, App Bar header with eyebrow and 20pt bold title, and a footer
/// of square buttons. Replaces the native `.confirmationDialog` / `.alert`, which render rounded
/// macOS chrome.
struct OPNConfirmationModal: View {
    let eyebrow: String
    let title: String
    let message: String
    let actions: [OPNConfirmationAction]
    let availableSize: CGSize
    let dismiss: () -> Void

    @Environment(\.opnUIScale) private var uiScale

    private var panelWidth: CGFloat {
        let windowWidth = availableSize.width - OPNDesign.Spacing.pageHorizontal(scale: uiScale) * 2
        return max(min(440 * uiScale, windowWidth), 280 * uiScale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(OPNDesign.accent)
                .frame(height: 2)
                .frame(maxWidth: .infinity)

            header

            Rectangle()
                .fill(OPNDesign.Stroke.subtle)
                .frame(height: 1)

            bodyMessage

            Rectangle()
                .fill(OPNDesign.Stroke.subtle)
                .frame(height: 1)

            footer
        }
        .frame(width: panelWidth)
        .background(OPNDesign.Surface.panel)
        .overlay { Rectangle().stroke(OPNDesign.Stroke.regular, lineWidth: 1) }
        .shadow(color: .black.opacity(0.58), radius: 28 * uiScale, y: 20 * uiScale)
        .onExitCommand(perform: dismiss)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            VStack(alignment: .leading, spacing: 6 * uiScale) {
                Text(eyebrow)
                    .font(.uiSans(size: 10 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.accent)
                    .tracking(1.1)
                Text(title)
                    .font(.uiSans(size: 20 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: OPNDesign.Spacing.xSmall(scale: uiScale))
            OPNModalCloseButton(uiScale: uiScale, action: dismiss)
        }
        .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
        .padding(.vertical, OPNDesign.Spacing.medium(scale: uiScale))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OPNDesign.Surface.appBar)
    }

    private var bodyMessage: some View {
        Text(message)
            .font(.uiSans(size: 12 * uiScale, weight: .medium))
            .foregroundStyle(OPNDesign.Text.secondary)
            .lineSpacing(2 * uiScale)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(OPNDesign.Spacing.card(scale: uiScale))
    }

    private var footer: some View {
        HStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            Spacer(minLength: OPNDesign.Spacing.xSmall(scale: uiScale))
            ForEach(actions.indices, id: \.self) { index in
                button(actions[index])
            }
        }
        .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
        .padding(.vertical, OPNDesign.Spacing.small(scale: uiScale))
    }

    @ViewBuilder
    private func button(_ action: OPNConfirmationAction) -> some View {
        switch action.role {
        case .standard:
            Button(action.title, action: action.handler)
                .buttonStyle(OPNModalSecondaryButtonStyle(uiScale: uiScale))
                .keyboardShortcut(.defaultAction)
        case .destructive:
            Button(action.title, action: action.handler)
                .buttonStyle(OPNModalDestructiveButtonStyle(uiScale: uiScale))
        case .cancel:
            Button(action.title, action: action.handler)
                .buttonStyle(OPNModalSecondaryButtonStyle(uiScale: uiScale))
                .keyboardShortcut(.cancelAction)
        }
    }
}

extension View {
    /// Presents the shared app-shell confirmation modal while `isPresented` is true. The modal
    /// renders at the window root, so it covers the whole surface regardless of where this view
    /// sits. Dismissal clears the bound state through `onDismiss`.
    func opnConfirmation(
        isPresented: Binding<Bool>,
        eyebrow: String,
        title: String,
        message: String,
        actions: [OPNConfirmationAction]
    ) -> some View {
        modifier(OPNConfirmationPresenter(
            isPresented: isPresented,
            eyebrow: eyebrow,
            title: title,
            message: message,
            actions: actions
        ))
    }
}

private struct OPNConfirmationPresenter: ViewModifier {
    let isPresented: Binding<Bool>
    let eyebrow: String
    let title: String
    let message: String
    let actions: [OPNConfirmationAction]

    func body(content: Content) -> some View {
        content
            .onAppear { syncPresentation(isPresented.wrappedValue) }
            .onChange(of: isPresented.wrappedValue) { _, presented in syncPresentation(presented) }
            .onDisappear { OPNConfirmationPresentation.shared.dismiss() }
    }

    private func syncPresentation(_ presented: Bool) {
        guard presented else {
            OPNConfirmationPresentation.shared.dismiss()
            return
        }
        OPNConfirmationPresentation.shared.present(
            OPNConfirmationPresentation.Request(
                eyebrow: eyebrow,
                title: title,
                message: message,
                actions: actions
            ),
            onDismiss: { isPresented.wrappedValue = false }
        )
    }
}

#if DEBUG
private struct OPNConfirmationModalPreview: View {
    var uiScale: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                OPNDesign.Surface.app
                OPNConfirmationModal(
                    eyebrow: "DELETE RECORDING",
                    title: "Delete \"Live Writer Regression\"?",
                    message: "This permanently removes the video file and metadata from OpenNOW recordings.",
                    actions: [
                        OPNConfirmationAction("CANCEL", role: .cancel) {},
                        OPNConfirmationAction("DELETE RECORDING", role: .destructive) {}
                    ],
                    availableSize: proxy.size,
                    dismiss: {}
                )
            }
        }
        .frame(width: 900 * uiScale, height: 640 * uiScale)
    }
}

#Preview("Destructive") {
    OPNConfirmationModalPreview()
}

#Preview("Destructive @ 1.5x") {
    OPNConfirmationModalPreview(uiScale: 1.5)
}

#Preview("Acknowledgement") {
    GeometryReader { proxy in
        ZStack {
            OPNDesign.Surface.app
            OPNConfirmationModal(
                eyebrow: "INPUT MONITORING",
                title: "Reset Failed",
                message: "The system denied the request to clear the Input Monitoring entry for this app.",
                actions: [OPNConfirmationAction("OK") {}],
                availableSize: proxy.size,
                dismiss: {}
            )
        }
    }
    .frame(width: 900, height: 640)
}
#endif

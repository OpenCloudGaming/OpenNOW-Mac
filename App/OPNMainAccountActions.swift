import Foundation
import SwiftData

@MainActor
final class OPNMainAccountActions {
    static let shared = OPNMainAccountActions()

    struct Target {
        let identifier: PersistentIdentifier
        let accountID: String
        let email: String
        let userID: String
        let providerID: String

        init(account: LoginAccount) {
            identifier = account.persistentModelID
            accountID = account.stableAccountID
            email = account.email
            userID = account.userId
            providerID = account.providerIdpId
        }
    }

    enum Request {
        case addAccount
        case reauthenticate(Target)
        case signOut(Target)
        case forget(Target)
    }

    private weak var login: LoginViewModel?
    private var pendingRequests: [Request] = []
    private let confirmation: OPNConfirmationPresentation
    private let handoff: OPNMainWindowAccountHandoff

    private enum ActionError: Error {
        case missingContext
    }

    init(confirmation: OPNConfirmationPresentation = .shared, handoff: OPNMainWindowAccountHandoff = .shared) {
        self.confirmation = confirmation
        self.handoff = handoff
    }

    @discardableResult
    func bind(login: LoginViewModel) -> Task<Void, Never> {
        self.login = login
        let queuedRequests = pendingRequests
        pendingRequests.removeAll()
        return Task {
            for request in queuedRequests {
                await perform(request, login: login)
            }
        }
    }

    func unbind(login: LoginViewModel) {
        guard self.login === login else { return }
        self.login = nil
    }

    @discardableResult
    func request(_ request: Request) -> Task<Void, Never>? {
        guard let login else {
            pendingRequests.append(request)
            return nil
        }
        return Task { await perform(request, login: login) }
    }

    private func perform(_ request: Request, login: LoginViewModel) async {
        do {
            try reload(login: login)
        } catch {
            showFailure("Saved accounts could not be loaded. Try again.")
            return
        }
        switch request {
        case .addAccount:
            login.beginAddAccount()
        case .reauthenticate(let target):
            guard let account = resolve(target, login: login) else { return }
            login.dismissAccountChooser()
            login.beginReauthentication(for: account)
        case .signOut(let target):
            guard let account = resolve(target, login: login) else { return }
            login.validationMessage = ""
            await login.signOutAccount(account)
            finishMutation(login: login)
        case .forget(let target):
            guard let account = resolve(target, login: login) else { return }
            login.validationMessage = ""
            login.forgetAccount(account)
            finishMutation(login: login)
        }
    }

    private func reload(login: LoginViewModel) throws {
        guard let modelContext = login.modelContext else { throw ActionError.missingContext }
        login.update(
            modelContext: modelContext,
            accounts: try modelContext.fetch(FetchDescriptor<LoginAccount>()),
            sessions: try modelContext.fetch(FetchDescriptor<LoginSession>()),
            devices: try modelContext.fetch(FetchDescriptor<LoginDeviceRegistration>())
        )
    }

    private func resolve(_ target: Target, login: LoginViewModel) -> LoginAccount? {
        guard let account = login.accounts.first(where: {
            $0.persistentModelID == target.identifier && $0.stableAccountID == target.accountID
                && $0.email == target.email && $0.userId == target.userID && $0.providerIdpId == target.providerID
        }) else {
            showFailure("This saved account changed or was removed. Choose the account again before continuing.")
            return nil
        }
        return account
    }

    private func finishMutation(login: LoginViewModel) {
        guard login.validationMessage.isEmpty else {
            showFailure(login.validationMessage)
            return
        }
        endHandoff()
    }

    private func showFailure(_ message: String) {
        confirmation.present(
            .init(
                eyebrow: "ACCOUNT",
                title: "Account action unavailable",
                message: message,
                actions: [OPNConfirmationAction("CLOSE") { [weak confirmation] in confirmation?.dismiss() }]
            ),
            onDismiss: { [weak self] in self?.endHandoff() }
        )
        handoff.begin(from: nil)
    }

    private func endHandoff() {
        guard login?.signInRequest == nil else { return }
        handoff.end()
    }
}

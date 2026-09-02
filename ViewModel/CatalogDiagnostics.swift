//
//  CatalogDiagnostics.swift
//  OpenNOW
//
//  Support diagnostics generation. Shared by the About settings card and the home error banner,
//  so a failed session can be reported without walking back through Settings.
//

import Foundation

@MainActor
extension CatalogViewModel {
    /// Asks for upload confirmation. `context` is the on-screen failure the user is reporting, so a
    /// banner-triggered report names the error that prompted it.
    func presentDiagnosticsUploadConfirmation(context: String = "") {
        guard !diagnosticsState.isWorking else { return }
        diagnosticsErrorContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        isDiagnosticsUploadConfirmationVisible = true
    }

    func cancelDiagnosticsUpload() {
        isDiagnosticsUploadConfirmationVisible = false
    }

    func confirmDiagnosticsUpload() {
        isDiagnosticsUploadConfirmationVisible = false
        generateUploadedDiagnostics()
    }

    func generateUploadedDiagnostics() {
        guard !diagnosticsState.isWorking else { return }
        Task { @MainActor in
            diagnosticsState = .preparing
            OPNSentry.logInfoMessage(OPNSentry.formattedLogMessage(level: "info", area: "Diagnostics", message: "Preparing user-requested diagnostics upload"))
            diagnosticsState = .readingLog
            let logText = OPNSentry.diagnosticsLogForUpload()
            diagnosticsState = .uploading
            do {
                let logURL = try await OPNSentry.uploadDiagnosticsLog(logText)
                diagnosticsState = .copying
                copyDiagnosticsToPasteboard(diagnosticsText(logURL: logURL, uploadError: "", inlineLog: ""))
                diagnosticsState = .copied(logURL.absoluteString)
                OPNSentry.logInfoMessage(OPNSentry.formattedLogMessage(level: "info", area: "Diagnostics", message: "Uploaded sanitized diagnostics log url=\(logURL.absoluteString)"))
            } catch {
                let message = error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription
                diagnosticsState = .copying
                copyDiagnosticsToPasteboard(diagnosticsText(logURL: nil, uploadError: message, inlineLog: logText))
                diagnosticsState = .failed(message)
                OPNSentry.logErrorMessage(OPNSentry.formattedLogMessage(level: "error", area: "Diagnostics", message: "Diagnostics upload failed; copied local diagnostics with inline logs error=\(message)"))
            }
        }
    }

    func diagnosticsText(logURL: URL?, uploadError: String, inlineLog: String) -> String {
        let account = SettingsAccountSnapshot(viewModel: self)
        let route = SettingsRouteSnapshot(regionUrl: selectedSettingsRegionUrl, revealSensitive: false)
        var lines = [
            "OpenNOW Mac Diagnostics",
            "Version: \(SettingsAppMetadata.versionWithBuild)",
            "Bundle: \(Bundle.main.bundleIdentifier ?? "Unknown")",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Account: \(account.displayName)",
            "Membership: \(account.membershipTier)",
            "User ID: \(SettingsFormat.maskedIdentifier(account.userId))",
            "Streaming: WebRTC",
            "Cloudmatch: \(route.summary)",
            "Logs: \(logURL?.absoluteString ?? "Not uploaded")"
        ]
        if !diagnosticsErrorContext.isEmpty {
            lines.append("Reported Error: \(diagnosticsErrorContext)")
        }
        if !uploadError.isEmpty {
            lines.append("Upload Error: \(uploadError)")
        }
        if !inlineLog.isEmpty {
            lines.append(contentsOf: ["", "Inline Logs:", inlineLog])
        }
        return lines.joined(separator: "\n")
    }

    private func copyDiagnosticsToPasteboard(_ value: String) {
        guard !value.isEmpty else { return }
        systemIntegration.copyToPasteboard(value)
    }
}

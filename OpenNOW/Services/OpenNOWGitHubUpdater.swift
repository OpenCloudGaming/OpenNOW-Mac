import Foundation

struct OpenNOWGitHubRelease: Sendable {
    let version: String
    let tagName: String
    let releaseNotes: String
    let releaseURL: String
    let assetName: String
    let assetDownloadURL: String
}

actor OpenNOWGitHubUpdater {
    private enum UpdateError: LocalizedError {
        case invalidResponse(String)
        case noReleaseAsset
        case notBundledApp
        case downloadFailed(String)
        case extractionFailed
        case validationFailed(String)
        case installerLaunchFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse(let message), .downloadFailed(let message), .validationFailed(let message), .installerLaunchFailed(let message):
                message
            case .noReleaseAsset:
                "The latest GitHub release does not include an OpenNOW macOS zip asset."
            case .notBundledApp:
                "Updates can only be installed from the packaged OpenNOW.app bundle."
            case .extractionFailed:
                "The update archive could not be extracted."
            }
        }
    }

    let currentVersion: String

    private let owner: String
    private let repository: String
    private let session: URLSession

    init(owner: String, repository: String) {
        self.owner = owner
        self.repository = repository
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func checkForUpdate() async throws -> OpenNOWGitHubRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest") else {
            throw UpdateError.invalidResponse("The GitHub release URL is invalid.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OpenNOW-Updater", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode), !data.isEmpty else {
            throw UpdateError.invalidResponse("GitHub did not return a valid release response.")
        }

        let decoded = try JSONSerialization.jsonObject(with: data)
        guard let json = decoded as? [String: Any] else {
            throw UpdateError.invalidResponse("GitHub release metadata was not valid JSON.")
        }

        let release = try release(from: json)
        return compareVersion(release.version, to: currentVersion) > 0 ? release : nil
    }

    func installRelease(_ release: OpenNOWGitHubRelease) async throws -> Bool {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension.lowercased() == "app" else {
            throw UpdateError.notBundledApp
        }
        guard let downloadURL = URL(string: release.assetDownloadURL) else {
            throw UpdateError.invalidResponse("The release asset download URL is invalid.")
        }

        let (archiveURL, response) = try await session.download(for: URLRequest(url: downloadURL))
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateError.downloadFailed("GitHub did not return the update archive.")
        }

        return try stageAndLaunchInstaller(downloadedArchiveURL: archiveURL, release: release, currentBundleURL: bundleURL)
    }

    private func stageAndLaunchInstaller(downloadedArchiveURL: URL, release: OpenNOWGitHubRelease, currentBundleURL: URL) throws -> Bool {
        let fileManager = FileManager.default
        let stagingURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveCopyURL = stagingURL.appendingPathComponent(release.assetName, isDirectory: false)
        let extractURL = stagingURL.appendingPathComponent("extracted", isDirectory: true)

        try fileManager.createDirectory(at: extractURL, withIntermediateDirectories: true)
        try fileManager.copyItem(at: downloadedArchiveURL, to: archiveCopyURL)

        let extractProcess = Process()
        extractProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        extractProcess.arguments = ["-x", "-k", archiveCopyURL.path, extractURL.path]
        try extractProcess.run()
        extractProcess.waitUntilExit()
        guard extractProcess.terminationStatus == 0 else {
            throw UpdateError.extractionFailed
        }

        guard let newBundleURL = findAppBundle(in: extractURL) else {
            throw UpdateError.validationFailed("The update archive did not contain an app bundle.")
        }
        try validateCandidateBundle(newBundleURL, expectedVersion: release.version, currentBundleURL: currentBundleURL)

        let scriptURL = stagingURL.appendingPathComponent("install-opennow-update.sh", isDirectory: false)
        let backupPath = currentBundleURL.deletingLastPathComponent().appendingPathComponent(".\(currentBundleURL.lastPathComponent).previous").path
        let script = """
        #!/bin/sh
        set -eu
        parent_pid='\(ProcessInfo.processInfo.processIdentifier)'
        target=\(shellQuoted(currentBundleURL.path))
        source=\(shellQuoted(newBundleURL.path))
        backup=\(shellQuoted(backupPath))
        staging=\(shellQuoted(stagingURL.path))
        while kill -0 "$parent_pid" >/dev/null 2>&1; do sleep 0.2; done
        rm -rf "$backup"
        if [ -d "$target" ]; then mv "$target" "$backup"; fi
        if mv "$source" "$target"; then
          /usr/bin/xattr -dr com.apple.quarantine "$target" >/dev/null 2>&1 || true
          /usr/bin/open "$target"
          rm -rf "$backup" "$staging"
        else
          if [ -d "$backup" ] && [ ! -d "$target" ]; then mv "$backup" "$target"; fi
          /usr/bin/open "$target" >/dev/null 2>&1 || true
          exit 1
        fi
        """
        try script.write(to: scriptURL, atomically: true, encoding: String.Encoding.utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let installerProcess = Process()
        installerProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        installerProcess.arguments = [scriptURL.path]
        do {
            try installerProcess.run()
            return true
        } catch {
            throw UpdateError.installerLaunchFailed(error.localizedDescription)
        }
    }

    private func release(from json: [String: Any]) throws -> OpenNOWGitHubRelease {
        let tagName = json["tag_name"] as? String ?? ""
        let version = normalizedVersion(tagName)
        let releaseNotes = json["body"] as? String ?? ""
        let releaseURL = json["html_url"] as? String ?? ""
        let assets = json["assets"] as? [[String: Any]] ?? []
        let selectedAsset = assets.first { asset in
            let name = asset["name"] as? String ?? ""
            return name.hasPrefix("OpenNOW-") && name.hasSuffix("-macOS.zip")
        } ?? assets.first { asset in
            let name = (asset["name"] as? String ?? "").lowercased()
            return name.hasSuffix(".zip") && name.contains("macos")
        }

        guard let selectedAsset else {
            throw UpdateError.noReleaseAsset
        }
        let assetName = selectedAsset["name"] as? String ?? ""
        let assetDownloadURL = selectedAsset["browser_download_url"] as? String ?? ""
        guard !version.isEmpty, !assetDownloadURL.isEmpty else {
            throw UpdateError.noReleaseAsset
        }

        return OpenNOWGitHubRelease(
            version: version,
            tagName: tagName,
            releaseNotes: releaseNotes,
            releaseURL: releaseURL,
            assetName: assetName,
            assetDownloadURL: assetDownloadURL
        )
    }

    private func findAppBundle(in directoryURL: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "app" {
                return url
            }
        }
        return nil
    }

    private func validateCandidateBundle(_ candidateURL: URL?, expectedVersion: String, currentBundleURL: URL) throws {
        guard let candidateURL else {
            throw UpdateError.validationFailed("The update archive did not contain an app bundle.")
        }
        let candidateBundle = Bundle(url: candidateURL)
        let candidateIdentifier = candidateBundle?.bundleIdentifier
        let currentIdentifier = Bundle.main.bundleIdentifier
        let candidateVersion = candidateBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let candidateExecutable = candidateBundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? ""
        let executablePath = candidateExecutable.isEmpty ? "" : candidateURL.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(candidateExecutable).path
        let executableExists = !executablePath.isEmpty && FileManager.default.isExecutableFile(atPath: executablePath)

        guard candidateIdentifier == currentIdentifier,
              executableExists,
              compareVersion(candidateVersion ?? "", to: expectedVersion) == 0,
              compareVersion(candidateVersion ?? "", to: currentVersion) > 0 else {
            throw UpdateError.validationFailed("The downloaded app bundle did not match OpenNOW or did not contain the expected newer version.")
        }
        guard verifyCodeSignature(for: candidateURL) else {
            throw UpdateError.validationFailed("The downloaded app bundle did not pass macOS code-signature verification.")
        }
        let currentParentPath = currentBundleURL.deletingLastPathComponent().path
        guard !currentParentPath.isEmpty, FileManager.default.isWritableFile(atPath: currentParentPath) else {
            throw UpdateError.validationFailed("OpenNOW does not have permission to replace the current app bundle. Move it to a writable folder and try again.")
        }
    }

    private func verifyCodeSignature(for bundleURL: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", bundleURL.path]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func normalizedVersion(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
    }

    private func compareVersion(_ left: String, to right: String) -> Int {
        let separators = CharacterSet(charactersIn: ".-_")
        let leftParts = normalizedVersion(left).components(separatedBy: separators)
        let rightParts = normalizedVersion(right).components(separatedBy: separators)
        let count = max(leftParts.count, rightParts.count)

        for index in 0..<count {
            let leftPart = index < leftParts.count ? leftParts[index] : "0"
            let rightPart = index < rightParts.count ? rightParts[index] : "0"
            if let leftNumber = Int(leftPart), let rightNumber = Int(rightPart) {
                if leftNumber < rightNumber { return -1 }
                if leftNumber > rightNumber { return 1 }
            } else {
                let result = leftPart.compare(rightPart, options: [.caseInsensitive, .numeric])
                if result == .orderedAscending { return -1 }
                if result == .orderedDescending { return 1 }
            }
        }
        return 0
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

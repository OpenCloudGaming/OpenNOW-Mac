import Cocoa
import Foundation

private let opnGitHubUpdaterErrorDomain = "OpenNOW.GitHubUpdater"

private enum OPNGitHubUpdaterErrorCode: Int {
    case invalidResponse = 1
    case noReleaseAsset = 2
    case notBundledApp = 3
    case downloadFailed = 4
    case extractionFailed = 5
    case validationFailed = 6
    case installerLaunchFailed = 7
}

@objc(OPNGitHubRelease)
final class OPNGitHubRelease: NSObject, @unchecked Sendable {
    @objc let version: String
    @objc let tagName: String
    @objc let releaseNotes: String
    @objc let releaseURL: String
    @objc let assetName: String
    @objc let assetDownloadURL: String

    @objc(initWithVersion:tagName:releaseNotes:releaseURL:assetName:assetDownloadURL:)
    init(version: String, tagName: String, releaseNotes: String, releaseURL: String, assetName: String, assetDownloadURL: String) {
        self.version = version
        self.tagName = tagName
        self.releaseNotes = releaseNotes
        self.releaseURL = releaseURL
        self.assetName = assetName
        self.assetDownloadURL = assetDownloadURL
        super.init()
    }
}

@objc(OPNGitHubUpdater)
final class OPNGitHubUpdater: NSObject, @unchecked Sendable {
    private let owner: String
    private let repository: String
    private let session: URLSession

    @objc var currentVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return version?.isEmpty == false ? version! : "0.0.0"
    }

    @objc(initWithOwner:repository:)
    init(owner: String, repository: String) {
        self.owner = owner
        self.repository = repository
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30.0
        configuration.timeoutIntervalForResource = 600.0
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
        super.init()
    }

    @objc(checkForUpdateWithCompletion:)
    func checkForUpdate(completion: @escaping @Sendable (OPNGitHubRelease?, NSError?) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest") else {
            completeUpdateCheck(completion, release: nil, error: error(.invalidResponse, "The GitHub releases URL is invalid."))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OpenNOW-Updater", forHTTPHeaderField: "User-Agent")
        addSentryTraceHeaders(to: &request)

        let task = session.dataTask(with: request) { [weak self] data, response, requestError in
            guard let self else { return }
            if let requestError {
                completeUpdateCheck(completion, release: nil, error: requestError as NSError)
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data, !data.isEmpty else {
                completeUpdateCheck(completion, release: nil, error: error(.invalidResponse, "GitHub did not return a valid release response."))
                return
            }

            do {
                let object = try JSONSerialization.jsonObject(with: data)
                guard let json = object as? [String: Any] else {
                    completeUpdateCheck(completion, release: nil, error: error(.invalidResponse, "GitHub release metadata was not valid JSON."))
                    return
                }
                let release = try release(from: json)
                if compareVersion(release.version, to: currentVersion) <= 0 {
                    completeUpdateCheck(completion, release: nil, error: nil)
                    return
                }
                completeUpdateCheck(completion, release: release, error: nil)
            } catch let parseError as NSError {
                completeUpdateCheck(completion, release: nil, error: parseError)
            }
        }
        task.resume()
    }

    @objc(installRelease:completion:)
    func installRelease(_ release: OPNGitHubRelease, completion: @escaping @Sendable (Bool, NSError?) -> Void) {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension.lowercased() == "app" else {
            completeInstall(completion, launched: false, error: error(.notBundledApp, "Updates can only be installed from the packaged OpenNOW.app bundle."))
            return
        }
        guard let downloadURL = URL(string: release.assetDownloadURL) else {
            completeInstall(completion, launched: false, error: error(.invalidResponse, "The release asset download URL is invalid."))
            return
        }

        var request = URLRequest(url: downloadURL)
        addSentryTraceHeaders(to: &request)
        let task = session.downloadTask(with: request) { [weak self] location, response, requestError in
            guard let self else { return }
            if let requestError {
                completeInstall(completion, launched: false, error: requestError as NSError)
                return
            }
            guard let location else {
                completeInstall(completion, launched: false, error: error(.downloadFailed, "The update archive could not be downloaded."))
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                completeInstall(completion, launched: false, error: error(.downloadFailed, "GitHub did not return the update archive."))
                return
            }
            stageAndLaunchInstaller(for: location, release: release, currentBundleURL: bundleURL, completion: completion)
        }
        task.resume()
    }

    private func stageAndLaunchInstaller(for archiveURL: URL, release: OPNGitHubRelease, currentBundleURL: URL, completion: @escaping @Sendable (Bool, NSError?) -> Void) {
        let fileManager = FileManager.default
        let stagingURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveCopyURL = stagingURL.appendingPathComponent(release.assetName, isDirectory: false)
        let extractURL = stagingURL.appendingPathComponent("extracted", isDirectory: true)

        do {
            try fileManager.createDirectory(at: extractURL, withIntermediateDirectories: true)
            try fileManager.copyItem(at: archiveURL, to: archiveCopyURL)
        } catch let fileError as NSError {
            completeInstall(completion, launched: false, error: fileError)
            return
        }

        let extractTask = Process()
        extractTask.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        extractTask.arguments = ["-x", "-k", archiveCopyURL.path, extractURL.path]
        do {
            try extractTask.run()
            extractTask.waitUntilExit()
        } catch let extractError as NSError {
            completeInstall(completion, launched: false, error: extractError)
            return
        }
        guard extractTask.terminationStatus == 0 else {
            completeInstall(completion, launched: false, error: error(.extractionFailed, "The update archive could not be extracted."))
            return
        }

        let newBundleURL = findAppBundle(in: extractURL)
        do {
            try validateCandidateBundle(newBundleURL, expectedVersion: release.version, currentBundleURL: currentBundleURL)
        } catch let validationError as NSError {
            completeInstall(completion, launched: false, error: validationError)
            return
        }
        guard let newBundleURL else {
            completeInstall(completion, launched: false, error: error(.validationFailed, "The update archive did not contain an app bundle."))
            return
        }

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

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch let fileError as NSError {
            completeInstall(completion, launched: false, error: fileError)
            return
        }

        let installerTask = Process()
        installerTask.executableURL = URL(fileURLWithPath: "/bin/sh")
        installerTask.arguments = [scriptURL.path]
        do {
            try installerTask.run()
            completeInstall(completion, launched: true, error: nil)
        } catch let launchError as NSError {
            completeInstall(completion, launched: false, error: launchError)
        }
    }

    private func release(from json: [String: Any]) throws -> OPNGitHubRelease {
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

        let assetName = selectedAsset?["name"] as? String ?? ""
        let assetURL = selectedAsset?["browser_download_url"] as? String ?? ""
        guard !version.isEmpty, !assetURL.isEmpty else {
            throw error(.noReleaseAsset, "The latest GitHub release does not include an OpenNOW macOS zip asset.")
        }

        return OPNGitHubRelease(version: version, tagName: tagName, releaseNotes: releaseNotes, releaseURL: releaseURL, assetName: assetName, assetDownloadURL: assetURL)
    }

    private func findAppBundle(in directoryURL: URL) -> URL? {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: directoryURL, includingPropertiesForKeys: keys, options: .skipsHiddenFiles) else { return nil }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
            return url
        }
        return nil
    }

    private func validateCandidateBundle(_ candidateURL: URL?, expectedVersion: String, currentBundleURL: URL) throws {
        guard let candidateURL else {
            throw error(.validationFailed, "The update archive did not contain an app bundle.")
        }
        let candidateBundle = Bundle(url: candidateURL)
        let candidateIdentifier = candidateBundle?.bundleIdentifier
        let currentIdentifier = Bundle.main.bundleIdentifier
        let candidateVersion = candidateBundle?.infoDictionary?["CFBundleShortVersionString"] as? String
        let candidateExecutable = candidateBundle?.infoDictionary?["CFBundleExecutable"] as? String
        let executablePath = candidateExecutable?.isEmpty == false ? candidateURL.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(candidateExecutable!).path : nil
        let executableExists = executablePath.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false

        if candidateIdentifier != currentIdentifier || !executableExists || compareVersion(candidateVersion ?? "", to: expectedVersion) != 0 || compareVersion(candidateVersion ?? "", to: currentVersion) <= 0 {
            throw error(.validationFailed, "The downloaded app bundle did not match OpenNOW or did not contain the expected newer version.")
        }
        guard verifyCodeSignature(for: candidateURL) else {
            throw error(.validationFailed, "The downloaded app bundle did not pass macOS code-signature verification.")
        }
        let currentParent = currentBundleURL.deletingLastPathComponent().path
        guard !currentParent.isEmpty, FileManager.default.isWritableFile(atPath: currentParent) else {
            throw error(.validationFailed, "OpenNOW does not have permission to replace the current app bundle. Move it to a writable folder and try again.")
        }
    }

    private func verifyCodeSignature(for bundleURL: URL) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["--verify", "--deep", "--strict", bundleURL.path]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
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
            if let leftNumber = Int64(leftPart), let rightNumber = Int64(rightPart) {
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

    private func error(_ code: OPNGitHubUpdaterErrorCode, _ description: String) -> NSError {
        NSError(domain: opnGitHubUpdaterErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: description])
    }

    private func completeUpdateCheck(_ completion: @escaping @Sendable (OPNGitHubRelease?, NSError?) -> Void, release: OPNGitHubRelease?, error: NSError?) {
        DispatchQueue.main.async { completion(release, error) }
    }

    private func completeInstall(_ completion: @escaping @Sendable (Bool, NSError?) -> Void, launched: Bool, error: NSError?) {
        DispatchQueue.main.async { completion(launched, error) }
    }

    private func addSentryTraceHeaders(to request: inout URLRequest) {
        let mutableRequest = NSMutableURLRequest(url: request.url!)
        mutableRequest.httpMethod = request.httpMethod ?? "GET"
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            mutableRequest.setValue(value, forHTTPHeaderField: key)
        }
        OPNSentry.addTraceHeaders(to: mutableRequest)
        request.allHTTPHeaderFields = mutableRequest.allHTTPHeaderFields
    }
}

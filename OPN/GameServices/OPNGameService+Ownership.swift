//
//  MacForceNow
//

import AppKit
import Foundation

extension OPNGameService {
    func addOwnedVariant(_ variantId: String, completion: @escaping OPNOwnershipActionCallback) {
        ownedVariantMutation(mutationName: "AddOwnedVariant", fieldName: "addOwnedVariant", variantId: variantId, completion: completion)
    }

    func removeOwnedVariant(_ variantId: String, completion: @escaping OPNOwnershipActionCallback) {
        ownedVariantMutation(mutationName: "RemoveOwnedVariant", fieldName: "removeOwnedVariant", variantId: variantId, completion: completion)
    }

    func selectOwnedVariant(_ variantId: String, completion: @escaping OPNOwnershipActionCallback) {
        ownedVariantMutation(mutationName: "SelectOwnedVariant", fieldName: "selectOwnedVariant", variantId: variantId, completion: completion)
    }

    func addFavoriteApp(_ appId: String, completion: @escaping OPNFavoriteActionCallback) {
        favoriteAppMutation(mutationName: "AddFavoriteApp", fieldName: "addFavoriteApp", appId: appId, completion: completion)
    }

    func removeFavoriteApp(_ appId: String, completion: @escaping OPNFavoriteActionCallback) {
        favoriteAppMutation(mutationName: "RemoveFavoriteApp", fieldName: "removeFavoriteApp", appId: appId, completion: completion)
    }

    func syncAccountProvider(store: String, completion: @escaping OPNOwnershipActionCallback) {
        let token = accountLinkingToken.isEmpty ? accessToken : accountLinkingToken
        guard !token.isEmpty else {
            dispatchOwnership(completion, false, "Missing account-linking token")
            return
        }
        guard !store.isEmpty else {
            dispatchOwnership(completion, false, "Missing store for sync")
            return
        }
        let encodedStore = percentEncodeQueryValue(store)
        guard let url = URL(string: "\(Self.accountLinkingServer)/v1/sync/\(encodedStore)") else {
            dispatchOwnership(completion, false, "Invalid ALS sync URL")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: Self.accountLinkingRequestTimeoutSeconds)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let networkStart = OPNNetworkLog.start(&request, operation: "als.sync")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { [weak self] data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "als.sync", startedAt: networkStart, data: data, response: response, error: error)
            guard let self else { return }
            if let error {
                self.dispatchOwnership(completion, false, error.localizedDescription)
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode != 202 {
                let message = statusCode > 0 ? "ALS sync returned HTTP \(statusCode)" : "Missing ALS sync response"
                _ = self.accountLinkingResponseSnippet(data)
                self.dispatchOwnership(completion, false, message)
                return
            }
            self.dispatchOwnership(completion, true, "")
        }.resume()
    }

    func startAccountLinking(store: String, completion: @escaping OPNOwnershipActionCallback) {
        let token = accountLinkingToken.isEmpty ? accessToken : accountLinkingToken
        guard !token.isEmpty else {
            dispatchOwnership(completion, false, "Missing account-linking token")
            return
        }
        guard !store.isEmpty else {
            dispatchOwnership(completion, false, "Missing store for account linking")
            return
        }
        guard let listener = AccountLinkingCallbackListener() else {
            dispatchOwnership(completion, false, "No available port for account linking callback")
            return
        }

        let redirectURI = "http://localhost:\(listener.port)/"
        var components = URLComponents(string: "\(Self.accountLinkingServer)/v1/login_url")
        components?.queryItems = [
            URLQueryItem(name: "platform", value: store),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "client_id", value: Self.accountLinkingClientId),
        ]
        guard let url = components?.url else {
            listener.close()
            dispatchOwnership(completion, false, "Invalid ALS login URL request")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: Self.accountLinkingRequestTimeoutSeconds)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        let networkStart = OPNNetworkLog.start(&request, operation: "als.loginUrl")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { [weak self] data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "als.loginUrl", startedAt: networkStart, data: data, response: response, error: error)
            guard let self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, statusCode == 200, let data else {
                listener.close()
                self.dispatchOwnership(completion, false, error?.localizedDescription ?? "ALS login URL request failed")
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
            guard let loginURLText = self.safeString(json?["login_url"]), let loginURL = URL(string: loginURLText) else {
                listener.close()
                self.dispatchOwnership(completion, false, "ALS login URL response did not include login_url")
                return
            }
            listener.wait(timeout: Self.accountLinkingCallbackTimeoutSeconds, completion: completion)
            Task { @MainActor in NSWorkspace.shared.open(loginURL) }
        }.resume()
    }

    func ownedVariantMutation(mutationName: String, fieldName: String, variantId: String, completion: @escaping OPNOwnershipActionCallback) {
        guard !variantId.isEmpty else {
            dispatchOwnership(completion, false, "Missing variant ID")
            return
        }
        let mutation = "mutation \(mutationName)($cmsId: String!, $locale: String!) { \(fieldName) (language: $locale, variantId: $cmsId) { app { id } } }"
        let variables: NSDictionary = ["cmsId": variantId, "locale": Self.currentGFNCatalogLocale()]
        postGraphQlJson(query: mutation, variables: variables) { [weak self] data, error in
            guard let self else { return }
            if !error.isEmpty {
                if mutationName == "RemoveOwnedVariant", Self.isGraphQLNotFoundError(error) {
                    self.dispatchOwnership(completion, true, "")
                    return
                }
                self.dispatchOwnership(completion, false, error)
                return
            }
            let app = (data?[fieldName] as? NSDictionary)?["app"] as? NSDictionary
            guard let appId = self.safeString(app?["id"]), !appId.isEmpty else {
                self.dispatchOwnership(completion, false, "Ownership mutation response did not include an app ID")
                return
            }
            self.dispatchOwnership(completion, true, "")
        }
    }

    func favoriteAppMutation(mutationName: String, fieldName: String, appId: String, completion: @escaping OPNFavoriteActionCallback) {
        guard !appId.isEmpty else {
            dispatchFavorite(completion, false, "Missing app ID")
            return
        }
        let mutation = "mutation \(mutationName)($appId: String!, $locale: String!) { \(fieldName) (language: $locale, appId: $appId) { app { id } } }"
        let variables: NSDictionary = ["appId": appId, "locale": Self.currentGFNCatalogLocale()]
        postGraphQlJson(query: mutation, variables: variables) { [weak self] data, error in
            guard let self else { return }
            if !error.isEmpty {
                if mutationName == "RemoveFavoriteApp", Self.isGraphQLNotFoundError(error) {
                    self.dispatchFavorite(completion, true, "")
                    return
                }
                self.dispatchFavorite(completion, false, error)
                return
            }
            let app = (data?[fieldName] as? NSDictionary)?["app"] as? NSDictionary
            guard let responseAppId = self.safeString(app?["id"]), !responseAppId.isEmpty else {
                self.dispatchFavorite(completion, false, "Favorite mutation response did not include an app ID")
                return
            }
            self.dispatchFavorite(completion, true, "")
        }
    }

    func percentEncodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?#%+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    func accountLinkingResponseSnippet(_ data: Data?) -> String {
        guard let data, !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return "" }
        let normalized = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return normalized.count > 512 ? String(normalized.prefix(512)) : normalized
    }
}

private final class AccountLinkingCallbackListener: @unchecked Sendable {
    let port: Int32
    let socketDescriptor: Int32
    let service = OPNGameService.shared

    init?() {
        let candidatePorts: [Int32] = [2259, 6460, 7119, 8870, 9096]
        for candidate in candidatePorts {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            if descriptor < 0 { continue }
            var reuse: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
            address.sin_port = in_port_t(candidate).bigEndian
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindResult == 0, listen(descriptor, 1) == 0 {
                socketDescriptor = descriptor
                port = candidate
                return
            }
            Darwin.close(descriptor)
        }
        return nil
    }

    func close() {
        Darwin.close(socketDescriptor)
    }

    func wait(timeout: TimeInterval, completion: @escaping OPNOwnershipActionCallback) {
        let descriptor = socketDescriptor
        DispatchQueue.global(qos: .default).async { [self, service] in
            var readSet = fd_set()
            self.fdZero(&readSet)
            self.fdSet(descriptor, set: &readSet)
            var time = timeval(tv_sec: Int(timeout), tv_usec: 0)
            let ready = select(descriptor + 1, &readSet, nil, nil, &time)
            if ready <= 0 {
                Darwin.close(descriptor)
                service.dispatchOwnership(completion, false, ready == 0 ? "Timed out waiting for account linking callback" : "Account linking callback listener failed")
                return
            }
            let client = accept(descriptor, nil, nil)
            Darwin.close(descriptor)
            if client < 0 {
                service.dispatchOwnership(completion, false, "Failed to accept account linking callback")
                return
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = recv(client, &buffer, buffer.count - 1, 0)
            let request = bytesRead > 0 ? String(bytes: buffer.prefix(bytesRead), encoding: .utf8) ?? "" : ""
            let hasError = request.contains("error=") || request.contains("error_description=")
            self.sendCallbackPage(client: client, success: !hasError)
            Darwin.close(client)
            if bytesRead <= 0 {
                service.dispatchOwnership(completion, false, "Empty account linking callback request")
            } else if hasError {
                service.dispatchOwnership(completion, false, "Account linking was not completed")
            } else {
                service.dispatchOwnership(completion, true, "")
            }
        }
    }

    func sendCallbackPage(client: Int32, success: Bool) {
        let successBody = "<!doctype html><html><head><meta charset=\"utf-8\"><title>MacForce Now Account Linking</title></head><body style=\"background:#050807;color:#f1fff7;font:16px -apple-system,BlinkMacSystemFont,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0\"><main><h1>Account link complete</h1><p>You can close this window and return to MacForceNow.</p></main><script>setTimeout(function(){window.close()},1200)</script></body></html>"
        let errorBody = "<!doctype html><html><head><meta charset=\"utf-8\"><title>MacForce Now Account Linking</title></head><body style=\"background:#140606;color:#fff0f0;font:16px -apple-system,BlinkMacSystemFont,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0\"><main><h1>Account link failed</h1><p>Return to MacForce Now to try again.</p></main></body></html>"
        let body = success ? successBody : errorBody
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        _ = response.withCString { send(client, $0, strlen($0), 0) }
    }

    func fdZero(_ set: inout fd_set) {
        memset(&set, 0, MemoryLayout<fd_set>.size)
    }

    func fdSet(_ descriptor: Int32, set: inout fd_set) {
        let intOffset = Int(descriptor) / 32
        let bitOffset = Int(descriptor) % 32
        withUnsafeMutablePointer(to: &set) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: MemoryLayout<fd_set>.size / MemoryLayout<Int32>.size) { values in
                values[intOffset] |= 1 << Int32(bitOffset)
            }
        }
    }
}

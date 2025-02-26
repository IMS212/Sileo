//
//  PaymentProvider.swift
//  Sileo
//
//  Created by Skitty on 6/28/20.
//  Copyright © 2020 CoolStar. All rights reserved.
//

import Foundation
import KeychainAccess
import LocalAuthentication

enum PaymentStatus: Int {
    case immediateSuccess = 0
    case actionRequred = 1
    case failed = -1
    case cancel = -2
}

class PaymentProvider: Hashable, Equatable, DownloadOverrideProviding {
    let baseURL: URL
    var info: [String: AnyObject]?
    var storedUserInfo: [String: AnyObject]?
    
    var isInfoFresh = false
    var isUserInfoFresh = false
    
    static let listUpdateNotificationName = "PaymentProviderListUpdateNotificationName"
    
    init(baseURL url: URL) {
        baseURL = url
        
        loadCache()
        fetchUserInfo(fromCache: true, completion: nil)
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(baseURL)
    }
    
    var hashableObject: AnyHashable {
        self as AnyHashable
    }
    
    func loadCache() {
        OperationQueue.main.addOperation {
            do {
                let jsonData = try Data(contentsOf: URL(fileURLWithPath: self.cachePath))
                let cacheInfo = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: AnyObject]
                self.info = cacheInfo?["info"] as? [String: AnyObject]
                self.info = cacheInfo?["userInfo"] as? [String: AnyObject]
            } catch { }
        }
    }
    
    func saveCache() {
        let cacheInfo: [String: Any] = ["info": info ?? NSNull(), "userInfo": storedUserInfo ?? NSNull()]
        do {
            let data = try JSONSerialization.data(withJSONObject: cacheInfo, options: [])
            try data.write(to: URL(fileURLWithPath: cachePath))
        } catch { }
    }
    
    var cachePath: String {
        let encodedURL = baseURL.absoluteString.addingPercentEncoding(withAllowedCharacters: NSCharacterSet.alphanumerics)
        let filename = String(format: "payment_provider_%@.json", encodedURL ?? "default")
        return NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0].appending(filename)
    }
    
    var isAuthenticated: Bool {
        self.authenticationToken != nil
    }
    
    var authenticationToken: String? {
        PaymentProvider.tokenKeychain[baseURL.absoluteString]
    }
    
    var authenticationURL: URL {
        let udid = UIDevice.current.uniqueIdentifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let platform = UIDevice.current.platform.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: String(format: "authenticate?udid=%@&model=%@", udid, platform), relativeTo: baseURL)!
    }
    
    func fetchInfo(fromCache: Bool, completion: ((PaymentError?, [String: AnyObject]?) -> Void)?) {
        var hasCompletedOnce = false
        // Load from stored value if possible and allowed
        if info != nil && fromCache {
            hasCompletedOnce = true
            completion?(nil, info)
            // If our info is fresh (refreshed since app launch), we can avoid re-fetching
            if isInfoFresh {
                return
            }
        }
        
        getRequest(withPath: "info") { error, data in
            guard error == nil,
                let data = data else {
                    completion?(error, nil)
                    return
            }
            // Check we got our required values
            if data["name"] as? String == nil || data["description"] as? String == nil {
                // Return error only if we haven't already served cached data
                if !hasCompletedOnce {
                    completion?(PaymentError.invalidResponse, nil)
                }
                return
            }
            
            // Store result, save cache, and complete
            self.info = data
            self.isInfoFresh = true
            self.saveCache()
            completion?(nil, data)
        }
    }
    
    func fetchUserInfo(fromCache: Bool, completion: ((PaymentError?, [String: AnyObject]?) -> Void)?) {
        var hasCompletedOnce = false
        // Load from stored value if possible and allowed
        if storedUserInfo != nil && fromCache {
            hasCompletedOnce = true
            completion?(nil, storedUserInfo)
            // If our user info is fresh (refreshed since app launch), we can avoid re-fetching
            if isUserInfoFresh {
                return
            }
        }
        
        postRequest(withPath: "user_info", includeToken: true, includePaymentSecret: false) { error, data, _ in
            guard error == nil,
                let data = data else {
                    completion?(error, nil)
                    return
            }
            // Check we got our required values
            guard data["items"] as? [AnyObject] != nil,
                let userProfile = data["user"] as? [String: AnyObject],
                userProfile["name"] as? String != nil,
                userProfile["email"] as? String != nil else {
                    // Return error only if we haven't already served cached data
                    if !hasCompletedOnce {
                        completion?(PaymentError.invalidResponse, nil)
                    }
                    return
            }
            
            // Store result, save cache, and complete
            self.storedUserInfo = data
            self.isUserInfoFresh = true
            self.saveCache()
            completion?(nil, data)
        }
    }
    
    func authenticate(withToken token: String, paymentSecret: String) {
        PaymentProvider.tokenKeychain[baseURL.absoluteString] = token
        PaymentProvider.paymentSecretKeychain[baseURL.absoluteString] = paymentSecret
        PaymentProvider.triggerListUpdateNotification()
    }
    
    func signOut(completion: @escaping () -> Void) {
        postRequest(withPath: "sign_out", includeToken: true, includePaymentSecret: false) { _, _, _ in
            self.invalidateSavedToken()
            completion()
        }
    }
    
    func invalidateSavedToken() {
        storedUserInfo = nil
        saveCache()
        PaymentProvider.tokenKeychain[baseURL.absoluteString] = nil
        PaymentProvider.paymentSecretKeychain[baseURL.absoluteString] = nil
        PaymentProvider.triggerListUpdateNotification()
    }
    
    func getPackageInfo(forIdentifier id: String, completion: @escaping (PaymentError?, PaymentPackageInfo?) -> Void) {
        let encodedIdentifier = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        let path = String(format: "package/%@/info", encodedIdentifier)
        postRequest(withPath: path, includeToken: true, includePaymentSecret: false) { error, data, _ in
            guard error == nil,
                let data = data else {
                    return completion(error, nil)
            }
            completion(nil, PaymentPackageInfo(dictionary: data))
        }
    }
    
    func initiatePurchase(forPackageIdentifier id: String, completion: @escaping (PaymentError?, PaymentStatus, URL?) -> Void) {
        let encodedIdentifier = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        let path = String(format: "package/%@/purchase", encodedIdentifier)
        postRequest(withPath: path, includeToken: true, includePaymentSecret: true) { error, data, cancel in
            if cancel {
                return completion(nil, PaymentStatus.cancel, nil)
            }
            guard error == nil,
                let data = data else {
                    return completion(error, .failed, nil)
            }
            // Check we got our required values
            guard let status = data["status"] as? Int else {
                return completion(PaymentError.invalidResponse, .failed, nil)
            }
            
            // Get and check validity of status
            if status < PaymentStatus.failed.rawValue || status > PaymentStatus.actionRequred.rawValue {
                return completion(PaymentError.invalidResponse, .failed, nil)
            }
            
            let actionURL = URL(string: data["url"] as? String ?? "")
            completion(nil, PaymentStatus(rawValue: status) ?? PaymentStatus.failed, actionURL)
        }
    }
    
    static func triggerListUpdateNotification() {
        NotificationCenter.default.post(name: Notification.Name(PaymentProvider.listUpdateNotificationName), object: nil)
        NotificationCenter.default.post(name: PackageListManager.reloadNotification, object: nil)
    }
    
    func downloadURL(for package: Package, from repo: Repo, completionHandler: @escaping (String?, URL?) -> Void) -> Bool {
        if !isAuthenticated || !package.commercial {
            return false
        }
        
        let encodedIdentifier = package.package.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? package.package
        let path = String(format: "package/%@/authorize_download", encodedIdentifier)
        let body = ["version": package.version as AnyObject, "repo": repo.repoURL as AnyObject]
        postRequest(withPath: path, includeToken: true, includePaymentSecret: false, body: body) { error, data, _ in
            guard error == nil,
                let data = data else {
                    return completionHandler(error?.message, nil)
            }
            
            guard let urlStr = data["url"] as? String,
                let downloadURL = URL(string: urlStr) else {
                return completionHandler(PaymentError.invalidResponse.message, nil)
            }
            if !downloadURL.isSecure {
                return completionHandler(String(localizationKey: "Insecure_Paid_Download", type: .error), nil)
            }
            
            completionHandler(nil, downloadURL)
        }
        
        return true
    }
    
    // MARK: - Request Utlities
    
    func getRequest(withPath path: String, completion: @escaping (PaymentError?, [String: AnyObject]?) -> Void) {
        let url = baseURL.appendingPathComponent(path)
        let request = URLManager.urlRequest(url, includingDeviceInfo: false)
        PaymentProvider.makeRequest(request, completion: completion)
    }
    
    func postRequest(withPath path: String, includeToken: Bool, includePaymentSecret: Bool, completion: @escaping (PaymentError?, [String: AnyObject]?, Bool) -> Void) {
        postRequest(withPath: path, includeToken: includeToken, includePaymentSecret: includePaymentSecret, body: nil, completion: completion)
    }
    
    func postRequest(withPath path: String, includeToken: Bool, includePaymentSecret: Bool, body originalBody: [String: AnyObject]?, completion: @escaping (PaymentError?, [String: AnyObject]?, Bool) -> Void) {
        let url = baseURL.appendingPathComponent(path)
        var request = URLManager.urlRequest(url, includingDeviceInfo: false)
        request.httpMethod = "POST"
        
        var body = originalBody ?? [:]
        if includeToken {
            if let token = authenticationToken {
                body["token"] = token as AnyObject
            }
            if includePaymentSecret {
                // This is my really *clever* way to check if user pressed cancel or not
                let context = LAContext()
                if context.canEvaluatePolicy(LAPolicy.deviceOwnerAuthentication, error: nil) {
                    if let secret = PaymentProvider.paymentSecretKeychain[baseURL.absoluteString] {
                        body["payment_secret"] = secret as AnyObject
                    } else {
                        return completion(nil, nil, true)
                    }
                }
            }
        }
        body["udid"] = UIDevice.current.uniqueIdentifier as AnyObject
        body["device"] = UIDevice.current.platform as AnyObject
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        } catch {
            return completion(PaymentError(error: error), nil, false)
        }
        
        PaymentProvider.makeRequest(request) { error, data in
            if let error = error {
                if error.shouldInvalidate && self.isAuthenticated {
                    self.invalidateSavedToken()
                }
            }
            if includePaymentSecret { NSLog("[Sileo] Completion moment") }
            completion(error, data, false)
        }
    }
    
    static func makeRequest(_ request: URLRequest, completion: @escaping (PaymentError?, [String: AnyObject]?) -> Void) {
        URLSession.shared.dataTask(with: request, completionHandler: { data, _, error in
            // Check if response had error, return error
            guard error == nil,
                let data = data else {
                    return completion(PaymentError(error: error), nil)
            }
            
            // Decode JSON
            do {
                guard let jsonData = try JSONSerialization.jsonObject(with: data, options: []) as? [String: AnyObject] else {
                    return completion(PaymentError(message: nil), nil)
                }
                
                // If there is a success key equal to false, or an error message field, return error
                if (jsonData["success"] != nil && !(jsonData["success"] as? Bool ?? false)) || jsonData["error"] as? String != nil {
                    let message = jsonData["error"] as? String
                    let recoveryURL = URL(string: jsonData["recovery_url"] as? String ?? "")
                    let shouldInvalidate = jsonData["invalidate"] as? Bool ?? false
                    return completion(PaymentError(message: message, recoveryURL: recoveryURL, shouldInvalidate: shouldInvalidate), nil)
                }
                
                completion(nil, jsonData)
            } catch {
                // If decoding error, return error
                return completion(PaymentError(error: error), nil)
            }
        }).resume()
    }
    
    // MARK: - Keychain Convenience
    
    static var tokenKeychain: Keychain {
        Keychain(service: "SileoPaymentToken", accessGroup: "org.coolstar.Sileo")
            .synchronizable(false)
    }
    
    static var paymentSecretKeychain: Keychain {
        Keychain(service: "SileoPaymentSecret", accessGroup: "org.coolstar.Sileo")
            .synchronizable(false)
            .accessibility(.whenUnlockedThisDeviceOnly, authenticationPolicy: .userPresence)
            .authenticationPrompt("Authenticate to complete your purchase")
    }
}

func == (lhs: PaymentProvider, rhs: PaymentProvider) -> Bool {
    lhs.baseURL == rhs.baseURL
}

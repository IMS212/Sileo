//
//  AppDelegate.swift
//  Sileo
//
//  Created by CoolStar on 8/29/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import Foundation
import UserNotifications
import SDWebImage
import Sentry

class AppDelegate: UIResponder, UIApplicationDelegate, UITabBarControllerDelegate {
    public var window: UIWindow?
    
    func applicationDidFinishLaunching(_ application: UIApplication) {
        DispatchQueue.global(qos: .background).async {
            spawn(command: "/usr/bin/uicache", args: ["uicache", "-p", "/Applications/Cydia.app"])
            spawn(command: "/usr/bin/uicache", args: ["uicache", "-p", "/Applications/SafeMode.app"])
        }
        
        _ = DatabaseManager.shared
        _ = DownloadManager.shared
        SileoThemeManager.shared.updateUserInterface()
        
        guard let tabBarController = self.window?.rootViewController as? UITabBarController else {
            fatalError("Invalid Storyboard")
        }
        tabBarController.delegate = self
        tabBarController.tabBar._blurEnabled = true
        tabBarController.tabBar.tag = WHITE_BLUR_TAG
        
        if let cacheClearFile = try? FileManager.default.url(for: .cachesDirectory,
                                                             in: .userDomainMask,
                                                             appropriateFor: nil,
                                                             create: true).appendingPathComponent(".sileoCacheCleared") {
            var cacheNeedsUpdating = false
            if FileManager.default.fileExists(atPath: cacheClearFile.path) {
                let attributes = try? FileManager.default.attributesOfItem(atPath: cacheClearFile.path)
                if let modifiedDate = attributes?[FileAttributeKey.modificationDate] as? Date {
                    if Date().timeIntervalSince(modifiedDate) > 3 * 24 * 3600 {
                        cacheNeedsUpdating = true
                        try? FileManager.default.removeItem(at: cacheClearFile)
                    }
                }
            } else {
                cacheNeedsUpdating = true
            }
            
            if cacheNeedsUpdating {
                SDImageCache.shared.clearDisk(onCompletion: nil)
                try? "".write(to: cacheClearFile, atomically: true, encoding: .utf8)
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + .seconds(3)) {
            let updatesPrompt = UserDefaults.standard.bool(forKey: "updatesPrompt")
            if !updatesPrompt {
                if UIApplication.shared.backgroundRefreshStatus == .denied {
                    DispatchQueue.main.async {
                        let title = String(localizationKey: "Background_App_Refresh")
                        let msg = String(localizationKey: "Background_App_Refresh_Message")
                        let alert = UIAlertController(title: title, message: msg, preferredStyle: .alert)
                        
                        let ackAction = UIAlertAction(title: String(localizationKey: "Acknowledge"), style: .default) { _ in
                            UserDefaults.standard.set(true, forKey: "updatesPrompt")
                            alert.dismiss(animated: true, completion: nil)
                        }
                        alert.addAction(ackAction)
                        
                        let dismissAction = UIAlertAction(title: String(localizationKey: "Dismiss"), style: .cancel) { _ in
                            alert.dismiss(animated: true, completion: nil)
                        }
                        alert.addAction(dismissAction)
                        
                        self.window?.rootViewController?.present(alert, animated: true, completion: nil)
                    }
                }
            }
        }
        
        UIApplication.shared.setMinimumBackgroundFetchInterval(4 * 3600)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) {_, _ in
            
        }
        
        _ = NotificationCenter.default.addObserver(forName: SileoThemeManager.sileoChangedThemeNotification, object: nil, queue: nil) { _ in
            self.updateTintColor()
            for window in UIApplication.shared.windows {
                for view in window.subviews {
                    view.removeFromSuperview()
                    window.addSubview(view)
                }
            }
        }
        self.updateTintColor()
        
        // Force all view controllers to load now
        for controller in tabBarController.viewControllers ?? [] {
            _ = controller.view
            if let navController = controller as? UINavigationController {
                _ = navController.viewControllers[0].view
            }
        }
        
        if !UserDefaults.standard.optionalBool("EnableAnalytics", fallback: true) {
            return
        }
        var appVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Error"
        #if targetEnvironment(simulator) || TARGET_SANDBOX
        appVer += "-demo"
        #else
        if FileManager.default.fileExists(atPath: "/odyssey/jailbreakd") {
            appVer += "-odyssey"
        } else if FileManager.default.fileExists(atPath: "/chimera/jailbreakd") {
            appVer += "-chimera"
        } else if FileManager.default.fileExists(atPath: "/electra/jailbreakd") {
            appVer += "-electra"
        } else if FileManager.default.fileExists(atPath: "/taurine/jailbreakd") {
            appVer += "-taurine"
        } else if FileManager.default.fileExists(atPath: "/usr/libexec/libhooker/pspawn_payload.dylib") &&
            FileManager.default.fileExists(atPath: "/.procursus_strapped") {
            appVer += "-odysseyra1n"
        } else if FileManager.default.fileExists(atPath: "/usr/libexec/libhooker/pspawn_payload.dylib") {
            appVer += "-libhooker"
        } else if FileManager.default.fileExists(atPath: "/.procursus_strapped") {
            appVer += "-procursus"
        } else if FileManager.default.fileExists(atPath: "/var/checkra1n.dmg") {
            appVer += "-checkrain"
        } else if FileManager.default.fileExists(atPath: "/usr/libexec/substrated") {
            appVer += "-substrate"
        } else if FileManager.default.fileExists(atPath: "/usr/libexec/substituted") {
            appVer += "-hackyA12"
        }
        #endif
    }
    
    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        PackageListManager.shared.waitForReady()
        
        let currentUpdates = PackageListManager.shared.availableUpdates().map({ $0.0 })
        guard let currentPackages = PackageListManager.shared.packagesList(loadIdentifier: "", repoContext: nil) else {
            return
        }
        RepoManager.shared.update(force: false, forceReload: false, isBackground: true) { _, _ in
            let newUpdates = PackageListManager.shared.availableUpdates().map({ $0.0 })
            guard let newPackages = PackageListManager.shared.packagesList(loadIdentifier: "", repoContext: nil) else {
                return
            }
            
            let diffUpdates = newUpdates.filter { !currentUpdates.contains($0) }
            if diffUpdates.count > 3 {
                let content = UNMutableNotificationContent()
                content.title = String(localizationKey: "Updates Available")
                content.body = String(format: String(localizationKey: "New updates for %d packages are available"), diffUpdates.count)
                content.badge = newUpdates.count as NSNumber
                
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                
                let request = UNNotificationRequest(identifier: "org.coolstar.sileo.updates", content: content, trigger: trigger)
                UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
            } else {
                for package in diffUpdates {
                    let content = UNMutableNotificationContent()
                    content.title = String(localizationKey: "New Update")
                    content.body = String(format: String(localizationKey: "%@ by %@ has been updated to version %@ on %@"),
                                          package.name ?? "",
                                          ControlFileParser.authorName(string: package.author ?? ""),
                                          package.version,
                                          package.sourceRepo?.displayName ?? "")
                    content.badge = newUpdates.count as NSNumber
                    
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                    
                    let request = UNNotificationRequest(identifier: "org.coolstar.sileo.update-\(package.package)",
                                                        content: content,
                                                        trigger: trigger)
                    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
                }
            }
            
            let diffPackages = newPackages.filter { !currentPackages.contains($0) }
            
            let wishlist = WishListManager.shared.wishlist
            for package in diffPackages {
                if wishlist.contains(package.package) {
                    let content = UNMutableNotificationContent()
                    content.title = String(localizationKey: "New Update")
                    content.body = String(format: String(localizationKey: "%@ by %@ has been updated to version %@ on %@"),
                                          package.name ?? "",
                                          ControlFileParser.authorName(string: package.author ?? ""),
                                          package.version,
                                          package.sourceRepo?.displayName ?? "")
                    content.badge = newUpdates.count as NSNumber
                    
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                    
                    let request = UNNotificationRequest(identifier: "org.coolstar.sileo.update-\(package.package)",
                                                        content: content,
                                                        trigger: trigger)
                    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
                }
            }
            
            completionHandler(.newData)
        }
    }
    
    func updateTintColor() {
        var tintColor = UIColor.tintColor
        if UIAccessibility.isInvertColorsEnabled {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            tintColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            
            tintColor = UIColor(red: 1 - red, green: 1 - green, blue: 1 - blue, alpha: 1 - alpha)
        }
        
        if #available(iOS 13, *) {
        } else {
            if UIColor.isDarkModeEnabled {
                UINavigationBar.appearance().barStyle = .blackTranslucent
                UITabBar.appearance().barStyle = .black
                UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).keyboardAppearance = .dark
            } else {
                UINavigationBar.appearance().barStyle = .default
                UITabBar.appearance().barStyle = .default
                UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).keyboardAppearance = .default
            }
        }
        
        UINavigationBar.appearance().tintColor = tintColor
        UIToolbar.appearance().tintColor = tintColor
        UISearchBar.appearance().tintColor = tintColor
        UITabBar.appearance().tintColor = tintColor
        
        UICollectionView.appearance().tintColor = tintColor
        UITableView.appearance().tintColor = tintColor
        DepictionBaseView.appearance().tintColor = tintColor
        self.window?.tintColor = tintColor
    }
    
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        DispatchQueue.global(qos: .default).async {
            PackageListManager.shared.waitForReady()
            DispatchQueue.main.async {
                if url.scheme == "file" {
                    // The file is a deb. Open the package view controller to that file.
                    let viewController = PackageViewController()
                    viewController.package = PackageListManager.shared.package(url: url)
                    viewController.isPresentedModally = true
                    guard let tabBarController = self.window?.rootViewController as? UITabBarController,
                        let featuredVc = tabBarController.viewControllers?[0] as? UINavigationController? else {
                        return
                    }
                    featuredVc?.pushViewController(viewController, animated: true)
                    tabBarController.selectedIndex = 0
                } else {
                    // presentModally ignored; we always present modally for an external URL open.
                    var presentModally = false
                    if let viewController = URLManager.viewController(url: url, isExternalOpen: true, presentModally: &presentModally) {
                        self.window?.rootViewController?.present(viewController, animated: true, completion: nil)
                    }
                }
            }
        }
        
        if url.scheme == "cydia" && url.absoluteString.count >= 55 {
            let fullURL = url.absoluteString
            let itemsSource = fullURL.components(separatedBy: "source=")
            if itemsSource.count < 2 {
                return false
            }
            
            guard let parsedURLStr = itemsSource[1].removingPercentEncoding else {
                return false
            }
            
            let parsedURL = URL(string: parsedURLStr)
            if !url.absoluteString.contains("package=") {
                if let tabBarController = self.window?.rootViewController as? UITabBarController,
                    let sourcesSVC = tabBarController.viewControllers?[2] as? UISplitViewController,
                      let sourcesNavNV = sourcesSVC.viewControllers[0] as? SileoNavigationController {
                      tabBarController.selectedViewController = sourcesSVC
                      if let sourcesVC = sourcesNavNV.viewControllers[0] as? SourcesViewController {
                        sourcesVC.presentAddSourceEntryField(url: parsedURL)
                      }
                }
            }
        } else if url.host == "source" && url.scheme == "sileo" {
            guard let tabBarController = self.window?.rootViewController as? UITabBarController,
                let sourcesSVC = tabBarController.viewControllers?[2] as? UISplitViewController,
                let sourcesNavNV = sourcesSVC.viewControllers[0] as? SileoNavigationController,
                let sourcesVC = sourcesNavNV.viewControllers[0] as? SourcesViewController else {
                return false
            }
            let newURL = url.absoluteURL
            tabBarController.selectedViewController = sourcesSVC
            sourcesVC.presentAddSourceEntryField(url: newURL)
        }
        return false
    }
    
    func application(_ application: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        guard let tabBarController = TabBarController.singleton,
              let controllers = tabBarController.viewControllers,
              let sourcesSVC = controllers[2] as? SourcesSplitViewController,
              let sourcesNVC = sourcesSVC.viewControllers[0] as? SileoNavigationController,
              let sourcesVC = sourcesNVC.viewControllers[0] as? SourcesViewController,
              let packageListNVC = controllers[3] as? SileoNavigationController,
              let packageListVC = packageListNVC.viewControllers[0] as? PackageListViewController
        else {
            return
        }
        
        if shortcutItem.type.hasSuffix(".UpgradeAll") {
            tabBarController.selectedViewController = packageListNVC
            
            let title = String(localizationKey: "Sileo")
            let msg = String(localizationKey: "Upgrade_All_Shortcut_Processing_Message")
            let alert = UIAlertController(title: title, message: msg, preferredStyle: .alert)
            packageListVC.present(alert, animated: true, completion: nil)
            
            sourcesVC.refreshSources(adjustRefreshControl: true, errorScreen: true, forceUpdate: true, forceReload: true, isBackground: false, completion: { _, _ in
                PackageListManager.shared.upgradeAll(completion: {
                    let autoConfirm = UserDefaults.standard.optionalBool("AutoConfirmUpgradeAllShortcut", fallback: false)
                    if autoConfirm {
                        let downloadMan = DownloadManager.shared
                        downloadMan.startUnqueuedDownloads()
                        downloadMan.reloadData(recheckPackages: false)
                    }
                    
                    tabBarController.presentPopupController()
                    alert.dismiss(animated: true, completion: nil)
                })
            })
        } else if shortcutItem.type.hasSuffix(".Refresh") {
            tabBarController.selectedViewController = sourcesSVC
            sourcesVC.refreshSources(adjustRefreshControl: true, errorScreen: true, forceUpdate: true, forceReload: true, isBackground: false, completion: nil)
        } else if shortcutItem.type.hasSuffix(".AddSource") {
            tabBarController.selectedViewController = sourcesSVC
            sourcesVC.addSource(nil)
        } else if shortcutItem.type.hasSuffix(".Packages") {
            tabBarController.selectedViewController = packageListNVC
        }
    }
    
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        // If switching away from the news tab
        if tabBarController.selectedIndex == 1 && viewController != tabBarController.selectedViewController {
            // Consider unread packages and articles as read after switching away from the news tab
            DispatchQueue.global().async {
                let stubs = PackageStub.stubs(limit: 0, offset: 0)
                for stub in stubs where stub.userReadDate == nil {
                    stub.userReadDate = Date()
                    stub.save()
                }
                
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: PackageListManager.didUpdateNotification, object: nil)
                }
            }
        }
        return true
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        UIColor.isTransitionLockedForiOS13Bug = true
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        UIColor.isTransitionLockedForiOS13Bug = false
    }
}

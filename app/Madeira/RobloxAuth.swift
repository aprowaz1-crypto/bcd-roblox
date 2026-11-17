// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
// Modified for BCD-RobloxDev on 2026-11-17: Roblox Studio's browser sign-in and its settings.

import Foundation
import AuthenticationServices
import UIKit

/// Roblox Studio's sign-in in this fork. Studio's WebView2 sign-in cannot run in BCD's Wine prefix (WebView2 needs a
/// Windows service manager), so BCD asks Studio to show the "log in with a browser" choice through two ClientSettings
/// timeout flags, then takes Studio's own OAuth request out of BCD's URL bridge (BCDOpenURL / Library.watchOpenURL)
/// and opens it here in ASWebAuthenticationSession. Roblox redirects to the scheme below; BCD writes that callback
/// into drive_c for the generated batch (BCDLaunchersLive) to hand to the running Studio, which forwards it to its
/// main instance the same way a native Windows protocol handler would.
///
/// No token, cookie or password is kept here: the session shows Roblox's own page, and only the one-shot callback URL
/// is written into the prefix and deleted by the batch as soon as Studio has it.
///
/// The flags are the public ones Vinegar (https://github.com/vinegarhq/vinegar) applies for the same purpose, plus
/// its D3D11 renderer preference. This file names no engine type: the app's only link to it is Library.watchOpenURL,
/// which passes the URL it already read; the iOS bits live in `BCDRobloxAuthSession` below (ENGINE_BOUND in
/// tools/ui-preview.py, like BCDLaunchersLive.swift).
enum BCDRobloxAuth {
    /// The scheme Roblox's OAuth page redirects to and Studio's installer registers on Windows.
    static let callbackScheme = "roblox-studio-auth"

    /// The folder under drive_c the app and the Windows batch share.
    static let folder = "ProgramData/BCD/DevMode"
    static let callbackFile = "auth.url"
    static let callbackRelativePath = folder + "/" + callbackFile

    /// Roblox's authorize endpoint Studio opens in its embedded browser.
    static let authorizeHost = "apis.roblox.com"
    static let authorizePath = "/oauth/v1/authorize"

    /// ClientAppSettings.json's flags, in a fixed order so the Swift writer and the generated batch write the same file.
    /// The two timeout flags make Studio's embedded sign-in dialog give up at once, so its "log in with browser" button
    /// is the way in; the four graphics flags keep Studio on D3D11, the renderer Wine can provide.
    static let studioSettings: [(key: String, value: String)] = [
        ("FIntStudioEmbeddedAuthorizationDialogLoadingTimeoutMillis", "1"),
        ("DFIntStudioEmbeddedAuthorizationDialogLoadingTimeoutMillis", "1"),
        ("FFlagDebugGraphicsPreferD3D11", "true"),
        ("FFlagDebugGraphicsDisableD3D12", "true"),
        ("FFlagDebugGraphicsDisableVulkan", "true"),
        ("FFlagDebugGraphicsDisableOpenGL", "true"),
    ]

    /// The file Studio reads at start-up, written again whenever Studio or Dev Mode opens (an update brings a new
    /// version folder). Foundation only; the batch writes the same keys when the installer has just made the folder.
    static var studioSettingsJSON: String {
        let body = studioSettings.map { "  \"\($0.key)\": \($0.value)" }.joined(separator: ",\n")
        return "{\n\(body)\n}\n"
    }

    /// The same flags as `echo` lines for a .bat: code page 437 is enough, every character here is ASCII.
    static var studioSettingsBatchLines: [String] {
        var lines = ["echo {"]
        for (index, setting) in studioSettings.enumerated() {
            let comma = index == studioSettings.count - 1 ? "" : ","
            lines.append("echo   \"\(setting.key)\": \(setting.value)\(comma)")
        }
        lines.append("echo }")
        return lines
    }

    /// Whether an address BCD's URL bridge found is Studio's own sign-in page, and not some other web link a game
    /// opened. The host and path are checked, and the OAuth redirect must name Studio's scheme (URLComponents has
    /// already decoded `roblox-studio-auth%3A%2F`). The fallback covers builds that omit the redirect in the query.
    static func isStudioAuthorizeRequest(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == authorizeHost,
              url.path.hasPrefix(authorizePath) else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { $0.name == "redirect_uri" && ($0.value?.contains(callbackScheme) ?? false) }
            || url.absoluteString.contains(callbackScheme)
    }

    /// The callback is exactly `roblox-studio-auth:/?code=...`; no other scheme is written into the prefix.
    static func isCallback(_ url: URL) -> Bool { url.scheme?.lowercased() == callbackScheme }

    static func callbackFileURL(in drive: URL) -> URL {
        drive.appendingPathComponent(callbackRelativePath)
    }

    /// A callback left by a session that ended before the batch read it is never handed to a new Studio.
    static func clearCallback(in drive: URL) {
        try? FileManager.default.removeItem(at: callbackFileURL(in: drive))
    }

    /// The one-shot hand-off: the batch reads the first line and deletes the file. Returns whether it was written.
    @discardableResult
    static func writeCallback(_ url: URL, in drive: URL) -> Bool {
        guard isCallback(url) else { return false }
        let file = callbackFileURL(in: drive)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (url.absoluteString + "\r\n").write(to: file, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}

enum BCDRobloxAuthError: LocalizedError {
    case busy
    case cannotStart
    case noCallback

    var errorDescription: String? {
        switch self {
        case .busy: return "A Roblox sign-in is already open. Finish it before starting another."
        case .cannotStart: return "BCD could not open Roblox's sign-in page. Try signing in again from Studio."
        case .noCallback: return "Roblox's sign-in did not return to BCD. Try again from Studio."
        }
    }
}

/// Keeps the one ASWebAuthenticationSession alive until Roblox answers, then gives the callback back to
/// LibraryModel so it can put it in drive_c. A canceled sheet reports an error; it never writes a half callback.
final class BCDRobloxAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = BCDRobloxAuthSession()

    private var session: ASWebAuthenticationSession?
    private var completion: ((Result<URL, Error>) -> Void)?

    @MainActor
    func begin(authorizeURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard session == nil else { completion(.failure(BCDRobloxAuthError.busy)); return }
        guard BCDRobloxAuth.isStudioAuthorizeRequest(authorizeURL) else {
            completion(.failure(BCDRobloxAuthError.cannotStart))
            return
        }
        self.completion = completion
        let auth = ASWebAuthenticationSession(url: authorizeURL,
                                              callbackURLScheme: BCDRobloxAuth.callbackScheme) { [weak self] url, error in
            // The framework calls this off the main thread; the model it answers is a main-actor object.
            DispatchQueue.main.async {
                guard let self else { return }
                let done = self.completion
                self.completion = nil
                self.session = nil
                if let url { done?(.success(url)) }
                else { done?(.failure(error ?? BCDRobloxAuthError.noCallback)) }
            }
        }
        auth.presentationContextProvider = self
        // Keep Roblox's own cookies: an ephemeral sheet would ask the player to type the password again.
        auth.prefersEphemeralWebBrowserSession = false
        session = auth
        guard auth.start() else {
            session = nil
            let done = self.completion
            self.completion = nil
            done?(.failure(BCDRobloxAuthError.cannotStart))
            return
        }
    }

    /// The window the sign-in sheet sits on: the front scene's key window, never a window BCD made for the preview.
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        func anchor() -> ASPresentationAnchor {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return scene?.keyWindow ?? UIWindow(frame: .zero)
        }
        return Thread.isMainThread ? anchor() : DispatchQueue.main.sync { anchor() }
    }
}

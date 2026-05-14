//
//  ActionExecutor.swift
//  TipTour
//
//  Autopilot execution layer. TipTour decides what should happen
//  (Gemini tool call -> AX/box_2d resolution -> workflow state); CUA
//  Driver Core handles the low-level macOS input delivery.
//

import AppKit
import CuaDriverCore
import Foundation

enum ActionExecutorError: Error, LocalizedError {
    case targetAppUnavailable
    case unparseableKeyboardShortcut(String)
    case invalidScrollDirection(String)
    case highlightedTextRangeUnavailable

    var errorDescription: String? {
        switch self {
        case .targetAppUnavailable:
            return "No target app is available for this autopilot action."
        case .unparseableKeyboardShortcut(let shortcutString):
            return "Couldn't parse keyboard shortcut \"\(shortcutString)\"."
        case .invalidScrollDirection(let direction):
            return "Invalid scroll direction \"\(direction)\"."
        case .highlightedTextRangeUnavailable:
            return "The highlighted text range is no longer available."
        }
    }
}

@MainActor
final class ActionExecutor {

    static let shared = ActionExecutor()

    private let postActivationSettleSeconds: TimeInterval = 0.05
    private let postForegroundActivationSettleSeconds: TimeInterval = 0.35
    private var pendingTextReplacementRangeByProcessIdentifier: [pid_t: CFRange] = [:]

    // MARK: - Public API

    func click(
        atGlobalScreenPoint globalScreenPoint: CGPoint,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        try AXInput.requireAuthorized()

        let targetApplication = try targetApplication(for: targetApp)
        try await activateTargetApplicationIfNeeded(targetApplication)

        let targetProcessIdentifier = targetApplication.processIdentifier
        let cuaScreenPoint = convertGlobalAppKitPointToCuaScreenPoint(globalScreenPoint)

        try MouseInput.click(
            at: cuaScreenPoint,
            toPid: targetProcessIdentifier,
            button: .left,
            count: 1,
            useFrontmostHIDPath: true
        )
        print("[ActionExecutor] CUA clicked pid=\(targetProcessIdentifier) at \(cuaScreenPoint)")
    }

    func rightClick(
        atGlobalScreenPoint globalScreenPoint: CGPoint,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        try await click(
            atGlobalScreenPoint: globalScreenPoint,
            activatingTargetApp: targetApp,
            button: .right,
            count: 1
        )
    }

    func doubleClick(
        atGlobalScreenPoint globalScreenPoint: CGPoint,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        try await click(
            atGlobalScreenPoint: globalScreenPoint,
            activatingTargetApp: targetApp,
            button: .left,
            count: 2
        )
    }

    func pressKeyboardShortcut(
        _ shortcutString: String,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        try AXInput.requireAuthorized()

        let targetApplication = try targetApplication(for: targetApp)
        try await activateTargetApplicationIfNeeded(targetApplication)

        let targetProcessIdentifier = targetApplication.processIdentifier
        let hotkeyTokens = try normalizedHotkeyTokens(from: shortcutString)

        try KeyboardInput.hotkey(
            hotkeyTokens,
            toPid: targetProcessIdentifier
        )
        print("[ActionExecutor] CUA pressed shortcut \"\(shortcutString)\" on pid=\(targetProcessIdentifier)")
    }

    func pressKey(
        _ keyName: String,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        try AXInput.requireAuthorized()

        let targetApplication = try targetApplication(for: targetApp)
        try await activateTargetApplicationIfNeeded(targetApplication)
        let targetProcessIdentifier = targetApplication.processIdentifier

        if normalizeShortcutToken(keyName) == "delete",
           hasPendingTextReplacementRange(for: targetProcessIdentifier) {
            let focusedElement = try AXInput.focusedElement(pid: targetProcessIdentifier)
            try applyPendingTextReplacementRange(
                processIdentifier: targetProcessIdentifier,
                focusedElement: focusedElement
            )
        }

        try KeyboardInput.press(
            normalizeShortcutToken(keyName),
            toPid: targetProcessIdentifier
        )
        print("[ActionExecutor] CUA pressed key \"\(keyName)\" on pid=\(targetProcessIdentifier)")
    }

    func typeText(
        _ text: String,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        try AXInput.requireAuthorized()

        let targetApplication = try targetApplication(for: targetApp)
        try await activateTargetApplicationIfNeeded(targetApplication)

        let targetProcessIdentifier = targetApplication.processIdentifier

        let hasArmedHighlightReplacementRange = hasPendingTextReplacementRange(
            for: targetProcessIdentifier
        )

        // Three-tier text input strategy, tried in order:
        //
        // 1. AX setAttribute("AXSelectedText") — zero-latency, preserves
        //    undo history, works on native Cocoa text fields. Silently
        //    succeeds even when the element lost focus, so we verify by
        //    reading AXValue back.
        //
        // 2. Clipboard Cmd+V — works in rich web editors (Google Docs,
        //    Notion web, etc.) that swallow AX writes but accept paste.
        //    Required for highlight-replacement where the selection range
        //    must be set before the paste lands; we don't fall through to
        //    typeCharacters in that case.
        //
        // 3. KeyboardInput.typeCharacters — CGEvent Unicode injection,
        //    character by character. Works everywhere that accepts keyboard
        //    input: Safari address bar, web content areas, Electron views,
        //    terminal emulators, games. No dependency on AX focus or
        //    pasteboard. Used as the final fallback when both AX and
        //    clipboard paths fail or aren't applicable.

        do {
            let focusedElement = try AXInput.focusedElement(pid: targetProcessIdentifier)
            if hasArmedHighlightReplacementRange {
                try applyPendingTextReplacementRange(
                    processIdentifier: targetProcessIdentifier,
                    focusedElement: focusedElement
                )
            }
            try AXInput.setAttribute(
                "AXSelectedText",
                on: focusedElement,
                value: text as CFString
            )

            // Verify insertion landed by reading AXValue. AXSelectedText
            // can silently succeed on an element that has already lost
            // focus (e.g. Safari address bar after TipTour activates).
            var valueRef: AnyObject?
            let readResult = AXUIElementCopyAttributeValue(focusedElement, "AXValue" as CFString, &valueRef)
            let currentValue = readResult == .success ? (valueRef as? String ?? "") : ""
            let insertionVerified = currentValue.contains(text)

            if insertionVerified {
                print("[ActionExecutor] CUA inserted \(text.count) characters via AX on pid=\(targetProcessIdentifier)")
                return
            }

            // AX write silently failed — element wasn't truly focused.
            print("[ActionExecutor] AX insert silently failed (value unchanged) — trying clipboard then typeCharacters on pid=\(targetProcessIdentifier)")
            guard !hasArmedHighlightReplacementRange else {
                // Highlight replacement requires the precise AX selection
                // range that was just applied. Clipboard paste would land
                // at an arbitrary cursor position. typeCharacters has the
                // same problem. Surface the error so the caller can
                // report it to the user instead of pasting in the wrong place.
                throw ActionExecutorError.highlightedTextRangeUnavailable
            }

            // Tier 2: clipboard paste.
            do {
                try await pasteTextUsingClipboard(text, toPid: targetProcessIdentifier)
                print("[ActionExecutor] CUA pasted \(text.count) characters via clipboard on pid=\(targetProcessIdentifier)")
                return
            } catch {
                print("[ActionExecutor] clipboard paste failed — falling back to typeCharacters: \(error.localizedDescription)")
            }

            // Tier 3: CGEvent Unicode injection via system HID tap (no pid).
            // This is identical to a real user typing — events route through
            // the frontmost app's focused field. Works in Chrome, Safari,
            // Electron, web content areas, and any app that accepts keyboard.
            // We do NOT pass toPid here because pid-routed keyboard events
            // are filtered by Chromium and other sandboxed apps.
            try KeyboardInput.typeCharacters(text)
            print("[ActionExecutor] CUA typed \(text.count) characters via HID tap on pid=\(targetProcessIdentifier)")

        } catch {
            guard !hasArmedHighlightReplacementRange else {
                print("[ActionExecutor] refused fallback — highlighted range could not be applied: \(error)")
                throw ActionExecutorError.highlightedTextRangeUnavailable
            }

            // AX focusedElement lookup itself failed. Try clipboard, then
            // HID-tap typeCharacters (same reasoning as tier 3 above).
            do {
                try await pasteTextUsingClipboard(text, toPid: targetProcessIdentifier)
                print("[ActionExecutor] CUA pasted \(text.count) characters via clipboard on pid=\(targetProcessIdentifier)")
            } catch {
                print("[ActionExecutor] clipboard also failed — using HID tap typeCharacters: \(error.localizedDescription)")
                try KeyboardInput.typeCharacters(text)
                print("[ActionExecutor] CUA typed \(text.count) characters via CGEvent Unicode on pid=\(targetProcessIdentifier)")
            }
        }
    }

    func setFocusedValue(
        _ value: String,
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        try AXInput.requireAuthorized()

        let targetApplication = try targetApplication(for: targetApp)
        try await activateTargetApplicationIfNeeded(targetApplication)

        let targetProcessIdentifier = targetApplication.processIdentifier
        let focusedElement = try AXInput.focusedElement(pid: targetProcessIdentifier)

        if hasPendingTextReplacementRange(for: targetProcessIdentifier) {
            try applyPendingTextReplacementRange(
                processIdentifier: targetProcessIdentifier,
                focusedElement: focusedElement
            )
            try AXInput.setAttribute(
                "AXSelectedText",
                on: focusedElement,
                value: value as CFString
            )
            print("[ActionExecutor] CUA replaced highlighted text via setValue payload on pid=\(targetProcessIdentifier)")
            return
        }

        try AXInput.setAttribute(
            "AXValue",
            on: focusedElement,
            value: value as CFString
        )
        print("[ActionExecutor] CUA set focused AXValue on pid=\(targetProcessIdentifier)")
    }

    func scroll(
        direction: String,
        amount: Int = 3,
        by granularity: String = "line",
        activatingTargetApp targetApp: NSRunningApplication? = nil
    ) async throws {
        try AXInput.requireAuthorized()

        let targetApplication = try targetApplication(for: targetApp)
        try await activateTargetApplicationIfNeeded(targetApplication)

        guard let keyName = scrollKeyName(direction: direction, granularity: granularity) else {
            throw ActionExecutorError.invalidScrollDirection("\(direction)/\(granularity)")
        }

        let targetProcessIdentifier = targetApplication.processIdentifier
        let clampedAmount = max(1, min(amount, 50))
        for _ in 0..<clampedAmount {
            try KeyboardInput.press(keyName, toPid: targetProcessIdentifier)
        }
        print("[ActionExecutor] CUA scrolled \(direction) via \(clampedAmount)x \(keyName) on pid=\(targetProcessIdentifier)")
    }

    func openApplication(named applicationName: String) async throws {
        let launchedApplication = try await AppLauncher.launch(
            name: applicationName,
            additionalArguments: remoteDebuggingArgumentsIfChromiumBrowser(applicationName)
        )
        if let runningApplication = NSRunningApplication(processIdentifier: launchedApplication.pid) {
            try await bringApplicationToForeground(runningApplication)
        }
        print("[ActionExecutor] CUA opened app \"\(applicationName)\" pid=\(launchedApplication.pid)")
    }

    func openURL(_ rawURLString: String, preferredApplicationName: String? = nil) async throws {
        let url = normalizedURL(from: rawURLString)
        if let preferredApplicationName, !preferredApplicationName.isEmpty {
            let launchedApplication = try await AppLauncher.launch(
                name: preferredApplicationName,
                urls: [url],
                additionalArguments: remoteDebuggingArgumentsIfChromiumBrowser(preferredApplicationName)
            )
            if let runningApplication = NSRunningApplication(processIdentifier: launchedApplication.pid) {
                try await bringApplicationToForeground(runningApplication)
            }
        } else {
            let launchedApplication = try await launchDefaultApplication(for: url)
            if let runningApplication = NSRunningApplication(processIdentifier: launchedApplication.pid) {
                try await bringApplicationToForeground(runningApplication)
            }
        }

        if let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        print("[ActionExecutor] opened URL \(url.absoluteString)")
    }

    func setPendingTextReplacementRange(
        processIdentifier: pid_t,
        location: Int,
        length: Int
    ) {
        guard location >= 0, length > 0 else { return }
        pendingTextReplacementRangeByProcessIdentifier[processIdentifier] = CFRange(
            location: location,
            length: length
        )
        print("[ActionExecutor] armed pending text replacement range pid=\(processIdentifier) location=\(location) length=\(length)")
    }

    private func click(
        atGlobalScreenPoint globalScreenPoint: CGPoint,
        activatingTargetApp targetApp: NSRunningApplication?,
        button: MouseInput.Button,
        count: Int
    ) async throws {
        try AXInput.requireAuthorized()

        let targetApplication = try targetApplication(for: targetApp)
        try await activateTargetApplicationIfNeeded(targetApplication)

        let targetProcessIdentifier = targetApplication.processIdentifier
        let cuaScreenPoint = convertGlobalAppKitPointToCuaScreenPoint(globalScreenPoint)

        try MouseInput.click(
            at: cuaScreenPoint,
            toPid: targetProcessIdentifier,
            button: button,
            count: count,
            useFrontmostHIDPath: true
        )
        print("[ActionExecutor] CUA \(button.rawValue)-clicked pid=\(targetProcessIdentifier) at \(cuaScreenPoint)")
    }

    // MARK: - Target App

    private func targetApplication(for targetApp: NSRunningApplication?) throws -> NSRunningApplication {
        if let targetApp {
            return targetApp
        }
        if let userTargetAppOverride = AccessibilityTreeResolver.userTargetAppOverride {
            return userTargetAppOverride
        }
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication {
            return frontmostApplication
        }
        throw ActionExecutorError.targetAppUnavailable
    }

    private func activateTargetApplicationIfNeeded(_ targetApplication: NSRunningApplication) async throws {
        if !targetApplication.isActive {
            targetApplication.activate()
            try await Task.sleep(nanoseconds: UInt64(postActivationSettleSeconds * 1_000_000_000))
        }
    }

    private func bringApplicationToForeground(_ targetApplication: NSRunningApplication) async throws {
        targetApplication.unhide()
        targetApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        try await Task.sleep(nanoseconds: UInt64(postForegroundActivationSettleSeconds * 1_000_000_000))
        raiseMainWindowIfPossible(for: targetApplication)
        try await Task.sleep(nanoseconds: UInt64(postActivationSettleSeconds * 1_000_000_000))
    }

    private func raiseMainWindowIfPossible(for targetApplication: NSRunningApplication) {
        let processIdentifier = targetApplication.processIdentifier
        guard processIdentifier > 0 else { return }

        let appElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.2)

        if let focusedWindow = accessibilityWindowAttribute(
            "AXFocusedWindow",
            of: appElement
        ) {
            AXUIElementPerformAction(focusedWindow, kAXRaiseAction as CFString)
            return
        }

        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let firstWindow = windows.first else {
            return
        }

        AXUIElementPerformAction(firstWindow, kAXRaiseAction as CFString)
    }

    private func accessibilityWindowAttribute(
        _ attributeName: String,
        of element: AXUIElement
    ) -> AXUIElement? {
        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &valueRef) == .success,
              let valueRef else {
            return nil
        }
        return valueRef as! AXUIElement
    }

    private func hasPendingTextReplacementRange(for processIdentifier: pid_t) -> Bool {
        pendingTextReplacementRangeByProcessIdentifier[processIdentifier] != nil
    }

    private func applyPendingTextReplacementRange(
        processIdentifier: pid_t,
        focusedElement: AXUIElement
    ) throws {
        guard var pendingRange = pendingTextReplacementRangeByProcessIdentifier[processIdentifier] else {
            return
        }

        guard let selectedRangeValue = AXValueCreate(.cfRange, &pendingRange) else {
            throw ActionExecutorError.highlightedTextRangeUnavailable
        }

        try AXInput.setAttribute(
            "AXSelectedTextRange",
            on: focusedElement,
            value: selectedRangeValue
        )
        pendingTextReplacementRangeByProcessIdentifier.removeValue(forKey: processIdentifier)
        print("[ActionExecutor] applied pending text replacement range pid=\(processIdentifier) location=\(pendingRange.location) length=\(pendingRange.length)")
    }

    private func pasteTextUsingClipboard(
        _ text: String,
        toPid targetProcessIdentifier: pid_t
    ) async throws {
        let pasteboard = NSPasteboard.general
        let previousPasteboardItems = copyPasteboardItems(from: pasteboard)

        let stagedTextItem = NSPasteboardItem()
        stagedTextItem.setString(text, forType: .string)

        pasteboard.clearContents()
        pasteboard.writeObjects([stagedTextItem])

        do {
            try KeyboardInput.hotkey(["cmd", "v"], toPid: targetProcessIdentifier)
            try await Task.sleep(nanoseconds: 80_000_000)
            restorePasteboard(pasteboard, items: previousPasteboardItems)
        } catch {
            restorePasteboard(pasteboard, items: previousPasteboardItems)
            throw error
        }
    }

    private func copyPasteboardItems(from pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        pasteboard.pasteboardItems?.map { pasteboardItem in
            let copiedPasteboardItem = NSPasteboardItem()
            for type in pasteboardItem.types {
                if let data = pasteboardItem.data(forType: type) {
                    copiedPasteboardItem.setData(data, forType: type)
                } else if let string = pasteboardItem.string(forType: type) {
                    copiedPasteboardItem.setString(string, forType: type)
                }
            }
            return copiedPasteboardItem
        } ?? []
    }

    private func restorePasteboard(
        _ pasteboard: NSPasteboard,
        items: [NSPasteboardItem]
    ) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }

    private func normalizedURL(from rawURLString: String) -> URL {
        let trimmedURLString = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: trimmedURLString), url.scheme != nil {
            return url
        }

        if trimmedURLString.hasPrefix("/") || trimmedURLString.hasPrefix("~") {
            let expandedPath = (trimmedURLString as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expandedPath)
        }

        return URL(string: "https://\(trimmedURLString)") ?? URL(fileURLWithPath: trimmedURLString)
    }

    private func launchDefaultApplication(for url: URL) async throws -> AppInfo {
        if let defaultApplicationURL = NSWorkspace.shared.urlForApplication(toOpen: url),
           let bundleIdentifier = Bundle(url: defaultApplicationURL)?.bundleIdentifier {
            return try await AppLauncher.launch(
                bundleId: bundleIdentifier,
                urls: [url],
                additionalArguments: remoteDebuggingArgumentsIfChromiumBrowser(bundleIdentifier)
            )
        }

        return try await AppLauncher.launch(
            name: "Safari",
            urls: [url]
        )
    }

    private func remoteDebuggingArgumentsIfChromiumBrowser(_ applicationNameOrBundleIdentifier: String) -> [String] {
        let normalized = applicationNameOrBundleIdentifier.lowercased()
        let isChromiumBrowser = normalized.contains("chrome")
            || normalized.contains("chromium")
            || normalized.contains("brave")
            || normalized.contains("edge")
            || normalized.contains("thebrowser")
            || normalized.contains("arc")

        guard isChromiumBrowser else { return [] }
        return ["--remote-debugging-port=9222"]
    }

    // MARK: - Coordinate Conversion

    /// TipTour stores global points in AppKit coordinates (bottom-left
    /// origin). CUA's pixel-addressed input primitives use screen points
    /// with a top-left origin.
    private func convertGlobalAppKitPointToCuaScreenPoint(_ globalAppKitPoint: CGPoint) -> CGPoint {
        guard let primaryScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main else {
            return globalAppKitPoint
        }
        return CGPoint(
            x: globalAppKitPoint.x,
            y: primaryScreen.frame.height - globalAppKitPoint.y
        )
    }

    // MARK: - Shortcut Parsing

    private func normalizedHotkeyTokens(from shortcutString: String) throws -> [String] {
        let rawTokens = shortcutString
            .split(whereSeparator: { $0 == "+" || $0 == "-" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !rawTokens.isEmpty else {
            throw ActionExecutorError.unparseableKeyboardShortcut(shortcutString)
        }

        var modifierTokens: [String] = []
        var finalKeyToken: String?

        for rawToken in rawTokens {
            let normalizedToken = normalizeShortcutToken(rawToken)
            if Self.modifierTokens.contains(normalizedToken) {
                modifierTokens.append(normalizedToken)
            } else {
                guard finalKeyToken == nil else {
                    throw ActionExecutorError.unparseableKeyboardShortcut(shortcutString)
                }
                finalKeyToken = normalizedToken
            }
        }

        guard let finalKeyToken else {
            throw ActionExecutorError.unparseableKeyboardShortcut(shortcutString)
        }

        return modifierTokens + [finalKeyToken]
    }

    private func normalizeShortcutToken(_ token: String) -> String {
        let normalizedRawToken = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            .lowercased()

        switch normalizedRawToken {
        case "cmd", "command", "⌘":
            return "cmd"
        case "opt", "option", "alt", "⌥":
            return "option"
        case "ctrl", "control", "⌃":
            return "ctrl"
        case "shift", "⇧":
            return "shift"
        case "esc":
            return "escape"
        case "del", "backspace":
            return "delete"
        case "return":
            return "return"
        default:
            return normalizedRawToken
        }
    }

    private func scrollKeyName(direction: String, granularity: String) -> String? {
        let normalizedDirection = direction.lowercased()
        let normalizedGranularity = granularity.lowercased()
        switch (normalizedDirection, normalizedGranularity) {
        case ("up", "line"): return "up"
        case ("down", "line"): return "down"
        case ("left", "line"): return "left"
        case ("right", "line"): return "right"
        case ("up", "page"): return "pageup"
        case ("down", "page"): return "pagedown"
        case ("left", "page"): return "left"
        case ("right", "page"): return "right"
        default: return nil
        }
    }

    private static let modifierTokens: Set<String> = [
        "cmd",
        "command",
        "shift",
        "option",
        "alt",
        "ctrl",
        "control",
        "fn"
    ]
}

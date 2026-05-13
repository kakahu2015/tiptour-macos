//
//  CompanionScreenCaptureUtility.swift
//  TipTour
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
    /// When this frame was captured. Used by ElementResolver to warn
    /// when resolution runs against a stale screenshot — large drift
    /// means the cursor is likely to land on a moved/gone element.
    let captureTimestamp: Date
}

@MainActor
enum CompanionScreenCaptureUtility {

    // MARK: - SCShareableContent cache
    //
    // SCShareableContent.excludingDesktopWindows is the single heaviest call
    // in the capture path (~50-200ms). Caching it for 10 seconds means the
    // 3-second periodic screenshot loop pays that cost at most once per 10s
    // instead of every frame. The cache is invalidated when the on-screen
    // window count changes (app launch/quit) or after the TTL expires.

    private struct CachedShareableContent {
        let content: SCShareableContent
        let ownAppWindows: [SCWindow]
        let nsScreenByDisplayID: [CGDirectDisplayID: NSScreen]
        let fetchedAt: Date
        let windowCount: Int
    }

    private static var cachedShareableContent: CachedShareableContent?
    /// How long the cache stays valid when the window count hasn't changed.
    private static let shareableContentCacheTTL: TimeInterval = 10.0

    private static func fetchShareableContent() async throws -> CachedShareableContent {
        let currentWindowCount = NSWorkspace.shared.runningApplications.count

        if let cached = cachedShareableContent,
           cached.windowCount == currentWindowCount,
           Date().timeIntervalSince(cached.fetchedAt) < shareableContentCacheTTL {
            return cached
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleIdentifier }

        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        let fresh = CachedShareableContent(
            content: content,
            ownAppWindows: ownAppWindows,
            nsScreenByDisplayID: nsScreenByDisplayID,
            fetchedAt: Date(),
            windowCount: currentWindowCount
        )
        cachedShareableContent = fresh
        return fresh
    }

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let cached = try await fetchShareableContent()
        let content = cached.content
        let ownAppWindows = cached.ownAppWindows
        let nsScreenByDisplayID = cached.nsScreenByDisplayID

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let maxDimension = 1280
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height,
                captureTimestamp: Date()
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    /// Lightweight capture of the cursor screen as a raw CGImage.
    /// Skips JPEG encoding — use this for on-device detection where
    /// you need a CGImage directly (no network transfer).
    static func capturePrimaryScreenAsCGImage() async throws -> CGImage {
        let cached = try await fetchShareableContent()
        let content = cached.content
        let ownAppWindows = cached.ownAppWindows
        let nsScreenByDisplayID = cached.nsScreenByDisplayID

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        let cursorDisplay = content.displays.first { display in
            let frame = nsScreenByDisplayID[display.displayID]?.frame ?? display.frame
            return frame.contains(mouseLocation)
        } ?? content.displays[0]

        let filter = SCContentFilter(display: cursorDisplay, excludingWindows: ownAppWindows)

        let configuration = SCStreamConfiguration()
        let maxDimension = 1280
        let aspectRatio = CGFloat(cursorDisplay.width) / CGFloat(cursorDisplay.height)
        if cursorDisplay.width >= cursorDisplay.height {
            configuration.width = maxDimension
            configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
        } else {
            configuration.height = maxDimension
            configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
        }

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }
}

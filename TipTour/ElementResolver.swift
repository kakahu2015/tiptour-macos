//
//  ElementResolver.swift
//  TipTour
//
//  Single entry point for "where on screen should the cursor fly to?"
//
//  Tries three lookup strategies in order of reliability:
//    1. macOS Accessibility tree (~30ms, pixel-perfect when the app
//       supports AX — almost all native Mac apps, most Cocoa third-party
//       apps, and Electron apps that respect AXManualAccessibility).
//    2. Browser DOM coordinates through CUA/CDP for Chromium web pages.
//    3. Raw Gemini-emitted box_2d coordinates as the absolute fallback.
//       These come from the same model that named the element, so they
//       reflect Gemini's spatial intent for that exact tool call.
//
//  The resolver returns a global AppKit screen coordinate so the cursor
//  overlay can fly to it without further conversion.
//

import AppKit
import Foundation

final class ElementResolver: @unchecked Sendable {

    static let shared = ElementResolver()

    private let axResolver = AccessibilityTreeResolver()
    private let browserCoordinateResolver = BrowserCoordinateResolver()

    // MARK: - Public Types

    /// Where the resolved coordinate came from — useful for logging and
    /// telling the cursor what confidence to render with.
    enum ResolutionSource {
        case accessibilityTree       // AX tree gave us exact frame
        case browserDOMCoordinates   // Browser DOM rect through CUA/CDP
        case llmRawCoordinates       // Straight from Gemini's box_2d, no refinement
    }

    struct Resolution {
        /// Global AppKit-space coordinate — ready to pass to the overlay.
        let globalScreenPoint: CGPoint
        /// The display the point is on.
        let displayFrame: CGRect
        /// Human-readable label describing what was pointed at.
        let label: String
        /// Where the resolution came from — for logging/telemetry.
        let source: ResolutionSource
        /// Global AppKit-space rect for the matched element, when the
        /// resolution source can produce one. AX always gives us this
        /// (pixel-perfect). Raw box_2d does not — the click detector
        /// falls back to a radius around `globalScreenPoint` when this
        /// is nil.
        let globalScreenRect: CGRect?
    }

    // MARK: - Resolution

    /// Try AX tree only. Runs on a background task so the walk doesn't
    /// block main. Returns nil if AX has no match for the label.
    /// `targetAppHint` (e.g. "Blender") lets us query the app the user
    /// is actually looking at when the system's focused app is a
    /// background recorder like Cap.
    func tryAccessibilityTree(label: String, targetAppHint: String? = nil) async -> Resolution? {
        let axResolverRef = axResolver
        let axResult = await Task.detached(priority: .userInitiated) {
            return axResolverRef.findElement(byLabel: label, targetAppHint: targetAppHint)
        }.value

        guard let axResult else { return nil }

        let globalPoint = await MainActor.run {
            displayFrameContaining(axResult.center) ?? axResult.screenFrame
        }
        print("[ElementResolver] ✓ AX matched \"\(label)\" → \"\(axResult.title)\" [\(axResult.role)] at \(axResult.center)")
        return Resolution(
            globalScreenPoint: axResult.center,
            displayFrame: globalPoint,
            label: label,
            source: .accessibilityTree,
            globalScreenRect: axResult.screenFrame
        )
    }

    /// Absolute last resort — use Gemini's raw box_2d coordinate as-is.
    func rawLLMCoordinate(
        label: String,
        llmHintInScreenshotPixels: CGPoint,
        capture: CompanionScreenCapture
    ) -> Resolution {
        let globalPoint = screenshotPixelToGlobalScreen(llmHintInScreenshotPixels, capture: capture)
        print("[ElementResolver] ⚠ using raw LLM coords for \"\(label)\" → screenshotPixel=\(llmHintInScreenshotPixels), capture=\(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels), displayFrame=\(capture.displayFrame), screen=\(globalPoint)")
        return Resolution(
            globalScreenPoint: globalPoint,
            displayFrame: capture.displayFrame,
            label: label,
            source: .llmRawCoordinates,
            globalScreenRect: nil
        )
    }

    /// Poll the AX tree repeatedly for up to `timeoutSeconds` waiting
    /// for `label` to appear. Returns the first successful resolution.
    /// Used by the workflow runner to wait for a newly-opened menu or
    /// sheet to settle after a click, instead of sleeping a fixed time.
    /// Polling is cheap (~20-40ms per tick) and exits early on match.
    func pollAccessibilityTree(
        label: String,
        targetAppHint: String?,
        timeoutSeconds: Double,
        pollIntervalSeconds: Double = 0.08
    ) async -> Resolution? {
        // Short-circuit for apps we already know don't expose an AX
        // tree (Blender, Unity, games). Saves up to a full `timeoutSeconds`
        // of wasted polling per step AND the CPU churn that causes
        // audio underruns in the Gemini Live output stream.
        if AccessibilityTreeResolver.isAppKnownToLackAXTree(hint: targetAppHint) {
            print("[AX] skipping poll for \"\(label)\" — app \"\(targetAppHint ?? "?")\" flagged as no-AX-tree")
            return nil
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let hit = await tryAccessibilityTree(label: label, targetAppHint: targetAppHint) {
                return hit
            }
            try? await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
        }
        return nil
    }

    /// Full resolution pipeline.
    ///
    /// When Gemini provides box_2d the coordinate is used as the primary
    /// spatial anchor — it reflects exactly what Gemini saw on-screen and
    /// which element it intended to target. AX label-matching is unreliable
    /// as a primary path for web/Electron content because many elements share
    /// the same label text (e.g. a Chrome toolbar button and a page-level
    /// button both titled "Google 搜索"), and AX picks whichever scores
    /// higher on text similarity regardless of position.
    ///
    /// Resolution order when box_2d IS present:
    ///   1. Convert box_2d to a global screen point.
    ///   2. Find the smallest AX element whose frame contains that point
    ///      (position-based snap — gives pixel-perfect center + hit rect).
    ///   3. Fall back to the raw converted coordinate when no AX element
    ///      covers the point (canvas apps, games, web layers).
    ///
    /// Resolution order when box_2d is NOT present:
    ///   1. AX label match (fast, pixel-perfect for native apps).
    ///   2. Multilingual AX fallback via worker semantic match.
    ///   3. Browser DOM/CDP coordinates (Chromium page geometry).
    ///   nil if nothing resolves.
    func resolve(
        label: String,
        llmHintInScreenshotPixels: CGPoint?,
        latestCapture: CompanionScreenCapture?,
        targetAppHint: String? = nil,
        proximityAnchorInGlobalScreen: CGPoint? = nil
    ) async -> Resolution? {

        if let capture = latestCapture {
            let ageSeconds = Date().timeIntervalSince(capture.captureTimestamp)
            if ageSeconds > 1.0 {
                print("[ElementResolver] ⚠ screenshot is \(String(format: "%.2f", ageSeconds))s old — coords may have drifted for \"\(label)\"")
            }
        }

        // ── Path A: box_2d present ──────────────────────────────────────
        // Gemini's visual grounding is the most spatially accurate signal
        // we have. Use the coordinate to find the element at that position
        // rather than guessing by label.
        if let hint = llmHintInScreenshotPixels, let capture = latestCapture {
            let candidateScreenPoint = screenshotPixelToGlobalScreen(hint, capture: capture)

            if !AccessibilityTreeResolver.isAppKnownToLackAXTree(hint: targetAppHint) {
                if let snappedResolution = await snapToAXElementAtPoint(
                    candidateScreenPoint,
                    label: label,
                    targetAppHint: targetAppHint,
                    capture: capture
                ) {
                    return snappedResolution
                }
            }

            // No AX element at that point — use the coordinate directly.
            print("[ElementResolver] ✓ box_2d direct for \"\(label)\" → screenshotPixel=\(hint), screen=\(candidateScreenPoint)")
            return Resolution(
                globalScreenPoint: candidateScreenPoint,
                displayFrame: capture.displayFrame,
                label: label,
                source: .llmRawCoordinates,
                globalScreenRect: nil
            )
        }

        // ── Path B: no box_2d — fall back to label-based lookup ─────────

        if !AccessibilityTreeResolver.isAppKnownToLackAXTree(hint: targetAppHint) {
            if let axResolution = await tryAccessibilityTree(label: label, targetAppHint: targetAppHint) {
                return axResolution
            }

            if let translatedLabel = await translateLabelViaSemanticMatch(
                originalLabel: label,
                targetAppHint: targetAppHint
            ),
               translatedLabel.caseInsensitiveCompare(label) != .orderedSame,
               let axResolution = await tryAccessibilityTree(
                   label: translatedLabel,
                   targetAppHint: targetAppHint
               ) {
                print("[ElementResolver] ✓ multilingual fallback resolved \"\(label)\" → \"\(translatedLabel)\"")
                return axResolution
            }
        }

        if let browserResolution = await browserCoordinateResolver.resolve(
            label: label,
            targetAppHint: targetAppHint
        ) {
            let displayFrame = await MainActor.run {
                displayFrameContaining(browserResolution.globalScreenPoint)
                    ?? NSScreen.main?.frame
                    ?? .zero
            }
            return Resolution(
                globalScreenPoint: browserResolution.globalScreenPoint,
                displayFrame: displayFrame,
                label: browserResolution.matchedLabel,
                source: .browserDOMCoordinates,
                globalScreenRect: browserResolution.globalScreenRect
            )
        }

        print("[ElementResolver] ✗ could not resolve \"\(label)\" — no box_2d and AX/browser missed")
        return nil
    }

    // MARK: - Position-Based AX Snap

    /// Given a screen point from box_2d, find the smallest AX element whose
    /// frame contains that point and snap the click to its center.
    ///
    /// "Smallest" means we prefer the leaf element that most tightly wraps
    /// the coordinate over a large ancestor container. This avoids snapping
    /// to e.g. the entire web content area instead of the specific button.
    ///
    /// The 120pt distance cap guards against huge container elements whose
    /// center drifts far from the original box_2d coordinate — in that case
    /// the raw box_2d coordinate is more accurate than the element center.
    private func snapToAXElementAtPoint(
        _ globalScreenPoint: CGPoint,
        label: String,
        targetAppHint: String?,
        capture: CompanionScreenCapture
    ) async -> Resolution? {
        let axResolverRef = axResolver
        let axResult = await Task.detached(priority: .userInitiated) {
            axResolverRef.findElementContainingPoint(globalScreenPoint, targetAppHint: targetAppHint)
        }.value

        guard let axResult else { return nil }

        let distanceFromBoxPoint = hypot(
            axResult.center.x - globalScreenPoint.x,
            axResult.center.y - globalScreenPoint.y
        )
        guard distanceFromBoxPoint < 120 else {
            print("[ElementResolver] AX snap skipped — element center \(String(format:"%.0f",distanceFromBoxPoint))pt from box_2d, using raw coords for \"\(label)\"")
            return nil
        }

        let displayFrame = await MainActor.run {
            displayFrameContaining(axResult.center) ?? capture.displayFrame
        }
        print("[ElementResolver] ✓ box_2d+AX snap \"\(label)\" → \"\(axResult.title)\" [\(axResult.role)] at \(axResult.center) (box_2d was \(globalScreenPoint))")
        return Resolution(
            globalScreenPoint: axResult.center,
            displayFrame: displayFrame,
            label: label,
            source: .accessibilityTree,
            globalScreenRect: axResult.screenFrame
        )
    }

    // MARK: - Multilingual Fallback

    /// When AX exact-match fails because the user's spoken language
    /// doesn't match the UI's display language (e.g. user said "guardar"
    /// but the UI shows "Save"), pull the current AX label list and ask
    /// the worker which candidate matches the user's intent semantically.
    ///
    /// Returns nil when the worker has nothing confident to suggest, the
    /// network call fails, or no AX labels could be collected.
    private func translateLabelViaSemanticMatch(
        originalLabel: String,
        targetAppHint: String?
    ) async -> String? {
        // Pull the same set-of-marks list we'd send to Gemini. Off-main
        // because the AX walk can take a few hundred ms on complex apps.
        let marks: [AccessibilityTreeResolver.ElementMark]? = await Task.detached(priority: .userInitiated) {
            self.axResolver.setOfMarksForTargetApp(hint: targetAppHint)
        }.value

        guard let marks = marks, !marks.isEmpty else {
            return nil
        }

        // Dedup labels (multiple AX nodes can have the same title) and
        // drop empty/whitespace-only ones.
        let candidateLabels: [String] = {
            var seen = Set<String>()
            var ordered: [String] = []
            for mark in marks {
                let trimmed = mark.label.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if seen.insert(trimmed).inserted {
                    ordered.append(trimmed)
                }
            }
            return ordered
        }()

        guard !candidateLabels.isEmpty else { return nil }

        guard let workerBaseURL = Self.workerBaseURLOverride
                ?? Self.defaultWorkerBaseURL else {
            return nil
        }
        guard let endpoint = URL(string: "\(workerBaseURL)/match-label") else {
            return nil
        }

        struct MatchLabelRequest: Encodable {
            let query: String
            let candidates: [String]
        }
        struct GeminiEnvelope: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]?
                }
                let content: Content?
            }
            let candidates: [Candidate]?
        }
        struct InnerMatch: Decodable { let match: String? }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        do {
            request.httpBody = try JSONEncoder().encode(MatchLabelRequest(
                query: originalLabel,
                candidates: candidateLabels
            ))
        } catch {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return nil
            }
            let envelope = try JSONDecoder().decode(GeminiEnvelope.self, from: data)
            let innerJSONText = envelope.candidates?.first?.content?.parts?.first?.text ?? "{}"
            guard let innerData = innerJSONText.data(using: .utf8) else { return nil }
            let inner = (try? JSONDecoder().decode(InnerMatch.self, from: innerData)) ?? InnerMatch(match: nil)
            return inner.match
        } catch {
            return nil
        }
    }

    /// Optional Worker base URL — set by CompanionManager from bundle
    /// config for distributed builds. Source builds leave this nil so
    /// they never hit the maintainer's Cloudflare Worker.
    nonisolated(unsafe) static var workerBaseURLOverride: String?
    private static let defaultWorkerBaseURL: String? = nil

    // MARK: - Coordinate Conversion

    /// Convert a point in screenshot pixel space (top-left origin) to
    /// global AppKit screen coordinates (bottom-left origin, spans all displays).
    /// Uses the capture's metadata (display frame, pixel dimensions) to scale.
    private func screenshotPixelToGlobalScreen(_ pixel: CGPoint, capture: CompanionScreenCapture) -> CGPoint {
        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)
        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let displayFrame = capture.displayFrame

        let clampedX = max(0, min(pixel.x, screenshotWidth))
        let clampedY = max(0, min(pixel.y, screenshotHeight))

        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY

        return CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )
    }

    /// Find the NSScreen whose frame contains the given global AppKit point.
    private func displayFrameContaining(_ globalPoint: CGPoint) -> CGRect? {
        for screen in NSScreen.screens {
            if screen.frame.contains(globalPoint) {
                return screen.frame
            }
        }
        return nil
    }
}

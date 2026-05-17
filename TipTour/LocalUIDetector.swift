//
//  LocalUIDetector.swift
//  TipTour
//
//  On-device UI element detector using the OmniParser YOLOv8 CoreML model
//  for bounding-box detection and Apple Vision for OCR label extraction.
//
//  Used by ElementResolver as the 4th resolution tier: when AX tree,
//  browser DOM, and box_2d+AX-snap all miss (canvas apps, games, Figma,
//  custom Electron surfaces with thin AX trees), this detector runs a
//  local YOLO pass over the screenshot and matches detected UI elements
//  to the step label via Apple Vision OCR — no network call required.
//
//  Architecture:
//    1. YOLO pass — detects all UI element bounding boxes in the screenshot
//       (640×640 input, NMS baked into the CoreML graph)
//    2. Apple Vision OCR — reads text from each detected box
//    3. Label fuzzy-match — scores OCR'd text against the target label,
//       returns the highest-confidence box whose text matches
//    4. Proximity tie-break — when multiple boxes score equally, prefer
//       the one nearest the optional proximity anchor (previous step's
//       resolved screen point), fixing nested-menu ambiguity
//

import AppKit
import CoreML
import Foundation
import Vision

final class LocalUIDetector: @unchecked Sendable {

    static let shared = LocalUIDetector()

    // MARK: - Types

    struct DetectedElement {
        /// Bounding box in global AppKit screen coordinates.
        let globalScreenRect: CGRect
        /// Center point in global AppKit screen coordinates.
        var globalScreenCenter: CGPoint {
            CGPoint(x: globalScreenRect.midX, y: globalScreenRect.midY)
        }
        /// OCR'd text label from Apple Vision (may be empty for icon-only elements).
        let ocrLabel: String
        /// YOLO detection confidence [0, 1].
        let detectionConfidence: Float
        /// Fuzzy match score against the query label [0, 1].
        let labelMatchScore: Float
    }

    // MARK: - Private State

    private var yoloModel: MLModel?
    private let modelLoadLock = NSLock()
    private var modelLoadError: Error?

    // Apple Vision OCR requests are lightweight — create one per call
    // rather than sharing a single request across concurrent tasks.

    // MARK: - Model Loading

    private func loadModelIfNeeded() throws -> MLModel {
        modelLoadLock.lock()
        defer { modelLoadLock.unlock() }

        if let loadError = modelLoadError {
            throw loadError
        }
        if let model = yoloModel {
            return model
        }

        guard let modelURL = Bundle.main.url(
            forResource: "OmniParserYOLO",
            withExtension: "mlpackage"
        ) else {
            let error = LocalUIDetectorError.modelNotFound
            modelLoadError = error
            throw error
        }

        let config = MLModelConfiguration()
        // Allow Neural Engine + GPU for fastest inference on Apple Silicon.
        config.computeUnits = .all

        let model = try MLModel(contentsOf: modelURL, configuration: config)
        yoloModel = model
        print("[LocalUIDetector] OmniParserYOLO model loaded")
        return model
    }

    // MARK: - Detection

    /// Detect all UI elements in the given screenshot image.
    /// Returns an array of bounding boxes with OCR labels in global AppKit coordinates.
    ///
    /// - Parameters:
    ///   - screenshotCGImage: The screenshot to analyze (any resolution — we resize to 640×640 for YOLO).
    ///   - capture: Metadata describing the display this screenshot came from, used for coordinate conversion.
    func detectElements(
        in screenshotCGImage: CGImage,
        capture: CompanionScreenCapture
    ) async throws -> [DetectedElement] {
        let model = try loadModelIfNeeded()

        // Resize screenshot to 640×640 for YOLO input
        guard let resizedImage = resizeCGImage(screenshotCGImage, to: CGSize(width: 640, height: 640)) else {
            throw LocalUIDetectorError.imageResizeFailed
        }

        // Run YOLO CoreML inference
        let yoloBoxes = try runYOLOInference(model: model, inputImage: resizedImage)
        guard !yoloBoxes.isEmpty else { return [] }

        // Convert YOLO relative coordinates to global AppKit coordinates
        let screenshotWidth = CGFloat(screenshotCGImage.width)
        let screenshotHeight = CGFloat(screenshotCGImage.height)
        let globalRects = yoloBoxes.map { box -> (globalRect: CGRect, confidence: Float) in
            let globalRect = yoloBoxToGlobalAppKitRect(
                relativeXCenter: box.xCenter,
                relativeYCenter: box.yCenter,
                relativeWidth: box.width,
                relativeHeight: box.height,
                screenshotWidthInPixels: screenshotWidth,
                screenshotHeightInPixels: screenshotHeight,
                capture: capture
            )
            return (globalRect, box.confidence)
        }

        // Run Apple Vision OCR on each detected bounding box to read its label
        let elementsWithLabels = await extractOCRLabels(
            from: screenshotCGImage,
            boxes: globalRects,
            screenshotWidthInPixels: screenshotWidth,
            screenshotHeightInPixels: screenshotHeight,
            capture: capture
        )

        return elementsWithLabels
    }

    /// Find the best-matching detected element for a given query label.
    ///
    /// - Parameters:
    ///   - queryLabel: The label Gemini emitted (e.g. "Save", "File", "+").
    ///   - screenshotCGImage: The screenshot to analyze.
    ///   - capture: Display metadata for coordinate conversion.
    ///   - proximityAnchorInGlobalScreen: Previous step's resolved point for tie-breaking.
    ///   - minimumMatchScore: Minimum fuzzy match score [0, 1] to accept a result (default 0.4).
    func findBestMatch(
        queryLabel: String,
        in screenshotCGImage: CGImage,
        capture: CompanionScreenCapture,
        proximityAnchorInGlobalScreen: CGPoint? = nil,
        minimumMatchScore: Float = 0.40
    ) async throws -> DetectedElement? {
        let allElements = try await detectElements(in: screenshotCGImage, capture: capture)
        guard !allElements.isEmpty else { return nil }

        // Score each element against the query label
        let scoredElements: [DetectedElement] = allElements.map { element in
            let matchScore = fuzzyLabelMatchScore(query: queryLabel, candidate: element.ocrLabel)
            return DetectedElement(
                globalScreenRect: element.globalScreenRect,
                ocrLabel: element.ocrLabel,
                detectionConfidence: element.detectionConfidence,
                labelMatchScore: matchScore
            )
        }

        // Filter below minimum match score
        let candidateElements = scoredElements.filter { $0.labelMatchScore >= minimumMatchScore }
        guard !candidateElements.isEmpty else {
            print("[LocalUIDetector] ✗ no match above threshold \(minimumMatchScore) for \"\(queryLabel)\"")
            return nil
        }

        // Sort by match score descending, then proximity to anchor if tied
        let sortedCandidates = candidateElements.sorted { lhs, rhs in
            let scoreDiff = lhs.labelMatchScore - rhs.labelMatchScore
            if abs(scoreDiff) > 0.05 {
                return scoreDiff > 0
            }
            // Tie-break: prefer element closer to the proximity anchor
            if let anchor = proximityAnchorInGlobalScreen {
                let lhsDist = hypot(lhs.globalScreenCenter.x - anchor.x, lhs.globalScreenCenter.y - anchor.y)
                let rhsDist = hypot(rhs.globalScreenCenter.x - anchor.x, rhs.globalScreenCenter.y - anchor.y)
                return lhsDist < rhsDist
            }
            return lhs.detectionConfidence > rhs.detectionConfidence
        }

        var best = sortedCandidates.first!

        // When Apple Vision merges several adjacent menu items into one text
        // block (e.g. "File Edit View" for a macOS menu bar), the match score
        // is high (substring hit) but the box center is nowhere near the
        // target item. Narrow the click point to where the matching substring
        // actually sits within the bounding box, using proportional char offsets.
        let queryLower = queryLabel.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let labelLower = best.ocrLabel.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if labelLower != queryLower,
           labelLower.contains(queryLower),
           let range = labelLower.range(of: queryLower) {
            let totalLength = labelLower.count
            if totalLength > 0 {
                let startOffset = labelLower.distance(from: labelLower.startIndex, to: range.lowerBound)
                let endOffset   = labelLower.distance(from: labelLower.startIndex, to: range.upperBound)
                let startFraction = CGFloat(startOffset) / CGFloat(totalLength)
                let endFraction   = CGFloat(endOffset)   / CGFloat(totalLength)
                let fullRect = best.globalScreenRect
                let narrowedX     = fullRect.origin.x + fullRect.width * startFraction
                let narrowedWidth = fullRect.width * (endFraction - startFraction)
                let narrowedRect  = CGRect(x: narrowedX, y: fullRect.origin.y,
                                           width: narrowedWidth, height: fullRect.height)
                best = DetectedElement(
                    globalScreenRect: narrowedRect,
                    ocrLabel: best.ocrLabel,
                    detectionConfidence: best.detectionConfidence,
                    labelMatchScore: best.labelMatchScore
                )
            }
        }

        print("[LocalUIDetector] ✓ matched \"\(queryLabel)\" → \"\(best.ocrLabel)\" score=\(String(format: "%.2f", best.labelMatchScore)) at \(best.globalScreenCenter)")
        return best
    }

    // MARK: - YOLO Inference

    private struct YOLOBox {
        let xCenter: CGFloat  // relative [0, 1]
        let yCenter: CGFloat  // relative [0, 1]
        let width: CGFloat    // relative [0, 1]
        let height: CGFloat   // relative [0, 1]
        let confidence: Float
    }

    private func runYOLOInference(model: MLModel, inputImage: CGImage) throws -> [YOLOBox] {
        guard let pixelBuffer = cgImageToPixelBuffer(inputImage) else {
            throw LocalUIDetectorError.pixelBufferConversionFailed
        }

        // The CoreML model input is named "image" (from the export metadata)
        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: pixelBuffer)
        ])

        let outputFeatures = try model.prediction(from: inputFeatures)

        // Outputs are "confidence" [N × 80] and "coordinates" [N × 4]
        // OmniParser's icon_detect model has only 1 class (UI element),
        // so we use class index 0 confidence.
        guard
            let confidenceArray = outputFeatures.featureValue(for: "confidence")?.multiArrayValue,
            let coordinatesArray = outputFeatures.featureValue(for: "coordinates")?.multiArrayValue
        else {
            throw LocalUIDetectorError.unexpectedModelOutput
        }

        let numberOfDetections = confidenceArray.shape[0].intValue
        var boxes: [YOLOBox] = []

        for detectionIndex in 0..<numberOfDetections {
            // confidence array shape: [N, numClasses] — we use class 0
            let confidence = confidenceArray[[detectionIndex, 0] as [NSNumber]].floatValue
            guard confidence > 0.0 else { continue }

            // coordinates array shape: [N, 4] — [x_center, y_center, width, height] relative
            let xCenter = CGFloat(coordinatesArray[[detectionIndex, 0] as [NSNumber]].floatValue)
            let yCenter = CGFloat(coordinatesArray[[detectionIndex, 1] as [NSNumber]].floatValue)
            let width   = CGFloat(coordinatesArray[[detectionIndex, 2] as [NSNumber]].floatValue)
            let height  = CGFloat(coordinatesArray[[detectionIndex, 3] as [NSNumber]].floatValue)

            boxes.append(YOLOBox(
                xCenter: xCenter,
                yCenter: yCenter,
                width: width,
                height: height,
                confidence: confidence
            ))
        }

        return boxes
    }

    // MARK: - OCR

    /// Run Apple Vision OCR on each YOLO bounding box region of the screenshot.
    /// Returns DetectedElement structs with OCR text (empty string for icon-only elements).
    private func extractOCRLabels(
        from screenshotCGImage: CGImage,
        boxes: [(globalRect: CGRect, confidence: Float)],
        screenshotWidthInPixels: CGFloat,
        screenshotHeightInPixels: CGFloat,
        capture: CompanionScreenCapture
    ) async -> [DetectedElement] {
        var results: [DetectedElement] = []

        for (globalRect, confidence) in boxes {
            // Convert the global AppKit rect back to screenshot pixel coordinates
            // so we can crop the CGImage for OCR
            let cropRect = globalAppKitRectToScreenshotPixelRect(
                globalRect,
                screenshotWidthInPixels: screenshotWidthInPixels,
                screenshotHeightInPixels: screenshotHeightInPixels,
                capture: capture
            )

            // Expand crop region slightly to include any surrounding text
            let expandedCropRect = cropRect.insetBy(dx: -4, dy: -4)
            let clampedCropRect = expandedCropRect.intersection(CGRect(
                x: 0, y: 0,
                width: screenshotWidthInPixels,
                height: screenshotHeightInPixels
            ))

            let ocrText = await runVisionOCR(on: screenshotCGImage, cropRegion: clampedCropRect)

            results.append(DetectedElement(
                globalScreenRect: globalRect,
                ocrLabel: ocrText,
                detectionConfidence: confidence,
                labelMatchScore: 0.0  // populated later by findBestMatch
            ))
        }

        return results
    }

    /// Run Apple Vision text recognition on a cropped region of an image.
    private func runVisionOCR(on image: CGImage, cropRegion: CGRect) async -> String {
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation]
                else {
                    continuation.resume(returning: "")
                    return
                }
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .fast  // fast is sufficient for single UI labels
            request.usesLanguageCorrection = false

            // Crop to the YOLO box region (Vision uses normalized [0,1] coordinates)
            guard let croppedImage = image.cropping(to: cropRegion) else {
                continuation.resume(returning: "")
                return
            }

            let handler = VNImageRequestHandler(cgImage: croppedImage, options: [:])
            try? handler.perform([request])
        }
    }

    // MARK: - Fuzzy Label Matching

    /// Score how well a candidate OCR label matches the query label.
    /// Returns a float in [0, 1]: 1.0 = exact match, 0.0 = no overlap.
    ///
    /// Uses a combination of:
    ///   - Case-insensitive exact match (1.0)
    ///   - Contains check (0.85)
    ///   - Token overlap ratio (Jaccard similarity on word tokens)
    ///   - Character-level overlap for short labels (handles icons like "+", "✕")
    private func fuzzyLabelMatchScore(query: String, candidate: String) -> Float {
        guard !candidate.isEmpty else { return 0.0 }

        let normalizedQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCandidate = candidate.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Exact match
        if normalizedQuery == normalizedCandidate { return 1.0 }

        // Substring containment
        if normalizedCandidate.contains(normalizedQuery) || normalizedQuery.contains(normalizedCandidate) {
            return 0.85
        }

        // Token Jaccard similarity
        let queryTokens = Set(normalizedQuery.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
        let candidateTokens = Set(normalizedCandidate.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
        if !queryTokens.isEmpty && !candidateTokens.isEmpty {
            let intersection = Float(queryTokens.intersection(candidateTokens).count)
            let union = Float(queryTokens.union(candidateTokens).count)
            let jaccard = intersection / union
            if jaccard > 0.0 { return min(0.80, jaccard) }
        }

        // Character-level overlap for short single-character labels ("+", "×", etc.)
        if normalizedQuery.count <= 2 && normalizedCandidate.count <= 3 {
            if normalizedCandidate.contains(normalizedQuery) { return 0.75 }
        }

        return 0.0
    }

    // MARK: - Coordinate Conversion

    /// Convert YOLO relative xywh (center-based, relative to 640×640 input)
    /// to a global AppKit CGRect, going through screenshot pixel space.
    private func yoloBoxToGlobalAppKitRect(
        relativeXCenter: CGFloat,
        relativeYCenter: CGFloat,
        relativeWidth: CGFloat,
        relativeHeight: CGFloat,
        screenshotWidthInPixels: CGFloat,
        screenshotHeightInPixels: CGFloat,
        capture: CompanionScreenCapture
    ) -> CGRect {
        // Step 1: Convert from YOLO's 640×640 space to screenshot pixel space
        let pixelXCenter = relativeXCenter * screenshotWidthInPixels
        let pixelYCenter = relativeYCenter * screenshotHeightInPixels
        let pixelWidth   = relativeWidth   * screenshotWidthInPixels
        let pixelHeight  = relativeHeight  * screenshotHeightInPixels

        // Step 2: Convert screenshot pixels to display points
        let displayWidth  = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let scaleX = displayWidth  / screenshotWidthInPixels
        let scaleY = displayHeight / screenshotHeightInPixels

        let displayXCenter = pixelXCenter * scaleX
        let displayYCenter = pixelYCenter * scaleY
        let displayWidth_box = pixelWidth  * scaleX
        let displayHeight_box = pixelHeight * scaleY

        // Step 3: Convert from display-local coordinates (top-left origin)
        // to global AppKit coordinates (bottom-left origin, multi-display)
        let displayFrame = capture.displayFrame
        let appKitYCenter = displayHeight - displayYCenter
        let globalXCenter = displayXCenter + displayFrame.origin.x
        let globalYCenter = appKitYCenter  + displayFrame.origin.y

        return CGRect(
            x: globalXCenter - displayWidth_box / 2,
            y: globalYCenter - displayHeight_box / 2,
            width: displayWidth_box,
            height: displayHeight_box
        )
    }

    /// Convert a global AppKit CGRect back to screenshot pixel coordinates (top-left origin).
    /// Used to crop the CGImage for OCR.
    private func globalAppKitRectToScreenshotPixelRect(
        _ globalRect: CGRect,
        screenshotWidthInPixels: CGFloat,
        screenshotHeightInPixels: CGFloat,
        capture: CompanionScreenCapture
    ) -> CGRect {
        let displayWidth  = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let displayFrame  = capture.displayFrame
        let scaleX = screenshotWidthInPixels  / displayWidth
        let scaleY = screenshotHeightInPixels / displayHeight

        // Remove display origin offset, flip Y from AppKit to top-left origin
        let displayLocalX = globalRect.origin.x - displayFrame.origin.x
        let displayLocalY = globalRect.origin.y - displayFrame.origin.y
        let topLeftY = displayHeight - (displayLocalY + globalRect.height)

        return CGRect(
            x: displayLocalX * scaleX,
            y: topLeftY * scaleY,
            width: globalRect.width  * scaleX,
            height: globalRect.height * scaleY
        )
    }

    // MARK: - Image Utilities

    private func resizeCGImage(_ image: CGImage, to targetSize: CGSize) -> CGImage? {
        let context = CGContext(
            data: nil,
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        context?.draw(image, in: CGRect(origin: .zero, size: targetSize))
        return context?.makeImage()
    }

    private func cgImageToPixelBuffer(_ image: CGImage) -> CVPixelBuffer? {
        let width  = image.width
        let height = image.height
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pixelBuffer)
        guard let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    // MARK: - Errors

    enum LocalUIDetectorError: Error {
        case modelNotFound
        case imageResizeFailed
        case pixelBufferConversionFailed
        case unexpectedModelOutput
    }
}

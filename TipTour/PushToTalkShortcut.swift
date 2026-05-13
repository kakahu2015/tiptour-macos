//
//  PushToTalkShortcut.swift
//  TipTour
//
//  Encodes the single shortcut TipTour listens for (control + option) and
//  translates raw CGEvents into press/release transitions for
//  GlobalPushToTalkShortcutMonitor.
//

import AppKit
import CoreGraphics

enum PushToTalkShortcut {
    enum ShortcutTransition {
        case pressed
        case released
        case escapePressed
        case none
    }

    /// macOS virtual key code for the Escape key.
    static let escapeKeyCode: UInt16 = 53

    static func shortcutTransition(
        for eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard eventType == .flagsChanged else { return .none }

        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
        let isControlOptionHeld = modifierFlags.contains(.control)
            && modifierFlags.contains(.option)
            && !modifierFlags.contains(.command)
            && !modifierFlags.contains(.shift)

        if isControlOptionHeld && !wasShortcutPreviouslyPressed {
            return .pressed
        }
        if !isControlOptionHeld && wasShortcutPreviouslyPressed {
            return .released
        }
        return .none
    }
}

import AppKit
import SwiftUI

/// Short, non-bouncing updates, shared by data publication and visible controls.
enum AppMotion {
    static let content = Animation.easeInOut(duration: 0.22)
    static let curve = Animation.easeInOut(duration: 0.4)
    static let list = Animation.easeInOut(duration: 0.32)
    static let notification = Animation.easeOut(duration: 0.24)

    @MainActor static func update(_ changes: () -> Void) {
        update(using: content, changes)
    }

    @MainActor static func update(using animation: Animation, _ changes: () -> Void) {
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : animation, changes)
    }
}

private struct SmoothUpdates<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : AppMotion.content, value: value)
    }
}

extension View {
    func smoothUpdates<Value: Equatable>(value: Value) -> some View { modifier(SmoothUpdates(value: value)) }
}

import Foundation

/// No periodic work when the panel is closed and there are no enabled custom levels.
enum ResourcePolicy {
    static func needsPolling(panelVisible: Bool, enabled: Bool, levels: [String: Float], sleeping: Bool, testing: Bool) -> Bool {
        !sleeping && !testing && (panelVisible || (enabled && levels.values.contains { $0 < 0.999 }))
    }
}

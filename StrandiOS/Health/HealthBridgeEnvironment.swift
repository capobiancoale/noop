#if os(iOS)
import SwiftUI

// MARK: - The Apple Health bridge, for screens that only read through it
//
// Today's and a WOD's glucose charts read Apple Health through the bridge (glucose, carbs and insulin around a
// time) but show nothing of its own state. As an environment object the bridge would redraw them on every
// change of that state (a sync starting and ending, what it wrote, a status line); as a plain environment value
// it reaches them without being observed. Screens that do show the bridge's state (the Apple Health screen, the
// import banner) keep observing it as an environment object.

private struct HealthBridgeKey: EnvironmentKey {
    static var defaultValue: HealthKitBridge? { nil }
}

extension EnvironmentValues {
    /// The Apple Health bridge, not observed (nil where none was set).
    var healthBridge: HealthKitBridge? {
        get { self[HealthBridgeKey.self] }
        set { self[HealthBridgeKey.self] = newValue }
    }
}
#endif

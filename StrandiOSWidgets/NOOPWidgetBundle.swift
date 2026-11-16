import WidgetKit
import SwiftUI

/// The widget extension entry point. Bundles the Charge widget, the Today's plan widget and the live-HR Live Activity.
@main
struct NOOPWidgetBundle: WidgetBundle {
    var body: some Widget {
        NOOPWidget()
        NOOPPlanWidget()
        NOOPLiveActivity()
    }
}

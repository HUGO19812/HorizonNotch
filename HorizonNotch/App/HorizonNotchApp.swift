import SwiftUI

@main
struct HorizonNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Windows are managed in AppKit (AppDelegate); SwiftUI needs at
        // least one scene.
        Settings { EmptyView() }
    }
}

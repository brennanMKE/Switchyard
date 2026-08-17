// SwitchyardApp.swift

import SwiftUI
import YardUI

@main
struct SwitchyardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

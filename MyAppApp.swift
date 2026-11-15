// MyAppApp.swift — replace the contents of your existing @main App file with this.
// Keep the struct name Xcode generated if it is different (e.g. Untitled_Project_2App).
import SwiftUI

@main
struct MyAppApp: App {
    // Registers HealthKit background delivery at every launch (also when iOS launches ASTRA in the background).
    @UIApplicationDelegateAdaptor(ASTRAAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

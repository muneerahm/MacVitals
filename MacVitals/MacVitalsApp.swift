//
//  MacVitalsApp.swift
//  MacVitals
//
//  Menu-bar-only app (LSUIElement = YES in build settings → no Dock icon).
//

import SwiftUI

@main
struct MacVitalsApp: App {
    @NSApplicationDelegateAdaptor(MacVitalsAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

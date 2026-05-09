//
//  UniClipboardApp.swift
//  UniClipboard
//
//  Created by mark on 2026/5/9.
//

import SwiftUI

@main
struct UniClipboardApp: App {
    @State private var vm = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(vm: vm)
        }
    }
}

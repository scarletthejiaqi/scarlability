//
//  scarlabilityApp.swift
//  scarlability
//
//  Created by Scarlett on 10/9/26.
//

import SwiftUI

@main
struct scarlabilityApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            // Handed down explicitly rather than through the environment: on the Mac (macOS 15's
            // SwiftUI), views reading an @Observable object from the environment crashed.
            RootView(model: model)
        }
        .commands {
            NoteCommands(model: model)
        }
    }
}

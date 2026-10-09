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
            RootView()
                .environment(model)
        }
    }
}

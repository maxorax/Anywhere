//
//  TurnApp.swift
//  Turn
//
//  Created by NodePassProject on 1/23/26.
//

import SwiftUI

@main
struct TurnApp: App {
    init() {
        CloudBlobSync.start()
        WatchSessionManager.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

//
//  GPXPointViewerApp.swift
//  GPXPointViewer
//

import SwiftUI

@main
struct GPXPointViewerApp: App {
    var body: some Scene {
        WindowGroup("GPX 点位查看器") {
            ContentView()
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1320, height: 860)
    }
}

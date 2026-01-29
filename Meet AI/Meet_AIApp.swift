//
//  Meet_AIApp.swift
//  Meet AI
//
//  Created by Meet Ramatri on 7/13/25.
//

import SwiftUI

@main
struct Meet_AIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

//import SwiftUI
//
//@main
//struct Meet_AIApp: App {
//    // 💡 Add this line to use the custom manager
//    @NSApplicationDelegateAdaptor(AppLifecycleManager.self) var appDelegate
//    
//    var body: some Scene {
//        WindowGroup {
//            ContentView()
//        }
//        // This is necessary to keep the window open when it loses focus,
//        // though the AppLifecycleManager is the main fix.
//        .windowResizability(.contentSize)
//    }
//}

// NOTE: The AppLifecycleManager class must be defined outside the App struct.
// It is already included in the previous code block.

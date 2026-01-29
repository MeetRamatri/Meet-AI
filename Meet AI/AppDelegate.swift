//
//  AppDelegate.swift
//  Meet AI
//
//  Created by Meet Ramatri on 7/13/25.
//

import Foundation
import Cocoa
import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: FloatingWindow!
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView()
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 300, height: 400)

        // MARK: - Floating Window
        window = FloatingWindow(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.sharingType = .none
        window.hasShadow = false
        window.contentView = hostingView
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .mainMenu // <- CRUCIAL for fullscreen floating
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]
        window.isMovableByWindowBackground = true
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)

        // MARK: - Menu Bar Icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        NSApp.activate(ignoringOtherApps: true)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Meet AI")
            button.action = #selector(toggleWindow)
            button.target = self
        }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) &&
                event.modifierFlags.contains(.shift) &&
                event.charactersIgnoringModifiers == "m" {
                self.toggleWindow()
            }
        }
    }

    @objc func toggleWindow() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

import AppKit
import BridgeCore
import ServiceManagement
import Sparkle
import SwiftUI

@main
struct MouseBridgeApp: App {
    @NSApplicationDelegateAdaptor private var app: AppDelegate

    var body: some Scene {
        MenuBarExtra("MouseBridge", systemImage: "display.2") {
            MenuView(monitors: app.monitors, tap: app.tap, updater: app.updater.updater)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitors = Monitors()
    let tap = EventTap()
    /// Sparkle checks the appcast hourly (SUScheduledCheckInterval) and shows its update popup.
    let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        tap.onBrightnessKey = { [monitors] up, fine in monitors.step(up: up, fine: fine) }
        Task { await monitors.reload() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [self] _ in
            MainActor.assumeIsolated {
                tap.rebuildLayout()
                Task { await monitors.reload() }
            }
        }
        if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) || !tap.start() {
            pollForAccessibility()
        }
    }

    func applicationWillTerminate(_ notification: Notification) { Gamma.restore() }

    /// The tap starts once Accessibility is granted. macOS sometimes only honors a new grant after a relaunch,
    /// which the menu offers while the tap is not running.
    private func pollForAccessibility() {
        Task {
            while !tap.start() { try? await Task.sleep(for: .seconds(2)) }
        }
    }
}

struct MenuView: View {
    let monitors: Monitors
    @Bindable var tap: EventTap
    let updater: SPUUpdater
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(monitors.all) { MonitorControls(monitor: $0) }
            Divider()
            if !tap.running {
                Text("Needs Accessibility permission").foregroundStyle(.secondary)
                HStack {
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    Button("Relaunch", action: relaunch)
                }
            }
            Toggle("Cursor bridge", isOn: $tap.bridgeEnabled)
            if tap.bridgeEnabled {
                Picker("Level", selection: $tap.alignment) {
                    ForEach(Alignment.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                }
                .pickerStyle(.segmented)
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            Divider()
            HStack {
                Button("Check for Updates") { updater.checkForUpdates() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .toggleStyle(.switch)
        .padding(14)
        .frame(width: 280)
        .onAppear { monitors.refreshHDR() }
    }

    private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(Bundle.main.bundlePath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

private struct MonitorControls: View {
    let monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(monitor.name).font(.headline)
            HStack {
                Image(systemName: "sun.max").frame(width: 18)
                Slider(value: Binding(get: { monitor.brightness }, set: { monitor.setBrightness($0) }))
            }
            if let volume = monitor.volume {
                HStack {
                    Image(systemName: "speaker.wave.2").frame(width: 18)
                    Slider(value: Binding(get: { volume }, set: { monitor.setVolume($0) }))
                }
            }
            if monitor.hdrSupported {
                Toggle("HDR", isOn: Binding(get: { monitor.hdr }, set: { monitor.setHDR($0) }))
            }
        }
    }
}

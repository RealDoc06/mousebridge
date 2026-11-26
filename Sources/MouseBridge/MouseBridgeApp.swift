import AppKit
import ServiceManagement
import Sparkle
import SwiftUI

@main
struct MouseBridgeApp: App {
    @NSApplicationDelegateAdaptor private var app: AppDelegate

    var body: some Scene {
        MenuBarExtra("MouseBridge", systemImage: "display.2") {
            MenuView(monitors: app.monitors, desk: app.desk, tap: app.tap, updater: app.updater.updater)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitors = Monitors()
    let desk = Desk()
    let tap = EventTap()
    /// Sparkle checks the appcast hourly (SUScheduledCheckInterval) and shows its update popup.
    let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        tap.onBrightnessKey = { [monitors] up, fine in monitors.step(up: up, fine: fine) }
        desk.onChange = { [tap] in tap.displays = $0 }
        desk.reload()
        Task { await monitors.reload() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [self] _ in
            MainActor.assumeIsolated {
                desk.reload()
                Shade.refit()
                // Again once settled too: a reconnected monitor's framebuffer details can lag the first notification.
                Task {
                    await monitors.reload(settle: .seconds(1))
                    desk.reload()
                }
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
    let desk: Desk
    @Bindable var tap: EventTap
    let updater: SPUUpdater
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if desk.row.count + desk.stacked.count > 1 {
                ArrangementView(
                    desk: desk,
                    names: Dictionary(monitors.all.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }),
                    width: Self.width - 2 * (Theme.padding + Theme.cardPadding)
                )
            }
            ForEach(monitors.all) { MonitorControls(monitor: $0) }
            Panel {
                Text("Settings")
            } content: {
                if !tap.running {
                    Text("Needs Accessibility permission").foregroundStyle(.orange)
                    HStack {
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        Button("Relaunch", action: relaunch)
                    }
                    .controlSize(.small)
                }
                ToggleRow(label: "Cursor bridge", isOn: $tap.bridgeEnabled)
                ToggleRow(label: "Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
            }
            HStack {
                Text("MouseBridge \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                    Divider()
                    Button("Quit MouseBridge") { NSApp.terminate(nil) }
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.1), in: .circle)
                        .contentShape(.circle)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.leading, 2)
        }
        .padding(Theme.padding)
        .frame(width: Self.width)
        .background(Theme.window)
        .environment(\.colorScheme, .dark)
        .background { GeometryReader { FitWindow(height: $0.size.height) } }
        .onAppear { monitors.refreshHDR() }
    }

    private static let width: CGFloat = 300

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
    /// The name being typed, non-nil while renaming.
    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        Panel {
            if let draft {
                TextField(monitor.defaultName, text: Binding(get: { draft }, set: { self.draft = $0 }))
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onAppear { focused = true }
                    .onSubmit(commit)
                    .onExitCommand { self.draft = nil }
                Button("Save", systemImage: "checkmark", action: commit)
                    .help("Save")
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
            } else {
                Text(monitor.name).lineLimit(1).help(monitor.name)
                Spacer()
                Group {
                    if !monitor.customName.isEmpty {
                        Button("Reset name", systemImage: "arrow.counterclockwise") { monitor.customName = "" }
                            .help("Reset to \(monitor.defaultName)")
                    }
                    Button("Rename", systemImage: "pencil") { draft = monitor.customName }.help("Rename")
                }
                .fontWeight(.regular)
                .foregroundStyle(.secondary)
            }
        } content: {
            HStack {
                // The display's own name, shown once it's renamed.
                if !monitor.customName.isEmpty {
                    Text(monitor.defaultName).font(.callout.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                switch monitor.dimming {
                case .ddc: Tag(text: "DDC").help("Brightness set on the display over DDC/CI")
                case .gamma: Tag(text: "Software").help("Brightness dimmed in software")
                case .shade: Tag(text: "Overlay").help("Dimmed with an overlay. The device's own backlight is set on the device.")
                }
            }
            LevelRow(label: "Brightness", value: monitor.brightness, set: monitor.setBrightness)
            if let volume = monitor.volume {
                LevelRow(label: "Volume", value: volume, set: monitor.setVolume)
            }
            if monitor.hdrSupported {
                ToggleRow(label: "HDR", isOn: Binding(get: { monitor.hdr }, set: { monitor.setHDR($0) }))
            }
        }
    }

    /// Saves the typed name. An empty name falls back to the display's own.
    private func commit() {
        monitor.customName = draft?.trimmingCharacters(in: .whitespaces) ?? monitor.customName
        draft = nil
    }
}

/// MenuBarExtra windows grow with their content but never shrink (seen on macOS 27): the smaller content is
/// centered in the old frame, so the popup drops away from the menu bar and leaves a stale frame behind.
/// Placed as a background, this sizes the window to the content's `height`, keeping its top edge. It also gives
/// the window the menu's dark appearance and rounder corners.
private struct FitWindow: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> FitView { FitView() }
    func updateNSView(_ view: FitView, context: Context) {
        view.height = height
        // Resizing the window inside SwiftUI's update pass could re-enter layout, so it waits a turn.
        DispatchQueue.main.async { view.fit() }
    }

    final class FitView: NSView {
        var height: CGFloat = 0

        override func viewDidMoveToWindow() {
            fit()
            // Dark like the content, so the window border, menus and tooltips match in light mode too.
            window?.appearance = NSAppearance(named: .darkAqua)
            // AppKit's private corner radius, which the window's mask and shadow both follow. KVC reaches
            // `_setCornerRadius:`; the check keeps a macOS without it on the default corners.
            guard let window, window.responds(to: NSSelectorFromString("_setCornerRadius:")) else { return }
            window.setValue(Theme.windowRadius, forKey: "cornerRadius")
        }

        func fit() {
            guard let window, height > 0 else { return }
            let frame = window.frame
            let fitted = window.frameRect(forContentRect: CGRect(x: 0, y: 0, width: frame.width, height: height)).height
            guard abs(frame.height - fitted) > 0.5 else { return }
            window.setFrame(CGRect(x: frame.minX, y: frame.maxY - fitted, width: frame.width, height: fitted), display: true)
        }
    }
}

import AppKit
import SwiftUI

@main
struct BiliMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppModel.shared

    var body: some Scene {
        WindowGroup("BiliMac", id: "main") {
            RootView()
                .environmentObject(app)
                .tint(Theme.pink)
                .task { await app.start() }
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button(L("设置…")) { app.go(.settings) }.keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button(L("搜索")) {
                    SearchNSTextField.focusRequested = true
                    let w = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
                    if let w, let f = w.contentView?.firstDescendant(of: SearchNSTextField.self) {
                        NSApp.activate(ignoringOtherApps: true)
                        w.makeKeyAndOrderFront(nil)
                        w.makeFirstResponder(f)
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button(L("后退")) { app.goBack() }.keyboardShortcut("[", modifiers: .command)
                Button(L("前进")) { app.goForward() }.keyboardShortcut("]", modifiers: .command)
            }
            CommandMenu(L("播放")) {
                Button(L("播放 / 暂停")) { app.nowPlaying?.togglePlay() }
                Button(L("下一个")) { app.playNext() }
                Button(L("上一个")) { app.playPrevious() }
                Divider()
                Button(L("切换弹幕")) { AppSettings.shared.danmakuOn.toggle() }
                Button(L("切换统计信息")) { AppSettings.shared.showStats.toggle() }
                Button(L("应用内全屏")) { app.toggleAppFull() }
                Button(L("屏幕全屏")) { app.toggleScreenFull() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        do { try HLSProxy.shared.start() } catch { log("proxy start failed: \(error)") }
        NSApp.setActivationPolicy(.regular)
        MainActor.assumeIsolated { AppSettings.shared.appearance.apply() }
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated { InputRouter.shared.install() }
        MainActor.assumeIsolated { HangRecorder.start() }
        if let size = Env.windowSize {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let w = NSApp.windows.first(where: { $0.canBecomeMain }) { w.setContentSize(size); w.center() }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for v in subviews {
            if let t = v as? T { return t }
            if let t = v.firstDescendant(of: type) { return t }
        }
        return nil
    }
}

import AndcintoshPlatform
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var runtime: MacRuntime?
    private var terminating = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating, let runtime else { return .terminateNow }
        terminating = true
        Task { await runtime.stop(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct AndcintoshApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var runtime: MacRuntime?
    @State private var startupError: String?
    init() {
        do { _runtime = State(initialValue: try MacRuntime()) }
        catch { _startupError = State(initialValue: Copy.failure(error)) }
    }
    var body: some Scene {
        Window("Andcintosh", id: "main") {
            Group {
                if let runtime { MainView(runtime: runtime) }
                else { ContentUnavailableView("无法启动", systemImage: "exclamationmark.triangle", description: Text(startupError ?? "请重新打开应用。")) }
            }
            .onAppear { delegate.runtime = runtime }
        }
        .defaultSize(width: 640, height: 720)
        MenuBarExtra("Andcintosh", systemImage: "arrow.triangle.2.circlepath") {
            RuntimeMenu(runtime: runtime)
        }
    }
}

private struct RuntimeMenu: View {
    var runtime: MacRuntime?
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if let runtime {
            Text(runtime.connected.isEmpty ? "未连接" : "已连接 \(runtime.connected.count) 台设备")
        }
        Button("打开 Andcintosh") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        if let runtime, runtime.running {
            Button("停止") { Task { await runtime.stop() } }
        }
        Divider()
        Button("退出 Andcintosh") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

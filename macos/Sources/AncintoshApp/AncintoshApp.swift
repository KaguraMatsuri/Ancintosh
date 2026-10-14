import AncintoshCore
import AncintoshPlatform
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
        Task { await runtime.dispose(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct AncintoshApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var runtime: MacRuntime?
    @State private var startupError: String?
    @State private var switchingMode = false
    @State private var sceneGeneration = UUID()
    #if DEBUG
    @State private var demoMode = false
    #endif
    init() {
        do {
            #if DEBUG
            let demonstration = ProcessInfo.processInfo.arguments.contains("--demo-topology")
            _demoMode = State(initialValue: demonstration)
            _runtime = State(initialValue: try demonstration ? TopologyDemo.makeRuntime() : MacRuntime())
            #else
            _runtime = State(initialValue: try MacRuntime())
            #endif
        } catch { _startupError = State(initialValue: Copy.failure(error)) }
    }
    var body: some Scene {
        Window("Ancintosh", id: "main") {
            Group {
                if let runtime { MainView(runtime: runtime).id(sceneGeneration) }
                else { ContentUnavailableView("无法启动", systemImage: "exclamationmark.triangle", description: Text(startupError ?? "请重新打开应用。")) }
            }
            .disabled(switchingMode)
            .onAppear { delegate.runtime = runtime }
            #if DEBUG
            .toolbar {
                Picker("Ancintosh", selection: $demoMode) {
                    Text("普通模式").tag(false)
                    Text("演示模式").tag(true)
                }.pickerStyle(.segmented).labelsHidden().disabled(switchingMode)
            }
            .onChange(of: demoMode) { _, mode in
                switchingMode = true
                Task {
                    await runtime?.dispose()
                    do { runtime = try mode ? TopologyDemo.makeRuntime() : MacRuntime(); startupError = nil }
                    catch { runtime = nil; startupError = Copy.failure(error) }
                    delegate.runtime = runtime; sceneGeneration = UUID(); switchingMode = false
                }
            }
            #endif
        }
        .defaultSize(width: 1100, height: 760)
        .defaultLaunchBehavior(.presented)
        MenuBarExtra("Ancintosh", systemImage: "arrow.triangle.2.circlepath") {
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
            ForEach(runtime.configuration.peers) { profile in
                Section(profile.name ?? profile.id.uuidString) {
                    if let peer = profile.identity, runtime.connected.contains(peer) {
                        Text("已连接")
                        Text(runtime.switching.contains(peer) ? "切换中" : (runtime.routes[peer] == .tcp ? "局域网传输" : "蓝牙传输"))
                        Text("AES-256-GCM · 前向保密")
                    } else { Text("未连接") }
                    if let failure = runtime.failures[profile.id] ?? profile.identity.flatMap({ runtime.failures[$0] }) {
                        Text(Copy.failure(failure))
                    }
                }
            }
        }
        Button("打开 Ancintosh") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        if let runtime, runtime.running {
            Button("停止") { Task { await runtime.stop() } }
        }
        Divider()
        Button("退出 Ancintosh") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

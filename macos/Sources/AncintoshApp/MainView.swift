import AncintoshCore
import AncintoshPlatform
import AppKit
import SwiftUI

struct MainView: View {
    var runtime: MacRuntime
    @State private var dividerReady = false
    @State private var editing: PeerProfile?
    @State private var editingMac = false
    @State private var macNameDraft = ""
    @State private var macNameError: String?
    @State private var error: String?
    @State private var operations = ViewOperations()

    var body: some View {
        HSplitView {
            SettingsView(runtime: runtime, operations: operations, editing: $editing, error: $error)
                .frame(minWidth: dividerReady ? 280 : 320, idealWidth: 320,
                    maxWidth: dividerReady ? 420 : 320, maxHeight: .infinity)
            TopologyPane(runtime: runtime, operations: operations, editing: $editing, error: $error,
                editMac: { macNameDraft = runtime.configuration.name; macNameError = nil; editingMac = true })
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            runtime.refreshPermissions()
            if runtime.isDemonstration { runtime.start() }
            // Seed the native divider once before allowing the full drag range.
            DispatchQueue.main.async { dividerReady = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in runtime.refreshPermissions() }
        .sheet(isPresented: $editingMac) {
            VStack {
                Form {
                    TextField("设备名称", text: $macNameDraft)
                    if let macNameError { Text(macNameError) }
                }.formStyle(.grouped)
                HStack {
                    Button("取消", role: .cancel) { editingMac = false }.keyboardShortcut(.cancelAction)
                    Button("保存") {
                        do { try runtime.renameMac(macNameDraft); editingMac = false }
                        catch { macNameError = Copy.failure(error) }
                    }.keyboardShortcut(.defaultAction)
                }.padding()
            }.frame(idealWidth: 400, idealHeight: 180)
        }
        .sheet(item: $editing) { profile in PeerEditor(profile: profile, runtime: runtime) }
        .alert("操作未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("确定", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}

private struct SettingsView: View {
    var runtime: MacRuntime
    let operations: ViewOperations
    @Binding var editing: PeerProfile?
    @Binding var error: String?

    var body: some View {
        Form {
            ConnectionSettings(runtime: runtime, operations: operations, error: $error, editing: $editing)
            TransferSettings(runtime: runtime, operations: operations, error: $error)
            NotificationSettings(runtime: runtime, operations: operations, error: $error)
            #if DEBUG
            if runtime.isDemonstration { DemonstrationSettings(runtime: runtime) }
            #endif
            FileTransferSettings(runtime: runtime, operations: operations, error: $error)
            LockSettings(runtime: runtime, operations: operations, error: $error)
            ClipboardPermissions(runtime: runtime)
            RuntimeFailure(runtime: runtime)
        }
        .formStyle(.grouped)
    }
}

private struct ConnectionSettings: View {
    var runtime: MacRuntime
    let operations: ViewOperations
    @Binding var error: String?
    @Binding var editing: PeerProfile?

    var body: some View {
        Section("连接") {
            LabeledContent("状态", value: runtime.connected.isEmpty ? (runtime.running ? "等待连接" : "已停止") : "已连接")
            HStack {
                Button("查找设备") { runtime.scan() }.disabled(operations.busy([.lifecycle])).accessibilityLabel("查找设备")
                if runtime.running { Button("停止") { perform(operations, scopes: [.lifecycle], error: $error) { await runtime.stop() } }.disabled(operations.busy([.lifecycle])) }
            }
            ForEach(runtime.discovered.values.sorted { $0.identifier.uuidString < $1.identifier.uuidString }, id: \.identifier) { device in
                if !runtime.configuration.peers.contains(where: { $0.id == device.identifier }) {
                    LabeledContent(device.name ?? device.identifier.uuidString) {
                        Button("配置") { editing = PeerProfile(id: device.identifier, name: device.name) }.disabled(operations.busy([.peer(device.identifier)]))
                    }
                }
            }
            if runtime.configuration.peers.isEmpty && runtime.discovered.isEmpty {
                Text("先在 Android 中保存密钥并启动，再查找设备。").foregroundStyle(.secondary)
            }
        }
    }
}

private struct TransferSettings: View {
    var runtime: MacRuntime
    let operations: ViewOperations
    @Binding var error: String?
    @State private var selected: UUID?

    var body: some View {
        Section("传输") {
            Toggle("wifi传输", isOn: Binding(get: { runtime.configuration.wifi }, set: { enabled in perform(operations, scopes: [.wifi], error: $error) { await runtime.wifi(enabled) } }))
                .disabled(operations.busy([.wifi]))
            if !runtime.configuration.wifi { Text(Copy.bluetoothVisibility).foregroundStyle(.secondary) }
            Picker("接收设备", selection: $selected) {
                Text("选择 Android").tag(Optional<UUID>.none)
                ForEach(runtime.configuration.peers) { profile in
                    if let identity = profile.identity { Text(profile.name ?? identity.uuidString).tag(Optional(identity)) }
                }
            }
            #if DEBUG
            if runtime.isDemonstration {
                HStack {
                    Button("验证") { if let selected { perform(operations, scopes: testScopes, error: $error) { try await runtime.verify(selected) } } }
                    Menu("测试") {
                        ForEach(DemonstrationTest.allCases, id: \.self) { test in
                            Button(test.rawValue) {
                                guard let selected else { return }
                                if test == .file { chooseFiles() }
                                else { runTest(test, peer: selected) }
                            }
                        }
                    }
                }.disabled(selected == nil || operations.busy(testScopes) || runtime.isTesting)
            }
            #endif
            Button(runtime.preparing ? "准备文件中…" : "发送文件") { chooseFiles() }
                .disabled(operations.busy(fileScopes) || runtime.preparing || selected.map { !runtime.connected.contains($0) } != false)
                .accessibilityLabel(runtime.preparing ? "准备文件中…" : "发送文件")
            Text("接收文件保存到下载目录中的 Ancintosh 文件夹。").foregroundStyle(.secondary)
        }
    }
    private var peerScope: ViewOperations.Scope? {
        selected.map { identity in
            .peer(runtime.configuration.peers.first(where: { $0.identity == identity })?.id ?? identity)
        }
    }
    private var fileScopes: Set<ViewOperations.Scope> {
        var scopes: Set<ViewOperations.Scope> = [.files]
        if let peerScope { scopes.insert(peerScope) }
        if runtime.isDemonstration { scopes.insert(.demonstration) }
        return scopes
    }
    #if DEBUG
    private var testScopes: Set<ViewOperations.Scope> {
        var scopes: Set<ViewOperations.Scope> = [.demonstration]
        if let peerScope { scopes.insert(peerScope) }
        return scopes
    }
    private func runTest(_ test: DemonstrationTest, peer: UUID) {
        var scopes = testScopes
        if test == .lock { scopes.insert(.lock) }
        perform(operations, scopes: scopes, error: $error) { try await runtime.test(test, peer: peer) }
    }
    #endif
    private func chooseFiles() {
        guard let selected else { return }
        let scopes = fileScopes
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.prompt = "发送文件"
        panel.begin { result in
            if result == .OK { perform(operations, scopes: scopes, error: $error) { try await runtime.files(panel.urls, peer: selected) } }
        }
    }
}

private struct NotificationSettings: View {
    var runtime: MacRuntime
    let operations: ViewOperations
    @Binding var error: String?

    var body: some View {
        Section("共享通知") {
            ForEach(runtime.configuration.peers) { profile in
                Toggle(profile.name ?? profile.id.uuidString, isOn: Binding(get: { profile.notifications == true },
                    set: { enabled in perform(operations, scopes: [.peer(profile.id)], error: $error) { try await runtime.shareNotifications(profile.id, enabled: enabled) } }))
                    .disabled(operations.busy([.peer(profile.id)]))
            }
            if runtime.configuration.peers.contains(where: { $0.notifications == true }) && !runtime.notificationAllowed && !runtime.isDemonstration {
                Text(Copy.failure(ProtocolFailure.permissionDenied))
                Button("打开系统设置") { openSystemSettings() }
            }
        }
    }
}

#if DEBUG
private struct DemonstrationSettings: View {
    var runtime: MacRuntime

    var body: some View {
        Section("测试") {
            TextEditor(text: Binding(get: { runtime.demonstrationText }, set: { runtime.demonstrationText = $0 }))
                .frame(minHeight: 64).accessibilityLabel("同步")
            if !runtime.demonstrationReceivedText.isEmpty { Text(runtime.demonstrationReceivedText).textSelection(.enabled) }
            if let result = runtime.demonstrationResult {
                HStack {
                    Text(runtime.configuration.peers.first(where: { $0.identity == result.peer })?.name ?? result.peer.uuidString)
                    Text(result.test.rawValue)
                    if result.passed == true { Image(systemName: "checkmark.circle").accessibilityLabel(result.test.rawValue) }
                    else if let failure = result.failure { Text(Copy.failure(failure)) }
                    else { ProgressView().accessibilityLabel(result.test.rawValue) }
                }
                if runtime.isTesting { Button("取消") { Task { await runtime.cancelTest() } } }
            }
        }
    }
}

#endif

private struct FileTransferSettings: View {
    var runtime: MacRuntime
    let operations: ViewOperations
    @Binding var error: String?

    var body: some View {
        if !runtime.transfers.isEmpty {
            Section("文件传输") {
                ForEach(runtime.transfers.values.sorted { $0.id.uuidString < $1.id.uuidString }) { transfer in
                    VStack(alignment: .leading) {
                        Text(transfer.name)
                        ProgressView(value: Double(transfer.bytes), total: Double(max(1, transfer.size)))
                            .accessibilityLabel("传输进度")
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(transfer.bytes), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(transfer.size), countStyle: .file))")
                            .foregroundStyle(.secondary)
                        if let failure = transfer.failure { Text(Copy.failure(failure)) }
                        else if !runtime.connected.contains(transfer.peer) { Text("已暂停，重新连接后继续。") }
                        HStack {
                            if transfer.failure != nil { Button("重试") { perform(operations, scopes: scopes(transfer.peer), error: $error) { try await runtime.retry(transfer.id, peer: transfer.peer) } }.disabled(operations.busy(scopes(transfer.peer))) }
                            Button("取消") { perform(operations, scopes: scopes(transfer.peer), error: $error) { await runtime.cancel(transfer.id, peer: transfer.peer) } }.disabled(operations.busy(scopes(transfer.peer)))
                        }
                    }
                }
            }
        }
    }
    private func scopes(_ identity: UUID) -> Set<ViewOperations.Scope> {
        [.peer(runtime.configuration.peers.first(where: { $0.identity == identity })?.id ?? identity)]
    }
}

private struct LockSettings: View {
    var runtime: MacRuntime
    let operations: ViewOperations
    @Binding var error: String?
    @State private var lockDelayDraft = ""
    @State private var lockDelayError: String?
    @State private var lockDelayInitialized = false

    var body: some View {
        Section("断连锁定") {
            Picker("主 Android", selection: Binding(get: { runtime.configuration.primary }, set: { primary in
                configureLock(enabled: runtime.configuration.lockEnabled, primary: primary)
            })) {
                Text("未选择").tag(Optional<UUID>.none)
                ForEach(runtime.configuration.peers) { profile in Text(profile.name ?? profile.id.uuidString).tag(Optional(profile.id)) }
            }
                .disabled(operations.busy([.lock]))
            Toggle("断连后锁定 Mac", isOn: Binding(get: { runtime.configuration.lockEnabled }, set: { enabled in
                configureLock(enabled: enabled, primary: runtime.configuration.primary)
            }))
                .disabled(operations.busy([.lock]) || runtime.configuration.primary == nil)
            TextField("锁定等待时间（秒）", text: $lockDelayDraft)
                .disabled(operations.busy([.lock]))
            HStack {
                Button("保存") { saveLockDelay() }
                    .disabled(operations.busy([.lock]) || lockDelayDraft == String(runtime.configuration.lockDelaySeconds))
                Button("取消") { resetLockDelayDraft() }
                    .disabled(operations.busy([.lock]) || (lockDelayDraft == String(runtime.configuration.lockDelaySeconds) && lockDelayError == nil))
            }
            if let lockDelayError { Text(lockDelayError) }
            Text("输入 1–3600 的整数秒，默认 15 秒。已开始的倒计时保持原值，新时间从下次断连生效。").foregroundStyle(.secondary)
            Text("主 Android 连接并通过认证后生效；意外断连 \(runtime.configuration.lockDelaySeconds) 秒后锁定，期间重连则取消。主动停止不会锁定。").foregroundStyle(.secondary)
            if !runtime.lockAllowed {
                if runtime.lockAuthorizationRequested {
                    Button("打开系统设置") { openSystemSettings() }
                        .accessibilityLabel("打开系统设置")
                } else {
                    Button("允许锁定所需的辅助功能权限") { _ = runtime.requestLockAuthorization() }
                        .accessibilityLabel("允许锁定所需的辅助功能权限")
                }
            }
        }
        .onAppear {
            guard !lockDelayInitialized else { return }
            resetLockDelayDraft(); lockDelayInitialized = true
        }
    }
    private func resetLockDelayDraft() {
        lockDelayDraft = String(runtime.configuration.lockDelaySeconds)
        lockDelayError = nil
    }
    private func saveLockDelay() {
        guard !operations.busy([.lock]) else { return }
        let value = lockDelayDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let seconds = Int(value), (1...3600).contains(seconds) else {
            lockDelayError = "请输入 1–3600 的整数秒。"
            return
        }
        do { try runtime.saveLockDelay(seconds: seconds); resetLockDelayDraft() }
        catch { lockDelayError = "请输入 1–3600 的整数秒。" }
    }
    private func configureLock(enabled: Bool, primary: UUID?) {
        guard !operations.busy([.lock]) else { return }
        if enabled {
            runtime.refreshPermissions()
            if !runtime.lockAllowed {
                if runtime.lockAuthorizationRequested { openSystemSettings() }
                else { _ = runtime.requestLockAuthorization() }
                guard runtime.lockAllowed else { return }
            }
        }
        do { try runtime.lock(enabled: enabled, primary: primary) }
        catch { self.error = Copy.failure(error) }
    }
}

private struct ClipboardPermissions: View {
    var runtime: MacRuntime

    var body: some View {
        if !runtime.clipboardAllowed {
            Section("粘贴板权限") {
                Text(Copy.clipboardHelp)
                Button("打开系统设置") { openSystemSettings() }
            }
        }
    }
}

private struct RuntimeFailure: View {
    var runtime: MacRuntime

    var body: some View {
        if let failure = runtime.failures.values.first {
            Section("提示") { Text(Copy.failure(failure)) }
        }
    }
}

private struct TopologyPane: View {
    var runtime: MacRuntime
    let operations: ViewOperations
    @Binding var editing: PeerProfile?
    @Binding var error: String?
    let editMac: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                topology
                    .frame(height: max(geometry.size.height - 32,
                        max(644, CGFloat((runtime.configuration.peers.count + 3) / 4) * 160 + 240)))
                    .padding(16)
            }
        }
    }

    private var topology: some View {
        ConnectionTopologyView(macName: runtime.configuration.name,
            devices: runtime.configuration.peers.enumerated().map { index, profile in
                let peer = profile.identity
                return TopologyDevice(profile: profile, priority: index + 1,
                    connected: peer.map { runtime.connected.contains($0) } == true,
                    route: peer.flatMap { runtime.routes[$0] }, switching: peer.map { runtime.switching.contains($0) } == true,
                    position: runtime.configuration.nodePositions[profile.id.uuidString])
            }, runtime: runtime, operations: operations,
            editMac: editMac,
            connect: { id in
                guard !operations.busy([.peer(id)]),
                      let profile = runtime.configuration.peers.first(where: { $0.id == id }) else { return }
                do { try runtime.connect(profile) } catch { self.error = Copy.failure(error) }
            }, edit: { id in editing = runtime.configuration.peers.first(where: { $0.id == id }) },
            move: movePeer, place: runtime.placeNodes)
    }

    private func movePeer(_ id: UUID, down: Bool) {
        guard !operations.busy([.peer(id)]), let index = runtime.configuration.peers.firstIndex(where: { $0.id == id }),
              down ? index + 1 < runtime.configuration.peers.count : index > 0 else { return }
        runtime.movePeers(from: IndexSet(integer: index), to: down ? index + 2 : index - 1)
    }
}

@MainActor private func openSystemSettings() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
}

@MainActor private func perform(_ operations: ViewOperations, scopes: Set<ViewOperations.Scope>,
                                error failure: Binding<String?>, action: @escaping @MainActor () async throws -> Void) {
    guard operations.begin(scopes) else { return }
    Task {
        defer { operations.finish(scopes) }
        do { try await action() }
        catch is CancellationError { }
        catch { failure.wrappedValue = Copy.failure(error) }
    }
}

private struct PeerEditor: View {
    let profile: PeerProfile
    var runtime: MacRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var key = ""
    @State private var failure: String?
    @State private var saving = false
    init(profile: PeerProfile, runtime: MacRuntime) {
        self.profile = profile; self.runtime = runtime
        _name = State(initialValue: profile.name ?? "")
    }
    var body: some View {
        VStack {
            Form {
                TextField("设备名称", text: $name)
                SecureField("密钥", text: $key)
                Text(Copy.keyHelp).foregroundStyle(.secondary)
                if let failure { Text(failure) }
            }
            .formStyle(.grouped)
            HStack {
                Button("取消", role: .cancel) { key = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            if key.isEmpty && runtime.configuration.peers.contains(where: { $0.id == profile.id }) {
                                try runtime.renamePeer(profile.id, name: name)
                            } else {
                                try await runtime.save(PeerProfile(id: profile.id, identity: profile.identity, name: name.isEmpty ? nil : name), key: key)
                            }
                            key = ""; dismiss()
                        } catch { failure = Copy.failure(error) }
                    }
                }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(idealWidth: 480, idealHeight: 300)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
    }
}

import AncintoshCore
import AncintoshPlatform
import AppKit
import SwiftUI

struct MainView: View {
    @Bindable var runtime: MacRuntime
    var demo: TopologyDemo? = nil
    @State private var dividerReady = false
    @State private var editing: PeerProfile?
    @State private var editingMac = false
    @State private var macNameDraft = ""
    @State private var macNameError: String?
    @State private var selected: UUID?
    @State private var error: String?
    @State private var busy = false
    @State private var lockDelayDraft = ""
    @State private var lockDelayError: String?

    var body: some View {
        HSplitView {
            settings.disabled(demo != nil).frame(minWidth: dividerReady ? 280 : 320, idealWidth: 320,
                maxWidth: dividerReady ? 420 : 320, maxHeight: .infinity)
            GeometryReader { geometry in
                ScrollView {
                    topology
                        .frame(height: max(geometry.size.height - 32,
                            max(644, CGFloat((runtime.configuration.peers.count + 3) / 4) * 160 + 240)))
                        .padding(16)
                }
            }
            .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            runtime.refreshPermissions(); resetLockDelayDraft()
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

    private var settings: some View {
        Form {
            Section("连接") {
                LabeledContent("状态", value: runtime.connected.isEmpty ? (runtime.running ? "等待连接" : "已停止") : "已连接")
                HStack {
                    Button("查找设备") { runtime.scan() }.disabled(busy).accessibilityLabel("查找设备")
                    if runtime.running { Button("停止") { perform { await runtime.stop() } }.disabled(busy) }
                }
                ForEach(runtime.discovered.values.sorted { $0.identifier.uuidString < $1.identifier.uuidString }, id: \.identifier) { device in
                    if !runtime.configuration.peers.contains(where: { $0.id == device.identifier }) {
                        LabeledContent(device.name ?? device.identifier.uuidString) {
                            Button("配置") { editing = PeerProfile(id: device.identifier, name: device.name) }.disabled(busy)
                        }
                    }
                }
                if runtime.configuration.peers.isEmpty && runtime.discovered.isEmpty {
                    Text("先在 Android 中保存密钥并启动，再查找设备。").foregroundStyle(.secondary)
                }
            }
            Section("传输") {
                Toggle("wifi传输", isOn: Binding(get: { runtime.configuration.wifi }, set: { enabled in perform { await runtime.wifi(enabled) } }))
                    .disabled(busy)
                if !runtime.configuration.wifi { Text(Copy.bluetoothVisibility).foregroundStyle(.secondary) }
                Picker("接收设备", selection: $selected) {
                    Text("选择 Android").tag(Optional<UUID>.none)
                    ForEach(runtime.configuration.peers) { profile in
                        if let identity = profile.identity { Text(profile.name ?? identity.uuidString).tag(Optional(identity)) }
                    }
                }
                Button(runtime.preparing ? "准备文件中…" : "发送文件") { chooseFiles() }
                    .disabled(busy || runtime.preparing || selected.map { !runtime.connected.contains($0) } != false)
                    .accessibilityLabel(runtime.preparing ? "准备文件中…" : "发送文件")
                Text("接收文件保存到下载目录中的 Ancintosh 文件夹。").foregroundStyle(.secondary)
            }
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
                                if transfer.failure != nil { Button("重试") { perform { try await runtime.retry(transfer.id, peer: transfer.peer) } }.disabled(busy) }
                                Button("取消") { perform { await runtime.cancel(transfer.id, peer: transfer.peer) } }.disabled(busy)
                            }
                        }
                    }
                }
            }
            Section("断连锁定") {
                Picker("主 Android", selection: Binding(get: { runtime.configuration.primary }, set: { primary in
                    configureLock(enabled: runtime.configuration.lockEnabled, primary: primary)
                })) {
                    Text("未选择").tag(Optional<UUID>.none)
                    ForEach(runtime.configuration.peers) { profile in Text(profile.name ?? profile.id.uuidString).tag(Optional(profile.id)) }
                }
                Toggle("断连后锁定 Mac", isOn: Binding(get: { runtime.configuration.lockEnabled }, set: { enabled in
                    configureLock(enabled: enabled, primary: runtime.configuration.primary)
                }))
                    .disabled(runtime.configuration.primary == nil)
                TextField("锁定等待时间（秒）", text: $lockDelayDraft)
                    .disabled(busy)
                HStack {
                    Button("保存") { saveLockDelay() }
                        .disabled(busy || lockDelayDraft == String(runtime.configuration.lockDelaySeconds))
                    Button("取消") { resetLockDelayDraft() }
                        .disabled(busy || (lockDelayDraft == String(runtime.configuration.lockDelaySeconds) && lockDelayError == nil))
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
            if !runtime.clipboardAllowed {
                Section("粘贴板权限") {
                    Text(Copy.clipboardHelp)
                    Button("打开系统设置") { openSystemSettings() }
                }
            }
            if let failure = runtime.failures.values.first {
                Section("提示") { Text(Copy.failure(failure)) }
            }
        }
        .formStyle(.grouped)
    }

    private var topology: some View {
        ConnectionTopologyView(macName: runtime.configuration.name,
            devices: demo?.devices ?? runtime.configuration.peers.enumerated().map { index, profile in
                let peer = profile.identity
                return TopologyDevice(profile: profile, priority: index + 1,
                    connected: peer.map { runtime.connected.contains($0) } == true,
                    route: peer.flatMap { runtime.routes[$0] }, switching: peer.map { runtime.switching.contains($0) } == true,
                    activities: peer.flatMap { runtime.activities[$0] } ?? [], position: runtime.configuration.nodePositions[profile.id.uuidString],
                    signalSending: runtime.packetTraffic.sending.contains(profile.id), signalReceiving: runtime.packetTraffic.receiving.contains(profile.id),
                    communicating: runtime.packetTraffic.visible.contains(profile.id))
            }, busy: busy, connectionManagementEnabled: demo == nil,
            editMac: { macNameDraft = runtime.configuration.name; macNameError = nil; editingMac = true },
            connect: { id in
                guard let profile = runtime.configuration.peers.first(where: { $0.id == id }) else { return }
                do { try runtime.connect(profile) } catch { self.error = Copy.failure(error) }
            }, edit: { id in editing = runtime.configuration.peers.first(where: { $0.id == id }) },
            move: movePeer, place: { positions in
                if let demo { demo.place(positions) } else { runtime.placeNodes(positions) }
            })
    }

    private func movePeer(_ id: UUID, down: Bool) {
        if let demo { demo.move(id, down: down); return }
        guard !busy, let index = runtime.configuration.peers.firstIndex(where: { $0.id == id }),
              down ? index + 1 < runtime.configuration.peers.count : index > 0 else { return }
        runtime.movePeers(from: IndexSet(integer: index), to: down ? index + 2 : index - 1)
    }
    private func resetLockDelayDraft() {
        lockDelayDraft = String(runtime.configuration.lockDelaySeconds)
        lockDelayError = nil
    }
    private func saveLockDelay() {
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
    private func openSystemSettings() { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { defer { busy = false }; do { try await action() } catch { self.error = Copy.failure(error) } }
    }
    private func chooseFiles() {
        guard let selected else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.prompt = "发送文件"
        panel.begin { result in
            if result == .OK { perform { try await runtime.files(panel.urls, peer: selected) } }
        }
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

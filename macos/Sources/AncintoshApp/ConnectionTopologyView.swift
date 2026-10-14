import AncintoshCore
import AncintoshPlatform
import SwiftUI

struct TopologyDevice: Identifiable {
    let profile: PeerProfile
    let priority: Int
    let connected: Bool
    let route: TransportKind?
    let switching: Bool
    let position: NodePosition?
    var id: UUID { profile.id }
}

struct ConnectionTopologyView: View {
    let macName: String
    let devices: [TopologyDevice]
    var runtime: MacRuntime
    let operations: ViewOperations
    var connectionManagementEnabled = true
    let editMac: () -> Void
    let connect: (UUID) -> Void
    let edit: (UUID) -> Void
    let move: (UUID, Bool) -> Void
    let place: ([UUID: NodePosition]) -> Void
    private let macHeight: CGFloat = 128
    private let nodeHeight: CGFloat = 208
    private struct DragSession {
        let id: UUID
        let origin: CGPoint
        let mouseStart: CGPoint
        var center: CGPoint
    }
    @State private var drag: DragSession?
    @State private var pendingPositions: [UUID: NodePosition] = [:]
    @GestureState private var gestureActive = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let mac = CGPoint(x: size.width / 2, y: size.height / 2)
            ZStack {
                ConnectionLines(runtime: runtime, devices: devices,
                    positions: Dictionary(uniqueKeysWithValues: devices.map { ($0.id, point($0, in: size)) }),
                    mac: mac, macWidth: macWidth(size), macHeight: macHeight,
                    nodeWidth: nodeWidth(size), nodeHeight: nodeHeight)
                ForEach(devices) { device in
                    node(device, size: size).position(point(device, in: size))
                }
                VStack(spacing: 6) {
                    Image(systemName: "laptopcomputer").font(.system(size: 40)).accessibilityHidden(true)
                    Text(macName).lineLimit(3).multilineTextAlignment(.center).help(macName)
                }
                .frame(width: macWidth(size), height: macHeight)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.4)))
                .overlay(alignment: .topTrailing) {
                    MacTopologyMenu(operations: operations, enabled: connectionManagementEnabled, edit: editMac)
                }
                .position(mac)
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: "topology")
            .transaction { transaction in transaction.animation = nil; transaction.disablesAnimations = true }
            .onChange(of: gestureActive) { _, active in if !active { drag = nil } }
            .onAppear { saveInitialPositions(size) }
            .onChange(of: devices.map(\.id)) { _, _ in saveInitialPositions(size) }
            .onChange(of: devices.map(\.position)) { _, _ in
                for device in devices where pendingPositions[device.id] == device.position {
                    pendingPositions.removeValue(forKey: device.id)
                }
            }
        }
    }

    private func node(_ device: TopologyDevice, size: CGSize) -> some View {
        VStack(spacing: 5) {
            Image(systemName: device.profile.kind == .pad ? "ipad.landscape" : "smartphone")
                .font(.system(size: 36)).accessibilityHidden(true)
            Text(device.profile.name ?? device.id.uuidString).lineLimit(3).multilineTextAlignment(.center)
                .help(device.profile.name ?? device.id.uuidString)
            Text(device.connected ? "已连接" : "离线").font(.caption)
                .foregroundStyle(device.connected ? Color.secondary : Color.red)
            if device.connected {
                Text(device.switching ? "切换中" : (device.route == .tcp ? "局域网传输" : "蓝牙传输"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            NodeTrafficStatus(runtime: runtime, device: device)
            Text("\(device.priority)").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: nodeWidth(size), height: nodeHeight)
        .contentShape(Rectangle())
        .gesture(DragGesture(coordinateSpace: .named("topology"))
            .updating($gestureActive) { _, active, transaction in active = true; transaction.disablesAnimations = true }
            .onChanged { value in
                if drag?.id != device.id {
                    let origin = point(device, in: size)
                    drag = DragSession(id: device.id, origin: origin, mouseStart: value.startLocation, center: origin)
                }
                guard let session = drag else { return }
                drag?.center = clamp(CGPoint(x: session.origin.x + value.location.x - session.mouseStart.x,
                                            y: session.origin.y + value.location.y - session.mouseStart.y), size)
            }
            .onEnded { value in
                guard let session = drag, session.id == device.id else { drag = nil; return }
                let end = clamp(CGPoint(x: session.origin.x + value.location.x - session.mouseStart.x,
                                       y: session.origin.y + value.location.y - session.mouseStart.y), size)
                let saved = NodePosition(x: end.x / max(1, size.width), y: end.y / max(1, size.height))
                // Keep the displayed endpoint until the parent supplies its persisted value.
                pendingPositions[device.id] = saved
                drag = nil
                place([device.id: saved])
            })
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(device.connected ? Color.secondary.opacity(0.4) : .red, lineWidth: device.connected ? 1 : 2))
        .overlay(alignment: .topTrailing) {
            DeviceTopologyMenu(device: device, count: devices.count, operations: operations,
                enabled: connectionManagementEnabled, connect: connect, edit: edit, move: move)
        }
        .accessibilityAction(named: "上移") { move(device.id, false) }
        .accessibilityAction(named: "下移") { move(device.id, true) }
    }
    private func initialPosition(_ device: TopologyDevice, _ size: CGSize) -> CGPoint {
        // Initial placement follows stable IDs. Priority remains independent of position.
        let ids = devices.map(\.id).sorted { $0.uuidString < $1.uuidString }
        let index = ids.firstIndex(of: device.id) ?? 0
        let angle = devices.count == 1 ? Double.pi / 2 : Double.pi + Double(index) * 2 * .pi / Double(max(1, devices.count))
        return CGPoint(x: size.width / 2 + cos(angle) * max(0, size.width / 2 - nodeWidth(size) / 2 - 14),
                       y: size.height / 2 + sin(angle) * max(0, size.height / 2 - nodeHeight / 2 - 14))
    }
    private func point(_ device: TopologyDevice, in size: CGSize) -> CGPoint {
        if let drag, drag.id == device.id { return drag.center }
        let saved = pendingPositions[device.id] ?? device.position
        let point = saved.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) } ?? initialPosition(device, size)
        return clamp(point, size)
    }
    private func nodeWidth(_ size: CGSize) -> CGFloat { min(132, max(96, size.width * 0.23)) }
    private func macWidth(_ size: CGSize) -> CGFloat { min(124, max(104, size.width * 0.22)) }
    private func clamp(_ point: CGPoint, _ size: CGSize) -> CGPoint {
        let inset = nodeWidth(size) / 2 + 8
        let verticalInset = nodeHeight / 2 + 8
        return CGPoint(x: min(max(inset, point.x), max(inset, size.width - inset)),
                       y: min(max(verticalInset, point.y), max(verticalInset, size.height - verticalInset)))
    }
    private func saveInitialPositions(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        var missing: [UUID: NodePosition] = [:]
        for device in devices where device.position == nil {
            let center = clamp(initialPosition(device, size), size)
            missing[device.id] = NodePosition(x: center.x / size.width, y: center.y / size.height)
        }
        if !missing.isEmpty { place(missing) }
    }
}

/// Packet updates invalidate the drawing layer, without invalidating the drag owner.
private struct ConnectionLines: View {
    var runtime: MacRuntime
    let devices: [TopologyDevice]
    let positions: [UUID: CGPoint]
    let mac: CGPoint
    let macWidth: CGFloat
    let macHeight: CGFloat
    let nodeWidth: CGFloat
    let nodeHeight: CGFloat

    var body: some View {
        let outbound = runtime.packetTraffic.sending
        let inbound = runtime.packetTraffic.receiving
        let visible = runtime.packetTraffic.visible
        let activities = runtime.activities
        Canvas { context, _ in
            for device in devices where device.connected || visible.contains(device.id) {
                guard let end = positions[device.id] else { continue }
                for sending in [true, false] {
                    let origin = sending ? mac : end, target = sending ? end : mac
                    let dx = target.x - origin.x, dy = target.y - origin.y
                    let distance = max(1, hypot(dx, dy)), ux = dx / distance, uy = dy / distance
                    let sourceHalfWidth = (sending ? macWidth : nodeWidth) / 2
                    let targetHalfWidth = (sending ? nodeWidth : macWidth) / 2
                    let sourceHalfHeight = (sending ? macHeight : nodeHeight) / 2
                    let targetHalfHeight = (sending ? nodeHeight : macHeight) / 2
                    let sourceMargin = min(sourceHalfWidth / max(0.001, abs(ux)), sourceHalfHeight / max(0.001, abs(uy))) + 2
                    let targetMargin = min(targetHalfWidth / max(0.001, abs(ux)), targetHalfHeight / max(0.001, abs(uy))) + 2
                    let start = CGPoint(x: origin.x + ux * sourceMargin - uy * 4, y: origin.y + uy * sourceMargin + ux * 4)
                    let tip = CGPoint(x: target.x - ux * targetMargin - uy * 4, y: target.y - uy * targetMargin + ux * 4)
                    guard distance > sourceMargin + targetMargin else { continue }
                    var line = Path(); line.move(to: start); line.addLine(to: tip)
                    // Both branches share the line's endpoint, color and Path.
                    line.addLine(to: CGPoint(x: tip.x - ux * 8 - uy * 4, y: tip.y - uy * 8 + ux * 4))
                    line.move(to: tip)
                    line.addLine(to: CGPoint(x: tip.x - ux * 8 + uy * 4, y: tip.y - uy * 8 - ux * 4))
                    let active = device.profile.identity.flatMap { activities[$0] }?.contains { $0.sending == sending } == true ||
                        (sending ? outbound.contains(device.id) : inbound.contains(device.id))
                    context.stroke(line, with: .color(active ? .green : .secondary.opacity(0.45)), lineWidth: 1.5)
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private struct NodeTrafficStatus: View {
    var runtime: MacRuntime
    let device: TopologyDevice

    var body: some View {
        let activities = device.profile.identity.flatMap { runtime.activities[$0] } ?? []
        let handshaking = runtime.handshaking.contains(device.id)
        let outbound = runtime.packetTraffic.sending.contains(device.id)
        let inbound = runtime.packetTraffic.receiving.contains(device.id)
        VStack(spacing: 5) {
            ForEach([true, false], id: \.self) { sending in
                let active = (device.connected && activities.contains { $0.sending == sending }) ||
                    (handshaking && (sending ? outbound : inbound))
                let clipboard = sending && activities.contains { $0.sending && $0.kind != .file }
                Text(handshaking ? "握手包" : (clipboard ? "发送粘贴板中" : "数据传输中"))
                    .font(.caption).lineLimit(1)
                    .opacity(active ? 1 : 0)
                    .accessibilityHidden(!active)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 40)
    }
}

private struct MacTopologyMenu: View {
    let operations: ViewOperations
    let enabled: Bool
    let edit: () -> Void

    var body: some View {
        Menu { Button("编辑", action: edit) } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize().padding(8)
            .disabled(operations.busy([]) || !enabled).accessibilityLabel("编辑")
    }
}

private struct DeviceTopologyMenu: View {
    let device: TopologyDevice
    let count: Int
    let operations: ViewOperations
    let enabled: Bool
    let connect: (UUID) -> Void
    let edit: (UUID) -> Void
    let move: (UUID, Bool) -> Void

    var body: some View {
        Menu {
            Button("连接") { connect(device.id) }.disabled(!enabled)
            Button("编辑") { edit(device.id) }.disabled(!enabled)
            Divider()
            Button("上移") { move(device.id, false) }.disabled(device.priority == 1)
            Button("下移") { move(device.id, true) }.disabled(device.priority == count)
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).fixedSize().padding(8)
        .disabled(operations.busy([.peer(device.id)])).accessibilityLabel("编辑")
    }
}

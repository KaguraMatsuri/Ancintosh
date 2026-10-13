import AncintoshCore
import AncintoshPlatform
import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class TopologyDemo {
    // Fixed seed IDs keep drag positions and priority independent of the simulated state.
    static let clipboardPhone = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let filePhone = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let offlinePhone = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    static let pad = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
    private static let clipboardTransfer = UUID(uuidString: "00000000-0000-4000-8000-000000000101")!
    private static let fileTransfer = UUID(uuidString: "00000000-0000-4000-8000-000000000102")!
    private(set) var profiles: [PeerProfile]
    private(set) var positions: [UUID: NodePosition] = [:]
    private(set) var padConnected = false
    let traffic = ConnectionTraffic()
    let runtime: MacRuntime
    private var generation: UUID?

    init() throws {
        let names = [Self.clipboardPhone: "Galaxy S24 Ultra", Self.filePhone: "Galaxy S21 Ultra",
                     Self.pad: "Galaxy Tab S8 Plus", Self.offlinePhone: "Galaxy Note 7"]
        let seededProfiles = [Self.clipboardPhone, Self.filePhone, Self.pad, Self.offlinePhone].map { id in
            var profile = PeerProfile(id: id, identity: id, name: names[id])
            profile.kind = id == Self.pad ? .pad : .phone
            profile.wifi = id == Self.clipboardPhone
            return profile
        }
        profiles = seededProfiles
        var configuration = MacConfiguration()
        configuration.name = "Mac"; configuration.peers = seededProfiles
        runtime = try MacRuntime(demonstration: configuration, traffic: traffic)
        updateRuntime(running: true)
    }

    var devices: [TopologyDevice] {
        profiles.enumerated().map { index, profile in
            let connected = profile.id == Self.clipboardPhone || profile.id == Self.filePhone || (profile.id == Self.pad && padConnected)
            let activities: [LinkActivity]
            switch profile.id {
            case Self.clipboardPhone: activities = [LinkActivity(id: Self.clipboardTransfer, kind: .text, sending: true)]
            case Self.filePhone: activities = [LinkActivity(id: Self.fileTransfer, kind: .file, sending: false)]
            default: activities = []
            }
            return TopologyDevice(profile: profile, priority: index + 1, connected: connected,
                route: connected ? (profile.wifi == true ? .tcp : .ble) : nil, switching: false,
                activities: activities, position: positions[profile.id],
                signalSending: traffic.sending.contains(profile.id), signalReceiving: traffic.receiving.contains(profile.id),
                communicating: traffic.visible.contains(profile.id),
                handshaking: profile.id == Self.pad && !padConnected && traffic.visible.contains(profile.id))
        }
    }

    func place(_ updates: [UUID: NodePosition]) {
        let registered = Set(profiles.map(\.id))
        for (id, value) in updates where registered.contains(id) && value.x.isFinite && value.y.isFinite {
            positions[id] = NodePosition(x: min(1, max(0, value.x)), y: min(1, max(0, value.y)))
        }
        updateRuntime()
    }

    func move(_ id: UUID, down: Bool) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let target = index + (down ? 1 : -1)
        guard profiles.indices.contains(target) else { return }
        profiles.swapAt(index, target)
        updateRuntime()
    }

    private func updateRuntime(running: Bool? = nil) {
        let active = running ?? runtime.running
        let devices = devices
        var configuration = runtime.configuration
        configuration.peers = profiles
        configuration.nodePositions = Dictionary(uniqueKeysWithValues: positions.map { ($0.key.uuidString, $0.value) })
        let connected = active ? Set(devices.filter(\.connected).map(\.id)) : []
        let routes = Dictionary(uniqueKeysWithValues: devices.compactMap { device in
            connected.contains(device.id) ? device.route.map { (device.id, $0) } : nil
        })
        let activities = Dictionary(uniqueKeysWithValues: devices.filter { connected.contains($0.id) && !$0.activities.isEmpty }.map { ($0.id, $0.activities) })
        runtime.updateDemonstration(configuration: configuration, connected: connected, routes: routes, activities: activities, running: active)
    }

    func run() async {
        stop()
        let current = UUID(); generation = current
        defer { if generation == current { stop() } }
        do {
            while !Task.isCancelled, generation == current {
                padConnected = false
                updateRuntime(running: true)
                let handshake = UUID()
                traffic.signal(Self.pad, .handshakeStarted(handshake))
                // Three packets in each direction, using the production 100 ms / 80 ms pulse.
                for packet in 0..<6 {
                    guard !Task.isCancelled, generation == current else { return }
                    traffic.signal(Self.pad, .packet(sending: packet.isMultiple(of: 2), handshake: true))
                    try await Task.sleep(for: .milliseconds(180))
                }
                guard generation == current else { return }
                traffic.signal(Self.pad, .handshakeEnded(handshake))
                padConnected = true
                updateRuntime()
                try await Task.sleep(for: .seconds(4))
            }
        } catch is CancellationError { }
        catch { }
    }

    func stop() {
        generation = nil
        traffic.stop()
        padConnected = false
        updateRuntime(running: false)
    }
}

struct TopologyDemoView: View {
    let demo: TopologyDemo

    var body: some View {
        MainView(runtime: demo.runtime, demo: demo)
        .task { await demo.run() }
        .onDisappear { demo.stop() }
    }
}

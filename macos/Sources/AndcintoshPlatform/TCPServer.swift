import AndcintoshCore
import Darwin
import Foundation
import Network

public actor TCPByteChannel: ByteChannel {
    private let connection: NWConnection
    private var closed = false
    public init(_ connection: NWConnection) {
        self.connection = connection
        connection.start(queue: DispatchQueue(label: "Andcintosh.tcp", qos: .utility))
    }
    public func readExactly(_ count: Int) async throws -> Data {
        guard count >= 0, count <= Wire.maxPlaintext + 16, !closed else { throw ProtocolFailure.invalidFrame }
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let bytes: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { content, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let content, !content.isEmpty { continuation.resume(returning: content) }
                    else { continuation.resume(throwing: ProtocolFailure.peerUnavailable) }
                }
            }
            result.append(bytes)
        }
        return result
    }
    public func write(_ data: Data) async throws {
        guard !closed else { throw ProtocolFailure.peerUnavailable }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    public func close() { closed = true; connection.cancel() }
}

public actor TCPServer {
    private var listeners: [NWListener] = []
    private var ready = false
    private var startupWaiters: [CheckedContinuation<[TCPAddress], any Error>] = []
    private var startupTimeout: Task<Void, Never>?

    private let identity: UUID
    private let coordinator: SyncCoordinator
    private let signal: (@Sendable (UUID, ConnectionSignal) async -> Void)?
    private let queue = DispatchQueue(label: "Andcintosh.listener", qos: .utility)

    public init(identity: UUID, coordinator: SyncCoordinator, signal: (@Sendable (UUID, ConnectionSignal) async -> Void)? = nil) {
        self.identity = identity; self.coordinator = coordinator; self.signal = signal
    }

    public func start() async throws -> [TCPAddress] {
        if ready { return addresses() }
        if listeners.isEmpty {
            for type in [NWInterface.InterfaceType.wifi, .wiredEthernet] {
                let tcp = NWProtocolTCP.Options()
                tcp.noDelay = true
                tcp.connectionTimeout = 5
                let parameters = NWParameters(tls: nil, tcp: tcp)
                parameters.requiredInterfaceType = type
                let listener = try NWListener(using: parameters, on: .any)
                listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let listener else { return }
                    Task { await self?.listenerChanged(listener, state: state) }
                }
                listeners.append(listener)
                listener.start(queue: queue)
            }
            startupTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await self?.stop()
            }
        }
        return try await withCheckedThrowingContinuation { startupWaiters.append($0) }
    }

    private func listenerChanged(_ listener: NWListener, state: NWListener.State) {
        guard listeners.contains(where: { $0 === listener }) else { return }
        switch state {
        case .ready:
            let endpoints = addresses()
            guard !endpoints.isEmpty else { return }
            ready = true
            startupTimeout?.cancel(); startupTimeout = nil
            let pending = startupWaiters; startupWaiters.removeAll()
            for waiter in pending { waiter.resume(returning: endpoints) }
        case .failed:
            listener.cancel(); listeners.removeAll { $0 === listener }
            if listeners.isEmpty { stop() }
        default: break
        }
    }
    public func stop() {
        ready = false
        startupTimeout?.cancel(); startupTimeout = nil
        let pending = startupWaiters; startupWaiters.removeAll()
        for waiter in pending { waiter.resume(throwing: ProtocolFailure.peerUnavailable) }
        for listener in listeners { listener.cancel() }
        listeners.removeAll()
    }

    private func addresses() -> [TCPAddress] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(first) }
        var result: [TCPAddress] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            let value = item.pointee
            guard let address = value.ifa_addr, [UInt8(AF_INET), UInt8(AF_INET6)].contains(address.pointee.sa_family),
                  value.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  value.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let name = String(cString: value.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            for listener in listeners {
                if let port = listener.port {
                    result.append(TCPAddress(host: String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self), port: port.rawValue))
                }
            }
        }
        return Array(result.prefix(8))
    }

    private func accept(_ connection: NWConnection) async {
        let channel = TCPByteChannel(connection)
        let timeout = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { await channel.close() } }
        do {
            let hello = try await Handshake.readHello(channel: channel)
            guard hello.role == .android else { throw ProtocolFailure.invalidHandshake }
            let key = try await coordinator.bindingKey(peer: hello.peerID, context: hello.contextID)
            let signal = self.signal, token = UUID()
            await signal?(hello.peerID, .handshakeStarted(token))
            defer { Task { await signal?(hello.peerID, .handshakeEnded(token)) } }
            let packet: @Sendable (Bool, Bool) -> Void = { sending, handshake in
                Task { await signal?(hello.peerID, .packet(sending: sending, handshake: handshake)) }
            }
            let auth = try await Handshake.authenticate(channel: channel, role: .mac, identity: identity,
                                                        key: key, context: hello.contextID, transport: .tcp,
                                                        expectedPeer: hello.peerID, remoteHello: hello, traffic: { packet($0, true) })
            timeout.cancel()
            try await coordinator.installTCP(auth.peer, channel: EncryptedChannel(raw: channel, authentication: auth, transport: .tcp, traffic: { packet($0, false) }), context: hello.contextID)
        } catch { timeout.cancel(); await channel.close() }
    }
}

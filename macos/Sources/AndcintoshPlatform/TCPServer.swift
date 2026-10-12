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
    private let identity: UUID
    private let coordinator: SyncCoordinator
    private let queue = DispatchQueue(label: "Andcintosh.listener", qos: .utility)

    public init(identity: UUID, coordinator: SyncCoordinator) { self.identity = identity; self.coordinator = coordinator }

    public func start() async throws -> [TCPAddress] {
        if !listeners.isEmpty { return addresses() }
        for type in [NWInterface.InterfaceType.wifi, .wiredEthernet] {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.connectionTimeout = 5
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.requiredInterfaceType = type
            let listener = try NWListener(using: parameters, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection) }
            }
            listeners.append(listener)
            listener.start(queue: queue)
        }
        for _ in 0..<50 {
            if !addresses().isEmpty { return addresses() }
            try await Task.sleep(for: .milliseconds(100))
        }
        stop()
        throw ProtocolFailure.peerUnavailable
    }

    public func stop() {
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
            let hello = try Hello.decode(await channel.readExactly(Wire.helloSize))
            guard hello.role == .android else { throw ProtocolFailure.invalidHandshake }
            let key = try await coordinator.bindingKey(peer: hello.peerID, context: hello.contextID)
            let auth = try await Handshake.authenticate(channel: channel, role: .mac, identity: identity,
                                                        key: key, context: hello.contextID, transport: .tcp,
                                                        expectedPeer: hello.peerID, remoteHello: hello)
            timeout.cancel()
            try await coordinator.installTCP(auth.peer, channel: EncryptedChannel(raw: channel, authentication: auth, transport: .tcp), context: hello.contextID)
        } catch { timeout.cancel(); await channel.close() }
    }
}

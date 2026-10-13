import AncintoshCore
import CoreBluetooth
import Foundation

@MainActor public enum BLEIdentifiers {
    public static let service = CBUUID(string: "3C633DE1-C3E5-4E81-A593-9ADF6D4A419F")
    public static let psm = CBUUID(string: "3C633DE1-C3E5-4E81-A593-9ADF6D4A41A0")
}

public struct BLEPeer: Sendable, Equatable {
    public let identifier: UUID
    public let name: String?
    public let rssi: Int
}

@MainActor
public final class BLEClient: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    public var discovered: ((BLEPeer) -> Void)?
    public var failed: ((UUID, ProtocolFailure) -> Void)?
    public var associated: ((UUID, UUID) -> Void)?
    public var signal: (@MainActor @Sendable (UUID, ConnectionSignal) -> Void)?
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var keys: [UUID: Data] = [:]
    private var identities: [UUID: UUID] = [:]
    private var stopped = true
    private var scanPending = false
    private var scanTask: Task<Void, Never>?
    private var lifecycle = BLEConnectionLifecycle()
    private var handshakes: [UUID: Task<Void, Never>] = [:]
    private var channels: [UUID: StreamByteChannel] = [:]
    private var cleanup: [UUID: Task<Void, Never>] = [:]
    private let identity: UUID
    private let coordinator: SyncCoordinator

    public init(identity: UUID, coordinator: SyncCoordinator) {
        self.identity = identity; self.coordinator = coordinator
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }
    public func scan() {
        stopped = false
        scanPending = true
        guard central.state == .poweredOn else { return }
        scanPending = false
        scanTask?.cancel()
        central.scanForPeripherals(withServices: [BLEIdentifiers.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.central.stopScan()
            self?.scanTask = nil
        }
    }
    public func connect(identifier: UUID, key: Data, expectedIdentity: UUID? = nil) throws {
        guard key.count == 32 else { throw ProtocolFailure.invalidKey }
        stopped = false
        if keys[identifier] != key || lifecycle.phase(identifier) == .failed {
            invalidateHandshake(identifier)
            lifecycle.reset(identifier)
        } else { lifecycle.register(identifier) }
        keys[identifier] = key
        if let expectedIdentity { identities[identifier] = expectedIdentity }
        guard central.state != .unknown, central.state != .resetting else { return }
        guard central.state == .poweredOn else { throw central.state == .unauthorized ? ProtocolFailure.permissionDenied : .peerUnavailable }
        guard let peripheral = peripherals[identifier] ?? central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            scan(); return
        }
        peripherals[identifier] = peripheral
        requestConnection(peripheral)
    }
    private func requestConnection(_ peripheral: CBPeripheral) {
        guard !stopped, central.state == .poweredOn, keys[peripheral.identifier] != nil else { return }
        peripheral.delegate = self
        if peripheral.state == .connected { openSession(peripheral) }
        else if lifecycle.beginConnection(peripheral.identifier) {
            central.connect(peripheral, options: [CBConnectPeripheralOptionEnableAutoReconnect: true])
        }
    }
    private func openSession(_ peripheral: CBPeripheral) {
        let device = peripheral.identifier
        guard !stopped, let token = lifecycle.beginOpening(device) else { return }
        let previous = cleanup[device]
        Task { [weak self, weak peripheral] in
            await previous?.value
            guard let self, let peripheral, !self.stopped, self.lifecycle.isCurrent(device, token: token),
                  peripheral.state == .connected else { return }
            peripheral.delegate = self
            peripheral.discoverServices([BLEIdentifiers.service])
        }
    }
    /// Handles a lost data channel even when the GATT link remains connected.
    public func sessionDisconnected(_ peer: UUID, intentional: Bool) {
        guard !stopped, !intentional,
              let device = identities.first(where: { $0.value == peer })?.key,
              lifecycle.sessionLost(device), let peripheral = peripherals[device] else { return }
        invalidateHandshake(device)
        requestConnection(peripheral)
    }
    public func sessionAuthenticated(_ peer: UUID) -> Bool {
        !stopped && identities.contains { device, identity in identity == peer && lifecycle.phase(device) == .ready }
    }
    @discardableResult private func invalidateHandshake(_ device: UUID) -> Task<Void, Never>? {
        let task = handshakes.removeValue(forKey: device)
        task?.cancel()
        if let raw = channels.removeValue(forKey: device) { Task { await raw.close() } }
        return task
    }
    public func stop() async {
        stopped = true
        scanPending = false
        scanTask?.cancel(); scanTask = nil
        central.stopScan()
        lifecycle.stop()
        let pending = Array(handshakes.values)
        for device in Array(handshakes.keys) { invalidateHandshake(device) }
        for peripheral in peripherals.values { central.cancelPeripheralConnection(peripheral) }
        for task in pending { await task.value }
        for task in cleanup.values { await task.value }
        cleanup.removeAll()
        await coordinator.stop()
    }
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn && !stopped {
            if scanPending { scan() }
            for id in keys.keys where lifecycle.phase(id) != .failed {
                guard let peripheral = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else { scan(); continue }
                peripherals[id] = peripheral
                requestConnection(peripheral)
            }
        } else if central.state != .poweredOn {
            lifecycle.radioUnavailable()
            for device in keys.keys {
                let pending = invalidateHandshake(device)
                if let peer = identities[device] { disconnectSession(device, peer: peer, intentional: stopped, pending: pending) }
            }
        }
    }
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !stopped else { return }
        peripherals[peripheral.identifier] = peripheral
        discovered?(BLEPeer(identifier: peripheral.identifier, name: peripheral.name, rssi: RSSI.intValue))
        if keys[peripheral.identifier] != nil { requestConnection(peripheral) }
    }
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !stopped, lifecycle.phase(peripheral.identifier) != nil else {
            central.cancelPeripheralConnection(peripheral); return
        }
        openSession(peripheral)
        if lifecycle.phase(peripheral.identifier) == .failed { central.cancelPeripheralConnection(peripheral) }
    }
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        guard !stopped else { return }
        lifecycle.disconnected(peripheral.identifier, reconnecting: false)
        failed?(peripheral.identifier, .peerUnavailable)
        if central.state == .poweredOn { scan() }
    }
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        disconnected(peripheral, reconnecting: false)
    }
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               timestamp: CFAbsoluteTime, isReconnecting: Bool, error: (any Error)?) {
        disconnected(peripheral, reconnecting: isReconnecting)
    }
    private func disconnected(_ peripheral: CBPeripheral, reconnecting: Bool) {
        let device = peripheral.identifier
        lifecycle.disconnected(device, reconnecting: reconnecting && !stopped)
        let pending = invalidateHandshake(device)
        if let peer = identities[device] { disconnectSession(device, peer: peer, intentional: stopped, pending: pending) }
        if !reconnecting, !stopped { requestConnection(peripheral) }
    }
    private func disconnectSession(_ device: UUID, peer: UUID, intentional: Bool, pending: Task<Void, Never>? = nil) {
        let previous = cleanup[device]
        cleanup[device] = Task { [coordinator] in
            await previous?.value
            await pending?.value
            await coordinator.disconnect(peer, intentional: intentional)
        }
    }
    private func failSession(_ peripheral: CBPeripheral, failure: ProtocolFailure) {
        let device = peripheral.identifier
        guard !stopped else { return }
        // Transport loss can recover; a failed proof or unsupported peer needs user action.
        if failure == .peerUnavailable || failure == .timeout { lifecycle.disconnected(device, reconnecting: false) }
        else { lifecycle.fail(device) }
        invalidateHandshake(device)
        failed?(device, failure)
        central.cancelPeripheralConnection(peripheral)
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard !stopped, lifecycle.phase(peripheral.identifier) == .opening else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == BLEIdentifiers.service }) else {
            failSession(peripheral, failure: .unsupported); return
        }
        peripheral.discoverCharacteristics([BLEIdentifiers.psm], for: service)
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard !stopped, lifecycle.phase(peripheral.identifier) == .opening else { return }
        guard error == nil, let characteristic = service.characteristics?.first(where: { $0.uuid == BLEIdentifiers.psm }) else {
            failSession(peripheral, failure: .unsupported); return
        }
        peripheral.readValue(for: characteristic)
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard !stopped, lifecycle.phase(peripheral.identifier) == .opening else { return }
        guard error == nil, characteristic.uuid == BLEIdentifiers.psm, let value = characteristic.value, value.count == 2 else {
            failSession(peripheral, failure: .unsupported); return
        }
        let psm = UInt16(value[value.startIndex]) | UInt16(value[value.index(after: value.startIndex)]) << 8
        peripheral.openL2CAPChannel(psm)
    }
    public func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: (any Error)?) {
        let device = peripheral.identifier
        guard !stopped, let token = lifecycle.beginAuthentication(device) else {
            channel?.inputStream.close(); channel?.outputStream.close(); return
        }
        guard error == nil, let channel, let key = keys[device] else {
            failSession(peripheral, failure: .peerUnavailable); return
        }
        let raw = StreamByteChannel(input: channel.inputStream, output: channel.outputStream, keeper: channel)
        channels[device] = raw
        let expected = identities[device]
        let identity = self.identity
        let coordinator = self.coordinator
        let handshakeToken = UUID()
        signal?(device, .handshakeStarted(handshakeToken))
        let packet: @Sendable (Bool, Bool) -> Void = { [weak self] sending, handshake in
            Task { @MainActor in
                guard let self, !self.stopped, self.lifecycle.isCurrent(device, token: token) else { return }
                self.signal?(device, .packet(sending: sending, handshake: handshake))
            }
        }
        handshakes[device] = Task { [weak self, weak peripheral] in
            let timeout = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { await raw.close() } }
            defer { timeout.cancel(); self?.signal?(device, .handshakeEnded(handshakeToken)) }
            do {
                let auth = try await Handshake.authenticate(channel: raw, role: .mac, identity: identity, key: key,
                                                            transport: .ble, expectedPeer: expected, traffic: { packet($0, true) })
                timeout.cancel()
                try Task.checkCancellation()
                guard let self, !self.stopped, self.lifecycle.authenticated(device, token: token) else { await raw.close(); return }
                self.identities[device] = auth.peer
                self.associated?(device, auth.peer)
                try await coordinator.installBLE(auth.peer, channel: EncryptedChannel(raw: raw, authentication: auth, transport: .ble, traffic: { packet($0, false) }))
                guard self.lifecycle.isCurrent(device, token: token) else { return }
                self.channels.removeValue(forKey: device)
                self.handshakes.removeValue(forKey: device)
                if self.keys.keys.allSatisfy({ self.lifecycle.phase($0) == .ready || self.lifecycle.phase($0) == .failed }) {
                    self.scanTask?.cancel(); self.scanTask = nil; self.central.stopScan()
                }
            } catch {
                await raw.close()
                guard let self, let peripheral, self.lifecycle.isCurrent(device, token: token), !Task.isCancelled else { return }
                self.failSession(peripheral, failure: error as? ProtocolFailure ?? .authenticationFailed)
            }
        }
    }

}

public final class StreamByteChannel: NSObject, ByteChannel, StreamDelegate, @unchecked Sendable {
    private let input: InputStream
    private let output: OutputStream
    private let keeper: AnyObject
    private let lock = NSLock()
    private var loop: CFRunLoop?
    private var thread: Thread!
    private var pending: [@Sendable () -> Void] = []
    private var reading: (Int, Data, CheckedContinuation<Data, any Error>)?
    private var writing: (Data, Int, CheckedContinuation<Void, any Error>)?
    private var closed = false

    public init(input: InputStream, output: OutputStream, keeper: AnyObject) {
        self.input = input; self.output = output; self.keeper = keeper
        super.init()
        thread = Thread { [weak self] in self?.run() }
        thread.name = "Ancintosh.ble.stream"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func run() {
        let runLoop = RunLoop.current
        runLoop.add(Port(), forMode: .default)
        input.delegate = self; output.delegate = self
        input.schedule(in: runLoop, forMode: .default); output.schedule(in: runLoop, forMode: .default)
        input.open(); output.open()
        lock.lock(); loop = CFRunLoopGetCurrent(); let initial = pending; pending.removeAll(); lock.unlock()
        for action in initial { action() }
        if !closed { CFRunLoopRun() }
        input.close(); output.close()
        input.remove(from: runLoop, forMode: .default); output.remove(from: runLoop, forMode: .default)
    }

    private func perform(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        if closed { lock.unlock(); action(); return }
        if let loop {
            lock.unlock()
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, action)
            CFRunLoopWakeUp(loop)
        } else { pending.append(action); lock.unlock() }
    }

    public func readExactly(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            perform { [self] in
                guard !closed, reading == nil, count >= 0, count <= Wire.maxPlaintext + 16 else {
                    continuation.resume(throwing: ProtocolFailure.invalidFrame); return
                }
                reading = (count, Data(), continuation)
                drainRead()
            }
        }
    }
    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            perform { [self] in
                guard !closed, writing == nil else { continuation.resume(throwing: ProtocolFailure.peerUnavailable); return }
                writing = (data, 0, continuation)
                drainWrite()
            }
        }
    }
    public func close() async { perform { [self] in terminate() } }

    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable: drainRead()
        case .hasSpaceAvailable: drainWrite()
        case .errorOccurred, .endEncountered: terminate()
        default: break
        }
    }
    private func drainRead() {
        guard var request = reading else { return }
        var buffer = [UInt8](repeating: 0, count: min(65_536, max(1, request.0 - request.1.count)))
        while request.1.count < request.0 && input.hasBytesAvailable {
            let count = input.read(&buffer, maxLength: min(buffer.count, request.0 - request.1.count))
            if count < 0 { reading = request; terminate(); return }
            if count == 0 { break }
            request.1.append(contentsOf: buffer.prefix(count))
        }
        if request.1.count == request.0 { reading = nil; request.2.resume(returning: request.1) }
        else { reading = request }
    }
    private func drainWrite() {
        guard var request = writing else { return }
        while request.1 < request.0.count && output.hasSpaceAvailable {
            let offset = request.1
            let count = request.0.withUnsafeBytes { bytes in
                output.write(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset), maxLength: request.0.count - offset)
            }
            if count < 0 { writing = request; terminate(); return }
            if count == 0 { break }
            request.1 += count
        }
        if request.1 == request.0.count { writing = nil; request.2.resume() }
        else { writing = request }
    }
    private func terminate() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        reading?.2.resume(throwing: ProtocolFailure.peerUnavailable); reading = nil
        writing?.2.resume(throwing: ProtocolFailure.peerUnavailable); writing = nil
        input.close(); output.close()
        if let loop { CFRunLoopStop(loop) }
    }
}

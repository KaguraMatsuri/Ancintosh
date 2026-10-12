import AndcintoshCore
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
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var keys: [UUID: Data] = [:]
    private var identities: [UUID: UUID] = [:]
    private var stopped = false
    private let identity: UUID
    private let coordinator: SyncCoordinator

    public init(identity: UUID, coordinator: SyncCoordinator) {
        self.identity = identity; self.coordinator = coordinator
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }
    public func scan() {
        guard central.state == .poweredOn else { return }
        stopped = false
        central.scanForPeripherals(withServices: [BLEIdentifiers.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        Task { [weak self] in try? await Task.sleep(for: .seconds(10)); self?.central.stopScan() }
    }
    public func connect(identifier: UUID, key: Data, expectedIdentity: UUID? = nil) throws {
        guard key.count == 32, central.state == .poweredOn else { throw ProtocolFailure.peerUnavailable }
        stopped = false
        keys[identifier] = key
        if let expectedIdentity { identities[identifier] = expectedIdentity }
        let peripheral = peripherals[identifier] ?? central.retrievePeripherals(withIdentifiers: [identifier]).first
        guard let peripheral else { throw ProtocolFailure.peerUnavailable }
        peripherals[identifier] = peripheral
        peripheral.delegate = self
        if peripheral.state == .connected { peripheral.discoverServices([BLEIdentifiers.service]) }
        else { central.connect(peripheral) }
    }
    public func stop() async {
        stopped = true
        central.stopScan()
        await coordinator.stop()
        for peripheral in peripherals.values { central.cancelPeripheralConnection(peripheral) }
    }
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            for peer in identities.values { Task { await coordinator.disconnect(peer) } }
        }
    }
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        discovered?(BLEPeer(identifier: peripheral.identifier, name: peripheral.name, rssi: RSSI.intValue))
    }
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([BLEIdentifiers.service])
    }
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        failed?(peripheral.identifier, .peerUnavailable)
        retry(peripheral)
    }
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        if let peer = identities[peripheral.identifier] { Task { await coordinator.disconnect(peer, intentional: stopped) } }
        retry(peripheral)
    }
    private func retry(_ peripheral: CBPeripheral) {
        guard !stopped, keys[peripheral.identifier] != nil else { return }
        Task { [weak self, weak peripheral] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, let peripheral, !self.stopped, self.central.state == .poweredOn else { return }
            self.central.connect(peripheral)
        }
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == BLEIdentifiers.service }) else {
            failed?(peripheral.identifier, .unsupported); return
        }
        peripheral.discoverCharacteristics([BLEIdentifiers.psm], for: service)
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard error == nil, let characteristic = service.characteristics?.first(where: { $0.uuid == BLEIdentifiers.psm }) else {
            failed?(peripheral.identifier, .unsupported); return
        }
        peripheral.readValue(for: characteristic)
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard error == nil, characteristic.uuid == BLEIdentifiers.psm, let value = characteristic.value, value.count == 2 else { return }
        let psm = UInt16(value[value.startIndex]) | UInt16(value[value.index(after: value.startIndex)]) << 8
        peripheral.openL2CAPChannel(psm)
    }
    public func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: (any Error)?) {
        guard error == nil, let channel, let key = keys[peripheral.identifier] else {
            failed?(peripheral.identifier, .peerUnavailable); return
        }
        let raw = StreamByteChannel(input: channel.inputStream, output: channel.outputStream, keeper: channel)
        let device = peripheral.identifier
        let expected = identities[device]
        let identity = self.identity
        let coordinator = self.coordinator
        Task { [weak self] in
            let timeout = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { await raw.close() } }
            do {
                let auth = try await Handshake.authenticate(channel: raw, role: .mac, identity: identity, key: key,
                                                            transport: .ble, expectedPeer: expected)
                timeout.cancel()
                self?.identities[device] = auth.peer
                self?.associated?(device, auth.peer)
                try await coordinator.installBLE(auth.peer, channel: EncryptedChannel(raw: raw, authentication: auth, transport: .ble))
            } catch {
                timeout.cancel(); await raw.close()
                self?.failed?(device, error as? ProtocolFailure ?? .authenticationFailed)
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
        thread.name = "Andcintosh.ble.stream"
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
        CFRunLoopRun()
        input.close(); output.close()
        input.remove(from: runLoop, forMode: .default); output.remove(from: runLoop, forMode: .default)
    }

    private func perform(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
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
        guard !closed else { return }
        closed = true
        reading?.2.resume(throwing: ProtocolFailure.peerUnavailable); reading = nil
        writing?.2.resume(throwing: ProtocolFailure.peerUnavailable); writing = nil
        input.close(); output.close()
        if let loop { CFRunLoopStop(loop) }
    }
}

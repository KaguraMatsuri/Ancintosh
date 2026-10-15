package io.github.kaguramatsuri.ancintosh.platform

import android.Manifest
import android.content.pm.PackageManager
import android.bluetooth.*
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.AdvertisingSet
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.AdvertisingSetParameters
import android.os.SystemClock
import android.content.Context
import android.os.ParcelUuid
import io.github.kaguramatsuri.ancintosh.core.*
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import kotlinx.coroutines.*

class BluetoothByteChannel(private val socket: BluetoothSocket) : ByteChannel {
    override suspend fun readExactly(count: Int): ByteArray = withContext(Dispatchers.IO) {
        if (count < 0 || count > Wire.MAX_PLAINTEXT + 16) fail(Failure.invalidFrame)
        val result = ByteArray(count); var position = 0
        while (position < count) { val n = socket.inputStream.read(result, position, count - position); if (n < 0) fail(Failure.peerUnavailable); position += n }
        result
    }
    override suspend fun write(data: ByteArray) = withContext(Dispatchers.IO) { socket.outputStream.write(data) }
    override fun close() { runCatching { socket.close() } }
}

class BLEPeripheral(private val context: Context, private val scope: CoroutineScope,
                    private val settings: DeviceSettings, private val session: SessionController,
                    private val failed: (Failure) -> Unit) {
    private val manager = context.getSystemService(BluetoothManager::class.java)
    private val adapter get() = manager.adapter
    private var server: BluetoothServerSocket? = null
    private var gatt: BluetoothGattServer? = null
    private var acceptor: Job? = null
    @Volatile private var running = false
    @Volatile private var generation = 0L
    private var active: BluetoothByteChannel? = null
    private var activeDevice: BluetoothDevice? = null
    private var advertising: AdvertiseCallback? = null
    private var setCallback: AdvertisingSetCallback? = null
    private var advertisingSet: AdvertisingSet? = null
    private var appliedInterval = 0
    private var requestedInterval = 0
    private var changingParameters = false
    private var legacyFallback = false
    private var powerTimer: Job? = null
    private val power = DiscoveryPowerPolicy()
    private val gattConnections = mutableSetOf<BluetoothDevice>()
    @Synchronized fun powerState(interactive: Boolean, constrained: Boolean) {
        power.environment(SystemClock.elapsedRealtime(), interactive, constrained)
        advertise()
    }
    private fun parameters(intervalMillis: Int) = AdvertisingSetParameters.Builder()
        .setLegacyMode(true).setConnectable(true).setScannable(true)
        .setInterval(intervalMillis * 8 / 5).build()

    private fun callback(cycle: Long) = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            if (!current(cycle)) return
            if (status == BluetoothGatt.GATT_SUCCESS) advertise(cycle) else failed(Failure.unsupported)
        }
        override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic) {
            if (!current(cycle)) return
            try {
                val bytes = ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN).putShort((server?.psm ?: 0).toShort()).array()
                if (offset !in 0..bytes.size || characteristic.uuid != PSM) gatt?.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
                else gatt?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, bytes.copyOfRange(offset, bytes.size))
            } catch (_: SecurityException) { failed(Failure.permissionDenied) }
        }
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (!current(cycle)) return
            synchronized(this@BLEPeripheral) {
                if (newState == BluetoothProfile.STATE_CONNECTED) gattConnections.add(device)
                if (newState == BluetoothProfile.STATE_DISCONNECTED) { gattConnections.remove(device); advertise(cycle) }
            }
            if (newState == BluetoothProfile.STATE_CONNECTED && adapter.isLe2MPhySupported) {
                try { gatt?.setPreferredPhy(device, BluetoothDevice.PHY_LE_2M_MASK, BluetoothDevice.PHY_LE_2M_MASK, BluetoothDevice.PHY_OPTION_NO_PREFERRED) }
                catch (_: SecurityException) { failed(Failure.permissionDenied) }
            }
            val channel = synchronized(this@BLEPeripheral) { active.takeIf { device == activeDevice } }
            if (newState == BluetoothProfile.STATE_DISCONNECTED && channel != null) {
                // Close this link only; the session read loop emits its own disconnect event.
                scope.launch { channel.close() }
            }
        }
    }
    private fun current(cycle: Long) = running && generation == cycle
    @Synchronized
    fun start() {
        if (running) return
        if (context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) != PackageManager.PERMISSION_GRANTED) fail(Failure.permissionDenied)
        try {
        if (!adapter.isEnabled || !adapter.isMultipleAdvertisementSupported) fail(Failure.unsupported)
        settings.loadKey()
        running = true
        val cycle = ++generation
        legacyFallback = false
        power.start(SystemClock.elapsedRealtime())
        server = adapter.listenUsingInsecureL2capChannel()
        gatt = manager.openGattServer(context, callback(cycle)) ?: fail(Failure.unsupported)
        val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(BluetoothGattCharacteristic(PSM, BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ))
        if (!gatt!!.addService(service)) fail(Failure.unsupported)
        val listener = server ?: fail(Failure.unsupported)
        acceptor = scope.launch(Dispatchers.IO) {
            while (current(cycle)) {
                val socket = try { listener.accept() } catch (_: Exception) { break }
                if (!current(cycle) || session.connected != null) { socket.close(); continue }
                val raw = BluetoothByteChannel(socket)
                val accepted = synchronized(this@BLEPeripheral) {
                    if (!current(cycle)) false else { active = raw; activeDevice = null; true }
                }
                if (!accepted) { raw.close(); break }
                val timeout = launch { delay(5000); raw.close() }
                try {
                    val auth = Handshake.authenticate(raw, Role.ANDROID, settings.identity, settings.loadKey(), transport = Transport.ble, expectedPeer = settings.mac)
                    timeout.cancel()
                    ensureActive()
                    val valid = synchronized(this@BLEPeripheral) {
                        if (!current(cycle) || active !== raw) false
                        else { settings.mac = auth.peer; activeDevice = socket.remoteDevice; power.connected(); stopAdvertising(); true }
                    }
                    if (!valid) { raw.close(); break }
                    session.installBLE(auth, EncryptedChannel(raw, auth, Transport.ble))
                } catch (cancelled: CancellationException) { raw.close(); throw cancelled }
                catch (_: SecurityException) { raw.close(); if (current(cycle)) failed(Failure.permissionDenied) }
                catch (_: Exception) { raw.close(); if (current(cycle)) failed(Failure.authenticationFailed) }
                finally {
                    timeout.cancel()
                    synchronized(this@BLEPeripheral) {
                        if (current(cycle) && session.connected == null && active === raw) {
                            active = null; activeDevice = null; advertise()
                        }
                    }
                }
            }
        }
        } catch (_: SecurityException) { stop(); fail(Failure.permissionDenied) }
    }
    @Synchronized
    private fun advertise(cycle: Long = generation) {
        if (!current(cycle) || session.connected != null) return
        if (legacyFallback) { advertiseLegacy(cycle); return }
        val now = SystemClock.elapsedRealtime()
        val interval = power.intervalMillis(now) ?: return
        powerTimer?.cancel(); powerTimer = null
        power.nextChange(now)?.let { deadline ->
            powerTimer = scope.launch {
                delay((deadline - SystemClock.elapsedRealtime()).coerceAtLeast(1))
                if (current(cycle)) advertise(cycle)
            }
        }
        try {
            val advertiser = adapter.bluetoothLeAdvertiser ?: return failed(Failure.unsupported)
            if (setCallback != null) {
                if (advertisingSet != null && appliedInterval != interval && !changingParameters && active == null && gattConnections.isEmpty()) {
                    changingParameters = true
                    advertisingSet?.enableAdvertising(false, 0, 0)
                }
                return
            }
            requestedInterval = interval
            val callback = object : AdvertisingSetCallback() {
                private fun valid() = current(cycle) && setCallback === this
                override fun onAdvertisingSetStarted(set: AdvertisingSet?, txPower: Int, status: Int) {
                    synchronized(this@BLEPeripheral) {
                        if (!valid()) return
                        if (status != ADVERTISE_SUCCESS || set == null) { fallbackAdvertising(cycle); return }
                        advertisingSet = set; appliedInterval = requestedInterval
                        advertise(cycle)
                    }
                }
                override fun onAdvertisingEnabled(set: AdvertisingSet, enabled: Boolean, status: Int) {
                    synchronized(this@BLEPeripheral) {
                        if (!valid()) return
                        if (status != ADVERTISE_SUCCESS) { fallbackAdvertising(cycle); return }
                        if (enabled) { changingParameters = false; advertise(cycle) }
                        else if (active != null || gattConnections.isNotEmpty()) {
                            set.enableAdvertising(true, 0, 0)
                        } else {
                            requestedInterval = power.intervalMillis(SystemClock.elapsedRealtime()) ?: return
                            set.setAdvertisingParameters(parameters(requestedInterval))
                        }
                    }
                }
                override fun onAdvertisingParametersUpdated(set: AdvertisingSet, txPower: Int, status: Int) {
                    synchronized(this@BLEPeripheral) {
                        if (!valid()) return
                        if (status != ADVERTISE_SUCCESS) { fallbackAdvertising(cycle); return }
                        appliedInterval = requestedInterval
                        set.enableAdvertising(true, 0, 0)
                    }
                }
            }
            setCallback = callback
            advertiser.startAdvertisingSet(parameters(interval),
                AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE)).build(),
                scanResponse(), null, null, callback)
        } catch (_: SecurityException) { stopAdvertising(); failed(Failure.permissionDenied) }
        catch (_: IllegalArgumentException) { fallbackAdvertising(cycle) }
        catch (_: IllegalStateException) { fallbackAdvertising(cycle) }
    }
    private fun scanResponse(): AdvertiseData {
        val length = try { adapter.name?.toByteArray(Charsets.UTF_8)?.size ?: 0 }
            catch (_: SecurityException) { 0 }
        return AdvertiseData.Builder().setIncludeDeviceName(length in 1..29).build()
    }
    /** Stop discovery first, keeping the established socket alive for GOODBYE. */
    @Synchronized fun prepareStop() {
        running = false
        power.stop()
        stopAdvertising()
        runCatching { server?.close() }; server = null
    }
    @Synchronized
    private fun fallbackAdvertising(cycle: Long) {
        stopAdvertising(); legacyFallback = true
        if (current(cycle)) advertiseLegacy(cycle)
    }
    @Synchronized
    private fun advertiseLegacy(cycle: Long = generation) {
        if (!current(cycle) || session.connected != null || advertising != null) return
        try {
            val advertiser = adapter.bluetoothLeAdvertiser ?: return failed(Failure.unsupported)
            val callback = object : AdvertiseCallback() {
                override fun onStartFailure(errorCode: Int) {
                    synchronized(this@BLEPeripheral) {
                        if (!current(cycle) || advertising !== this) return
                        advertising = null
                        failed(Failure.unsupported)
                    }
                }
            }
            advertising = callback
            advertiser.startAdvertising(
                AdvertiseSettings.Builder().setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER).setConnectable(true).build(),
                AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE)).build(),
                scanResponse(), callback)
        } catch (_: SecurityException) { advertising = null; failed(Failure.permissionDenied) }
    }
    @Synchronized
    private fun stopAdvertising() {
        powerTimer?.cancel(); powerTimer = null
        val previous = setCallback
        setCallback = null; advertisingSet = null; changingParameters = false; appliedInterval = 0
        if (previous != null) {
            try { adapter.bluetoothLeAdvertiser?.stopAdvertisingSet(previous) }
            catch (_: SecurityException) { failed(Failure.permissionDenied) }
        }
        val callback = advertising ?: return
        advertising = null
        try { adapter.bluetoothLeAdvertiser?.stopAdvertising(callback) }
        catch (_: SecurityException) { failed(Failure.permissionDenied) }
    }
    @Synchronized
    fun sessionDisconnected() {
        // A previous session's event must not close a newer connection or handshake.
        if (!running || session.connected != null || (active != null && activeDevice == null)) return
        active?.close(); active = null; activeDevice = null
        power.disconnected(SystemClock.elapsedRealtime())
        if (running) advertise()
    }
    @Synchronized
    fun stop(): Job? {
        running = false; generation++
        power.stop(); gattConnections.clear()
        val pending = acceptor
        pending?.cancel(); acceptor = null
        active?.close(); active = null
        runCatching { server?.close() }; server = null
        stopAdvertising()
        try { gatt?.close() }
        catch (_: SecurityException) { failed(Failure.permissionDenied) }
        gatt = null; activeDevice = null
        return pending
    }
    companion object {
        val SERVICE: UUID = UUID.fromString("3c633de1-c3e5-4e81-a593-9adf6d4a419f")
        val PSM: UUID = UUID.fromString("3c633de1-c3e5-4e81-a593-9adf6d4a41a0")
    }
}

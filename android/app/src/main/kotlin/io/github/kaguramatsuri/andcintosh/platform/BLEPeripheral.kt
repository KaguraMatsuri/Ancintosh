package io.github.kaguramatsuri.andcintosh.platform

import android.Manifest
import android.content.pm.PackageManager
import android.bluetooth.*
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.os.ParcelUuid
import io.github.kaguramatsuri.andcintosh.core.*
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
    private var running = false
    private var active: BluetoothByteChannel? = null
    private var activeDevice: BluetoothDevice? = null
    private val advertising = object : AdvertiseCallback() {
        override fun onStartFailure(errorCode: Int) { failed(Failure.unsupported) }
    }
    private val callback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            if (status == BluetoothGatt.GATT_SUCCESS) advertise() else failed(Failure.unsupported)
        }
        override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic) {
            try {
            val bytes = ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN).putShort((server?.psm ?: 0).toShort()).array()
            if (offset !in 0..bytes.size || characteristic.uuid != PSM) gatt?.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
            else gatt?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, bytes.copyOfRange(offset, bytes.size))
            } catch (_: SecurityException) { failed(Failure.permissionDenied) }
        }
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED && adapter.isLe2MPhySupported) {
                try { gatt?.setPreferredPhy(device, BluetoothDevice.PHY_LE_2M_MASK, BluetoothDevice.PHY_LE_2M_MASK, BluetoothDevice.PHY_OPTION_NO_PREFERRED) }
                catch (_: SecurityException) { failed(Failure.permissionDenied) }
            }
            if (newState == BluetoothProfile.STATE_DISCONNECTED && device == activeDevice) {
                activeDevice = null
                scope.launch { session.disconnect(); if (running) advertise() }
            }
        }
    }
    fun start() {
        if (running) return
        if (context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) != PackageManager.PERMISSION_GRANTED) fail(Failure.permissionDenied)
        try {
        if (!adapter.isEnabled || !adapter.isMultipleAdvertisementSupported) fail(Failure.unsupported)
        settings.loadKey()
        running = true
        server = adapter.listenUsingInsecureL2capChannel()
        gatt = manager.openGattServer(context, callback) ?: fail(Failure.unsupported)
        val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(BluetoothGattCharacteristic(PSM, BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ))
        if (!gatt!!.addService(service)) fail(Failure.unsupported)
        acceptor = scope.launch(Dispatchers.IO) {
            while (running) {
                val socket = try { server?.accept() ?: break } catch (_: Exception) { break }
                if (session.connected != null) { socket.close(); continue }
                val raw = BluetoothByteChannel(socket)
                val timeout = launch { delay(5000); raw.close() }
                try {
                    val auth = Handshake.authenticate(raw, Role.ANDROID, settings.identity, settings.loadKey(), transport = Transport.ble, expectedPeer = settings.mac)
                    timeout.cancel(); settings.mac = auth.peer; active = raw; activeDevice = socket.remoteDevice
                    adapter.bluetoothLeAdvertiser?.stopAdvertising(advertising)
                    session.installBLE(auth, EncryptedChannel(raw, auth, Transport.ble))
                } catch (_: SecurityException) { timeout.cancel(); raw.close(); failed(Failure.permissionDenied) }
                catch (_: Exception) { timeout.cancel(); raw.close(); failed(Failure.authenticationFailed) }
            }
        }
        } catch (_: SecurityException) { stop(); fail(Failure.permissionDenied) }
    }
    private fun advertise() {
        if (!running) return
        try {
        adapter.bluetoothLeAdvertiser?.stopAdvertising(advertising)
        adapter.bluetoothLeAdvertiser?.startAdvertising(
            AdvertiseSettings.Builder().setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER).setConnectable(true).build(),
            AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE)).build(),
            AdvertiseData.Builder().setIncludeDeviceName(true).build(), advertising)
        } catch (_: SecurityException) { failed(Failure.permissionDenied) }
    }
    fun stop() {
        running = false; acceptor?.cancel(); active?.close(); active = null
        runCatching { server?.close() }; server = null
        try { gatt?.close(); adapter.bluetoothLeAdvertiser?.stopAdvertising(advertising) }
        catch (_: SecurityException) { failed(Failure.permissionDenied) }
        gatt = null; activeDevice = null
    }
    companion object {
        val SERVICE: UUID = UUID.fromString("3c633de1-c3e5-4e81-a593-9adf6d4a419f")
        val PSM: UUID = UUID.fromString("3c633de1-c3e5-4e81-a593-9adf6d4a41a0")
    }
}

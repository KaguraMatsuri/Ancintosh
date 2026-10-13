package io.github.kaguramatsuri.ancintosh.platform

import android.content.Context
import android.net.ConnectivityManager
import android.net.InetAddresses
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import io.github.kaguramatsuri.ancintosh.core.*
import java.net.InetSocketAddress
import java.net.Inet6Address
import java.net.NetworkInterface
import java.net.Socket
import kotlinx.coroutines.*

class SocketByteChannel(private val socket: Socket) : ByteChannel {
    override suspend fun readExactly(count: Int): ByteArray = withContext(Dispatchers.IO) {
        if (count < 0 || count > Wire.MAX_PLAINTEXT + 16) fail(Failure.invalidFrame)
        val bytes = ByteArray(count); var offset = 0
        while (offset < count) { val n = socket.getInputStream().read(bytes, offset, count - offset); if (n < 0) fail(Failure.peerUnavailable); offset += n }
        bytes
    }
    override suspend fun write(data: ByteArray) = withContext(Dispatchers.IO) { socket.getOutputStream().write(data) }
    override fun close() { runCatching { socket.close() } }
}

class TCPClient(context: Context, private val scope: CoroutineScope, private val session: SessionController) {
    private val manager = context.getSystemService(ConnectivityManager::class.java)
    private var network: Network? = null
    private var recovery: Job? = null
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            this@TCPClient.network = network
            recovery?.cancel(); recovery = scope.launch { delay(5000); session.requestUpgrade() }
        }
        override fun onLost(network: Network) {
            if (this@TCPClient.network == network) {
                this@TCPClient.network = null; recovery?.cancel(); scope.launch { session.tcpLost() }
            }
        }
    }
    fun start() {
        manager.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), callback)
    }
    fun stop() { recovery?.cancel(); runCatching { manager.unregisterNetworkCallback(callback) } }
    suspend fun connect(event: SyncEvent.Offer) {
        val wifi = network ?: return
        for ((host, port) in event.addresses) {
            if (port !in 1..65535) continue
            var address = runCatching { InetAddresses.parseNumericAddress(host.substringBefore('%')) }.getOrNull() ?: continue
            if (address.isAnyLocalAddress || address.isLoopbackAddress || address.isMulticastAddress) continue
            if (address is Inet6Address && address.isLinkLocalAddress) {
                val name = manager.getLinkProperties(wifi)?.interfaceName ?: continue
                val iface = NetworkInterface.getByName(name) ?: continue
                address = Inet6Address.getByAddress(null, address.address, iface)
            }
            val socket = wifi.socketFactory.createSocket()
            socket.tcpNoDelay = true; socket.soTimeout = 5000
            val channel = SocketByteChannel(socket)
            try {
                withContext(Dispatchers.IO) { socket.connect(InetSocketAddress(address, port), 1000) }
                val auth = Handshake.authenticate(channel, Role.ANDROID, session.identity, event.binding, event.context, Transport.tcp, event.peer)
                socket.soTimeout = 0
                session.installTCP(event.context, EncryptedChannel(channel, auth, Transport.tcp)); return
            } catch (_: Exception) { channel.close() }
        }
    }
}

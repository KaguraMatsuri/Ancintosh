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
    @Volatile private var network: Network? = null
    @Volatile private var registered = false
    private var recovery: Job? = null
    private var connecting: Job? = null
    private val sockets = java.util.concurrent.ConcurrentHashMap.newKeySet<Socket>()
    private var backoff = RecoveryBackoff()
    private fun recover(reset: Boolean = false) = synchronized(this) {
        if (reset) { recovery?.cancel(); recovery = null; backoff = RecoveryBackoff() }
        if (!registered || network == null || recovery?.isActive == true) return@synchronized
        recovery = scope.launch {
            try {
                while (registered && network != null && session.permitsWifi) {
                    if (session.usingTCP) { backoff = RecoveryBackoff(); return@launch }
                    delay(backoff.nextMillis())
                    if (session.permitsWifi) session.requestUpgrade()
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { }
        }
    }
    fun sessionChanged() {
        if (session.permitsWifi && !session.usingTCP) recover()
        else synchronized(this) {
            recovery?.cancel(); recovery = null; backoff = RecoveryBackoff()
            if (!session.permitsWifi) { connecting?.cancel(); sockets.forEach { runCatching { it.close() } } }
        }
    }
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            this@TCPClient.network = network
            recover(reset = true)
        }
        override fun onLost(network: Network) {
            if (this@TCPClient.network == network) {
                this@TCPClient.network = null; recovery?.cancel(); connecting?.cancel()
                sockets.forEach { runCatching { it.close() } }
                scope.launch { session.tcpLost() }
            }
        }
    }
    @Synchronized fun start() {
        if (registered) return
        registered = true
        try { manager.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), callback) }
        catch (error: Exception) { registered = false; throw error }
    }
    @Synchronized fun stop() {
        registered = false; network = null
        recovery?.cancel(); recovery = null; connecting?.cancel(); connecting = null
        sockets.forEach { runCatching { it.close() } }; sockets.clear()
        runCatching { manager.unregisterNetworkCallback(callback) }
    }
    suspend fun connect(event: SyncEvent.Offer) {
        val job = currentCoroutineContext()[Job]
        synchronized(this) {
            if (!registered || connecting?.isActive == true) return
            connecting = job
        }
        try { attempt(event) }
        finally { synchronized(this) { connecting = null }; recover() }
    }
    private suspend fun attempt(event: SyncEvent.Offer) = withTimeout(5000) {
        val wifi = network ?: return@withTimeout
        for ((host, port) in event.addresses) {
            if (port !in 1..65535) continue
            var address = runCatching { InetAddresses.parseNumericAddress(host.substringBefore('%')) }.getOrNull() ?: continue
            if (address.isAnyLocalAddress || address.isLoopbackAddress || address.isMulticastAddress) continue
            if (address is Inet6Address && address.isLinkLocalAddress) {
                val name = manager.getLinkProperties(wifi)?.interfaceName ?: continue
                val iface = NetworkInterface.getByName(name) ?: continue
                address = Inet6Address.getByAddress(null, address.address, iface)
            }
            currentCoroutineContext().ensureActive()
            if (!registered || network != wifi || !session.permitsWifi) return@withTimeout
            val socket = wifi.socketFactory.createSocket()
            sockets.add(socket)
            // Closing the socket interrupts blocking connect/read on cancellation.
            val closer = launch(start = CoroutineStart.UNDISPATCHED) {
                try { awaitCancellation() } finally { if (sockets.contains(socket)) runCatching { socket.close() } }
            }
            socket.tcpNoDelay = true; socket.soTimeout = 5000
            val channel = SocketByteChannel(socket)
            try {
                withContext(Dispatchers.IO) { socket.connect(InetSocketAddress(address, port), 1000) }
                val auth = Handshake.authenticate(channel, Role.ANDROID, session.identity, event.binding, event.context, Transport.tcp, event.peer)
                socket.soTimeout = 0
                ensureActive()
                if (!registered || network != wifi) fail(Failure.peerUnavailable)
                session.installTCP(event.context, EncryptedChannel(channel, auth, Transport.tcp))
                sockets.remove(socket)
                // The installed encrypted channel owns this socket from this point.
                closer.cancel()
                return@withTimeout
            } catch (cancelled: CancellationException) { channel.close(); throw cancelled }
            catch (_: Exception) { channel.close() }
            finally { sockets.remove(socket); closer.cancel() }
        }
    }
}

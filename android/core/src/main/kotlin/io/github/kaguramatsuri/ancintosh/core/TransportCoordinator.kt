package io.github.kaguramatsuri.ancintosh.core

class TransportCoordinator {
    var localWifi = true; private set
    var remoteWifi = true; private set
    var bleAuthenticated = false; private set
    var current = Transport.ble; private set
    private var availableSince: Long? = null
    fun authenticated(value: Boolean) { bleAuthenticated = value; if (!value) { current = Transport.ble; availableSince = null } }
    fun preference(local: Boolean? = null, remote: Boolean? = null) {
        local?.let { localWifi = it }; remote?.let { remoteWifi = it }
        if (!localWifi || !remoteWifi) { current = Transport.ble; availableSince = null }
    }
    fun path(available: Boolean, now: Long) {
        if (!available) { current = Transport.ble; availableSince = null }
        else if (localWifi && remoteWifi && availableSince == null) availableSince = now
    }
    fun shouldUpgrade(now: Long): Boolean = bleAuthenticated && localWifi && remoteWifi && current == Transport.ble && availableSince?.let { now - it >= 5000 } == true
    fun activateTCP() { if (!bleAuthenticated || !localWifi || !remoteWifi) fail(Failure.peerUnavailable); current = Transport.tcp }
    fun tcpLost() { current = Transport.ble; availableSince = null }
}

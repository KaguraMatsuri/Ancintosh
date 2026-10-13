package io.github.kaguramatsuri.andcintosh.core

/** Monotonic deadlines; the radio sends advertisements without an application timer per packet. */
class DiscoveryPowerPolicy {
    private var running = false
    private var connected = false
    private var interactive = true
    private var constrained = false
    private var recoveryUntil = 0L
    private var boostUntil = 0L
    fun start(now: Long) { running = true; connected = false; recoveryUntil = now + 60_000; boostUntil = 0 }
    fun stop() { running = false; connected = false; recoveryUntil = 0; boostUntil = 0 }
    fun connected() { connected = true; recoveryUntil = 0; boostUntil = 0 }
    fun disconnected(now: Long) {
        if (!connected) return
        connected = false; recoveryUntil = now + 60_000; boostUntil = 0
    }
    fun environment(now: Long, interactive: Boolean, constrained: Boolean) {
        if (interactive && !this.interactive && !constrained) boostUntil = now + 30_000
        if (!interactive || constrained) boostUntil = 0
        this.interactive = interactive; this.constrained = constrained
    }
    fun intervalMillis(now: Long): Int? {
        if (!running || connected) return null
        return if (!constrained && now < maxOf(recoveryUntil, boostUntil)) 1_000 else 5_000
    }
    fun nextChange(now: Long): Long? = maxOf(recoveryUntil, boostUntil)
        .takeIf { intervalMillis(now) == 1_000 && it > now }
}

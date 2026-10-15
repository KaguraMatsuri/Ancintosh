package io.github.kaguramatsuri.ancintosh.core

class RecoveryBackoff {
    private var attempt = 0
    @Synchronized fun nextMillis(): Long {
        val delays = longArrayOf(5_000, 15_000, 30_000, 60_000)
        val value = delays[attempt]
        attempt = minOf(attempt + 1, delays.lastIndex)
        return value
    }
}

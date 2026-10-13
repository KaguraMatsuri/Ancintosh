package io.github.kaguramatsuri.andcintosh.core

import kotlin.test.*

class DiscoveryPowerPolicyTests {
    @Test fun recoveryAndTemporaryBoostExpireWithoutPolling() {
        val policy = DiscoveryPowerPolicy(); policy.start(0)
        assertEquals(1_000, policy.intervalMillis(59_999)); assertEquals(60_000, policy.nextChange(0))
        assertEquals(5_000, policy.intervalMillis(60_000)); assertNull(policy.nextChange(60_000))
        policy.environment(61_000, false, false); policy.environment(62_000, true, false)
        assertEquals(1_000, policy.intervalMillis(80_000)); assertEquals(5_000, policy.intervalMillis(92_000))
        policy.environment(90_000, true, false) // duplicate screen event cannot extend the lease
        assertEquals(5_000, policy.intervalMillis(92_000))
    }
    @Test fun constrainedConnectionAndStopTakePrecedence() {
        val policy = DiscoveryPowerPolicy(); policy.start(0)
        policy.environment(1, true, true); assertEquals(5_000, policy.intervalMillis(2)); assertNull(policy.nextChange(2))
        policy.connected(); assertNull(policy.intervalMillis(3))
        policy.disconnected(100); policy.environment(100, true, false)
        assertEquals(1_000, policy.intervalMillis(101))
        policy.disconnected(50_000); assertEquals(5_000, policy.intervalMillis(60_100))
        policy.stop(); policy.environment(70_000, true, false); assertNull(policy.intervalMillis(70_000))
    }
}

package io.github.kaguramatsuri.andcintosh.core

import java.io.File
import org.json.JSONObject
import kotlin.test.*

class ConfigurationTests {
    private fun fixture() = JSONObject(File("../../protocol/fixtures/configuration.json").readText()).getJSONObject("configuration")
    @Test fun sharedConfigurationFixturePreservesDeviceAndPolicyFields() {
        val value = ManagedConfiguration.decode(fixture())
        assertEquals(7, value.revision)
        assertEquals(DeviceKind.pad, value.device?.kind)
        assertEquals(value.primary, value.device?.renameRequest)
        assertEquals(30, value.lockDelaySeconds)
        assertFalse(value.device!!.wifi)
        val record = Record(RecordKind.CONFIGURATION, metadata = fixture().toString().toByteArray())
        assertEquals(RecordKind.CONFIGURATION, Record.decode(record.encode()).kind)
    }
    @Test fun invalidAuthorityAndPolicyAreRejected() {
        for (mutate in listOf<(JSONObject) -> Unit>(
            { it.put("revision", -1) }, { it.put("lockDelaySeconds", 0) },
            { it.getJSONObject("mac").put("kind", "phone") },
            { it.getJSONObject("device").put("priority", -1) })) {
            val value = fixture(); mutate(value)
            assertFailsWith<ProtocolException> { ManagedConfiguration.decode(value) }
        }
    }
}

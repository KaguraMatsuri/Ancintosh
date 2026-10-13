import Foundation
import Testing
@testable import AncintoshCore

@Test func configurationWireFixturePreservesDeviceAndPolicyFields() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { root.deleteLastPathComponent() }
    let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/configuration.json"))) as! [String: Any]
    let reportData = try JSONSerialization.data(withJSONObject: fixture["report"]!)
    let report = try Wire.decodeJSON(DeviceInformation.self, reportData)
    #expect(report.kind == .pad && !report.wifi && report.renameRequest != nil)
    let bytes = try JSONSerialization.data(withJSONObject: fixture["configuration"]!)
    let value = try Wire.decodeJSON(ManagedConfiguration.self, bytes)
    #expect(value.revision == 7 && value.device?.name == "Pad" && value.device?.priority == 1)
    #expect(value.device?.renameRequest == value.primary && value.mac.kind == .mac && value.lockDelaySeconds == 30)
    for (kind, metadata) in [(RecordKind.deviceInformation, reportData), (.configuration, bytes)] {
        let decoded = try Record.decode(Record(kind, metadata: metadata).encoded())
        #expect(decoded.kind == kind && decoded.metadata == metadata)
    }
}

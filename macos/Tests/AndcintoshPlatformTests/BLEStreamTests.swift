import Foundation
import Testing
import AndcintoshCore
@testable import AndcintoshPlatform

@Test func closedBLEStreamRejectsLateOperations() async {
    let channel = StreamByteChannel(input: InputStream(data: Data()), output: OutputStream.toMemory(), keeper: NSObject())
    await channel.close()
    do { try await channel.write(Data([1])); Issue.record("Closed stream accepted a write") }
    catch let error as ProtocolFailure { #expect(error == .invalidFrame || error == .peerUnavailable) }
    catch { Issue.record("Unexpected stream error: \(error)") }
    await #expect(throws: ProtocolFailure.invalidFrame) { try await channel.readExactly(1) }
    await channel.close()
}

#if DEBUG
import AncintoshCore
import AncintoshPlatform
import Foundation

@MainActor enum TopologyDemo {
    static let clipboardPhone = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let filePhone = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let offlinePhone = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    static let pad = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
    static func makeRuntime() throws -> MacRuntime {
        let names = [clipboardPhone: "Galaxy S24 Ultra", filePhone: "Galaxy S21 Ultra", pad: "Galaxy Tab S8 Plus", offlinePhone: "Galaxy Note 7"]
        var configuration = MacConfiguration()
        configuration.name = "Mac"
        configuration.peers = [clipboardPhone, filePhone, pad, offlinePhone].map { id in
            var profile = PeerProfile(id: id, identity: id, name: names[id])
            profile.kind = id == pad ? .pad : .phone
            profile.wifi = id == clipboardPhone
            return profile
        }
        return try MacRuntime(demonstration: configuration, traffic: ConnectionTraffic())
    }
}
#endif

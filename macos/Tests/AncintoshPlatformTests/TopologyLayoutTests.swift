import Foundation
import Testing
@testable import AncintoshPlatform

@Test func topologyKeepsDevicesInBoundsAndApartAcrossCountsAndWidths() {
    for count in 1...24 {
        let ids = (1...count).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
        for width in [500.0, 747, 1087] {
            for stacked in [false, true] {
                let saved = stacked ? Dictionary(uniqueKeysWithValues: ids.map { ($0, NodePosition(x: 0.5, y: 0.5)) }) : [:]
                let layout = TopologyLayout.arrange(ids: ids, saved: saved, size: CGSize(width: width, height: 644))
                #expect(layout.positions.count == count)
                let w = min(132, max(96, layout.size.width * 0.23))
                let macW = min(124, max(104, layout.size.width * 0.22))
                var rectangles = [CGRect(x: (layout.size.width - macW)/2, y: (layout.size.height - 128)/2, width: macW, height: 128)]
                for id in ids {
                    guard let position = layout.positions[id] else { continue }
                    #expect((0...1).contains(position.x) && (0...1).contains(position.y))
                    let rect = CGRect(x: position.x * layout.size.width - w/2, y: position.y * layout.size.height - 104, width: w, height: 208)
                    #expect(rect.minX >= 0 && rect.maxX <= layout.size.width && rect.minY >= 0 && rect.maxY <= layout.size.height)
                    #expect(!rectangles.contains { rect.insetBy(dx: -5, dy: -5).intersects($0.insetBy(dx: -5, dy: -5)) })
                    rectangles.append(rect)
                }
                let repeated = TopologyLayout.arrange(ids: ids, saved: layout.positions, size: layout.size)
                #expect(repeated.size == layout.size)
                for id in ids {
                    #expect(abs((layout.positions[id]?.x ?? 0) - (repeated.positions[id]?.x ?? 0)) < 0.000001)
                    #expect(abs((layout.positions[id]?.y ?? 0) - (repeated.positions[id]?.y ?? 0)) < 0.000001)
                }
            }
        }
    }
}

@Test func recoveryDelayIsBoundedAndAResetRestartsTheWindow() {
    var backoff = RecoveryBackoff()
    let expected: [Duration] = [.seconds(5), .seconds(15), .seconds(30), .seconds(60)]
    for index in 0..<100 { #expect(backoff.next() == expected[min(index, 3)]) }
    backoff = RecoveryBackoff()
    #expect(backoff.next() == .seconds(5))
}

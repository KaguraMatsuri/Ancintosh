import Foundation

/// Geometry shared by the native canvas and its bounds/collision checks.
public enum TopologyLayout {
    public static func minimumSize(count: Int) -> CGSize {
        CGSize(width: 500, height: count <= 4 ? 644 : max(644, CGFloat((count + 1) / 2) * 232 + 32))
    }
    public static func initialPosition(_ id: UUID, ids: [UUID], size: CGSize) -> CGPoint {
        let sorted = ids.sorted { $0.uuidString < $1.uuidString }
        let index = sorted.firstIndex(of: id) ?? 0
        if sorted.count <= 4 {
            let angle = sorted.count == 1 ? Double.pi / 2 : Double.pi + Double(index) * 2 * .pi / Double(max(1, sorted.count))
            return CGPoint(x: size.width / 2 + cos(angle) * max(0, size.width / 2 - nodeWidth(size) / 2 - 14),
                           y: size.height / 2 + sin(angle) * max(0, size.height / 2 - 104 - 14))
        }
        let rows = (sorted.count + 1) / 2
        let first = (size.height - CGFloat(rows - 1) * 232) / 2
        return CGPoint(x: index % 2 == 0 ? nodeWidth(size) / 2 + 14 : size.width - nodeWidth(size) / 2 - 14,
                       y: first + CGFloat(index / 2) * 232)
    }
    public static func arrange(ids: [UUID], saved: [UUID: NodePosition], size original: CGSize,
                               preferred: UUID? = nil) -> (size: CGSize, positions: [UUID: NodePosition]) {
        var ids = Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
        if let preferred, let index = ids.firstIndex(of: preferred) { ids.remove(at: index); ids.insert(preferred, at: 0) }
        let minimum = minimumSize(count: ids.count)
        var size = CGSize(width: max(minimum.width, original.width), height: max(minimum.height, original.height))
        let targets = Dictionary(uniqueKeysWithValues: ids.map { id in
            let point = saved[id].map { CGPoint(x: $0.x * original.width, y: $0.y * original.height) }
                ?? initialPosition(id, ids: ids, size: size)
            return (id, point)
        })
        while true {
            let width = nodeWidth(size), pitch = CGFloat(232)
            let macWidth = min(124, max(104, size.width * 0.22))
            var occupied = [CGRect(x: (size.width - macWidth) / 2, y: (size.height - 128) / 2, width: macWidth, height: 128)]
            var result: [UUID: NodePosition] = [:]
            let rows = max(2, Int((size.height - 28) / pitch))
            let first = (size.height - CGFloat(rows - 1) * pitch) / 2
            var grid: [CGPoint] = []
            for row in 0..<rows {
                for x in [width / 2 + 14, size.width - width / 2 - 14] {
                    grid.append(CGPoint(x: x, y: first + CGFloat(row) * pitch))
                }
            }
            for id in ids {
                let raw = targets[id]!
                let target = CGPoint(x: min(max(width / 2 + 8, raw.x.isFinite ? raw.x : size.width / 2), size.width - width / 2 - 8),
                                     y: min(max(112, raw.y.isFinite ? raw.y : size.height / 2), size.height - 112))
                var candidates = [target] + grid
                for rect in occupied {
                    candidates.append(CGPoint(x: rect.minX - width / 2 - 12, y: target.y))
                    candidates.append(CGPoint(x: rect.maxX + width / 2 + 12, y: target.y))
                    candidates.append(CGPoint(x: target.x, y: rect.minY - 116))
                    candidates.append(CGPoint(x: target.x, y: rect.maxY + 116))
                }
                for dx in [-1, 0, 1] {
                    for dy in [-1, 0, 1] where dx != 0 || dy != 0 {
                        candidates.append(CGPoint(x: target.x + CGFloat(dx) * (width + 12), y: target.y + CGFloat(dy) * 220))
                    }
                }
                candidates.sort {
                    let a = hypot($0.x - target.x, $0.y - target.y), b = hypot($1.x - target.x, $1.y - target.y)
                    return a == b ? ($0.y == $1.y ? $0.x < $1.x : $0.y < $1.y) : a < b
                }
                guard let point = candidates.first(where: { candidate in
                    guard candidate.x >= width / 2 + 8, candidate.x <= size.width - width / 2 - 8,
                          candidate.y >= 112, candidate.y <= size.height - 112 else { return false }
                    // Ignore subpixel round-off when saved normalized coordinates touch the gap boundary.
                    let inset = CGFloat(-6 + 0.000001)
                    let rect = CGRect(x: candidate.x - width / 2, y: candidate.y - 104, width: width, height: 208).insetBy(dx: inset, dy: inset)
                    return !occupied.contains { rect.intersects($0.insetBy(dx: inset, dy: inset)) }
                }) else { break }
                occupied.append(CGRect(x: point.x - width / 2, y: point.y - 104, width: width, height: 208))
                result[id] = NodePosition(x: point.x / size.width, y: point.y / size.height)
            }
            if result.count == ids.count { return (size, result) }
            size.height += pitch * 2
        }
    }
    private static func nodeWidth(_ size: CGSize) -> CGFloat { min(132, max(96, size.width * 0.23)) }
}

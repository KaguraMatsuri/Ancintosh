import Foundation

struct RecoveryBackoff: Sendable {
    private var attempt = 0
    mutating func next() -> Duration {
        let seconds = [5, 15, 30, 60]
        let value = seconds[attempt]
        attempt = min(attempt + 1, seconds.count - 1)
        return .seconds(value)
    }
}

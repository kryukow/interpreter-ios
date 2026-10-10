import Foundation

struct AudioBudget: Codable {
    static let dollarsPerMinute = 0.034
    var remaining: Double?
    private(set) var spent = 0.0
    private(set) var seconds = 0.0
    mutating func record(bytes: Int) {
        guard bytes > 0 else { return }
        let duration = Double(bytes) / Double(RealtimeProtocol.bytesPerSecond)
        let cost = duration / 60 * Self.dollarsPerMinute
        seconds += duration; spent += cost
        if let value = remaining { remaining = value - cost }
    }
    mutating func setRemaining(_ text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(clean), value.isFinite, value >= 0, value <= 1_000_000 else { return false }
        remaining = value; return true
    }
}

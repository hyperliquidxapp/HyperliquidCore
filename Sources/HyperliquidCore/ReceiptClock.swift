/// Process-local receipt age, including time spent asleep. Never persisted.
public enum ReceiptClock {
    private static let origin = ContinuousClock.now
    public static var now: Double {
        let duration = origin.duration(to: ContinuousClock.now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1_000_000_000_000_000_000
    }
}

/// Require consecutive idle samples from the same call app. An unreadable sample,
/// a reconnect, or a long gap (such as sleep) starts the grace period over.
struct CallEndWatch {
    let appID: String
    private var idleSince: ContinuousClock.Instant?
    private var lastSample: ContinuousClock.Instant?
    var isPending: Bool { idleSince != nil }

    init(appID: String) { self.appID = appID }

    mutating func update(active: Bool?, at now: ContinuousClock.Instant) -> Bool {
        if let lastSample, lastSample.duration(to: now) > .seconds(5) { idleSince = nil }
        lastSample = now
        guard active == false else {
            idleSince = nil
            return false
        }
        guard let idleSince else {
            self.idleSince = now
            return false
        }
        return idleSince.duration(to: now) >= .seconds(12)
    }
}

import Foundation
import Testing
@testable import BetterWispr
import BetterWisprCore

@Test func idleCallStopsAfterGracePeriod() {
    var watch = CallEndWatch(appID: "call")
    let start = ContinuousClock.now
    for second in stride(from: 0, to: 12, by: 2) {
        let shouldStop = watch.update(active: false, at: start.advanced(by: .seconds(second)))
        #expect(!shouldStop)
        #expect(watch.isPending)
    }
    let afterGrace = watch.update(active: false, at: start.advanced(by: .seconds(12)))
    #expect(afterGrace)
}

@Test(arguments: [true, nil] as [Bool?])
func activeOrUnknownAudioCancelsPendingStop(activity: Bool?) {
    var watch = CallEndWatch(appID: "call")
    let start = ContinuousClock.now
    for second in stride(from: 0, through: 10, by: 2) {
        let shouldStop = watch.update(active: false, at: start.advanced(by: .seconds(second)))
        #expect(!shouldStop)
    }
    let interrupted = watch.update(active: activity, at: start.advanced(by: .seconds(12)))
    #expect(!interrupted)
    #expect(!watch.isPending)
    let restarted = watch.update(active: false, at: start.advanced(by: .seconds(14)))
    #expect(!restarted)
    let afterSleep = watch.update(active: false, at: start.advanced(by: .seconds(90)))
    #expect(!afterSleep)
}

@MainActor @Test func onlyAssociateAnUnambiguousCallAtStart() {
    let zoom = DetectedMeeting(platform: .zoom, appID: "us.zoom.xos")
    let browser = DetectedMeeting(platform: .googleMeet, appID: "com.google.Chrome")
    func source(_ prompt: DetectedMeeting?, _ apps: [String]) -> String? {
        MeetingDetector.sourceApp(for: prompt, recording: apps) { _ in ["Google Meet"] }
    }
    #expect(source(nil, []) == nil)
    #expect(source(nil, [zoom.appID]) == zoom.appID)
    #expect(source(nil, [zoom.appID, browser.appID]) == nil)
    #expect(source(browser, [zoom.appID, browser.appID]) == browser.appID)
    #expect(source(browser, [zoom.appID]) == nil)
    #expect(MeetingDetector.sourceApp(for: nil, recording: [browser.appID], windowTitles: { _ in [] }) == nil)
}

@Test func oldSettingsEnableCallEndStoppingAndOptOutPersists() throws {
    let current = try JSONEncoder().encode(AppSettings())
    var legacy = try #require(JSONSerialization.jsonObject(with: current) as? [String: Any])
    legacy.removeValue(forKey: "stopAfterCall")
    let data = try JSONSerialization.data(withJSONObject: legacy)
    var settings = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(settings.stopAfterCall)
    settings.stopAfterCall = false
    let saved = try JSONEncoder().encode(settings)
    #expect(try !JSONDecoder().decode(AppSettings.self, from: saved).stopAfterCall)
}

@MainActor @Test func callEndFinishesTheRightRecordingAndSavesItsNote() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    let note = Meeting(notes: "Keep this thought", modelName: "Test", language: "en")
    try store.save(note)
    let model = MeetingModel(store: store)
    model.notesSettings.notesSelection = .connection(UUID())
    let run = MeetingRun(meetingID: note.id, phase: .recording)
    model.runs[note.id] = run
    let start = ContinuousClock.now
    func sampleIdle(_ run: MeetingRun) {
        for second in stride(from: 0, through: 12, by: 2) {
            model.updateCallActivity(false, for: run, at: start.advanced(by: .seconds(second)))
        }
    }
    sampleIdle(run)
    #expect(model.capturing === run)
    let stale = MeetingRun(meetingID: UUID(), phase: .recording)
    stale.callEnd = CallEndWatch(appID: "call")
    sampleIdle(stale)
    #expect(model.capturing === run)
    run.callEnd = CallEndWatch(appID: "call")
    sampleIdle(run)
    #expect(run.phase == .finishing)
    await run.work?.value
    #expect(!model.isActive(note.id))
    let saved = try #require(store.load().meetings.first)
    #expect(saved.notes == note.notes)
    #expect(saved.duration > 0)
}

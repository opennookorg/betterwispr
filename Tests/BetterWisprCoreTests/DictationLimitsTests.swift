import AVFoundation
import Foundation
import Testing
@testable import BetterWisprCore

@Test func theHardStopComesFromFramesAtTheActualSampleRateAndStaysUnderTheOverflow() {
    #expect(DictationLimits.maximumFrames < AVAudioFramePosition(UInt32.max))
    #expect(DictationLimits.maximumDuration(sampleRate: 48_000) == 89_128.96)
    #expect(DictationLimits.maximumDuration(sampleRate: 96_000) == 44_564.48)
    #expect(DictationLimits.maximumDuration(sampleRate: 16_000) == 267_386.88)
}

@Test func remindersCountWholeHours() {
    #expect(DictationLimits.reminderHour(after: 3599) == 0)
    #expect(DictationLimits.reminderHour(after: 3600) == 1)
    #expect(DictationLimits.reminderHour(after: 3 * 3600 + 5) == 3)
}

@Test func onlyLongDictationsAskAndOnlyWhenTheyLeaveTheMacOrPaste() {
    let long = DictationLimits.confirmationDuration
    #expect(DictationLimits.asksBeforeSending(duration: long, isOnDevice: false))
    #expect(!DictationLimits.asksBeforeSending(duration: long - 1, isOnDevice: false))
    #expect(!DictationLimits.asksBeforeSending(duration: long, isOnDevice: true))
    #expect(DictationLimits.asksBeforePasting(duration: long, autoPaste: true))
    #expect(!DictationLimits.asksBeforePasting(duration: long - 1, autoPaste: true))
    #expect(!DictationLimits.asksBeforePasting(duration: long, autoPaste: false))
}

@Test func theWriterStopsAtItsFrameLimitAndKeepsWhatItCaptured() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("limit.caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
    buffer.frameLength = 4_800
    buffer.floatChannelData?[0].update(repeating: 0.5, count: 4_800)
    let writer = try RecordingWriter(url: url, format: format, threshold: 0.002, frameLimit: 9_600)

    #expect(!writer.write(buffer).isEmpty)
    #expect(!writer.reachedFrameLimit)
    #expect(!writer.write(buffer).isEmpty)
    #expect(writer.reachedFrameLimit)
    #expect(writer.write(buffer).isEmpty)

    let result = writer.finish()
    #expect(result.duration == 0.2)
    #expect(result.hasSpeech)
    #expect(result.error == nil)
    #expect(try AVAudioFile(forReading: url).length == 9_600)
}

@Test @MainActor func theStartupSweepRemovesOnlyOldAbandonedRecordings() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let now = Date()
    func file(_ name: String, age: TimeInterval) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("audio".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }
    let day: TimeInterval = 24 * 3600
    let abandoned = try file("betterwispr-\(UUID().uuidString).caf", age: day + 60)
    let kept = [
        try file("betterwispr-\(UUID().uuidString).caf", age: day - 60),
        try file("betterwispr-warm-up.caf", age: day * 2),
        try file("betterwispr-warm-up-\(UUID().uuidString).caf", age: day * 2),
        try file("betterwispr-meeting-\(UUID().uuidString).caf", age: day * 2),
        try file("betterwispr-\(UUID().uuidString).wav", age: day * 2),
    ]

    AudioRecorder.removeLeftovers(in: folder, now: now)

    #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    for url in kept { #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)") }
}

import CoreGraphics
import Testing
@testable import BetterWispr

@MainActor
@Test func restingCapsuleOnlyTakesThePointerNearTheVisiblePill() {
    let hover = CapsuleHover()
    hover.update(regions: [.surface: CGRect(x: 202, y: 218, width: 36, height: 6)])

    hover.move(to: CGPoint(x: 220, y: 221))
    #expect(hover.isHovering)
    hover.move(to: CGPoint(x: 155, y: 200))
    #expect(hover.isHovering)

    for outside in [CGPoint(x: 20, y: 221), CGPoint(x: 420, y: 230), CGPoint(x: 220, y: 120), CGPoint(x: 220, y: 20), CGPoint(x: 150, y: 221)] {
        hover.move(to: outside)
        #expect(!hover.isHovering, "\(outside)")
    }
    hover.move(to: nil)
    #expect(!hover.isHovering)
}

@MainActor
@Test func recordingCapsuleTakesThePointerOverThePillButNotTheEmptyPanel() {
    let hover = CapsuleHover()
    let pill = CGRect(x: 150, y: 184, width: 140, height: 40)
    hover.update(regions: [.surface: pill, .dictation: CGRect(x: 250, y: 188, width: 32, height: 32)])

    hover.move(to: CGPoint(x: 260, y: 200))
    #expect(hover.isHovering)
    #expect(hover.target == .dictation)

    hover.move(to: CGPoint(x: 60, y: 200))
    #expect(!hover.isHovering)
    #expect(hover.target == nil)
    hover.move(to: CGPoint(x: 220, y: 100))
    #expect(!hover.isHovering)
}

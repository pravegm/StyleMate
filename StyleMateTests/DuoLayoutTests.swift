import CoreGraphics
import Testing
@testable import StyleMate

/// The fold FoldAwareSplit and Profile split at: the active one half-open, the inactive one open flat, none on
/// the cover or without a hinge. Values are the Duo simulator's (duo.yml): a 40 pt band at x 456-496 of a
/// 951 x 669 pt inner display, reported flat and half-open alike.
struct DuoLayoutTests {

    private static let fold = CGRect(x: 456, y: 0, width: 40, height: 669)

    private func state(_ hinge: DuoHingeState, crease: CGRect? = DuoLayoutTests.fold, active: Bool = false) -> DuoLayoutState {
        var s = DuoLayoutState()
        s.hinge = hinge
        s.creaseInGlobal = crease
        s.isCreaseActive = active
        s.isWideLayout = crease != nil
        s.windowSize = crease != nil ? CGSize(width: 951, height: 669) : CGSize(width: 466, height: 678)
        return s
    }

    @Test func flatUsesTheInactiveFold() {
        let s = state(.fullyOpen)
        #expect(s.posture == .flat)
        // A full-width pane 16 pt in from the window edge: the band in its own coordinates.
        #expect(s.foldBand(in: CGRect(x: 16, y: 0, width: 919, height: 669)) == CGRect(x: 440, y: 0, width: 40, height: 669))
        // The active-only reading stays nil flat (DuoCreaseReader's contract).
        #expect(s.crease(in: CGRect(x: 0, y: 0, width: 951, height: 669)) == nil)
    }

    @Test func halfOpenBookUsesTheActiveFold() {
        let s = state(.partiallyOpen, active: true)
        #expect(s.posture == .book)
        let frame = CGRect(x: 0, y: -100_000, width: 951, height: 200_000)
        #expect(s.foldBand(in: frame) == s.crease(in: frame))
        #expect(s.foldBand(in: frame)?.minX == 456)
    }

    @Test func noFoldOnTheCoverWithoutAHingeOrAwayFromThePane() {
        #expect(state(.closed, crease: nil).foldBand(in: CGRect(x: 0, y: 0, width: 466, height: 678)) == nil)
        #expect(state(.unavailable, crease: nil).foldBand(in: CGRect(x: 0, y: 0, width: 466, height: 678)) == nil)
        // A sheet on the leading half (half-open) or a pane right of the fold doesn't cross it.
        #expect(state(.fullyOpen).foldBand(in: CGRect(x: 520, y: 0, width: 400, height: 669)) == nil)
        #expect(state(.partiallyOpen).foldBand(in: CGRect(x: 8, y: 280, width: 440, height: 389)) == nil)
    }
}

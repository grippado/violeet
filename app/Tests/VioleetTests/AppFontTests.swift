// The chrome's type scale.
//
// What is worth pinning is not the arithmetic but the two properties the scale
// exists to guarantee: the hierarchy holds at every body size the user can
// choose, and nothing goes to zero at the bottom of the range.

import Foundation
import Testing

@testable import Violeet

private let allSteps: [AppFont.Step] = [
    .badge, .micro, .small, .caption, .body, .title, .headline, .display,
]

@Test("the default scale is the system's body size")
func defaultBody() {
    #expect(AppFont.default.body == TerminalSettings.WindowSettings.defaultInterfaceFontSize)
    #expect(AppFont.default.size(.body) == 13)
}

@Test("the steps stay in order at every size the setting allows")
func hierarchyHolds() {
    let range = TerminalSettings.WindowSettings.interfaceFontSizeRange
    for body in stride(from: range.lowerBound, through: range.upperBound, by: 1) {
        let scale = AppFont(body: body)
        let sizes = allSteps.map { scale.size($0) }
        // Non-decreasing, and not all the same: a scale that flattened would
        // leave a heading indistinguishable from the metrics under it.
        #expect(sizes == sizes.sorted())
        #expect(sizes.first! < sizes.last!)
    }
}

@Test("nothing collapses to nothing at the small end")
func smallEndStaysLegible() {
    let smallest = AppFont(body: TerminalSettings.WindowSettings.interfaceFontSizeRange.lowerBound)
    for step in allSteps {
        #expect(smallest.size(step) >= 6)
    }
    // Even a body somebody forced below the range cannot produce a zero or
    // negative font, which is a crash rather than a small label.
    #expect(AppFont(body: 1).size(.badge) >= 6)
}

@Test("moving the body moves the whole scale with it")
func scaleFollowsBody() {
    let small = AppFont(body: 13)
    let large = AppFont(body: 17)
    for step in allSteps where small.size(step) > 6 {
        #expect(large.size(step) == small.size(step) + 4)
    }
}

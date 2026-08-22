import AppKit
@testable import FolioKit

/// The metrics every layout test reads a document at: the app's own defaults.
let testMetrics = DocumentMetrics(ramp: TypeRamp(family: .serif, textSize: 13),
                                  lineWidth: .comfortable, density: .airy)

/// A pane width that holds exactly `columns` columns, and comfortably so.
///
/// Column-count assertions used to name a literal — 900, 1500, 1600 — which said nothing about
/// why that number meant two columns, and left them sitting some 30pt below the three-column
/// threshold once the cap was lifted. Any change to the type ramp would have flipped them
/// silently. Derived from the measure, a test asking for two columns keeps asking for two.
///
/// Half a column past the threshold rather than on it: the middle of the band cannot round into
/// the one below, and is still far short of buying another column.
func paneWidth(forColumns columns: Int, metrics: DocumentMetrics = testMetrics) -> CGFloat {
    let step = metrics.measure + DocumentStackView.gutter
    let threshold = metrics.measure * CGFloat(columns)
        + DocumentStackView.gutter * CGFloat(columns - 1)
        + DocumentMetrics.minimumPadding * 2
    return (threshold + step / 2).rounded()
}

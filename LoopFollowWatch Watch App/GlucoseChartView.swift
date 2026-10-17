// LoopFollow
// GlucoseChartView.swift

import Charts
import SwiftUI

/// Recent BG readings with the low/high lines, synced from the iPhone.
struct GlucoseChartView: View {
    let points: [WatchGlucoseHistory.Point]
    /// Boluses, SMBs and carbs, drawn with the iPhone graph's symbols and colors.
    let treatments: [WatchTreatmentHistory.Treatment]
    /// When the phone last downloaded treatments; nil when unknown.
    let treatmentsAsOf: TimeInterval?
    let unit: GlucoseSnapshot.Unit

    /// Hours shown; the phone sends three.
    private let hours = 3.0

    /// The iPhone graph's declutter gaps (BGChartModel.Spread): markers stay at their true times.
    private static let insulinGap: TimeInterval = 240
    private static let carbGap: TimeInterval = 250
    /// Approximate width of one digit of a 9 pt label, in points.
    private static let labelDigitWidth: CGFloat = 5
    /// Height of a label line above its marker, in points.
    private static let labelLineHeight: CGFloat = 12
    /// Room the trailing y-axis labels and the hour labels take from the plot, in points.
    private static let yAxisWidth: CGFloat = 26
    private static let xAxisHeight: CGFloat = 20
    /// Once BG is this far past the last treatment download, missing markers may just be unknown.
    private static let staleTreatmentsAfter: TimeInterval = 15 * 60

    private var thresholds: (low: Double, high: Double) { LAAppGroupSettings.thresholdsMgdl() }

    private func display(_ mgdl: Double) -> Double {
        unit == .mmol ? GlucoseConversion.toMmol(mgdl) : mgdl
    }

    private var visibleTreatments: [WatchTreatmentHistory.Treatment] {
        let cutoff = Date().addingTimeInterval(-hours * 3600).timeIntervalSince1970
        return treatments.filter { $0.date >= cutoff }
    }

    /// The last treatment download, when BG has moved well past it; nil while treatments are current.
    private var staleTreatmentsAsOf: TimeInterval? {
        guard let asOf = treatmentsAsOf, let newest = points.last?.date,
              newest - asOf > Self.staleTreatmentsAfter
        else { return nil }
        return asOf
    }

    /// BG axis range in mg/dL covering the readings, markers and range lines, with room above
    /// the highest marker for its amount label when any label is shown.
    private func mgdlRange(markers: [Double], hasLabels: Bool) -> (low: Double, high: Double) {
        let values = points.map { Double($0.mgdl) } + markers + [thresholds.low, thresholds.high]
        let low = max(0, (values.min() ?? 40) - 10)
        let high = (values.max() ?? 300) + 10 + (hasLabels ? 25 : 0)
        return (low, high)
    }

    var body: some View {
        if points.count < 2 {
            Text("Waiting for readings")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            GeometryReader { geometry in
                chart(size: geometry.size)
            }
            .padding(.horizontal, 2)
        }
    }

    private func chart(size: CGSize) -> some View {
        let end = Date()
        let start = end.addingTimeInterval(-hours * 3600)
        let visible = visibleTreatments
        // Label room is measured against the range the graph will have once labels are added.
        let provisional = mgdlRange(markers: visible.map { Double($0.mgdl) }, hasLabels: visible.contains { !$0.label.isEmpty })
        let secondsPerPoint = hours * 3600 / Double(max(size.width - Self.yAxisWidth, 60))
        let mgdlPerPoint = (provisional.high - provisional.low) / Double(max(size.height - Self.xAxisHeight, 60))
        let drawn = WatchTreatmentHistory.drawn(
            visible,
            insulinGap: Self.insulinGap,
            carbGap: Self.carbGap,
            secondsPerLabelUnit: Double(Self.labelDigitWidth) * secondsPerPoint,
            mgdlPerLabelHeight: Double(Self.labelLineHeight) * mgdlPerPoint
        )
        // Spreading can push the oldest marker left of the plot; leave it off rather than draw it outside.
        .filter { $0.drawnDate >= start.timeIntervalSince1970 }
        let range = mgdlRange(markers: drawn.map { Double($0.treatment.mgdl) }, hasLabels: drawn.contains(where: \.showsLabel))

        return Chart {
            RuleMark(y: .value("low", display(thresholds.low)))
                .foregroundStyle(.red.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            RuleMark(y: .value("high", display(thresholds.high)))
                .foregroundStyle(.orange.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

            ForEach(points, id: \.date) { point in
                PointMark(
                    x: .value("time", Date(timeIntervalSince1970: point.date)),
                    y: .value("bg", display(Double(point.mgdl)))
                )
                .symbolSize(12)
                .foregroundStyle(GlucoseColor.color(forMgdl: Double(point.mgdl), thresholds: thresholds))
            }

            if let asOf = staleTreatmentsAsOf, asOf >= start.timeIntervalSince1970 {
                RuleMark(x: .value("treatments as of", Date(timeIntervalSince1970: asOf)))
                    .foregroundStyle(.yellow.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }

            treatmentMarks(drawn)
        }
        .chartXScale(domain: start ... end)
        .chartYScale(domain: display(range.low) ... display(range.high))
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3))
        }
        .overlay(alignment: .topLeading) {
            if let asOf = staleTreatmentsAsOf {
                // Treatments after this time are unknown, so a missing marker doesn't mean no insulin or carbs.
                Text("Treatments until \(Date(timeIntervalSince1970: asOf), style: .time)")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow)
            }
        }
    }

    /// Same symbols and colors as the iPhone graph: blue dot for a bolus, blue downward
    /// triangle for an SMB, orange dot for carbs, each with its amount above when it fits.
    @ChartContentBuilder
    private func treatmentMarks(_ drawn: [WatchTreatmentHistory.Drawn]) -> some ChartContent {
        ForEach(Array(drawn.enumerated()), id: \.offset) { _, item in
            let treatment = item.treatment
            let x = PlottableValue.value("time", Date(timeIntervalSince1970: item.drawnDate))
            let y = PlottableValue.value("treatment", display(Double(treatment.mgdl)))
            PointMark(x: x, y: y)
                .symbol(treatment.kind == .smb ? AnyChartSymbolShape(DownwardTriangle()) : AnyChartSymbolShape(BasicChartSymbolShape.circle))
                .symbolSize(treatment.kind == .smb ? 22 : 28)
                .foregroundStyle((treatment.kind == .carbs ? Color.orange : Color.blue).opacity(0.75))
                .annotation(position: .top, alignment: .center, spacing: 1) {
                    if item.showsLabel {
                        Text(treatment.label).font(.system(size: 9)).foregroundStyle(.white)
                    }
                }
            if treatment.kind == .carbs {
                // A white ring keeps carbs from reading as an orange above-range BG dot.
                PointMark(x: x, y: y)
                    .symbol(BasicChartSymbolShape.circle.strokeBorder(lineWidth: 1))
                    .symbolSize(28)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

/// The iPhone graph's SMB symbol.
private struct DownwardTriangle: ChartSymbolShape {
    var perceptualUnitRect: CGRect { CGRect(x: 0, y: 0, width: 1, height: 1) }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

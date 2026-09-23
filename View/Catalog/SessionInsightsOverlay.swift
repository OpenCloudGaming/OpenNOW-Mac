import SwiftUI

/// The post-session summary: what the stream that just ended measured about itself, with a
/// "Don't show this again" escape in the footer.
struct SessionInsightsOverlay: View {
    let insights: SessionInsights
    let uiScale: CGFloat
    let dismiss: (_ isOptingOut: Bool) -> Void

    @State private var isOptingOut = false

    private static let metricColumns = 3

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                OPNDesign.Surface.scrim
                    .ignoresSafeArea()
                    .onTapGesture { dismiss(isOptingOut) }

                panel(availableSize: proxy.size)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onExitCommand { dismiss(isOptingOut) }
    }

    private func panel(availableSize: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(OPNDesign.accent)
                .frame(height: 2)
                .frame(maxWidth: .infinity)

            header

            rule

            ScrollView(.vertical) {
                bodyContent
            }
            .frame(maxHeight: bodyMaxHeight(availableSize: availableSize))
            .fixedSize(horizontal: false, vertical: true)

            rule

            footer
        }
        .frame(width: panelWidth(availableSize: availableSize))
        .background(OPNDesign.Surface.panel)
        .overlay { Rectangle().stroke(OPNDesign.Stroke.regular, lineWidth: 1) }
        .shadow(color: .black.opacity(0.58), radius: 28 * uiScale, y: 20 * uiScale)
    }

    private var rule: some View {
        Rectangle()
            .fill(OPNDesign.Stroke.subtle)
            .frame(height: 1)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            VStack(alignment: .leading, spacing: 6 * uiScale) {
                Text("SESSION INSIGHTS")
                    .font(.uiSans(size: 10 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.accent)
                    .tracking(1.1)
                Text(insights.title)
                    .font(.uiSans(size: 20 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: OPNDesign.Spacing.xSmall(scale: uiScale))
            OPNModalCloseButton(uiScale: uiScale) { dismiss(isOptingOut) }
        }
        .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
        .padding(.vertical, OPNDesign.Spacing.medium(scale: uiScale))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OPNDesign.Surface.appBar)
    }

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.contentVertical(scale: uiScale)) {
            HStack(spacing: 10 * uiScale) {
                Text(insights.outcome.headline)
                    .font(.uiSans(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(outcomeColor)
                Text(insights.transportName)
                    .font(.uiSans(size: 10 * uiScale, weight: .bold))
                    .tracking(SettingsTagMetrics.tracking * uiScale)
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .padding(.horizontal, 6 * uiScale)
                    .padding(.vertical, 2 * uiScale)
                    .background(OPNDesign.Fill.neutral(0.08))
                    .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
                Spacer(minLength: 0)
            }

            Text("Played for \(insights.durationText)")
                .font(.uiSans(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.secondary)

            if !insights.streamShapeText.isEmpty {
                Text(insights.streamShapeText)
                    .font(.uiSans(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !insights.metrics.isEmpty {
                metricsGrid
            }

            OPNReportIssueNotice(text: insights.guidance, uiScale: uiScale)
        }
        .padding(OPNDesign.Spacing.card(scale: uiScale))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metricsGrid: some View {
        let columns = Self.metricColumns
        let rows = stride(from: 0, to: insights.metrics.count, by: columns).map { start in
            Array(insights.metrics[start..<min(start + columns, insights.metrics.count)])
        }
        return VStack(alignment: .leading, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
                    ForEach(rows[index]) { metric in
                        metricCard(metric)
                    }
                    ForEach(0..<(columns - rows[index].count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
            }
        }
    }

    private func metricCard(_ metric: SessionInsights.Metric) -> some View {
        VStack(alignment: .leading, spacing: 5 * uiScale) {
            Text(metric.label.uppercased())
                .font(.uiSans(size: 9 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.muted)
                .tracking(SettingsTagMetrics.tracking * uiScale)
                .lineLimit(1)
            Text(metric.value)
                .font(.uiSans(size: 15 * uiScale, weight: .bold))
                .foregroundStyle(metric.tone == .caution ? OPNDesign.Semantic.warning : OPNDesign.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12 * uiScale)
        .background(OPNDesign.Fill.neutral(0.045))
        .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            OPNReportIssueCheckbox(
                title: "Don't show this again",
                subtitle: "Turns off the post-session summary in Settings.",
                isOn: $isOptingOut,
                uiScale: uiScale
            )
            .frame(maxWidth: 280 * uiScale, alignment: .leading)

            Spacer(minLength: OPNDesign.Spacing.small(scale: uiScale))

            Button("DONE") { dismiss(isOptingOut) }
                .buttonStyle(VendorGetInButtonStyle(uiScale: uiScale))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
        .padding(.vertical, OPNDesign.Spacing.small(scale: uiScale))
    }

    private var outcomeColor: Color {
        insights.outcome == .failed ? OPNDesign.Semantic.destructive : OPNDesign.Text.primary
    }

    private func panelWidth(availableSize: CGSize) -> CGFloat {
        let windowWidth = availableSize.width - OPNDesign.Spacing.pageHorizontal(scale: uiScale) * 2
        return max(min(560 * uiScale, windowWidth), 320 * uiScale)
    }

    private func bodyMaxHeight(availableSize: CGSize) -> CGFloat {
        max(availableSize.height - 220 * uiScale, 200 * uiScale)
    }
}

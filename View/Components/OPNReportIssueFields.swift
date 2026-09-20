import SwiftUI

/// The interactive pieces the Report an Issue modal is assembled from: the channel cards, the
/// category chips, and the labelled fields — split from the modal itself to keep each file small.

/// The two channels as a pair of square selectable cards. Selected carries the accent fill, a 2px
/// accent stroke, and the `.isSelected` trait; the other stays a neutral row fill.
struct OPNReportIssueTargetPicker: View {
    @Binding var selection: OPNIssueReportTarget
    let uiScale: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            ForEach(OPNIssueReportTarget.allCases) { target in
                card(target)
            }
        }
    }

    private func card(_ target: OPNIssueReportTarget) -> some View {
        let isSelected = selection == target
        return Button { selection = target } label: {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                Text(target.title.uppercased())
                    .font(.uiSans(size: 11 * uiScale, weight: .bold))
                    .foregroundStyle(isSelected ? OPNDesign.accentInk : OPNDesign.Text.primary)
                    .tracking(0.8)
                Text(target.subtitle)
                    .font(.uiSans(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(OPNDesign.Spacing.small(scale: uiScale))
            .background(isSelected ? OPNDesign.accent.opacity(0.14) : OPNDesign.Fill.neutral(0.045))
            .overlay {
                Rectangle().strokeBorder(
                    isSelected ? OPNDesign.accent.opacity(0.55) : OPNDesign.Stroke.subtle,
                    lineWidth: isSelected ? 2 : 1
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The category as a row of square selectable chips, the app-shell stand-in for a segmented picker.
/// Selected carries the accent fill and an on-accent label; the rest are neutral chips.
struct OPNReportIssueCategoryPicker: View {
    @Binding var selection: OPNIssueReportCategory?
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * uiScale) {
            Text("CATEGORY")
                .font(.uiSans(size: 10 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.muted)
                .tracking(0.8)
            HStack(spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
                ForEach(OPNIssueReportCategory.allCases) { category in
                    chip(category)
                }
            }
        }
    }

    private func chip(_ category: OPNIssueReportCategory) -> some View {
        let isSelected = selection == category
        return Button { selection = category } label: {
            Text(category.title.uppercased())
                .font(.uiSans(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(isSelected ? OPNDesign.onAccent : OPNDesign.Text.secondary)
                .tracking(0.6)
                .padding(.horizontal, OPNDesign.Spacing.small(scale: uiScale))
                .frame(height: 28 * uiScale)
                .background(isSelected ? OPNDesign.accent : OPNDesign.Fill.neutral(0.06))
                .overlay {
                    Rectangle().strokeBorder(isSelected ? OPNDesign.accent : OPNDesign.Stroke.regular, lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A labelled text field on Surface Field with an accent focus stroke, matching the settings search
/// field's drawn placeholder so no system prompt colour leaks into the panel.
struct OPNReportIssueInput: View {
    let label: String
    let placeholder: String
    var isMultiline = false
    @Binding var text: String
    let uiScale: CGFloat

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * uiScale) {
            Text(label.uppercased())
                .font(.uiSans(size: 10 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.muted)
                .tracking(0.8)
            field
        }
    }

    private var field: some View {
        TextField("", text: $text, axis: isMultiline ? .vertical : .horizontal)
            .textFieldStyle(.plain)
            .font(.uiSans(size: 13 * uiScale, weight: .medium))
            .foregroundStyle(OPNDesign.Text.primary)
            .lineLimit(isMultiline ? 4...8 : 1...1)
            .focused($isFocused)
            .onSubmit { isFocused = false }
            .padding(.horizontal, OPNDesign.Spacing.small(scale: uiScale))
            .padding(.vertical, 10 * uiScale)
            .background(OPNDesign.Surface.field)
            .overlay {
                Rectangle().strokeBorder(
                    isFocused ? OPNDesign.accent.opacity(0.6) : OPNDesign.Stroke.regular,
                    lineWidth: isFocused ? 2 : 1
                )
            }
            .overlay(alignment: .topLeading) {
                guard text.isEmpty else { return AnyView(EmptyView()) }
                return AnyView(
                    Text(placeholder)
                        .font(.uiSans(size: 13 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.muted)
                        .padding(.horizontal, OPNDesign.Spacing.small(scale: uiScale))
                        .padding(.vertical, 10 * uiScale)
                        .allowsHitTesting(false)
                )
            }
    }
}

/// Square checkbox row: 18×18 accent fill with an on-accent checkmark when on, neutral field when
/// off. The form's only boolean, so it is lighter than a settings toggle row.
struct OPNReportIssueCheckbox: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let uiScale: CGFloat

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(alignment: .top, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
                ZStack {
                    Rectangle()
                        .fill(isOn ? OPNDesign.accent : OPNDesign.Fill.neutral(0.06))
                    Rectangle()
                        .strokeBorder(isOn ? OPNDesign.accent : OPNDesign.Stroke.regular, lineWidth: 1)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.uiSans(size: 10 * uiScale, weight: .bold))
                            .foregroundStyle(OPNDesign.onAccent)
                    }
                }
                .frame(width: 18 * uiScale, height: 18 * uiScale)

                VStack(alignment: .leading, spacing: 3 * uiScale) {
                    Text(title)
                        .font(.uiSans(size: 12 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                    Text(subtitle)
                        .font(.uiSans(size: 11 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// An accent-bar note, the same callout language the diagnostics confirmation uses.
struct OPNReportIssueNotice: View {
    let text: String
    let uiScale: CGFloat

    var body: some View {
        Text(text)
            .font(.uiSans(size: 11 * uiScale, weight: .medium))
            .foregroundStyle(OPNDesign.Text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, OPNDesign.Spacing.small(scale: uiScale))
            .padding(.leading, OPNDesign.Spacing.small(scale: uiScale) + 14 * uiScale)
            .padding(.trailing, OPNDesign.Spacing.small(scale: uiScale))
            .background(alignment: .leading) {
                Rectangle()
                    .fill(OPNDesign.accent)
                    .frame(width: 4 * uiScale)
            }
            .background(OPNDesign.Fill.neutral(0.045))
            .overlay { Rectangle().strokeBorder(OPNDesign.Stroke.subtle, lineWidth: 1) }
    }
}

/// The post-submission state: names where the report went, and says the pasteboard holds a copy so
/// a browser that dropped the link is still recoverable.
struct OPNReportIssueConfirmation: View {
    let target: OPNIssueReportTarget
    let diagnosticsUploadFailed: Bool
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            HStack(spacing: 10 * uiScale) {
                ZStack {
                    Rectangle().fill(OPNDesign.accent.opacity(0.16))
                    Image(systemName: "checkmark")
                        .font(.uiSans(size: 15 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.accentInk)
                }
                .frame(width: 40 * uiScale, height: 40 * uiScale)
                .overlay { Rectangle().strokeBorder(OPNDesign.accent.opacity(0.42), lineWidth: 1) }

                VStack(alignment: .leading, spacing: 4 * uiScale) {
                    Text("\(target.destinationName) opened")
                        .font(.uiSans(size: 16 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                    Text("Finish the report there. A full copy is already on your clipboard.")
                        .font(.uiSans(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if diagnosticsUploadFailed {
                Text("The diagnostics log could not be uploaded; the report was sent without it.")
                    .font(.uiSans(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Semantic.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

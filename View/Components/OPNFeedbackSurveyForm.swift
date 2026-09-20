import SwiftUI

/// NVIDIA's feedback questionnaire drawn natively: a star rating, a free-text field, and a choice
/// row. The answers are the same `{qid, oids, value}` objects NVIDIA's own survey submits, so the
/// reader gets OpenNOW's chrome while NVIDIA still receives a valid response.
struct OPNFeedbackSurveyForm: View {
    @ObservedObject var presentation: OPNReportIssuePresentation
    let uiScale: CGFloat

    var body: some View {
        if let page = presentation.surveyPage {
            VStack(alignment: .leading, spacing: OPNDesign.Spacing.medium(scale: uiScale)) {
                ForEach(Array(page.questions.enumerated()), id: \.element.id) { index, question in
                    questionView(question, number: index + 1)
                }
                if let error = presentation.surveyErrorMessage {
                    Text(error)
                        .font(.uiSans(size: 12 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Semantic.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func questionView(_ question: GxSurveyQuestion, number: Int) -> some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            Text("\(number). \(question.text)")
                .font(.uiSans(size: 14 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.primary)
                .fixedSize(horizontal: false, vertical: true)

            switch question.kind {
            case .csat, .nps: ratingRow(question)
            case .text: textField(question)
            case .single: choiceRows(question, isMultiSelect: false)
            case .multi: choiceRows(question, isMultiSelect: true)
            case .dropdown, .info, .unknown: EmptyView()
            }
        }
    }

    private func ratingRow(_ question: GxSurveyQuestion) -> some View {
        let options = question.options
        let selectedID = presentation.surveyAnswer(for: question.id).optionIDs.first
        let selectedIndex = selectedID.flatMap { id in options.firstIndex { $0.id == id } }
        return HStack(spacing: 10 * uiScale) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                // Cumulative fill: choosing the fourth star fills the first four, the way a rating
                // control reads, while the answer still carries the one chosen option.
                let isFilled = selectedIndex.map { index <= $0 } ?? false
                Button {
                    presentation.setSurveySelection(questionID: question.id, optionID: option.id)
                } label: {
                    Image(systemName: isFilled ? "star.fill" : "star")
                        .font(.uiSans(size: 20 * uiScale, weight: .regular))
                        .foregroundStyle(isFilled ? OPNDesign.accent : OPNDesign.Text.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(option.name) of \(options.count)"))
                .accessibilityAddTraits(selectedIndex == index ? .isSelected : [])
            }
        }
    }

    private func textField(_ question: GxSurveyQuestion) -> some View {
        let value = presentation.surveyAnswer(for: question.id).value
        let binding = Binding(
            get: { presentation.surveyAnswer(for: question.id).value },
            set: { presentation.setSurveyText(questionID: question.id, value: $0) }
        )
        return TextField("", text: binding, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.uiSans(size: 13 * uiScale, weight: .medium))
            .foregroundStyle(OPNDesign.Text.primary)
            .lineLimit(3...6)
            .padding(.horizontal, OPNDesign.Spacing.small(scale: uiScale))
            .padding(.vertical, 9 * uiScale)
            .background(OPNDesign.Surface.field)
            .overlay { Rectangle().strokeBorder(OPNDesign.Stroke.regular, lineWidth: 1) }
            .overlay(alignment: .topLeading) {
                guard value.isEmpty else { return AnyView(EmptyView()) }
                return AnyView(
                    Text("Do not include any personal information")
                        .font(.uiSans(size: 13 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.muted)
                        .padding(.horizontal, OPNDesign.Spacing.small(scale: uiScale))
                        .padding(.vertical, 10 * uiScale)
                        .allowsHitTesting(false)
                )
            }
    }

    private func choiceRows(_ question: GxSurveyQuestion, isMultiSelect: Bool) -> some View {
        let selected = Set(presentation.surveyAnswer(for: question.id).optionIDs)
        return VStack(alignment: .leading, spacing: 2 * uiScale) {
            ForEach(question.options) { option in
                let isSelected = selected.contains(option.id)
                Button {
                    if isMultiSelect {
                        presentation.toggleSurveySelection(questionID: question.id, optionID: option.id)
                    } else {
                        presentation.setSurveySelection(questionID: question.id, optionID: option.id)
                    }
                } label: {
                    HStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
                        selectionIndicator(isSelected: isSelected, isMultiSelect: isMultiSelect)
                        Text(option.name)
                            .font(.uiSans(size: 13 * uiScale, weight: .medium))
                            .foregroundStyle(OPNDesign.Text.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6 * uiScale)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private func selectionIndicator(isSelected: Bool, isMultiSelect: Bool) -> some View {
        ZStack {
            Rectangle()
                .fill(isSelected ? OPNDesign.accent : OPNDesign.Fill.neutral(0.06))
            Rectangle()
                .strokeBorder(isSelected ? OPNDesign.accent : OPNDesign.Stroke.regular, lineWidth: 1)
            if isSelected {
                if isMultiSelect {
                    Image(systemName: "checkmark")
                        .font(.uiSans(size: 10 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.onAccent)
                } else {
                    Rectangle()
                        .fill(OPNDesign.onAccent)
                        .frame(width: 7 * uiScale, height: 7 * uiScale)
                }
            }
        }
        .frame(width: 18 * uiScale, height: 18 * uiScale)
    }
}

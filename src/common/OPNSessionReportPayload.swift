import Foundation

@objcMembers
@objc(OPNSessionReportPayload)
final class OPNSessionReportPayload: NSObject {
    let gameTitle: String
    let success: Bool
    let launchText: String
    let averageLatencyText: String
    let averageBitrateText: String
    let droppedFramesText: String
    let reportText: String
    let copyText: String
    let shouldShow: Bool
    let displayScore: Int
    let displayReason: String

    init(
        gameTitle: String,
        success: Bool,
        launchText: String,
        averageLatencyText: String,
        averageBitrateText: String,
        droppedFramesText: String,
        reportText: String,
        copyText: String,
        shouldShow: Bool,
        displayScore: Int,
        displayReason: String
    ) {
        self.gameTitle = gameTitle
        self.success = success
        self.launchText = launchText
        self.averageLatencyText = averageLatencyText
        self.averageBitrateText = averageBitrateText
        self.droppedFramesText = droppedFramesText
        self.reportText = reportText
        self.copyText = copyText
        self.shouldShow = shouldShow
        self.displayScore = displayScore
        self.displayReason = displayReason
        super.init()
    }
}

import Foundation

@objcMembers
@objc(OPNSessionReportPayload)
public final class OPNSessionReportPayload: NSObject {
    public let gameTitle: String
    public let success: Bool
    public let launchText: String
    public let averageLatencyText: String
    public let averageBitrateText: String
    public let droppedFramesText: String
    public let reportText: String
    public let copyText: String
    public let shouldShow: Bool
    public let displayScore: Int
    public let displayReason: String

    public init(
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

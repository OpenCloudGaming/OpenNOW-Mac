public struct OPNStreamSettings: Equatable, Sendable {
    public var resolution = "1920x1080"
    public var fps = 60
    public var codec = "H264"
    public var colorQuality = "8bit_420"
    public var maxBitrateMbps = 50
    public var prefilterMode = 0
    public var prefilterSharpness = 0
    public var prefilterDenoise = 0
    public var prefilterModel = 0
    public var enableCloudGsync = false
    public var enableL4S = false
    public var enableReflex = true
    public var lowLatencyMode = false
    public var enableHdr = false
    public var microphoneMode = "disabled"
    public var microphoneDeviceId = ""
    public var microphonePushToTalkKeyCode = 9
    public var microphonePushToTalkModifierMask = 0
    public var gameVolume = 1.0
    public var microphoneVolume = 1.0
    public var keyboardLayout = "us"
    public var gameLanguage = "en_US"
    public var accountLinked = true
    public var selectedStore = ""
    public var networkTestSessionId = ""
    public var networkType = "Unknown"
    public var networkLatencyMs = -1
    public var remoteControllersBitmap: UInt32 = 0
    public var supportedHidDevices: UInt32 = 0
    public var availableSupportedControllers: [String] = []

    public init() {}
}

enum ControllerMappingFocusPolicy {
    static func allowsMappings(appIsActive: Bool, windowIsKey: Bool,
                               remoteInputEnabled: Bool, overlayCapturesInput: Bool) -> Bool {
        appIsActive && windowIsKey && remoteInputEnabled && !overlayCapturesInput
    }

    static func allowsGamepadWithoutFocus(isPictureInPictureMode: Bool, isCouchCoopActive: Bool) -> Bool {
        isPictureInPictureMode || isCouchCoopActive
    }

    static func releasesGamepadsOnFocusLoss(isCouchCoopActive: Bool) -> Bool {
        !isCouchCoopActive
    }
}

enum ControllerMappingFocusPolicy {
    static func allowsMappings(appIsActive: Bool, windowIsKey: Bool,
                               remoteInputEnabled: Bool, overlayCapturesInput: Bool) -> Bool {
        appIsActive && windowIsKey && remoteInputEnabled && !overlayCapturesInput
    }
}

enum ControllerMappingFocusPolicy {
    /// Mappings follow the frontmost stream, except that couch co-op lets a pad keep playing its own
    /// stream while another window has the focus. The overlay and remote-input gates still apply.
    static func allowsMappings(appIsActive: Bool, windowIsKey: Bool,
                               remoteInputEnabled: Bool, overlayCapturesInput: Bool,
                               allowsBackgroundPads: Bool = false) -> Bool {
        ((appIsActive && windowIsKey) || allowsBackgroundPads) && remoteInputEnabled && !overlayCapturesInput
    }
}

//
//  RemoteCoOpInviteClipboard.swift
//  OpenNOW
//
//  Putting an invite on the pasteboard is the one piece of Remote Co-Op hosting that needs AppKit.
//  It lives here so the view models that drive the HUD do not have to import AppKit for a single
//  two-line side effect.
//

import AppKit
import Foundation

public enum OPNRemoteCoOpInviteClipboard {
    public static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

//  The autopilot: a dev harness that drives a session from a shell — auto end, scripted steps, a
//  polled command file, snapshots — so decode, bitrate and pacing can be measured with nobody at
//  the keyboard.
//

//  swiftlint:disable:next no_appkit_in_view_model
import AppKit
import Foundation

extension NativeNVSTHostViewModel {

    /// Dev harness. `OPN_NVST_AUTOPILOT_SECONDS=<n>` ends the stream n seconds after it connects —
    /// through the same path as the End Stream button, so the seat session is released and the next
    /// launch is a fresh session rather than a resume — and then quits the app. With a `.gfnpc`
    /// shortcut file it lets a whole session be driven from a shell (`open -a "OpenNOW Dev" --env
    /// OPN_NVST_AUTOPILOT_SECONDS=60 title.gfnpc`) and judged from `~/Library/Logs/OpenNOW/` with
    /// nobody at the keyboard. Not a behaviour switch: it only ever shortens a session.
    func scheduleAutopilotEndIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["OPN_NVST_AUTOPILOT_SECONDS"],
              let seconds = Double(raw), seconds > 0 else { return }
        OpenNOWLog.info(.stream, "Autopilot: ending the stream in \(Int(seconds)) s and quitting")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !self.didEnd else { return }
            _ = await self.finish(reason: .userRequested, message: "Autopilot run complete.")
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    /// Dev harness companion to `scheduleAutopilotEndIfRequested`: `OPN_NVST_AUTOPILOT_SCRIPT`
    /// holds `;`-separated `<seconds>:<action>` steps run after connect. `key<code>` presses and
    /// releases a mac key code (36 Return, 49 Space, 53 Escape); `click<x>,<y>` moves the pointer
    /// to a fraction of the picture and left-clicks; `snap<name>` writes the latest decoded frame
    /// to `OPN_NVST_AUTOPILOT_SNAPSHOT_DIR/<name>.jpg` (the temporary directory by default), which
    /// is the harness's eyes — a screen capture needs a recording grant the shell does not have.
    /// Enough to get a title past a launcher screen so a scripted session reaches the picture the
    /// run is meant to measure, and to prove what it reached.
    func scheduleAutopilotScriptIfRequested() {
        guard let script = ProcessInfo.processInfo.environment["OPN_NVST_AUTOPILOT_SCRIPT"], !script.isEmpty else { return }
        for step in script.split(separator: ";") {
            let parts = step.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let delay = Double(parts[0]) else { continue }
            let action = parts[1]
            OpenNOWLog.info(.stream, "Autopilot: \(action) at +\(Int(delay)) s")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !self.didEnd else { return }
                await self.performAutopilotAction(action)
            }
        }
    }

    /// Dev harness, interactive form: `OPN_NVST_AUTOPILOT_COMMAND_FILE` names a text file whose new
    /// lines are executed as they appear (same grammar as the script, plus `end`), polled every
    /// second. Lets a shell snapshot the picture, look, and choose the next click while the session
    /// runs — launcher windows do not sit still between sessions, so a blind script cannot.
    func startAutopilotCommandFileIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["OPN_NVST_AUTOPILOT_COMMAND_FILE"], !path.isEmpty else { return }
        OpenNOWLog.info(.stream, "Autopilot: following commands in \(path)")
        Task { [weak self] in
            var consumed = 0
            while let self, !self.didEnd {
                try? await Task.sleep(for: .seconds(1))
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
                guard lines.count > consumed else { continue }
                for line in lines[consumed...] where !line.isEmpty {
                    OpenNOWLog.info(.stream, "Autopilot: command \(line)")
                    if line == "end" {
                        _ = await self.finish(reason: .userRequested, message: "Autopilot run complete.")
                        try? await Task.sleep(for: .seconds(3))
                        await MainActor.run { NSApp.terminate(nil) }
                        return
                    }
                    await self.performAutopilotAction(line)
                }
                consumed = lines.count
            }
        }
    }

    /// A session launched with `open` from a shell is not the frontmost app, so its fullscreen
    /// Space never shows and `MTKView` never draws — every render-side measurement reads zero.
    /// Under any autopilot switch the app asks for activation itself once connected. macOS may
    /// still refuse (cooperative activation); the render log line says whether drawing started.
    func activateForAutopilotIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPN_NVST_AUTOPILOT_SECONDS"] != nil || environment["OPN_NVST_AUTOPILOT_COMMAND_FILE"] != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        nativeView?.window?.makeKeyAndOrderFront(nil)
        OpenNOWLog.info(.stream, "Autopilot: requested activation (active=\(NSApp.isActive))")
    }

    func performAutopilotAction(_ action: String) async {
        if action.hasPrefix("osnap") || action.hasPrefix("rsnap") || action.hasPrefix("snap") {
            performAutopilotSnapshot(action)
            return
        }
        if action.hasPrefix("fill"), let mode = Int(action.dropFirst(4)) {
            updateNativePillarboxFill(modeIndex: mode)
            return
        }
        guard let dispatcher = inputDispatcher else {
            OpenNOWLog.warning(.stream, "Autopilot: no input dispatcher for \(action)")
            return
        }
        if action.hasPrefix("key"), let code = UInt16(action.dropFirst(3)) {
            await performAutopilotKey(code, dispatcher: dispatcher)
            return
        }
        if action.hasPrefix("click") {
            await performAutopilotClick(action, dispatcher: dispatcher)
            return
        }
        if action.hasPrefix("pad") {
            await performAutopilotPad(String(action.dropFirst(3)), dispatcher: dispatcher)
            return
        }
        if action == "reconnect" {
            // The same in-place recovery the stall watchdog and the network-path monitor run, on
            // demand: tears the transport down, resumes the session through CloudMatch and
            // negotiates again. The only way to exercise that path without pulling a cable.
            guard let path else { return }
            let recovered = await attemptInPlaceReconnect(path: path, reason: "autopilot")
            OpenNOWLog.info(.stream, "Autopilot: reconnect \(recovered ? "succeeded" : "failed")")
            return
        }
        OpenNOWLog.warning(.stream, "Autopilot: unknown action \(action)")
    }

    private static let autopilotPadButtons: [String: GamepadButtons] = [
        "a": .south,
        "b": .east,
        "x": .west,
        "y": .north,
        "start": .start,
        "select": .select,
        "back": .select,
        "lb": .leftShoulder,
        "rb": .rightShoulder,
        "up": .dpadUp,
        "down": .dpadDown,
        "left": .dpadLeft,
        "right": .dpadRight
    ]

    /// `pad<button>` taps one button on the seat's pad 0 for 120 ms (`padA`, `padB`, `padX`,
    /// `padY`, `padStart`, `padSelect`, `padLB`, `padRB`, `padUp/Down/Left/Right`). Games that
    /// rumble only the active player's controller (Streets of Rage 4 hands player 1 to whichever
    /// device pressed first) need a pad press before the keyboard-driven harness can measure rumble.
    private func performAutopilotPad(_ name: String, dispatcher: NativeNVSTInputDispatcher) async {
        guard let buttons = Self.autopilotPadButtons[name.lowercased()] else {
            OpenNOWLog.warning(.stream, "Autopilot: unknown pad button \(name)")
            return
        }
        func state(_ pressed: GamepadButtons) -> UserInputEvent {
            .gamepad(GamepadState(deviceID: InputDeviceID("autopilot-pad"), playerIndex: 0, buttons: pressed, timestamp: autopilotTimestamp()))
        }
        dispatcher.enqueue(state(buttons))
        try? await Task.sleep(for: .milliseconds(120))
        dispatcher.enqueue(state([]))
        OpenNOWLog.info(.stream, "Autopilot: tapped pad button \(name)")
    }

    /// `osnap` renders offscreen, `rsnap` reads the next drawable back, `snap` writes the decoded frame.
    private func performAutopilotSnapshot(_ action: String) {
        let directory = ProcessInfo.processInfo.environment["OPN_NVST_AUTOPILOT_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        func url(prefix: Int, fallback: String) -> URL {
            let name = String(action.dropFirst(prefix))
            return directory.appendingPathComponent("\(name.isEmpty ? fallback : name).jpg")
        }
        if action.hasPrefix("osnap") {
            let target = url(prefix: 5, fallback: "offscreen")
            if let size = nativeView?.nvstBifrostFreeRenderer?.writeOffscreenRenderSnapshot(to: target) {
                OpenNOWLog.info(.stream, "Autopilot: offscreen render \(Int(size.width))x\(Int(size.height)) -> \(target.path)")
            } else {
                OpenNOWLog.warning(.stream, "Autopilot: offscreen render failed -> \(target.path)")
            }
        } else if action.hasPrefix("rsnap") {
            nativeView?.nvstBifrostFreeRenderer?.requestRenderSnapshot(to: url(prefix: 5, fallback: "render"))
        } else {
            let target = url(prefix: 4, fallback: "frame")
            if let size = nativeView?.nvstBifrostFreeRenderer?.writeLatestFrameJPEG(to: target) {
                OpenNOWLog.info(.stream, "Autopilot: snapshot \(Int(size.width))x\(Int(size.height)) -> \(target.path)")
            } else {
                OpenNOWLog.warning(.stream, "Autopilot: snapshot failed (no frame yet?) -> \(target.path)")
            }
        }
    }

    private func autopilotTimestamp() -> MediaTimestamp {
        MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    private func performAutopilotKey(_ code: UInt16, dispatcher: NativeNVSTInputDispatcher) async {
        dispatcher.enqueue(.keyboard(KeyboardEvent(deviceID: "keyboard", keyCode: code, scanCode: code, isPressed: true, timestamp: autopilotTimestamp())))
        try? await Task.sleep(for: .milliseconds(90))
        dispatcher.enqueue(.keyboard(KeyboardEvent(deviceID: "keyboard", keyCode: code, scanCode: code, isPressed: false, timestamp: autopilotTimestamp())))
        OpenNOWLog.info(.stream, "Autopilot: pressed key \(code)")
    }

    private func performAutopilotClick(_ action: String, dispatcher: NativeNVSTInputDispatcher) async {
        let coordinates = action.dropFirst(5).split(separator: ",").compactMap { Double($0) }
        guard coordinates.count == 2 else { return }
        // The viewport must have the stream's aspect: the seat maps absolute coordinates
        // through it, and a square one landed clicks at a resolution-dependent offset
        // (+0.10/+0.085 at 5120x2160, +0.20/+0.12 at 2560x1440). The negotiated frame size
        // is the exact answer; 16:9 is the fallback before the first stats sample.
        let parts = (latestNativeStats?.resolution ?? "").lowercased().split(separator: "x").compactMap { Int32($0) }
        let viewportWidth: Int32 = parts.count == 2 && parts[0] > 0 ? parts[0] : 1920
        let viewportHeight: Int32 = parts.count == 2 && parts[1] > 0 ? parts[1] : 1080
        dispatcher.enqueueAbsoluteMove(NativeNVSTAbsoluteMouseEvent(
            x: Int32(min(max(coordinates[0], 0), 1) * Double(viewportWidth - 1)),
            y: Int32(min(max(coordinates[1], 0), 1) * Double(viewportHeight - 1)),
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            timestamp: autopilotTimestamp()
        ))
        try? await Task.sleep(for: .milliseconds(120))
        dispatcher.enqueue(.mouse(.button(deviceID: "mouse", button: .left, isPressed: true, timestamp: autopilotTimestamp())))
        try? await Task.sleep(for: .milliseconds(90))
        dispatcher.enqueue(.mouse(.button(deviceID: "mouse", button: .left, isPressed: false, timestamp: autopilotTimestamp())))
        OpenNOWLog.info(.stream, "Autopilot: clicked \(coordinates[0]),\(coordinates[1])")
    }
}

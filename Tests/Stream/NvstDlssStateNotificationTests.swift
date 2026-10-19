//  The seat's `DlssState` custom message: the only report of what the running session actually
//  applied, and the envelope it arrives in.

import Foundation
import Testing
@testable import OpenNOW

@Suite struct NvstDlssStateNotificationTests {
    @Test func theSeatEnvelopeParsesTheBifrostFieldNames() throws {
        let command = customMessage("""
        {
          "messageType": "DlssState",
          "dataType": "json",
          "sizeInBytes": 148,
          "messageRecipient": "GFN",
          "data": "{\\"srOverrideActive\\":true,\\"rrOverrideActive\\":true,\\"fgOverrideActive\\":true,\\"fgCurrentMultiplier\\":4,\\"overrides\\":{\\"srMode\\":5,\\"srModel\\":1,\\"srScale\\":100,\\"rrModel\\":7,\\"fgMode\\":1,\\"fgModel\\":1,\\"fgMultiplier\\":4}}"
        }
        """)
        let state = try #require(NvstDlssStateNotification.parse(command))

        #expect(state.isSuperResolutionOverridden)
        #expect(state.isRayReconstructionOverridden)
        #expect(state.isFrameGenerationOverridden)
        #expect(state.activeFrameGenerationMultiplier == 4)
        #expect(state.overrides.superResolutionMode == DlssSuperResolutionMode.dlaa.rawValue)
        #expect(state.overrides.rayReconstructionModel == 7)
        #expect(state.overrides.frameGenerationMode == DlssFrameGenerationMode.dynamic.rawValue)
    }

    /// The native client's own bridge renames the four flags before its UI sees them, so a state
    /// that has already been through it has to read the same way.
    @Test func theNativeBridgeSpellingsParseAsWell() throws {
        let command = customMessage("""
        {
          "messageType": "DlssState",
          "data": "{\\"superResolutionActive\\":true,\\"rayReconstructionActive\\":false,\\"frameGenerationActive\\":true,\\"activeFgMultiplier\\":3,\\"overrides\\":{\\"srMode\\":4,\\"srScale\\":33,\\"fgMode\\":1,\\"fgMultiplier\\":3}}"
        }
        """)
        let state = try #require(NvstDlssStateNotification.parse(command))

        #expect(state.isSuperResolutionOverridden)
        #expect(!state.isRayReconstructionOverridden)
        #expect(state.isFrameGenerationOverridden)
        #expect(state.activeFrameGenerationMultiplier == 3)
    }

    /// A payload that carries no envelope is read as the state itself.
    @Test func aBareStateObjectParses() throws {
        let command = customMessage(#"{"srOverrideActive":true,"overrides":{"srMode":3,"srScale":67}}"#)
        let state = try #require(NvstDlssStateNotification.parse(command))

        #expect(state.isSuperResolutionOverridden)
        #expect(!state.isFrameGenerationOverridden)
        #expect(state.overrides.superResolutionScale == 67)
    }

    @Test func anotherCustomMessageTypeIsNotAState() {
        let command = customMessage(#"{"messageType":"TrueHdrEnablementChange","data":"{\"isTrueHdrEnabled\":true}"}"#)
        #expect(NvstDlssStateNotification.parse(command) == nil)
        #expect(NvstDlssStateNotification.messageType(of: command) == "TrueHdrEnablementChange")
    }

    /// Only the custom-message carriers are read; a JSON control command of any other kind is not a
    /// DLSS state, however state-shaped its payload looks.
    @Test func onlyTheCustomMessageCarriersAreRead() {
        let payload = Data(#"{"srOverrideActive":true,"overrides":{"srMode":5}}"#.utf8)
        #expect(NvstDlssStateNotification.parse(NvstControlCommand(code: .hdrMode, payload: payload)) == nil)
        #expect(NvstDlssStateNotification.messageType(of: NvstControlCommand(code: .hdrMode, payload: payload)) == nil)
        #expect(NvstDlssStateNotification.parse(NvstControlCommand(code: .customMessageFinal, payload: payload)) != nil)
    }

    /// A message that is JSON but says nothing about DLSS must not be read as "nothing applied".
    @Test func anEmptyObjectIsNotAState() {
        #expect(NvstDlssStateNotification.parse(customMessage(#"{"messageType":"DlssState"}"#)) == nil)
        #expect(NvstDlssStateNotification.parse(customMessage("{}")) == nil)
        #expect(NvstDlssStateNotification.parse(NvstControlCommand(code: .customMessage, payload: Data("not json".utf8))) == nil)
    }

    @Test func theAppliedLabelsNameWhatTheSeatIsRunning() {
        let state = NvstDlssStateNotification(
            isSuperResolutionOverridden: true,
            isRayReconstructionOverridden: true,
            isFrameGenerationOverridden: true,
            activeFrameGenerationMultiplier: 4,
            overrides: NvstDlssStateNotification.Overrides(
                superResolutionMode: DlssSuperResolutionMode.dlaa.rawValue,
                superResolutionModel: 1,
                superResolutionScale: 100,
                rayReconstructionModel: 7,
                frameGenerationMode: DlssFrameGenerationMode.dynamic.rawValue,
                frameGenerationModel: 1,
                frameGenerationMultiplier: 4
            )
        )

        #expect(state.superResolutionLabel == "DLAA 100%")
        #expect(state.frameGenerationLabel == "Dynamic up to 4×")
        #expect(state.rayReconstructionLabel == "Preset F")
    }

    /// A fixed multiplier is a mode the settings card does not offer, but the seat can still report
    /// it, and it has to render as itself rather than fall back to "In-game".
    @Test func aFixedFrameGenerationMultiplierIsNamed() {
        let state = NvstDlssStateNotification(
            isSuperResolutionOverridden: false,
            isRayReconstructionOverridden: false,
            isFrameGenerationOverridden: true,
            activeFrameGenerationMultiplier: 0,
            overrides: NvstDlssStateNotification.Overrides(
                superResolutionMode: 0,
                superResolutionModel: 0,
                superResolutionScale: 0,
                rayReconstructionModel: 0,
                frameGenerationMode: 2,
                frameGenerationModel: 1,
                frameGenerationMultiplier: 4
            )
        )

        #expect(state.frameGenerationLabel == "Fixed up to 4×")
    }

    /// A Custom Super Resolution override carries its own input scale, and the label has to use the
    /// seat's number rather than the fixed table, which has no entry for Custom.
    @Test func aCustomSuperResolutionUsesTheSeatsOwnScale() {
        let state = NvstDlssStateNotification(
            isSuperResolutionOverridden: true,
            isRayReconstructionOverridden: false,
            isFrameGenerationOverridden: false,
            activeFrameGenerationMultiplier: 0,
            overrides: NvstDlssStateNotification.Overrides(
                superResolutionMode: DlssSuperResolutionMode.custom.rawValue,
                superResolutionModel: 1,
                superResolutionScale: 80,
                rayReconstructionModel: 0,
                frameGenerationMode: 0,
                frameGenerationModel: 0,
                frameGenerationMultiplier: 0
            )
        )

        #expect(state.superResolutionLabel == "Custom 80%")
    }

    @Test func theSummaryNamesEveryFeatureInPresentationOrder() {
        let state = NvstDlssStateNotification(
            isSuperResolutionOverridden: false,
            isRayReconstructionOverridden: false,
            isFrameGenerationOverridden: false,
            activeFrameGenerationMultiplier: 0,
            overrides: .none
        )
        #expect(state.summary == "sr=off rr=off fg=off")
    }

    private func customMessage(_ json: String) -> NvstControlCommand {
        NvstControlCommand(code: .customMessage, payload: Data(json.utf8))
    }
}

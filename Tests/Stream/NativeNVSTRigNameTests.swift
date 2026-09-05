import Foundation
import Testing
@testable import OpenNOW

struct NativeNVSTRigNameTests {
    private let payload = """
    {"features":[{"name":"enableGpuNameMappingV2","value":{"enableGpuNameMapping":true,"gpuNameMap":[
      {"gpuName":"1060b / T10-8","mappedGpuName":"Basic Rig","mappedGdnGpuName":"NVIDIA T10"},
      {"gpuName":"4080p / L40Sx2","mappedGpuName":"GeForce RTX 4080","mappedGdnGpuName":"NVIDIA L96"},
      {"gpuName":"5080h / B40","mappedGpuName":"GeForce RTX 5080","mappedGdnGpuName":"NVIDIA B40-96"}]}}]}
    """

    @Test func theServicesMapIsReadOutOfTheCloudVariables() {
        let variables = OPNStreamPreferences.cloudVariables(from: payload)
        #expect(variables.gpuNameMap["5080h / B40"] == "GeForce RTX 5080")
        #expect(variables.gpuNameMap["1060b / T10-8"] == "Basic Rig")
        #expect(variables.gpuNameMap.count == 3)
    }

    @Test func friendlyNameUsesTheMapThenTheModelNumberThenTheIdentifier() {
        let map = OPNStreamPreferences.cloudVariables(from: payload).gpuNameMap
        #expect(OPNStreamPreferences.friendlyGPUName(for: "5080h / B40", map: map) == "GeForce RTX 5080")
        #expect(OPNStreamPreferences.friendlyGPUName(for: "1060b / T10-8", map: map) == "Basic Rig")
        // Not in the map: the model number at the front still names the tier.
        #expect(OPNStreamPreferences.friendlyGPUName(for: "5090h / B60", map: map) == "GeForce RTX 5090")
        // Nothing to go on: vendor prefixes trimmed, otherwise as given.
        #expect(OPNStreamPreferences.friendlyGPUName(for: "NVIDIA GeForce RTX 4080", map: [:]) == "RTX 4080")
        #expect(OPNStreamPreferences.friendlyGPUName(for: "", map: map) == "")
    }
}

import CoreImage
import Testing
@testable import OpenNOW

@Suite("Device code QR rendering")
struct DeviceCodeQRViewTests {
    @Test func encodesAverificationURI() {
        let image = DeviceCodeQRView.qrCodeImage(for: "https://nvidia.com/activate?user_code=ABCD-EFGH")
        #expect(image != nil)
        #expect(image?.width == image?.height)
        #expect((image?.width ?? 0) > 0)
    }

    @Test func rejectsAnEmptyPayload() {
        #expect(DeviceCodeQRView.qrCodeImage(for: "") == nil)
    }
}

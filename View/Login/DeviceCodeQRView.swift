import AppKit
import CoreImage
import SwiftUI

struct DeviceCodeQRView: View {
    private let image: CGImage?

    init(payload: String) {
        image = Self.qrCodeImage(for: payload)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            } else {
                Color.clear
            }
        }
        .background(Color.white)
        .accessibilityLabel("Sign-in QR code")
    }

    static func qrCodeImage(for payload: String) -> CGImage? {
        guard !payload.isEmpty,
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage, !outputImage.extent.isInfinite else {
            return nil
        }
        let context = CIContext(options: nil)
        return context.createCGImage(outputImage, from: outputImage.extent)
    }
}

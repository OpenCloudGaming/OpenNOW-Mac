import AppKit
import CoreImage
import SwiftUI

/// Renders the device-code verification URL as a scannable QR code.
///
/// The code is generated locally with Core Image and drawn black-on-white with a quiet zone, so
/// the panel behind it — dark in every appearance — never bleeds into the modules and breaks the
/// scan.
struct DeviceCodeQRView: View {
    private let image: CGImage?

    init(payload: String) {
        image = Self.qrCodeImage(for: payload)
    }

    var body: some View {
        ZStack {
            if let image {
                // Rendered at one pixel per module and scaled nearest-neighbour here; bilinear
                // upscaling would blur module edges and cost scannability.
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

    /// The verification URL encoded as a QR bitmap, or `nil` when there is nothing to encode.
    static func qrCodeImage(for payload: String) -> CGImage? {
        guard !payload.isEmpty,
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }
        // The message must be UTF-8 bytes; the filter treats a Swift `String` value as raw data
        // input and mis-encodes it.
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage, !outputImage.extent.isInfinite else {
            return nil
        }
        let context = CIContext(options: nil)
        return context.createCGImage(outputImage, from: outputImage.extent)
    }
}

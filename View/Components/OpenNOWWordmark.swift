import AppKit
import SwiftUI

/// The OpenNOW wordmark lockup: the isolated cloud mark beside `OPENNOW` set in the
/// project typeface. Height-driven so call sites control the footprint; the text and
/// spacing scale with the mark rather than carrying their own fixed sizes.
///
/// Replaces the vendored NVIDIA wordmark image previously used on the About and
/// launch-overlay surfaces with the app's own brand.
struct OpenNOWWordmark: View {
    var height: CGFloat = 32

    var body: some View {
        HStack(alignment: .center, spacing: height * 0.28) {
            VendorResourceImage(name: "logo-isolated", fileExtension: "svg")
                .scaledToFit()
                .frame(height: height)
            Text("OPENNOW")
                .font(OpenNOWUIFont.font(size: height * 0.44, weight: .bold))
                .foregroundStyle(OpenNOWDesign.Text.primary)
                .tracking(0.4)
        }
        .fixedSize()
    }
}

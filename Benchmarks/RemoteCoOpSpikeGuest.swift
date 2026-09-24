//  M0 spike guest: receives the host's forwarded *source* compressed video on a UDP port and reports
//  what it decodes. It runs the same `RemoteCoOpNativeGuestReceiver` the in-app native guest window
//  does — this is the headless twin — and writes occasional PNGs so the picture can be inspected.
//
//      swift run --scratch-path .build/shared OpenNOWBenchmarks coop-spike-guest --port 9000
//

import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers
@testable import OpenNOW

private final class SpikePNGWriter: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var frameCount = 0

    init(directory: URL) {
        self.directory = directory
    }

    /// Every 120th frame, so a long run does not fill the temporary directory.
    func note(_ frame: OPNVideoFrame) {
        lock.lock()
        frameCount += 1
        let index = frameCount
        lock.unlock()
        guard index % 120 == 0 else { return }
        writePNG(frame.pixelBuffer, to: directory.appendingPathComponent("frame-\(index).png"))
    }

    private func writePNG(_ pixelBuffer: CVPixelBuffer, to url: URL) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = CIContext(options: nil).createCGImage(image, from: image.extent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
    }
}

private func spikeGuestPort() -> UInt16 {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--port"), index + 1 < arguments.count,
          let port = UInt16(arguments[index + 1]) else { return 9000 }
    return port
}

func runRemoteCoOpSpikeGuest() -> Bool {
    // Long-lived process with stdout redirected: without this, `print` sits in the block buffer and a
    // Ctrl-C loses the very stats the spike exists to show.
    setvbuf(stdout, nil, _IONBF, 0)
    let port = spikeGuestPort()
    guard NWEndpoint.Port(rawValue: port) != nil else {
        print("invalid port \(port)")
        return false
    }

    let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("opennow-coop-spike", isDirectory: true)
    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    let receiver = RemoteCoOpNativeGuestReceiver()
    let writer = SpikePNGWriter(directory: outputDirectory)
    receiver.onFrame = { writer.note($0) }
    receiver.onState = { print($0) }
    receiver.onStats = { stats in
        print(String(format: "%@ %@ %.0f fps %.1f Mbps decoded=%@ missed=%@",
                     stats.codecName, stats.resolutionText, stats.framesPerSecond, stats.megabitsPerSecond,
                     "\(stats.decoded)", "\(stats.failures)"))
    }

    do {
        try receiver.start(port: port)
    } catch {
        print("could not listen on udp/\(port): \(error.localizedDescription)")
        return false
    }
    print("writing a frame to \(outputDirectory.path) every 120 frames")
    print("co-op spike guest ready. Ctrl-C to stop.")
    dispatchMain()
}

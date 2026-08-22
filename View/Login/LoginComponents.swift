//
//  LoginComponents.swift
//  MacForceNow
//
//  Created by Jayian on 6/14/26.
//

import AppKit
import SwiftUI

struct LoginBackdrop: View {
    var body: some View {
        MacForceNowDesign.Surface.app
        .ignoresSafeArea()
    }
}

struct VendorResourceImage: View {
    private let image: NSImage?

    init(name: String, fileExtension: String) {
        image = Self.loadImage(name: name, fileExtension: fileExtension)
    }

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
        } else {
            Color.black
        }
    }

    /// Decodes every brand asset used by the first screens up front so the startup
    /// scene and login window never pay a synchronous `NSImage(contentsOf:)` SVG/PNG
    /// decode on a first-frame render.
    nonisolated static func prewarm() {
        let assets: [(name: String, fileExtension: String)] = [
            ("logo-isolated", "svg"),
            ("logo", "png"),
            ("LoginWallContentBackground", "png"),
            ("LoginWallFallbackTile", "png"),
            ("Marquee_Hero_Image_Gradient", "svg"),
            ("nv-gfn-logo_v3", "png"),
            ("avatar_generic_118", "svg")
        ]
        for asset in assets {
            _ = loadImage(name: asset.name, fileExtension: asset.fileExtension)
        }
    }

    nonisolated private static func loadImage(name: String, fileExtension: String) -> NSImage? {
        let cacheKey = "\(name).\(fileExtension)" as NSString
        if let cachedImage = imageCache.object(forKey: cacheKey) {
            return cachedImage
        }

        for subdirectory in ["MacForceNow", "Resources/MacForceNow", "NVIDIA", "Resources/NVIDIA", nil] as [String?] {
            let url = Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: subdirectory)
            if let url, let image = NSImage(contentsOf: url) {
                imageCache.setObject(image, forKey: cacheKey)
                return image
            }
        }
        return nil
    }

    nonisolated(unsafe) private static let imageCache = NSCache<NSString, NSImage>()
}

struct VendorSplashLoadingView: View {
    var message = "Loading GeForce NOW catalog"
    var showsMessage = true
    var onCancel: (() -> Void)?

    var body: some View {
        GeometryReader { proxy in
            let isCompact = min(proxy.size.width, proxy.size.height) < 600
            ZStack {
                Color.black

                RadialGradient(
                    stops: [
                        .init(color: .white.opacity(0.20), location: 0.00),
                        .init(color: .white.opacity(0.05), location: 0.50),
                        .init(color: .white.opacity(0.00), location: 1.00)
                    ],
                    center: .top,
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.72
                )

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.80), location: 0.00),
                        .init(color: .black.opacity(0.40), location: 0.25),
                        .init(color: .black.opacity(0.20), location: 0.35),
                        .init(color: .black.opacity(0.20), location: 0.65),
                        .init(color: .black.opacity(0.40), location: 0.75),
                        .init(color: .black.opacity(0.80), location: 1.00)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                Color.black.opacity(0.18)

                VStack(spacing: isCompact ? 16 : 24) {
                    VendorResourceImage(name: "logo", fileExtension: "png")
                        .scaledToFit()
                        .frame(width: isCompact ? 78 : 138, height: isCompact ? 78 : 138)

                    if showsMessage {
                        VStack(spacing: 14) {
                            VendorIndeterminateProgressBar()
                                .frame(width: isCompact ? 188 : 260, height: 4)
                            Text(message)
                                .font(.nvidiaSans(size: 13, weight: .bold))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }

                    if let onCancel {
                        Button(action: onCancel) {
                            Text("CANCEL")
                                .font(.nvidiaSans(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .tracking(0.3)
                        }
                        .buttonStyle(VendorSplashCancelButtonStyle())
                        .padding(.top, isCompact ? 8 : 12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .background(.black)
    }
}

private struct VendorSplashCancelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, MacForceNowDesign.Spacing.medium)
            .frame(height: 34)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08))
            .overlay { Rectangle().stroke(MacForceNowDesign.Stroke.regular, lineWidth: 1) }
    }
}

struct VendorIndeterminateProgressBar: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let indicatorWidth = max(width * 0.34, 72)

            TimelineView(.periodic(from: .now, by: MacForceNowDesign.Motion.ambientFrameInterval)) { timeline in
                let cycleDuration = 1.15
                let progress = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
                let phase = -0.36 + (1.40 * progress)

                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(.white.opacity(0.24))
                    Rectangle()
                        .fill(MacForceNowDesign.accent)
                        .frame(width: indicatorWidth)
                        .offset(x: phase * width)
                }
                .clipped()
            }
        }
    }
}

struct GFNHeroArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            if reduceMotion {
                artwork(proxy: proxy, motionTime: 0, isAnimated: false)
            } else {
                TimelineView(.periodic(from: .now, by: MacForceNowDesign.Motion.ambientFrameInterval)) { timeline in
                    artwork(proxy: proxy, motionTime: timeline.date.timeIntervalSinceReferenceDate, isAnimated: true)
                }
            }
        }
    }

    private func artwork(proxy: GeometryProxy, motionTime: TimeInterval, isAnimated: Bool) -> some View {
        let backgroundBaseHeight = max(proxy.size.height, proxy.size.width * 0.5)
        let gridHeight = 1.66 * backgroundBaseHeight
        let gridWidth = 2.5 * backgroundBaseHeight
        let imageHeight = 0.22 * backgroundBaseHeight
        let rowOffset = 0.1 * backgroundBaseHeight

        return ZStack {
            RadialGradient(
                colors: [Color(red: 0.286, green: 0.286, blue: 0.286), .black],
                center: UnitPoint(x: 0.65, y: 0.25),
                startRadius: 0,
                endRadius: max(proxy.size.width, proxy.size.height) * 0.75
            )

            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<6, id: \.self) { column in
                            let motion = Self.tileMotion(row: row, column: column, motionTime: motionTime, imageHeight: imageHeight, isAnimated: isAnimated)

                            LoginWallGridTile(urlString: Self.orderedTileURLs[row * 6 + column])
                                .frame(height: imageHeight)
                                .scaleEffect(motion.scale)
                                .rotation3DEffect(.degrees(motion.pitch), axis: (x: 1, y: 0, z: 0), perspective: 0.72)
                                .rotation3DEffect(.degrees(motion.yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.72)
                                .offset(x: motion.x, y: motion.y)
                                .opacity(motion.opacity)

                            if column < 5 {
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .frame(width: gridWidth)
                    .offset(x: row.isMultiple(of: 2) ? rowOffset : -rowOffset)

                    if row < 5 {
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(width: gridWidth, height: gridHeight)
            .rotationEffect(.degrees(-15))
            .position(x: proxy.size.width - (gridWidth / 2) + (0.12 * backgroundBaseHeight), y: proxy.size.height / 2)
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
        .clipped()
    }

    private static func tileMotion(row: Int, column: Int, motionTime: TimeInterval, imageHeight: CGFloat, isAnimated: Bool) -> (x: CGFloat, y: CGFloat, scale: CGFloat, opacity: Double, pitch: Double, yaw: Double) {
        guard isAnimated else { return (0, 0, 1, 1, 0, 0) }

        let primaryPhase = motionTime * 0.42 + Double(row) * 0.73 + Double(column) * 0.41
        let secondaryPhase = motionTime * 0.31 + Double(column) * 0.67 - Double(row) * 0.28
        let drift = max(1, imageHeight * 0.026)

        return (
            x: CGFloat(sin(secondaryPhase)) * drift * 0.28,
            y: CGFloat(cos(primaryPhase)) * drift,
            scale: CGFloat(1 + sin(secondaryPhase) * 0.006),
            opacity: 0.94 + ((sin(primaryPhase * 0.8) + 1) * 0.025),
            pitch: sin(primaryPhase) * 0.55,
            yaw: cos(secondaryPhase) * 0.72
        )
    }

    private static let tileURLs = [
        "https://img.nvidiagrid.net/apps/107928616/ZZ/TV_BANNER_01_5ad039a4-c04f-4f62-aee2-061e1f7cdbb2.jpg",
        "https://img.nvidiagrid.net/apps/103550572/ZZ/TV_BANNER_01_81697ce5-1b94-4814-a567-b76af4a3bd5f.jpg",
        "https://img.nvidiagrid.net/apps/101138111/ZZ/TV_BANNER_01_9b412ae4-1af5-4a5a-b560-20632b95106a.jpg",
        "https://img.nvidiagrid.net/apps/101805611/ZZ/TV_BANNER_01_4c1806a2-a0fb-41bc-90b8-fc0727c51973.jpg",
        "https://img.nvidiagrid.net/apps/101574711/ZZ/TV_BANNER_01_3852ab9d-e683-4180-8d22-a1afe8d01c19.jpg",
        "https://img.nvidiagrid.net/apps/101595711/ZZ/TV_BANNER_01_636e3871-d3c8-4637-a294-5797bd8bae77.jpg",
        "https://img.nvidiagrid.net/apps/102926463/ZZ/TV_BANNER_01_e7481c30-9615-4943-8e5e-a2b1b4524a49.jpg",
        "https://img.nvidiagrid.net/apps/102240611/ZZ/TV_BANNER_01_8a1a13f8-3481-4d8d-a0ed-2dcd596ff011.jpg",
        "https://img.nvidiagrid.net/apps/100871511/ZZ/TV_BANNER_01_3629f9cc-82e9-4274-81d8-7390374a2c4a.jpg",
        "https://img.nvidiagrid.net/apps/100881611/ZZ/TV_BANNER_01_c0c8f3b9-66a8-4d44-8fa6-33ceb557d39f.jpg",
        "https://img.nvidiagrid.net/apps/102456711/ZZ/TV_BANNER_01_bd23da25-fc82-4a12-a8e4-7aebd9e8f3e2.jpg",
        "https://img.nvidiagrid.net/apps/102757911/ZZ/TV_BANNER_01_4d783878-a7df-4185-9ea3-00a84328cb8c.jpg",
        "https://img.nvidiagrid.net/apps/100886311/ZZ/TV_BANNER_01_3c0caea0-426c-43ef-891d-175723e2f98d.jpg",
        "https://img.nvidiagrid.net/apps/102697711/ZZ/TV_BANNER_01_2e282480-47a1-4da3-8efb-3d01213da708.jpg",
        "https://img.nvidiagrid.net/apps/100885311/ZZ/TV_BANNER_01_00c9dc2a-941c-4f00-bd63-05eaf6ede662.jpg",
        "https://img.nvidiagrid.net/apps/100884811/ZZ/TV_BANNER_01_8b2e4223-92d0-4b95-93a7-ec44ed6c1a88.jpg",
        "https://img.nvidiagrid.net/apps/101535511/ZZ/TV_BANNER_01_a7f8fd8f-2c18-42de-b887-4a6a78414f0e.png",
        "https://img.nvidiagrid.net/apps/107696947/ZZ/TV_BANNER_01_eadc37df-4ac5-4d93-9059-3898f2b29cf5.jpg",
        "https://img.nvidiagrid.net/apps/100980011/ZZ/TV_BANNER_01_a81c5653-1d0c-44fc-a6ea-3a3a290d4036.jpg",
        "https://img.nvidiagrid.net/apps/100883711/ZZ/TV_BANNER_01_c370071e-0f90-416d-b007-211fa24dd477.jpg",
        "https://img.nvidiagrid.net/apps/107069168/ZZ/TV_BANNER_01_7b3a959a-38b7-4ac8-b592-5ad73801f3a5.jpg",
        "https://img.nvidiagrid.net/apps/100885211/ZZ/TV_BANNER_01_93876b27-9695-43bb-bafa-4bea6e9f3426.jpg",
        "https://img.nvidiagrid.net/apps/101385811/ZZ/TV_BANNER_01_8f713d3f-fe74-4816-a35c-4b57fe1f385d.jpg",
        "https://img.nvidiagrid.net/apps/103955842/ZZ/TV_BANNER_01_8f7b8453-2ee0-4651-aab2-06c359a84a88.jpg",
        "https://img.nvidiagrid.net/apps/101803711/ZZ/TV_BANNER_01_6adbd882-66c7-40bc-b47d-784eb38fd170.jpg",
        "https://img.nvidiagrid.net/apps/100888211/ZZ/TV_BANNER_01_1da892b7-d660-4546-ac1b-492216efac76.jpg",
        "https://img.nvidiagrid.net/apps/102290811/ZZ/TV_BANNER_01_79490f29-f467-43a1-81b2-1d6ee728ed01.jpg",
        "https://img.nvidiagrid.net/apps/100884011/ZZ/TV_BANNER_01_742eeb39-c372-4b14-b0ff-2b2e8f02ee97.jpg",
        "https://img.nvidiagrid.net/apps/103387780/ZZ/TV_BANNER_01_dd536249-e0ac-42c7-86f5-702b9621fc92.jpg",
        "https://img.nvidiagrid.net/apps/100987011/ZZ/TV_BANNER_01_4d957482-945f-44d4-9d39-e0102a1458ce.jpg"
    ]

    private static let reorder = [26, 22, 32, 31, 30, 29, 25, 21, 17, 13, 12, 28, 23, 19, 14, 9, 3, 6, 24, 20, 16, 10, 1, 4, 36, 18, 15, 5, 2, 8, 35, 34, 33, 27, 11, 7]

    private static let orderedTileURLs: [String?] = {
        var ordered = Array<String?>(repeating: nil, count: 36)
        for (index, url) in tileURLs.enumerated() {
            guard let target = reorder.firstIndex(of: index + 1) else { continue }
            ordered[target] = url
        }
        return ordered
    }()
}

private struct LoginWallGridTile: View {
    let urlString: String?

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .opacity(1)
            } else {
                fallbackTile
            }
        }
        .task(id: urlString) {
            image = nil
            guard let urlString, let url = URL(string: urlString) else { return }
            guard let cached = await CatalogImageCache.shared.image(for: url, maxPixelSize: 768) else { return }
            guard !Task.isCancelled else { return }
            image = cached.image
        }
    }

    private var fallbackTile: some View {
        VendorResourceImage(name: "LoginWallFallbackTile", fileExtension: "png")
            .scaledToFit()
            .opacity(0.5)
    }
}

struct AccountAvatar: View {
    let name: String
    var size: CGFloat = 42

    private var initials: String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        let fallback = name.first.map(String.init) ?? "O"
        let value = letters.isEmpty ? fallback : String(letters)
        return value.uppercased()
    }

    var body: some View {
        Text(initials)
            .nvidiaFont(size: size * 0.34, weight: .bold)
            .foregroundStyle(.black)
            .frame(width: size, height: size)
            .background(MacForceNowDesign.accent, in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
    }
}

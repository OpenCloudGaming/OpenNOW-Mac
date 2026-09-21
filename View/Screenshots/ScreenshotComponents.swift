import AppKit
import SwiftUI

struct ScreenshotMetric: View {
    let title: String
    let value: String
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * uiScale) {
            Text(title)
                .font(.recordingsFont(size: 9 * uiScale, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(OPNDesign.Text.muted)
            Text(value)
                .font(.recordingsFont(size: 13 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10 * uiScale)
        .background(RecordingsLayout.card)
        .overlay { Rectangle().stroke(RecordingsLayout.stroke, lineWidth: 1) }
    }
}

struct ScreenshotSearchField: View {
    @Binding var text: String
    let uiScale: CGFloat

    var body: some View {
        HStack(spacing: 10 * uiScale) {
            Image(systemName: "magnifyingglass")
                .font(.recordingsFont(size: 13 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.accentInk.opacity(0.85))
            TextField("Search title, file, or app ID", text: $text)
                .textFieldStyle(.plain)
                .font(.recordingsFont(size: 13 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.primary)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(OPNDesign.Text.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12 * uiScale)
        .frame(height: 40 * uiScale)
        .background(OPNDesign.Stroke.subtle)
        .overlay { Rectangle().stroke(RecordingsLayout.stroke, lineWidth: 1) }
    }
}

struct ScreenshotFilterChip: View {
    let filter: ScreenshotFilter
    let isActive: Bool
    let uiScale: CGFloat
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6 * uiScale) {
                Image(systemName: filter.systemImage)
                    .font(.recordingsFont(size: 10 * uiScale, weight: .bold))
                Text(filter.title)
            }
            .font(.recordingsFont(size: 10 * uiScale, weight: .bold))
            .foregroundStyle(isActive ? .black.opacity(0.86) : isHovering ? OPNDesign.Text.primary : OPNDesign.Text.secondary)
            .padding(.horizontal, 9 * uiScale)
            .frame(height: 28 * uiScale)
            .background(isActive ? OPNDesign.accent : OPNDesign.Fill.neutral(isHovering ? 0.09 : 0.055))
            .overlay { Rectangle().stroke(isActive ? OPNDesign.accent : RecordingsLayout.stroke, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct ScreenshotAlbumChip: View {
    let title: String
    let count: Int
    let isActive: Bool
    let uiScale: CGFloat
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6 * uiScale) {
                Text(title)
                    .lineLimit(1)
                Text("\(count)")
                    .font(.recordingsFont(size: 9 * uiScale, weight: .bold))
                    .foregroundStyle(isActive ? .black.opacity(0.7) : OPNDesign.Text.muted)
                    .padding(.horizontal, 5 * uiScale)
                    .frame(height: 15 * uiScale)
                    .background(isActive ? .black.opacity(0.12) : OPNDesign.Fill.neutral(0.10))
            }
            .font(.recordingsFont(size: 10 * uiScale, weight: .bold))
            .foregroundStyle(isActive ? .black.opacity(0.86) : isHovering ? OPNDesign.Text.primary : OPNDesign.Text.secondary)
            .padding(.horizontal, 9 * uiScale)
            .frame(height: 28 * uiScale)
            .background(isActive ? OPNDesign.accent : OPNDesign.Fill.neutral(isHovering ? 0.09 : 0.055))
            .overlay { Rectangle().stroke(isActive ? OPNDesign.accent : RecordingsLayout.stroke, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct ScreenshotPill: View {
    let text: String
    let isActive: Bool
    let uiScale: CGFloat

    var body: some View {
        Text(text)
            .font(.recordingsFont(size: 9 * uiScale, weight: .bold))
            .foregroundStyle(isActive ? .black.opacity(0.86) : OPNDesign.Text.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7 * uiScale)
            .frame(height: 20 * uiScale)
            .background(isActive ? OPNDesign.accent : OPNDesign.Stroke.subtle)
            .overlay { Rectangle().stroke(isActive ? OPNDesign.accent : OPNDesign.Stroke.subtle, lineWidth: 1) }
    }
}

struct ScreenshotRow: View {
    let screenshot: StreamScreenshot
    let isSelected: Bool
    let uiScale: CGFloat
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12 * uiScale) {
                HStack(alignment: .top, spacing: 12 * uiScale) {
                    ScreenshotThumbnail(screenshot: screenshot, isSelected: isSelected, isHovering: isHovering, uiScale: uiScale)
                    VStack(alignment: .leading, spacing: 6 * uiScale) {
                        Text(screenshot.title)
                            .font(.recordingsFont(size: 14 * uiScale, weight: .bold))
                            .foregroundStyle(OPNDesign.Text.primary)
                            .lineLimit(2)
                        Text(RecordingFormat.relativeDateText(screenshot.createdAt))
                            .font(.recordingsFont(size: 11 * uiScale, weight: .medium))
                            .foregroundStyle(OPNDesign.Text.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 7 * uiScale) {
                    ScreenshotPill(text: screenshot.width > 0 && screenshot.height > 0 ? "\(screenshot.width)x\(screenshot.height)" : "AUTO", isActive: isSelected, uiScale: uiScale)
                    ScreenshotPill(text: RecordingFormat.compactFileSizeText(screenshot.fileSizeBytes), isActive: false, uiScale: uiScale)
                    Spacer(minLength: 0)
                    if !screenshot.albumIDs.isEmpty {
                        ScreenshotPill(text: "\(screenshot.albumIDs.count) album\(screenshot.albumIDs.count == 1 ? "" : "s")", isActive: true, uiScale: uiScale)
                    }
                }
            }
            .padding(13 * uiScale)
            .background(background)
            .overlay(alignment: .leading) { Rectangle().fill(isSelected ? OPNDesign.accent : .clear).frame(width: 3) }
            .overlay { Rectangle().stroke(isSelected ? OPNDesign.accent.opacity(0.48) : OPNDesign.Fill.neutral(isHovering ? 0.18 : 0.08), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(screenshot.title)
        .accessibilityValue("\(RecordingFormat.relativeDateText(screenshot.createdAt)), \(screenshot.width)x\(screenshot.height), \(RecordingFormat.compactFileSizeText(screenshot.fileSizeBytes))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var background: some ShapeStyle {
        if isSelected { return AnyShapeStyle(OPNDesign.accent.opacity(0.105)) }
        return AnyShapeStyle(OPNDesign.Fill.neutral(isHovering ? 0.075 : 0.04))
    }
}

struct ScreenshotThumbnail: View {
    let screenshot: StreamScreenshot
    let isSelected: Bool
    let isHovering: Bool
    let uiScale: CGFloat
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 76 * uiScale, height: 46 * uiScale)
                    .clipped()
            } else {
                LinearGradient(
                    colors: [OPNDesign.Fill.neutral(0.13), OPNDesign.Fill.neutral(0.03), OPNDesign.accent.opacity(isSelected ? 0.24 : 0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                DiagonalGrid()
                    .stroke(Color.black.opacity(0.35), lineWidth: 1)
                Image(systemName: "camera.fill")
                    .font(.recordingsFont(size: 18 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.secondary)
            }
            if isHovering || isSelected {
                Rectangle().fill(Color.black.opacity(thumbnail == nil ? 0 : 0.22))
                Image(systemName: "magnifyingglass")
                    .font(.recordingsFont(size: 17 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .shadow(color: .black.opacity(0.6), radius: 7 * uiScale, y: 2 * uiScale)
            }
        }
        .frame(width: 76 * uiScale, height: 46 * uiScale)
        .overlay(alignment: .bottomTrailing) {
            Text(screenshot.width > 0 && screenshot.height > 0 ? "\(screenshot.width)x\(screenshot.height)" : "AUTO")
                .font(.recordingsFont(size: 8 * uiScale, weight: .bold))
                .foregroundStyle(.black.opacity(0.86))
                .padding(.horizontal, 5 * uiScale)
                .frame(height: 15 * uiScale)
                .background(OPNDesign.accent)
        }
        .overlay { Rectangle().stroke(OPNDesign.Stroke.regular, lineWidth: 1) }
        .task(id: screenshot.id) {
            thumbnail = await ScreenshotImageLoader.image(for: screenshot, longestEdge: 360)
        }
    }
}

/// The large reader. Loads a downscaled copy rather than the full PNG, so a 4K still does not pin
/// tens of megabytes of decoded pixels the moment it is selected.
struct ScreenshotImageView: View {
    let screenshot: StreamScreenshot
    let longestEdge: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading image…")
                        .font(.recordingsFont(size: 11, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                }
            }
        }
        .task(id: screenshot.id) {
            image = nil
            image = await ScreenshotImageLoader.image(for: screenshot, longestEdge: longestEdge)
        }
    }
}

struct ScreenshotEmptyState: View {
    enum Kind {
        case library
        case search
    }

    let kind: Kind
    let action: () -> Void
    let uiScale: CGFloat

    var body: some View {
        VStack(spacing: 16 * uiScale) {
            ZStack {
                Circle()
                    .fill(OPNDesign.accent.opacity(0.10))
                    .frame(width: 78 * uiScale, height: 78 * uiScale)
                Image(systemName: kind == .library ? "camera.fill" : "line.3.horizontal.decrease.circle")
                    .font(.recordingsFont(size: 32 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.accentInk)
            }
            Text(kind == .library ? "No screenshots yet" : "No matches")
                .font(.recordingsFont(size: 18 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.primary)
            Text(kind == .library ? "Start a stream, open the sidebar, and press the camera to save stills here." : "Clear search, filters, or the album to show the rest of your screenshots.")
                .font(.recordingsFont(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280 * uiScale)
            Button(kind == .library ? "Refresh" : "Clear Filters", action: action)
                .buttonStyle(RecordingActionButtonStyle(tone: .primary, uiScale: uiScale))
        }
        .padding(28 * uiScale)
    }
}

struct ScreenshotEmptyPlayer: View {
    let message: String
    let uiScale: CGFloat

    var body: some View {
        VStack(spacing: 18 * uiScale) {
            ZStack {
                Rectangle()
                    .fill(OPNDesign.Fill.neutral(0.045))
                    .frame(width: 180 * uiScale, height: 108 * uiScale)
                    .overlay { Rectangle().stroke(OPNDesign.Stroke.regular, lineWidth: 1) }
                Image(systemName: "camera.fill")
                    .font(.recordingsFont(size: 42 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.accentInk.opacity(0.88))
            }
            Text("Select a screenshot")
                .font(.recordingsFont(size: 24 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.primary)
            Text(message.isEmpty ? "Your captured stills appear here with a large preview, file actions, and albums." : message)
                .font(.recordingsFont(size: 13 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420 * uiScale)
        }
        .padding(36 * uiScale)
        .background(RecordingsLayout.surface)
        .overlay { Rectangle().stroke(RecordingsLayout.stroke, lineWidth: 1) }
        .shadow(color: .black.opacity(0.42), radius: 22 * uiScale, y: 10 * uiScale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A small centered text-entry panel for album names and screenshot titles. Kept in the page rather
/// than raised as a sheet so it layers exactly like the collection dialogs the catalog already uses.
struct ScreenshotTextPrompt: View {
    let title: String
    let eyebrow: String
    let placeholder: String
    let confirmTitle: String
    @Binding var text: String
    let uiScale: CGFloat
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 16 * uiScale) {
                VStack(alignment: .leading, spacing: 5 * uiScale) {
                    Text(eyebrow)
                        .font(.recordingsFont(size: 10 * uiScale, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(OPNDesign.accentInk)
                    Text(title)
                        .font(.recordingsFont(size: 18 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                }
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.recordingsFont(size: 13 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .padding(.horizontal, 12 * uiScale)
                    .frame(height: 40 * uiScale)
                    .background(OPNDesign.Stroke.subtle)
                    .overlay { Rectangle().stroke(RecordingsLayout.stroke, lineWidth: 1) }
                    .focused($isFocused)
                    .onSubmit(onConfirm)
                HStack(spacing: 10 * uiScale) {
                    Spacer()
                    Button("CANCEL", action: onCancel)
                        .buttonStyle(RecordingActionButtonStyle(tone: .secondary, uiScale: uiScale))
                    Button(confirmTitle, action: onConfirm)
                        .buttonStyle(RecordingActionButtonStyle(tone: .primary, uiScale: uiScale))
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24 * uiScale)
            .frame(maxWidth: 420 * uiScale)
            .background {
                Rectangle().fill(RecordingsLayout.surface)
                Rectangle().fill(RecordingsLayout.card)
            }
            .overlay { Rectangle().stroke(RecordingsLayout.strongStroke, lineWidth: 1) }
            .shadow(color: .black.opacity(0.55), radius: 24 * uiScale, y: 10 * uiScale)
            .onAppear { isFocused = true }
        }
    }
}

/// Decodes a screenshot off the main thread and caches it by id. One image per id; the two call
/// sites differ only in how many pixels they ask for, and both are small next to the source PNG.
@MainActor
enum ScreenshotImageLoader {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for screenshot: StreamScreenshot, longestEdge: CGFloat) async -> NSImage? {
        let key = "\(screenshot.id.uuidString)-\(Int(longestEdge))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let url = screenshot.imageURL
        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(64, longestEdge)
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

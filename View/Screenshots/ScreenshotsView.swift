import AppKit
import SwiftUI

/// The screenshot library page. Left column is the albums, search, filters and the shot list; the
/// right pane is the selected image with its file actions and album membership.
struct ScreenshotsView: View {
    @Environment(\.opnUIScale) private var uiScale
    @StateObject private var model = ScreenshotsViewModel()
    /// Set only when controller mode embeds this page; nil on the desktop surface.
    @Environment(\.controllerPageCommand) private var controllerPageCommand

    @State private var albumEditor: ScreenshotAlbumEditorState = .hidden
    @State private var albumNameDraft = ""
    @State private var renamingScreenshot: StreamScreenshot?
    @State private var screenshotNameDraft = ""
    @State private var contextMenuScreenshot: StreamScreenshot?
    @State private var contextMenuAnchor: CGPoint = .zero
    @State private var contextSurface = OPNContextSurface()

    private var visibleScreenshots: [StreamScreenshot] { model.visibleScreenshots }

    private var librarySubtitle: String {
        guard let newest = model.stats.newest else { return "Captured stills from your streams" }
        return "Latest: \(RecordingFormat.relativeDateText(newest.createdAt))"
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                libraryList
                    .frame(width: min(proxy.size.width * 0.45, OPNDesign.clamped(proxy.size.width * 0.34, minimum: 380 * uiScale, maximum: 520 * uiScale)))
                    .disabled(model.editorViewModel != nil)
                previewPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The pane's decorative backdrop ignores the safe area; clipping keeps it inside
                    // the pane so it can never paint the diagonal grid over the list.
                    .clipped()
            }
        }
        // Opaque base, not the striped backdrop: the list is the page's content surface and the
        // stripes belong to the empty preview only.
        .background(RecordingsLayout.surface)
        .ignoresSafeArea(edges: .bottom)
        .overlay { albumEditorOverlay }
        .overlay { renameOverlay }
        .onAppear { model.reload(showMessage: false) }
        .onDisappear { model.closeEditor() }
        .onChange(of: controllerPageCommand) { _, pageCommand in
            guard let pageCommand else { return }
            model.applyControllerCommand(pageCommand.command)
        }
        .onChange(of: visibleScreenshots.map(\.id)) { _, ids in
            model.reconcileSelection(withVisibleIDs: ids)
        }
        .opnConfirmation(
            isPresented: screenshotDeleteDialogPresented,
            eyebrow: "DELETE SCREENSHOT",
            title: model.deleteDialogTitle,
            message: "This permanently removes the image and its metadata from OpenNOW screenshots.",
            actions: [
                OPNConfirmationAction("CANCEL", role: .cancel) { model.pendingDelete = nil },
                OPNConfirmationAction("DELETE SCREENSHOT", role: .destructive) { model.deletePendingScreenshot() }
            ]
        )
        .opnConfirmation(
            isPresented: albumDeleteDialogPresented,
            eyebrow: "DELETE ALBUM",
            title: "Delete \"\(model.pendingAlbumDelete?.name ?? "album")\"?",
            message: "The screenshots stay in your library; only the album is removed.",
            actions: [
                OPNConfirmationAction("CANCEL", role: .cancel) { model.pendingAlbumDelete = nil },
                OPNConfirmationAction("DELETE ALBUM", role: .destructive) { model.deletePendingAlbum() }
            ]
        )
    }

    // MARK: - Left column

    private var libraryList: some View {
        VStack(alignment: .leading, spacing: 0) {
            libraryHeader
            ScreenshotSearchField(text: $model.searchText, uiScale: uiScale)
                .padding(.horizontal, 18 * uiScale)
                .padding(.top, 4 * uiScale)
            albumStrip
                .padding(.top, 12 * uiScale)
                // Above the sort/filter row and the shot list: the album "Manage" menu opens
                // downward over both, and a lower z-order let them draw on top of the panel.
                .zIndex(3)
            sortAndFilters
                .padding(.horizontal, 18 * uiScale)
                .padding(.top, 12 * uiScale)
                .zIndex(1)

            if model.screenshots.isEmpty {
                ScreenshotEmptyState(kind: .library, action: { model.reload(showMessage: true) }, uiScale: uiScale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleScreenshots.isEmpty {
                ScreenshotEmptyState(kind: .search, action: {
                    model.clearSearch()
                    model.clearFilters()
                    model.selectAlbum(.all)
                }, uiScale: uiScale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 10 * uiScale) {
                        ForEach(visibleScreenshots) { screenshot in
                            ScreenshotRow(screenshot: screenshot, isSelected: model.selectedScreenshot?.id == screenshot.id, uiScale: uiScale) {
                                model.select(screenshot)
                            }
                            .background {
                                OPNContextRowAnchor(surface: contextSurface, id: screenshot.id)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .padding(.horizontal, 14 * uiScale)
                    .padding(.vertical, 18 * uiScale)
                }
            }
        }
        .background(RecordingsLayout.sidebar)
        .background {
            OPNContextMenuHost(
                surface: contextSurface,
                onContextClick: { id, point in
                    guard model.editorViewModel == nil else { return }
                    guard let screenshot = visibleScreenshots.first(where: { $0.id == id }) else { return }
                    contextMenuScreenshot = screenshot
                    contextMenuAnchor = point
                },
                onDismiss: { contextMenuScreenshot = nil }
            )
            .allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) { Rectangle().fill(RecordingsLayout.stroke).frame(width: 1) }
        .overlay { contextMenuOverlay }
    }

    @ViewBuilder
    private var contextMenuOverlay: some View {
        if let screenshot = contextMenuScreenshot {
            OPNContextMenuOverlay(items: contextMenuItems(for: screenshot), anchor: contextMenuAnchor) {
                contextMenuScreenshot = nil
            }
        }
    }

    private func contextMenuItems(for screenshot: StreamScreenshot) -> [OPNDropdownItem] {
        [
            OPNDropdownItem(id: "open", title: "Open Screenshot") { model.open(screenshot) },
            OPNDropdownItem(id: "edit", title: "Edit Screenshot") { model.startEditing(screenshot) },
            OPNDropdownItem(id: "rename", title: "Rename…") {
                renamingScreenshot = screenshot
                screenshotNameDraft = screenshot.title
            },
            OPNDropdownItem(id: "reveal", title: "Reveal in Finder") { model.reveal(screenshot) },
            OPNDropdownItem(id: "copy", title: "Copy File Path") { model.copyPath(screenshot) },
            OPNDropdownItem(id: "delete", title: "Delete", isDestructive: true, startsGroup: true) {
                model.pendingDelete = screenshot
            }
        ]
    }

    private var libraryHeader: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            HStack(alignment: .top, spacing: 12 * uiScale) {
                VStack(alignment: .leading, spacing: 5 * uiScale) {
                    Text("SCREENSHOTS")
                        .font(.recordingsFont(size: 11 * uiScale, weight: .bold))
                        .tracking(1.6 * uiScale)
                        .foregroundStyle(OPNDesign.accentInk)
                    HStack(alignment: .center, spacing: 10 * uiScale) {
                        Text("Captured Stills")
                            .font(.recordingsFont(size: 25 * uiScale, weight: .bold))
                            .foregroundStyle(OPNDesign.Text.primary)
                        OPNBetaTag(uiScale: uiScale * 0.9)
                    }
                    Text(librarySubtitle)
                        .font(.recordingsFont(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Button { model.reload(showMessage: true) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.recordingsFont(size: 15 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                        .frame(width: 40 * uiScale, height: 40 * uiScale)
                        .background(OPNDesign.Stroke.subtle)
                        .overlay { Rectangle().stroke(RecordingsLayout.stroke, lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .help("Refresh screenshots")
            }

            HStack(spacing: 8 * uiScale) {
                ScreenshotMetric(title: "SHOTS", value: "\(model.stats.count)", uiScale: uiScale)
                ScreenshotMetric(title: "ALBUMS", value: "\(model.stats.albumCount)", uiScale: uiScale)
                ScreenshotMetric(title: "SIZE", value: RecordingFormat.compactFileSizeText(model.stats.totalBytes), uiScale: uiScale)
            }
        }
        .padding(.horizontal, 22 * uiScale)
        .padding(.top, 22 * uiScale)
        .padding(.bottom, 16 * uiScale)
    }

    private var albumStrip: some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            HStack(spacing: 8 * uiScale) {
                Text("ALBUMS")
                    .font(.recordingsFont(size: 10 * uiScale, weight: .bold))
                    .tracking(1.0 * uiScale)
                    .foregroundStyle(OPNDesign.Text.muted)
                Spacer()
                Button {
                    albumNameDraft = ""
                    albumEditor = .create
                } label: {
                    HStack(spacing: 5 * uiScale) {
                        Image(systemName: "plus")
                        Text("New Album")
                    }
                    .font(.recordingsFont(size: 10 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.accentInk)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18 * uiScale)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7 * uiScale) {
                    ScreenshotAlbumChip(title: "All Screenshots", count: model.stats.count, isActive: model.selectedAlbum == .all, uiScale: uiScale) {
                        model.selectAlbum(.all)
                    }
                    ScreenshotAlbumChip(title: "Unfiled", count: model.unfiledCount, isActive: model.selectedAlbum == .unfiled, uiScale: uiScale) {
                        model.selectAlbum(.unfiled)
                    }
                    ForEach(model.albums) { album in
                        ScreenshotAlbumChip(title: album.name, count: model.albumCounts[album.id] ?? 0, isActive: model.selectedAlbum == .album(album.id), uiScale: uiScale) {
                            model.selectAlbum(.album(album.id))
                        }
                    }
                }
                .padding(.horizontal, 18 * uiScale)
            }

            if case .album(let id) = model.selectedAlbum, let album = model.albums.first(where: { $0.id == id }) {
                HStack(spacing: 8 * uiScale) {
                    Spacer()
                    OPNDropdownMenu(items: [
                        OPNDropdownItem(id: "rename", title: "Rename Album…") {
                            albumNameDraft = album.name
                            albumEditor = .rename(album)
                        },
                        OPNDropdownItem(id: "delete", title: "Delete Album", isDestructive: true) {
                            model.pendingAlbumDelete = album
                        }
                    ]) {
                        HStack(spacing: 6 * uiScale) {
                            Image(systemName: "ellipsis")
                            Text("Manage \"\(album.name)\"")
                        }
                        .font(.recordingsFont(size: 10 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.secondary)
                    }
                }
                .padding(.horizontal, 18 * uiScale)
            }
        }
    }

    private var sortAndFilters: some View {
        VStack(alignment: .leading, spacing: 12 * uiScale) {
            HStack(spacing: 10 * uiScale) {
                OPNDropdownMenu(
                    items: ScreenshotSortOrder.allCases.map { order in
                        OPNDropdownItem(id: order.id, title: order.title, isSelected: order == model.sortOrder) { model.sortOrder = order }
                    }
                ) {
                    HStack(spacing: 8 * uiScale) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(model.sortOrder.title)
                        Image(systemName: "chevron.down")
                            .font(.recordingsFont(size: 9 * uiScale, weight: .bold))
                    }
                    .font(.recordingsFont(size: 11 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .padding(.horizontal, OPNDesign.Spacing.controlRow(scale: uiScale))
                    .frame(height: 32 * uiScale)
                    .background(RecordingsLayout.card)
                    .overlay { Rectangle().stroke(RecordingsLayout.stroke, lineWidth: 1) }
                }

                Spacer()

                Text("\(visibleScreenshots.count) shown")
                    .font(.recordingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
            }
            .zIndex(1)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7 * uiScale) {
                    ForEach(ScreenshotFilter.allCases) { filter in
                        ScreenshotFilterChip(filter: filter, isActive: model.activeFilters.contains(filter), uiScale: uiScale) {
                            model.toggleFilter(filter)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Dialogs

    private var screenshotDeleteDialogPresented: Binding<Bool> {
        Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } })
    }

    private var albumDeleteDialogPresented: Binding<Bool> {
        Binding(get: { model.pendingAlbumDelete != nil }, set: { if !$0 { model.pendingAlbumDelete = nil } })
    }

    @ViewBuilder
    private var albumEditorOverlay: some View {
        if albumEditor != .hidden {
            ScreenshotTextPrompt(
                title: albumEditor.isRename ? "Rename Album" : "New Album",
                eyebrow: "ALBUM",
                placeholder: "Album name",
                confirmTitle: albumEditor.isRename ? "RENAME" : "CREATE",
                text: $albumNameDraft,
                uiScale: uiScale,
                onCancel: { albumEditor = .hidden },
                onConfirm: {
                    let name = albumNameDraft
                    switch albumEditor {
                    case .create:
                        if let album = model.createAlbum(named: name) { model.selectAlbum(.album(album.id)) }
                    case .rename(let album):
                        model.renameAlbum(album, to: name)
                    case .hidden:
                        break
                    }
                    albumEditor = .hidden
                }
            )
        }
    }

    @ViewBuilder
    private var renameOverlay: some View {
        if let screenshot = renamingScreenshot {
            ScreenshotTextPrompt(
                title: "Rename Screenshot",
                eyebrow: "SCREENSHOT",
                placeholder: "Screenshot title",
                confirmTitle: "RENAME",
                text: $screenshotNameDraft,
                uiScale: uiScale,
                onCancel: { renamingScreenshot = nil },
                onConfirm: {
                    model.rename(screenshot, to: screenshotNameDraft)
                    renamingScreenshot = nil
                }
            )
        }
    }
}

// MARK: - Right pane

extension ScreenshotsView {
    private var previewPane: some View {
        // The backdrop is a `.background`, never a ZStack sibling: an `ignoresSafeArea` child in a
        // ZStack drew its blend-mode grid over the content instead of under it.
        Group {
            if let editor = model.editorViewModel {
                ScreenshotEditorView(
                    model: editor,
                    onCancel: model.closeEditor,
                    onSave: model.startEditorSave
                )
                .id(editor.screenshot.id)
            }
            if model.editorViewModel == nil, let selected = model.selectedScreenshot {
                screenshotDetail(selected)
            }
            if model.editorViewModel == nil, model.selectedScreenshot == nil {
                ScreenshotEmptyPlayer(message: model.message, uiScale: uiScale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RecordingsBackdrop())
    }

    private func screenshotDetail(_ screenshot: StreamScreenshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            detailHeader(screenshot)
            ScreenshotImageView(screenshot: screenshot, longestEdge: 2400)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .overlay { Rectangle().stroke(Color.black.opacity(0.72), lineWidth: 1) }
                .padding(20 * uiScale)
            detailFooter(screenshot)
        }
    }

    private func detailHeader(_ screenshot: StreamScreenshot) -> some View {
        HStack(alignment: .top, spacing: 14 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                Text(screenshot.title)
                    .font(.recordingsFont(size: 20 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .lineLimit(2)
                Text("\(RecordingFormat.dateText(screenshot.createdAt)) · \(RecordingFormat.relativeDateText(screenshot.createdAt))")
                    .font(.recordingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 7 * uiScale) {
                ScreenshotPill(text: screenshot.width > 0 && screenshot.height > 0 ? "\(screenshot.width)x\(screenshot.height)" : "AUTO", isActive: false, uiScale: uiScale)
                ScreenshotPill(text: RecordingFormat.compactFileSizeText(screenshot.fileSizeBytes), isActive: false, uiScale: uiScale)
                if !screenshot.applicationID.isEmpty {
                    ScreenshotPill(text: screenshot.applicationID, isActive: false, uiScale: uiScale)
                }
            }
        }
        .padding(.horizontal, 22 * uiScale)
        .padding(.top, 22 * uiScale)
        .background(RecordingsLayout.surface)
    }

    private func detailFooter(_ screenshot: StreamScreenshot) -> some View {
        VStack(alignment: .leading, spacing: 12 * uiScale) {
            SettingsFlowLayout(spacing: 8 * uiScale) {
                Button { model.startEditing(screenshot) } label: {
                    HStack(spacing: 6 * uiScale) {
                        Text("Edit")
                        OPNBetaTag(uiScale: uiScale)
                    }
                }
                    .buttonStyle(RecordingActionButtonStyle(tone: .secondary, uiScale: uiScale))
                Button("Open") { model.open(screenshot) }
                    .buttonStyle(RecordingActionButtonStyle(tone: .primary, uiScale: uiScale))
                Button("Reveal in Finder") { model.reveal(screenshot) }
                    .buttonStyle(RecordingActionButtonStyle(tone: .secondary, uiScale: uiScale))
                Button("Copy Path") { model.copyPath(screenshot) }
                    .buttonStyle(RecordingActionButtonStyle(tone: .secondary, uiScale: uiScale))
                Button("Delete") { model.pendingDelete = screenshot }
                    .buttonStyle(RecordingActionButtonStyle(tone: .destructive, uiScale: uiScale))
            }
            if !model.message.isEmpty {
                Text(model.message)
                    .font(.recordingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(model.copiedPathScreenshotID == screenshot.id ? OPNDesign.accentInk : OPNDesign.Text.tertiary)
                    .lineLimit(2)
            }
            albumMembership(screenshot)
        }
        .padding(.horizontal, 22 * uiScale)
        .padding(.top, 12 * uiScale)
        .padding(.bottom, 20 * uiScale)
        .background(RecordingsLayout.surface)
    }

    private func albumMembership(_ screenshot: StreamScreenshot) -> some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            HStack(spacing: 8 * uiScale) {
                Text("ALBUMS")
                    .font(.recordingsFont(size: 10 * uiScale, weight: .bold))
                    .tracking(1.0 * uiScale)
                    .foregroundStyle(OPNDesign.Text.muted)
                Spacer()
                Button {
                    albumNameDraft = ""
                    albumEditor = .create
                } label: {
                    HStack(spacing: 5 * uiScale) {
                        Image(systemName: "plus")
                        Text("New Album")
                    }
                    .font(.recordingsFont(size: 10 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.accentInk)
                }
                .buttonStyle(.plain)
            }
            if model.albums.isEmpty {
                Text("No albums yet. Create one to file this shot.")
                    .font(.recordingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7 * uiScale) {
                        ForEach(model.albums) { album in
                            let isMember = screenshot.albumIDs.contains(album.id)
                            Button {
                                model.setAlbumMembership(screenshot, album: album, isMember: !isMember)
                            } label: {
                                HStack(spacing: 6 * uiScale) {
                                    Image(systemName: isMember ? "checkmark.square.fill" : "square")
                                        .font(.recordingsFont(size: 10 * uiScale, weight: .bold))
                                    Text(album.name)
                                }
                                .font(.recordingsFont(size: 10 * uiScale, weight: .bold))
                                .foregroundStyle(isMember ? .black.opacity(0.86) : OPNDesign.Text.secondary)
                                .padding(.horizontal, 9 * uiScale)
                                .frame(height: 28 * uiScale)
                                .background(isMember ? OPNDesign.accent : OPNDesign.Fill.neutral(0.055))
                                .overlay { Rectangle().stroke(isMember ? OPNDesign.accent : RecordingsLayout.stroke, lineWidth: 1) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

enum ScreenshotAlbumEditorState: Equatable {
    case hidden
    case create
    case rename(ScreenshotAlbum)

    var isRename: Bool {
        if case .rename = self { return true }
        return false
    }
}

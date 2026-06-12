import Foundation

extension OPNGameCatalogView {
    @objc func updateButtonHintPillFrame() {}

    @objc func updateSearchPanelFrame() {}

    @objc func scheduleRenderStore() {
        guard !renderStoreScheduled else { return }
        renderStoreScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderStoreScheduled = false
            self.rebuildSwiftUICatalog()
        }
    }

    @objc func scheduleRenderStoreAfterResize() {
        scheduleRenderStore()
    }

    @objc func resizeRenderTimerFired(_ timer: Timer) {
        resizeRenderTimer = nil
        scheduleRenderStore()
    }

    @objc func renderStore() {
        rebuildSwiftUICatalog()
    }

    @objc(addEmptyStoreStateWithY:contentX:width:)
    func addEmptyStoreState(y: CGFloat, contentX: CGFloat, width: CGFloat) {}

    @objc func updateDesktopHeroFrameForCurrentBounds() {}

    @objc func updateRowFramesForCurrentBounds() {}

    @objc func updateRowVirtualizationForVisibleBounds() {}

    @objc func updateImagePreloadingForMountedRows() {}

    @objc(updateImagePreloadingForRowLayout:)
    func updateImagePreloading(for rowLayout: OPNStoreRowLayout?) {}

    @objc(addSection:index:y:contentX:width:)
    func addSection(_ section: OPNCatalogPanelSectionObject, index sectionIndex: Int, y: CGFloat, contentX: CGFloat, width: CGFloat) {}

    @objc func storeScrollViewBoundsDidChange(_ notification: Notification) {}

    @objc func rowScrollViewBoundsDidChange(_ notification: Notification) {}
}

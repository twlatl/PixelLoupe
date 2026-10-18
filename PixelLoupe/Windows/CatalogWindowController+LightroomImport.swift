import AppKit

/// Library ▸ Lightroom Import Report, and the report shown when an import finishes.
extension CatalogWindowController {
    @objc func showLightroomImportReport(_ sender: Any?) {
        guard let report = LightroomImportReport.load(from: store.packageURL) else { return }
        presentLightroomImportReport(report)
    }

    func presentLightroomImportReport(_ report: LightroomImportReport) {
        if let existing = lightroomReportController, existing.window?.isVisible == true {
            existing.showWindow(nil)
            return
        }
        let controller = LightroomImportReportWindowController(report: report)
        controller.onShowPhotos = { [weak self] key in
            guard let self else { return }
            state.presentation = .grid
            state.filter.scope = .importDifference(reason: key)
            window?.makeKeyAndOrderFront(nil)
        }
        lightroomReportController = controller
        controller.showWindow(nil)
    }
}

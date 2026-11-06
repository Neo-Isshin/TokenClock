#if os(macOS)
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

/// A retained native utility window, sharing the application's model and worker lifecycle.
@MainActor
final class ModelDetectNativeWindow: NSWindowController, NSWindowDelegate {
    let model: ModelDetectNativeModel
    private var hostingView: NSHostingView<ModelDetectNativeView>?
    private var openPanel: NSOpenPanel?
    private var savePanel: NSSavePanel?
    private var phaseObservation: AnyCancellable?

    init(model: ModelDetectNativeModel = ModelDetectNativeModel()) {
        self.model = model
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(model:)") }

    override func loadWindow() {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 480),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = L10n.shared.tr("menu.sessionAssessment")
        panel.minSize = NSSize(width: 860, height: 420)
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.delegate = self
        let hosting = NSHostingView(rootView: makeView())
        panel.contentView = hosting
        hostingView = hosting
        window = panel
        panel.center()
        phaseObservation = model.$phase.sink { [weak self] phase in
            guard let window = self?.window else { return }
            var frame = window.frame
            let height: CGFloat = phase == .result ? 770 : 510
            frame.origin.y += frame.height - height
            frame.size.height = height
            if let screen = window.screen { frame.origin.y = max(screen.visibleFrame.minY, frame.origin.y) }
            window.setFrame(frame, display: true)
        }
    }

    func show(sourcePath: String? = nil, expectedModel: String? = nil, activate: Bool = true) {
        if hostingView == nil { loadWindow() }
        if model.phase == .running {
            focus(activate: activate)
            return
        }
        if let sourcePath {
            model.newDetection()
            model.sourceURL = nil
            model.selectedSessionID = ""
            model.comparisonModel = ""
            model.mode = .session
            model.filePurpose = "session"
            if let path = ModelDetectSessionSource.usablePath(sourcePath) {
                model.prefillSource(URL(fileURLWithPath: path), expectedModel: expectedModel)
            } else {
                model.errorMessage = ModelDetectNativeText.text("会话日志不可读取，请重新选择文件。", "會話日誌無法讀取，請重新選擇檔案。", "The session log is unavailable. Choose the file again.")
            }
        }
        model.connect()
        focus(activate: activate)
    }

    /// A row with no exact log path must ask for a file, never construct a path from its model or ID.
    func showSession(sourcePath: String?, expectedModel: String? = nil, activate: Bool = true) {
        if model.phase == .running {
            show(activate: activate)
            return
        }
        if let path = ModelDetectSessionSource.usablePath(sourcePath) {
            show(sourcePath: path, expectedModel: expectedModel, activate: activate)
            return
        }
        model.newDetection()
        model.sourceURL = nil
        model.selectedSessionID = ""
        model.comparisonModel = ""
        model.mode = .session
        model.filePurpose = "session"
        show(activate: activate)
        chooseFile(sessionOnly: true)
    }

    private func focus(activate: Bool) {
        guard activate else { return }
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshLocalization() {
        window?.title = L10n.shared.tr("menu.sessionAssessment")
        hostingView?.rootView = makeView()
    }

    private func makeView() -> ModelDetectNativeView {
        ModelDetectNativeView(model: model,
                              onChooseFile: { [weak self] in self?.chooseFile() },
                              onExport: { [weak self] kind in self?.export(kind: kind) })
    }

    private func chooseFile(sessionOnly: Bool = false) {
        guard openPanel == nil, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        let extensions = sessionOnly ? ["json", "jsonl", "txt"] : ["json", "jsonl", "txt", "py", "html", "svg"]
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = sessionOnly ? L10n.shared.tr("modelDetect.selectSessionLog") : L10n.shared.tr("modelDetect.chooseFile")
        openPanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.openPanel = nil
            guard response == .OK, let url = panel.url else { return }
            guard let path = ModelDetectSessionSource.usablePath(url.path) else {
                self.model.errorMessage = L10n.shared.tr("modelDetect.fileLimit")
                return
            }
            self.model.prefillSource(URL(fileURLWithPath: path))
        }
    }

    private func export(kind: String) {
        guard ["summary.html", "report.json", "report.html", "observation.json", "evidence.zip"].contains(kind),
              savePanel == nil, let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ModelDetect-" + kind
        panel.canCreateDirectories = true
        if let ext = kind.split(separator: ".").last, let type = UTType(filenameExtension: String(ext)) {
            panel.allowedContentTypes = [type]
        }
        savePanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.savePanel = nil
            guard response == .OK, let destination = panel.url else { return }
            self.model.export(kind: kind, destination: destination)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Closing this presentation does not cancel the retained model's task.
        openPanel?.cancel(nil)
        savePanel?.cancel(nil)
    }
}
#endif

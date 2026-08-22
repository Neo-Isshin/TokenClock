import Foundation
import CGtk

/// Native GTK settings window mirroring the normal macOS preference model.
final class LinuxSettingsWindow: @unchecked Sendable {
    struct ToolOption {
        let emoji: String
        let name: String
        let service: String
        let pathKey: SettingsKey
    }

    static let toolOptions: [ToolOption] = [
        .init(emoji: "🦞", name: "OpenClaw", service: "openclaw", pathKey: .openclawPath),
        .init(emoji: "✳️", name: "Claude Code", service: "claudeCode", pathKey: .claudeCodePath),
        .init(emoji: "✨", name: "Gemini CLI", service: "gemini", pathKey: .geminiPath),
        .init(emoji: "🤖", name: "Codex", service: "codex", pathKey: .codexPath),
        .init(emoji: "⚕️", name: "Hermes", service: "hermes", pathKey: .hermesPath),
        .init(emoji: "🐙", name: "OpenCode", service: "opencode", pathKey: .opencodePath),
        .init(emoji: "🟣", name: "Qwen Code", service: "qwen", pathKey: .qwenPath),
        .init(emoji: "🐙", name: "Copilot", service: "copilot", pathKey: .copilotPath),
        .init(emoji: "⚡", name: "Grok", service: "grok", pathKey: .grokPath),
        .init(emoji: "🤝", name: "Aider", service: "aider", pathKey: .aiderPath),
        .init(emoji: "🛡️", name: "Antigravity", service: "antigravity", pathKey: .antigravityPath),
        .init(emoji: "🤖", name: "Cline", service: "cline", pathKey: .clinePath),
        .init(emoji: "▶️", name: "Continue", service: "continue", pathKey: .continuePath),
        .init(emoji: "🖱️", name: "Cursor Agent", service: "cursorAgent", pathKey: .cursorAgentPath),
    ]

    private weak var owner: LinuxApp?
    private let model: LinuxUsageModel
    private var parent: UnsafeMutablePointer<GtkWidget>?
    private(set) var window: UnsafeMutablePointer<GtkWidget>?

    private var apiEnabledButton: UnsafeMutablePointer<GtkWidget>?
    private var apiPortSpin: UnsafeMutablePointer<GtkWidget>?
    private var cursorCloudButton: UnsafeMutablePointer<GtkWidget>?
    private var detectionLabel: UnsafeMutablePointer<GtkWidget>?
    private var toolButtons: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private var pathEntries: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private var rateWindowButtons: [Int: UnsafeMutablePointer<GtkWidget>] = [:]
    private var thresholdSpins: [SettingsKey: UnsafeMutablePointer<GtkWidget>] = [:]
    private var selectedRateWindow = 10
    private var customNameEntry: UnsafeMutablePointer<GtkWidget>?
    private var customEntries: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private var customNumericEntries: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private var customToggleButtons: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private var customHandButtons: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private var customNumberStyleButtons: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private var customFontButtons: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private var sectionRevealers: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private var sectionButtons: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private var sectionTitles: [String: String] = [:]
    private var expandedSections: Set<String> = []
    private var selectedCustomHandStyle = "round"
    private var selectedCustomNumberStyle = "arabic"
    private var selectedCustomFont = "rounded"
    private var pricingModelEntry: UnsafeMutablePointer<GtkWidget>?
    private var pricingInputEntry: UnsafeMutablePointer<GtkWidget>?
    private var pricingOutputEntry: UnsafeMutablePointer<GtkWidget>?
    private var pricingCacheReadEntry: UnsafeMutablePointer<GtkWidget>?
    private var pricingCacheWriteEntry: UnsafeMutablePointer<GtkWidget>?
    private var pricingRemoveModels: [String: String] = [:]
    private var pricingRefreshInFlight = false

    private lazy var opaque = Unmanaged.passUnretained(self).toOpaque()

    init(parent: UnsafeMutablePointer<GtkWidget>, owner: LinuxApp, model: LinuxUsageModel) {
        self.parent = parent
        self.owner = owner
        self.model = model
        buildWindow(parent: parent)
    }

    func show() {
        loadValues()
        guard let window else { return }
        gtk_widget_show_all(window)
        // A GtkRevealer still contributes its hidden child's natural width. Re-assert the
        // user-facing fixed geometry after realization so long hints/custom editors cannot make
        // the collapsed overview wider than the macOS-normal settings panel.
        gtk_window_resize(tc_gtk_window(window), 520, 548)
        syncDisclosureStates()
        gtk_window_present(tc_gtk_window(window))
    }

    func hide() {
        if let window { gtk_widget_hide(window) }
    }

    func refreshLanguage() {
        guard let parent else { return }
        if let window { gtk_widget_destroy(window) }
        window = nil
        clearWidgetReferences()
        buildWindow(parent: parent)
    }

    fileprivate func handleAction(widget: UnsafeMutablePointer<GtkWidget>) {
        let name = String(cString: tc_gtk_widget_name(widget))
        if name.hasPrefix("settings:section:") {
            toggleDisclosure(String(name.dropFirst("settings:section:".count)))
            return
        }
        if name.hasPrefix("settings:browse:") {
            browse(service: String(name.dropFirst("settings:browse:".count)))
            return
        }
        if name.hasPrefix("settings:rate-window:"),
           let value = Int(name.dropFirst("settings:rate-window:".count)) {
            selectedRateWindow = value
            updateRateWindowButtons()
            return
        }
        if name.hasPrefix("settings:custom-hand:") {
            selectedCustomHandStyle = String(name.dropFirst("settings:custom-hand:".count))
            updateCustomHandButtons()
            return
        }
        if name.hasPrefix("settings:custom-number-style:") {
            selectedCustomNumberStyle = String(name.dropFirst("settings:custom-number-style:".count))
            updateCustomOptionButtons()
            return
        }
        if name.hasPrefix("settings:custom-font:") {
            selectedCustomFont = String(name.dropFirst("settings:custom-font:".count))
            updateCustomOptionButtons()
            return
        }
        if name.hasPrefix("settings:custom-apply:"),
           let id = UUID(uuidString: String(name.dropFirst("settings:custom-apply:".count))) {
            owner?.applyCustomTheme(id: id)
            loadCustomThemeValues()
            return
        }
        if name.hasPrefix("settings:custom-delete:"),
           let id = UUID(uuidString: String(name.dropFirst("settings:custom-delete:".count))) {
            LinuxCustomThemeStore.shared.delete(id: id)
            owner?.customThemeListChanged()
            refreshLanguage()
            show()
            return
        }
        if name.hasPrefix("settings:pricing-remove:"),
           let model = pricingRemoveModels[name] {
            PricingService.shared.setCustomPrice(model: model, price: nil)
            owner?.pricingCatalogDidChange()
            refreshLanguage()
            show()
            return
        }
        switch name {
        case "settings:detect": runDetection()
        case "settings:clock-face": owner?.openThemePickerFromSettings()
        case "settings:custom-save": saveCustomTheme()
        case "settings:custom-reset": resetCustomTheme()
        case "settings:pricing-save": saveCustomPrice()
        case "settings:pricing-refresh": refreshPricingCatalog()
        case "settings:save": saveAndClose()
        case "settings:cancel": hide()
        default: break
        }
    }

    private func buildWindow(parent: UnsafeMutablePointer<GtkWidget>) {
        guard let createdWindow = gtk_window_new(GTK_WINDOW_TOPLEVEL),
              let root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0),
              let scroll = gtk_scrolled_window_new(nil, nil),
              let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8) else { return }
        window = createdWindow
        gtk_window_set_title(tc_gtk_window(createdWindow), L10n.shared.tr("settings.title"))
        gtk_window_set_default_size(tc_gtk_window(createdWindow), 520, 548)
        gtk_window_set_resizable(tc_gtk_window(createdWindow), 0)
        gtk_window_set_transient_for(tc_gtk_window(createdWindow), tc_gtk_window(parent))
        gtk_window_set_position(tc_gtk_window(createdWindow), GTK_WIN_POS_CENTER_ON_PARENT)
        gtk_window_set_keep_above(tc_gtk_window(createdWindow), 1)
        _ = tc_gtk_hide_on_delete(createdWindow)
        gtk_container_add(tc_gtk_container(createdWindow), root)

        gtk_scrolled_window_set_policy(
            tc_gtk_scrolled_window(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC
        )
        gtk_container_set_border_width(tc_gtk_container(content), 14)
        gtk_container_add(tc_gtk_container(scroll), content)
        gtk_box_pack_start(tc_gtk_box(root), scroll, 1, 1, 0)

        let title = gtk_label_new(L10n.shared.tr("settings.title"))
        gtk_label_set_xalign(tc_gtk_label(title), 0)
        tc_gtk_add_class(title, "tokenclock-settings-title")
        gtk_box_pack_start(tc_gtk_box(content), title, 0, 0, 2)
        if let overview = overviewPage() {
            tc_gtk_add_class(overview, "tokenclock-settings-overview")
            gtk_box_pack_start(tc_gtk_box(content), overview, 0, 0, 0)
        }
        appendDisclosure(
            key: "api", title: localized(zh: "本地 API", en: "Local API"),
            page: localAPIPage(), to: content
        )
        appendDisclosure(
            key: "tools", title: L10n.shared.tr("settings.toolSelection"),
            page: toolsPage(), to: content
        )
        appendDisclosure(
            key: "paths", title: L10n.shared.tr("settings.dataPaths"),
            page: pathsPage(), to: content
        )
        appendDisclosure(
            key: "usage", title: L10n.shared.tr("rate.title"),
            page: usagePage(), to: content
        )
        appendDisclosure(
            key: "pricing", title: L10n.shared.tr("pricing.title"),
            page: pricingPage(), to: content
        )
        appendDisclosure(
            key: "themes", title: localized(zh: "表盘与自定义", en: "Clock Faces & Custom"),
            page: themesPage(), to: content
        )

        let footer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
        gtk_container_set_border_width(tc_gtk_container(footer), 12)
        let spacer = gtk_label_new("")
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_pack_start(tc_gtk_box(footer), spacer, 1, 1, 0)
        appendButton(localized(zh: "取消", en: "Cancel"), name: "settings:cancel", to: footer)
        appendButton(L10n.shared.tr("settings.done"), name: "settings:save", to: footer)
        gtk_box_pack_end(tc_gtk_box(root), footer, 0, 0, 0)

        tc_gtk_apply_css("""
        .tokenclock-settings-title { font-size: 20px; font-weight: 700; padding: 2px 3px 7px; }
        .tokenclock-settings-section { font-size: 14px; font-weight: 700; }
        .tokenclock-settings-hint { color: rgba(110, 110, 110, 0.95); font-size: 11px; }
        .tokenclock-settings-row { padding: 5px; }
        .tokenclock-settings-overview {
            background: rgba(120, 120, 120, 0.055); border-radius: 10px; padding: 10px;
        }
        .tokenclock-settings-disclosure {
            background: rgba(120, 120, 120, 0.06);
            border: 1px solid rgba(120, 120, 120, 0.16);
            border-radius: 9px; padding: 9px 11px; font-weight: 600;
        }
        .tokenclock-settings-disclosure:hover { background: rgba(73, 132, 255, 0.10); }
        """)
        loadValues()
    }

    private func localAPIPage() -> UnsafeMutablePointer<GtkWidget>? {
        let page = verticalPage(border: 12)
        apiEnabledButton = gtk_check_button_new_with_label(
            localized(zh: "启用本地只读 API 服务", en: "Enable local read-only API server")
        )
        gtk_box_pack_start(tc_gtk_box(page), apiEnabledButton, 0, 0, 0)

        let portRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
        gtk_box_pack_start(tc_gtk_box(portRow), gtk_label_new(localized(zh: "端口", en: "Port")), 0, 0, 0)
        apiPortSpin = gtk_entry_new()
        gtk_entry_set_input_purpose(tc_gtk_entry(apiPortSpin), GTK_INPUT_PURPOSE_NUMBER)
        gtk_widget_set_size_request(apiPortSpin, 90, -1)
        gtk_box_pack_start(tc_gtk_box(portRow), apiPortSpin, 0, 0, 0)
        let endpoint = gtk_label_new("/api/usage   ·   /api/history")
        tc_gtk_add_class(endpoint, "tokenclock-settings-hint")
        gtk_box_pack_start(tc_gtk_box(portRow), endpoint, 0, 0, 0)
        gtk_box_pack_start(tc_gtk_box(page), portRow, 0, 0, 0)
        return page
    }

    private func overviewPage() -> UnsafeMutablePointer<GtkWidget>? {
        let page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)
        gtk_container_set_border_width(tc_gtk_container(page), 4)
        let detectRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
        let detectTitle = gtk_label_new(L10n.shared.tr("settings.autoDetect"))
        gtk_label_set_xalign(tc_gtk_label(detectTitle), 0)
        tc_gtk_add_class(detectTitle, "tokenclock-settings-section")
        gtk_box_pack_start(tc_gtk_box(detectRow), detectTitle, 1, 1, 0)
        appendButton(L10n.shared.tr("settings.redetect"), name: "settings:detect", to: detectRow)
        gtk_box_pack_start(tc_gtk_box(page), detectRow, 0, 0, 0)
        detectionLabel = gtk_label_new("")
        gtk_label_set_xalign(tc_gtk_label(detectionLabel), 0)
        gtk_widget_set_hexpand(detectionLabel, 1)
        tc_gtk_add_class(detectionLabel, "tokenclock-settings-hint")
        gtk_box_pack_start(tc_gtk_box(page), detectionLabel, 0, 0, 0)

        cursorCloudButton = gtk_check_button_new_with_label(L10n.shared.tr("dataFetch.cursorCloud"))
        gtk_box_pack_start(tc_gtk_box(page), cursorCloudButton, 0, 0, 0)
        let cursorHint = gtk_label_new(L10n.shared.tr("dataFetch.cursorCloudHint"))
        gtk_label_set_xalign(tc_gtk_label(cursorHint), 0)
        gtk_label_set_ellipsize(tc_gtk_label(cursorHint), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(tc_gtk_label(cursorHint), 58)
        tc_gtk_add_class(cursorHint, "tokenclock-settings-hint")
        gtk_box_pack_start(tc_gtk_box(page), cursorHint, 0, 0, 0)
        return page
    }

    private func toolsPage() -> UnsafeMutablePointer<GtkWidget>? {
        let page = verticalPage()
        appendSection(L10n.shared.tr("settings.toolSelection"), to: page)
        let columns = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 18)
        let left = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)
        let right = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)
        gtk_box_pack_start(tc_gtk_box(columns), left, 1, 1, 0)
        gtk_box_pack_start(tc_gtk_box(columns), right, 1, 1, 0)
        for (index, option) in Self.toolOptions.enumerated() {
            let button = gtk_check_button_new_with_label("\(option.emoji)  \(option.name)")
            gtk_box_pack_start(tc_gtk_box(index < 7 ? left : right), button, 0, 0, 0)
            toolButtons[option.name] = button
        }
        gtk_box_pack_start(tc_gtk_box(page), columns, 0, 0, 0)
        let hint = gtk_label_new(
            localized(
                zh: "关闭的工具不会参与扫描、表盘汇总与本地 API 输出。",
                en: "Disabled tools are excluded from scans, the clock total, and local API output."
            )
        )
        gtk_label_set_xalign(tc_gtk_label(hint), 0)
        tc_gtk_add_class(hint, "tokenclock-settings-hint")
        gtk_box_pack_start(tc_gtk_box(page), hint, 0, 0, 0)
        return page
    }

    private func pathsPage() -> UnsafeMutablePointer<GtkWidget>? {
        guard let page = verticalPage() else { return nil }
        appendSection(L10n.shared.tr("settings.dataPaths"), to: page)
        for option in Self.toolOptions {
            let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
            tc_gtk_add_class(row, "tokenclock-settings-row")
            let label = gtk_label_new("\(option.emoji) \(option.name)")
            gtk_label_set_xalign(tc_gtk_label(label), 0)
            gtk_widget_set_size_request(label, 130, -1)
            let entry = gtk_entry_new()
            gtk_entry_set_placeholder_text(tc_gtk_entry(entry), L10n.shared.tr("settings.defaultPath"))
            gtk_widget_set_hexpand(entry, 1)
            let browse = gtk_button_new_with_label(L10n.shared.tr("settings.browse"))
            gtk_widget_set_name(browse, "settings:browse:\(option.service)")
            _ = tc_gtk_on_clicked(browse, linuxSettingsAction, opaque)
            gtk_box_pack_start(tc_gtk_box(row), label, 0, 0, 0)
            gtk_box_pack_start(tc_gtk_box(row), entry, 1, 1, 0)
            gtk_box_pack_start(tc_gtk_box(row), browse, 0, 0, 0)
            gtk_box_pack_start(tc_gtk_box(page), row, 0, 0, 0)
            pathEntries[option.service] = entry
        }
        let hint = gtk_label_new(L10n.shared.tr("settings.hint.emptyPath"))
        gtk_label_set_xalign(tc_gtk_label(hint), 0)
        gtk_label_set_line_wrap(tc_gtk_label(hint), 1)
        tc_gtk_add_class(hint, "tokenclock-settings-hint")
        gtk_box_pack_start(tc_gtk_box(page), hint, 0, 0, 4)
        return page
    }

    private func usagePage() -> UnsafeMutablePointer<GtkWidget>? {
        let page = verticalPage()
        appendSection(L10n.shared.tr("rate.title"), to: page)
        let periodRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
        gtk_box_pack_start(tc_gtk_box(periodRow), gtk_label_new(L10n.shared.tr("rate.period")), 0, 0, 0)
        for value in [10, 30, 60] {
            let title = value == 60 ? L10n.shared.tr("rate.1hour") : L10n.shared.tr("rate.\(value)min")
            let button = gtk_button_new_with_label(title)
            gtk_widget_set_name(button, "settings:rate-window:\(value)")
            _ = tc_gtk_on_clicked(button, linuxSettingsAction, opaque)
            gtk_box_pack_start(tc_gtk_box(periodRow), button, 0, 0, 0)
            rateWindowButtons[value] = button
        }
        gtk_box_pack_start(tc_gtk_box(page), periodRow, 0, 0, 0)

        let thresholds: [(SettingsKey, String, Int)] = [
            (.rateBurst, "💥 \(L10n.shared.tr("rate.burst"))", 500_000),
            (.rateHot, "🔥 \(L10n.shared.tr("rate.hot"))", 100_000),
            (.rateActive, "🏃 \(L10n.shared.tr("rate.active"))", 20_000),
            (.rateCalm, "☕ \(L10n.shared.tr("rate.calm"))", 2_000),
        ]
        for (key, title, _) in thresholds {
            let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
            let label = gtk_label_new(title)
            gtk_label_set_xalign(tc_gtk_label(label), 0)
            gtk_widget_set_size_request(label, 160, -1)
            let spin = gtk_entry_new()
            gtk_entry_set_input_purpose(tc_gtk_entry(spin), GTK_INPUT_PURPOSE_NUMBER)
            gtk_widget_set_size_request(spin, 150, -1)
            gtk_box_pack_start(tc_gtk_box(row), label, 0, 0, 0)
            gtk_box_pack_start(tc_gtk_box(row), spin, 0, 0, 0)
            gtk_box_pack_start(tc_gtk_box(row), gtk_label_new("tokens / period"), 0, 0, 0)
            gtk_box_pack_start(tc_gtk_box(page), row, 0, 0, 0)
            thresholdSpins[key] = spin
        }
        let hint = gtk_label_new(L10n.shared.tr("rate.rest"))
        gtk_label_set_xalign(tc_gtk_label(hint), 0)
        tc_gtk_add_class(hint, "tokenclock-settings-hint")
        gtk_box_pack_start(tc_gtk_box(page), hint, 0, 0, 0)
        return page
    }

    private func pricingPage() -> UnsafeMutablePointer<GtkWidget>? {
        guard let page = verticalPage() else { return nil }
        let summary = PricingService.shared.catalogSummary
        let generated = summary.generatedAt.map { String($0.prefix(10)) } ?? "—"

        // GTK computes a hidden revealer's natural width before it is expanded. A single long
        // pricing sentence therefore widened the entire non-resizable Settings window to nearly
        // 1,000 px. Insert a semantic sentence break so the collapsed page keeps the normal
        // 520 px footprint while preserving the full explanatory text.
        let rawNote = L10n.shared.tr("pricing.note")
        let wrappedNote = rawNote
            .replacingOccurrences(of: ". Usage", with: ".\nUsage")
            .replacingOccurrences(of: "，订阅", with: "，\n订阅")
            .replacingOccurrences(of: "，訂閱", with: "，\n訂閱")
        let note = gtk_label_new(wrappedNote)
        gtk_label_set_xalign(tc_gtk_label(note), 0)
        gtk_label_set_line_wrap(tc_gtk_label(note), 1)
        gtk_label_set_max_width_chars(tc_gtk_label(note), 62)
        tc_gtk_add_class(note, "tokenclock-settings-hint")
        gtk_box_pack_start(tc_gtk_box(page), note, 0, 0, 0)

        let statusRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
        let status = gtk_label_new(L10n.shared.tr("pricing.catalog", summary.count, generated))
        gtk_label_set_xalign(tc_gtk_label(status), 0)
        gtk_widget_set_hexpand(status, 1)
        gtk_box_pack_start(tc_gtk_box(statusRow), status, 1, 1, 0)
        appendButton(
            pricingRefreshInFlight ? L10n.shared.tr("pricing.refreshing") : L10n.shared.tr("pricing.refresh"),
            name: "settings:pricing-refresh", to: statusRow
        )
        gtk_box_pack_start(tc_gtk_box(page), statusRow, 0, 0, 0)

        let unpriced = PricingService.shared.unpricedModels
        if !unpriced.isEmpty {
            appendSection(L10n.shared.tr("pricing.unpricedTitle"), to: page)
            let wrappedModels = stride(from: 0, to: unpriced.count, by: 3).map { start in
                unpriced[start..<min(start + 3, unpriced.count)].joined(separator: "  ·  ")
            }.joined(separator: "\n")
            let label = gtk_label_new(wrappedModels)
            gtk_label_set_xalign(tc_gtk_label(label), 0)
            gtk_label_set_line_wrap(tc_gtk_label(label), 1)
            gtk_label_set_max_width_chars(tc_gtk_label(label), 62)
            tc_gtk_add_class(label, "tokenclock-settings-hint")
            gtk_box_pack_start(tc_gtk_box(page), label, 0, 0, 0)
        }

        appendSection(L10n.shared.tr("pricing.customTitle"), to: page)
        let headers = gtk_label_new("\(L10n.shared.tr("pricing.modelName"))  ·  \(L10n.shared.tr("pricing.input"))  ·  \(L10n.shared.tr("pricing.output"))  ·  \(L10n.shared.tr("pricing.cacheRead"))  ·  \(L10n.shared.tr("pricing.cacheWrite"))")
        gtk_label_set_xalign(tc_gtk_label(headers), 0)
        gtk_label_set_max_width_chars(tc_gtk_label(headers), 62)
        tc_gtk_add_class(headers, "tokenclock-settings-hint")
        gtk_box_pack_start(tc_gtk_box(page), headers, 0, 0, 0)

        let editor = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 5)
        pricingModelEntry = pricingEntry(placeholder: L10n.shared.tr("pricing.example"), width: 150, to: editor)
        pricingInputEntry = pricingEntry(placeholder: "3.0", width: 58, to: editor)
        pricingOutputEntry = pricingEntry(placeholder: "15.0", width: 58, to: editor)
        pricingCacheReadEntry = pricingEntry(placeholder: "0.3", width: 58, to: editor)
        pricingCacheWriteEntry = pricingEntry(placeholder: "3.75", width: 58, to: editor)
        appendButton(L10n.shared.tr("pricing.addCustom"), name: "settings:pricing-save", to: editor)
        gtk_box_pack_start(tc_gtk_box(page), editor, 0, 0, 0)

        pricingRemoveModels.removeAll()
        for (index, model) in PricingService.shared.customModels.enumerated() {
            guard let price = PricingService.shared.customPrice(for: model) else { continue }
            let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
            let description = String(
                format: "%@  ·  %.6g / %.6g / %.6g / %.6g",
                model, price.input, price.output, price.cacheRead, price.cacheWrite
            )
            let label = gtk_label_new(description)
            gtk_label_set_xalign(tc_gtk_label(label), 0)
            gtk_widget_set_hexpand(label, 1)
            gtk_box_pack_start(tc_gtk_box(row), label, 1, 1, 0)
            let action = "settings:pricing-remove:\(index)"
            pricingRemoveModels[action] = model
            appendButton(L10n.shared.tr("pricing.remove"), name: action, to: row)
            gtk_box_pack_start(tc_gtk_box(page), row, 0, 0, 0)
        }
        return page
    }

    @discardableResult
    private func pricingEntry(placeholder: String, width: Int32, to row: UnsafeMutablePointer<GtkWidget>?) -> UnsafeMutablePointer<GtkWidget>? {
        let entry = gtk_entry_new()
        gtk_entry_set_placeholder_text(tc_gtk_entry(entry), placeholder)
        let characterWidth: gint = width >= 100 ? 14 : 5
        gtk_entry_set_width_chars(tc_gtk_entry(entry), characterWidth)
        gtk_entry_set_max_width_chars(tc_gtk_entry(entry), characterWidth)
        gtk_widget_set_size_request(entry, gint(width), -1)
        gtk_box_pack_start(tc_gtk_box(row), entry, 0, 0, 0)
        return entry
    }

    private func saveCustomPrice() {
        guard let modelEntry = pricingModelEntry else { return }
        let name = String(cString: gtk_entry_get_text(tc_gtk_entry(modelEntry)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        func number(_ widget: UnsafeMutablePointer<GtkWidget>?) -> Double {
            guard let widget else { return 0 }
            return Double(String(cString: gtk_entry_get_text(tc_gtk_entry(widget)))) ?? 0
        }
        PricingService.shared.setCustomPrice(
            model: name,
            price: ModelPrice(
                input: number(pricingInputEntry),
                output: number(pricingOutputEntry),
                cacheRead: number(pricingCacheReadEntry),
                cacheWrite: number(pricingCacheWriteEntry)
            )
        )
        owner?.pricingCatalogDidChange()
        refreshLanguage()
        show()
    }

    private func refreshPricingCatalog() {
        guard !pricingRefreshInFlight else { return }
        pricingRefreshInFlight = true
        Task.detached(priority: .utility) { [weak self] in
            try? await PricingService.shared.refresh()
            guard let self else { return }
            _ = tc_gtk_idle_add(linuxPricingRefreshFinished, self.opaque)
        }
        refreshLanguage()
        show()
    }

    fileprivate func pricingRefreshFinished() {
        pricingRefreshInFlight = false
        owner?.pricingCatalogDidChange()
        refreshLanguage()
        show()
    }

    private func themesPage() -> UnsafeMutablePointer<GtkWidget>? {
        guard let page = verticalPage() else { return nil }
        appendSection(L10n.shared.tr("theme.title"), to: page)
        let description = gtk_label_new(
            localized(
                zh: "使用与 macOS normal 相同的可视化表盘选择器预览并切换内置表盘。",
                en: "Preview and switch built-in faces with the same visual picker model as macOS normal."
            )
        )
        gtk_label_set_xalign(tc_gtk_label(description), 0)
        gtk_label_set_line_wrap(tc_gtk_label(description), 1)
        gtk_box_pack_start(tc_gtk_box(page), description, 0, 0, 0)
        appendButton(L10n.shared.tr("menu.clockFace"), name: "settings:clock-face", to: page)

        appendSection(localized(zh: "自定义表盘", en: "Custom Clock Face"), to: page)
        let nameRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
        gtk_box_pack_start(tc_gtk_box(nameRow), gtk_label_new(localized(zh: "名称", en: "Name")), 0, 0, 0)
        customNameEntry = gtk_entry_new()
        gtk_widget_set_hexpand(customNameEntry, 1)
        gtk_box_pack_start(tc_gtk_box(nameRow), customNameEntry, 1, 1, 0)
        gtk_box_pack_start(tc_gtk_box(page), nameRow, 0, 0, 0)

        let colorFields: [(String, String)] = [
            ("dial", localized(zh: "表盘底色", en: "Dial")),
            ("rim", localized(zh: "外圈颜色", en: "Rim")),
            ("hour", localized(zh: "时针", en: "Hour hand")),
            ("minute", localized(zh: "分针", en: "Minute hand")),
            ("second", localized(zh: "秒针", en: "Second hand")),
            ("centerOuter", localized(zh: "中心点外圈", en: "Center outer")),
            ("centerInner", localized(zh: "中心点内圈", en: "Center inner")),
            ("tick", localized(zh: "普通刻度", en: "Tick marks")),
            ("majorTick", localized(zh: "主刻度", en: "Major ticks")),
            ("number", localized(zh: "数字", en: "Numbers")),
            ("primary", localized(zh: "主要文字", en: "Primary text")),
            ("secondary", localized(zh: "次要文字", en: "Secondary text")),
            ("panel", localized(zh: "详情面板", en: "Detail panel")),
            ("panelText", localized(zh: "面板文字", en: "Panel text")),
            ("panelSubtext", localized(zh: "面板次要文字", en: "Panel subtext")),
            ("panelBorder", localized(zh: "面板边框", en: "Panel border")),
            ("panelDivider", localized(zh: "面板分隔线", en: "Panel dividers")),
        ]
        for (key, title) in colorFields {
            let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
            let label = gtk_label_new(title)
            gtk_label_set_xalign(tc_gtk_label(label), 0)
            gtk_widget_set_size_request(label, 150, -1)
            let entry = gtk_entry_new()
            gtk_entry_set_placeholder_text(tc_gtk_entry(entry), "#RRGGBB or #RRGGBBAA")
            gtk_widget_set_size_request(entry, 190, -1)
            gtk_box_pack_start(tc_gtk_box(row), label, 0, 0, 0)
            gtk_box_pack_start(tc_gtk_box(row), entry, 0, 0, 0)
            gtk_box_pack_start(tc_gtk_box(page), row, 0, 0, 0)
            customEntries[key] = entry
        }

        let handRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
        gtk_box_pack_start(tc_gtk_box(handRow), gtk_label_new(localized(zh: "指针样式", en: "Hand style")), 0, 0, 0)
        for (key, title) in [("round", "Round"), ("tapered", "Tapered"), ("lance", "Lance"), ("sword", "Sword")] {
            let button = gtk_button_new_with_label(title)
            gtk_widget_set_name(button, "settings:custom-hand:\(key)")
            _ = tc_gtk_on_clicked(button, linuxSettingsAction, opaque)
            gtk_box_pack_start(tc_gtk_box(handRow), button, 0, 0, 0)
            customHandButtons[key] = button
        }
        gtk_box_pack_start(tc_gtk_box(page), handRow, 0, 0, 0)

        for (key, title) in [
            ("rimWidth", localized(zh: "外圈宽度", en: "Rim width")),
            ("hourWidth", localized(zh: "时针宽度", en: "Hour width")),
            ("minuteWidth", localized(zh: "分针宽度", en: "Minute width")),
            ("secondWidth", localized(zh: "秒针宽度", en: "Second width")),
        ] {
            let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
            let label = gtk_label_new(title)
            gtk_label_set_xalign(tc_gtk_label(label), 0)
            gtk_widget_set_size_request(label, 150, -1)
            let entry = gtk_entry_new()
            gtk_entry_set_input_purpose(tc_gtk_entry(entry), GTK_INPUT_PURPOSE_NUMBER)
            gtk_widget_set_size_request(entry, 100, -1)
            gtk_box_pack_start(tc_gtk_box(row), label, 0, 0, 0)
            gtk_box_pack_start(tc_gtk_box(row), entry, 0, 0, 0)
            gtk_box_pack_start(tc_gtk_box(page), row, 0, 0, 0)
            customNumericEntries[key] = entry
        }

        let visibilityRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10)
        for (key, title) in [
            ("ticks", localized(zh: "显示刻度", en: "Show ticks")),
            ("numbers", localized(zh: "显示数字", en: "Show numbers")),
            ("decoration", localized(zh: "天空装饰", en: "Sky decoration")),
        ] {
            let button = gtk_check_button_new_with_label(title)
            gtk_box_pack_start(tc_gtk_box(visibilityRow), button, 0, 0, 0)
            customToggleButtons[key] = button
        }
        gtk_box_pack_start(tc_gtk_box(page), visibilityRow, 0, 0, 0)

        let numberStyleRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
        gtk_box_pack_start(tc_gtk_box(numberStyleRow), gtk_label_new(localized(zh: "数字样式", en: "Number style")), 0, 0, 0)
        for (key, title) in [("arabic", "Arabic"), ("chinese", localized(zh: "中文", en: "Chinese"))] {
            let button = gtk_button_new_with_label(title)
            gtk_widget_set_name(button, "settings:custom-number-style:\(key)")
            _ = tc_gtk_on_clicked(button, linuxSettingsAction, opaque)
            gtk_box_pack_start(tc_gtk_box(numberStyleRow), button, 0, 0, 0)
            customNumberStyleButtons[key] = button
        }
        gtk_box_pack_start(tc_gtk_box(page), numberStyleRow, 0, 0, 0)

        let fontRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
        gtk_box_pack_start(tc_gtk_box(fontRow), gtk_label_new(localized(zh: "数字字体", en: "Number font")), 0, 0, 0)
        for (key, title) in [("rounded", "Rounded"), ("serif", "Serif"), ("monospaced", "Mono"), ("default", "Default")] {
            let button = gtk_button_new_with_label(title)
            gtk_widget_set_name(button, "settings:custom-font:\(key)")
            _ = tc_gtk_on_clicked(button, linuxSettingsAction, opaque)
            gtk_box_pack_start(tc_gtk_box(fontRow), button, 0, 0, 0)
            customFontButtons[key] = button
        }
        gtk_box_pack_start(tc_gtk_box(page), fontRow, 0, 0, 0)

        let actionRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
        appendButton(localized(zh: "恢复经典默认", en: "Reset to Classic"), name: "settings:custom-reset", to: actionRow)
        appendButton(localized(zh: "保存并应用", en: "Save & Apply"), name: "settings:custom-save", to: actionRow)
        gtk_box_pack_start(tc_gtk_box(page), actionRow, 0, 0, 0)

        let savedThemes = LinuxCustomThemeStore.shared.themes
        if !savedThemes.isEmpty {
            appendSection(L10n.shared.tr("menu.myClockFaces"), to: page)
            for saved in savedThemes {
                let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
                let label = gtk_label_new(saved.name)
                gtk_label_set_xalign(tc_gtk_label(label), 0)
                gtk_widget_set_hexpand(label, 1)
                gtk_box_pack_start(tc_gtk_box(row), label, 1, 1, 0)
                appendButton(localized(zh: "应用", en: "Apply"), name: "settings:custom-apply:\(saved.id.uuidString)", to: row)
                appendButton(localized(zh: "删除", en: "Delete"), name: "settings:custom-delete:\(saved.id.uuidString)", to: row)
                gtk_box_pack_start(tc_gtk_box(page), row, 0, 0, 0)
            }
        }
        return page
    }

    private func verticalPage(border: Int = 18) -> UnsafeMutablePointer<GtkWidget>? {
        let page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)
        gtk_container_set_border_width(tc_gtk_container(page), guint(border))
        return page
    }

    private func appendPage(
        _ page: UnsafeMutablePointer<GtkWidget>?,
        title: String,
        to notebook: UnsafeMutablePointer<GtkWidget>
    ) {
        guard let page else { return }
        _ = gtk_notebook_append_page(tc_gtk_notebook(notebook), page, gtk_label_new(title))
    }

    private func appendDisclosure(
        key: String,
        title: String,
        page: UnsafeMutablePointer<GtkWidget>?,
        to content: UnsafeMutablePointer<GtkWidget>
    ) {
        guard let page,
              let button = gtk_button_new_with_label("▸  \(title)"),
              let revealer = gtk_revealer_new() else { return }
        gtk_widget_set_name(button, "settings:section:\(key)")
        gtk_button_set_relief(tc_gtk_button(button), GTK_RELIEF_NONE)
        gtk_button_set_alignment(tc_gtk_button(button), 0, 0.5)
        tc_gtk_add_class(button, "tokenclock-settings-disclosure")
        _ = tc_gtk_on_clicked(button, linuxSettingsAction, opaque)
        gtk_revealer_set_transition_type(
            tc_gtk_revealer(revealer), GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN
        )
        gtk_revealer_set_transition_duration(tc_gtk_revealer(revealer), 160)
        gtk_container_add(tc_gtk_container(revealer), page)
        gtk_box_pack_start(tc_gtk_box(content), button, 0, 0, 0)
        gtk_box_pack_start(tc_gtk_box(content), revealer, 0, 0, 0)
        sectionRevealers[key] = revealer
        sectionButtons[key] = button
        sectionTitles[key] = title
    }

    private func toggleDisclosure(_ key: String) {
        if expandedSections.contains(key) { expandedSections.remove(key) }
        else { expandedSections.insert(key) }
        syncDisclosureState(key)
    }

    private func syncDisclosureStates() {
        for key in sectionRevealers.keys { syncDisclosureState(key) }
    }

    private func syncDisclosureState(_ key: String) {
        let expanded = expandedSections.contains(key)
        if let revealer = sectionRevealers[key] {
            gtk_revealer_set_reveal_child(tc_gtk_revealer(revealer), expanded ? 1 : 0)
        }
        if let button = sectionButtons[key], let title = sectionTitles[key] {
            gtk_button_set_label(tc_gtk_button(button), "\(expanded ? "▾" : "▸")  \(title)")
        }
    }

    private func appendSection(_ title: String, to page: UnsafeMutablePointer<GtkWidget>?) {
        let label = gtk_label_new(title)
        gtk_label_set_xalign(tc_gtk_label(label), 0)
        tc_gtk_add_class(label, "tokenclock-settings-section")
        gtk_box_pack_start(tc_gtk_box(page), label, 0, 0, 2)
    }

    private func appendButton(
        _ title: String,
        name: String,
        to box: UnsafeMutablePointer<GtkWidget>?
    ) {
        let button = gtk_button_new_with_label(title)
        gtk_widget_set_name(button, name)
        _ = tc_gtk_on_clicked(button, linuxSettingsAction, opaque)
        gtk_box_pack_start(tc_gtk_box(box), button, 0, 0, 0)
    }

    private func loadValues() {
        let defaults = UserDefaults.standard
        if let apiEnabledButton {
            gtk_toggle_button_set_active(
                tc_gtk_toggle_button(apiEnabledButton),
                defaults.bool(for: .apiServerEnabled, default: true) ? 1 : 0
            )
        }
        if let apiPortSpin {
            let raw = defaults.int(for: .apiServerPort)
            gtk_entry_set_text(
                tc_gtk_entry(apiPortSpin),
                "\(raw > 0 ? raw : Int(AppConfig.LocalServer.defaultPort))"
            )
        }
        if let cursorCloudButton {
            gtk_toggle_button_set_active(
                tc_gtk_toggle_button(cursorCloudButton),
                defaults.bool(for: .cursorCloudFetchEnabled, default: true) ? 1 : 0
            )
        }
        let enabled = model.enabledTools
        for (name, button) in toolButtons {
            gtk_toggle_button_set_active(tc_gtk_toggle_button(button), enabled.contains(name) ? 1 : 0)
        }
        for option in Self.toolOptions {
            guard let entry = pathEntries[option.service] else { continue }
            gtk_entry_set_text(tc_gtk_entry(entry), defaults.string(for: option.pathKey) ?? "")
        }
        selectedRateWindow = model.rateWindowMinutes
        updateRateWindowButtons()
        let thresholdDefaults: [SettingsKey: Int] = [
            .rateBurst: 500_000, .rateHot: 100_000, .rateActive: 20_000, .rateCalm: 2_000,
        ]
        for (key, spin) in thresholdSpins {
            let saved = defaults.int(for: key)
            gtk_entry_set_text(tc_gtk_entry(spin), "\(saved > 0 ? saved : thresholdDefaults[key] ?? 0)")
        }
        loadCustomThemeValues()
    }

    private func loadCustomThemeValues() {
        let store = LinuxCustomThemeStore.shared
        let config = store.config
        let activeID = UserDefaults.standard.string(for: .activeCustomThemeId).flatMap(UUID.init(uuidString:))
        let name = activeID.flatMap { id in store.themes.first(where: { $0.id == id })?.name }
            ?? localized(zh: "我的表盘", en: "My Clock Face")
        if let customNameEntry { gtk_entry_set_text(tc_gtk_entry(customNameEntry), name) }
        let values: [String: LinuxThemeColor] = [
            "dial": config.dialColor, "rim": config.dialRimColor,
            "hour": config.hourHandColor, "minute": config.minuteHandColor,
            "second": config.secondHandColor,
            "centerOuter": config.centerDotOuterColor, "centerInner": config.centerDotInnerColor,
            "tick": config.tickMarkColor, "majorTick": config.majorTickMarkColor,
            "number": config.numberColor,
            "primary": config.textPrimaryColor, "secondary": config.textSecondaryColor,
            "panel": config.dropdownBgColor, "panelText": config.dropdownTextColor,
            "panelSubtext": config.dropdownSubtextColor,
            "panelBorder": config.dropdownBorderColor,
            "panelDivider": config.dropdownDividerColor,
        ]
        for (key, color) in values where customEntries[key] != nil {
            gtk_entry_set_text(tc_gtk_entry(customEntries[key]), hexString(color))
        }
        let numbers: [String: Double] = [
            "rimWidth": config.dialRimWidth,
            "hourWidth": config.hourHandWidth,
            "minuteWidth": config.minuteHandWidth,
            "secondWidth": config.secondHandWidth,
        ]
        for (key, value) in numbers where customNumericEntries[key] != nil {
            gtk_entry_set_text(tc_gtk_entry(customNumericEntries[key]), String(format: "%.1f", value))
        }
        let toggles = [
            "ticks": config.hasTickMarks,
            "numbers": config.showNumbers,
            "decoration": config.hasDialDecoration,
        ]
        for (key, enabled) in toggles where customToggleButtons[key] != nil {
            gtk_toggle_button_set_active(tc_gtk_toggle_button(customToggleButtons[key]), enabled ? 1 : 0)
        }
        selectedCustomHandStyle = config.handStyleRaw
        selectedCustomNumberStyle = config.numberStyleRaw
        selectedCustomFont = config.numberFontDesignRaw
        updateCustomOptionButtons()
    }

    private func updateCustomHandButtons() {
        for (key, button) in customHandButtons {
            let title = key.prefix(1).uppercased() + key.dropFirst()
            gtk_button_set_label(tc_gtk_button(button), key == selectedCustomHandStyle ? "✓ \(title)" : title)
        }
    }

    private func updateCustomOptionButtons() {
        updateCustomHandButtons()
        for (key, button) in customNumberStyleButtons {
            let title = key == "arabic" ? "Arabic" : localized(zh: "中文", en: "Chinese")
            gtk_button_set_label(tc_gtk_button(button), key == selectedCustomNumberStyle ? "✓ \(title)" : title)
        }
        for (key, button) in customFontButtons {
            let title: String
            switch key {
            case "rounded": title = "Rounded"
            case "serif": title = "Serif"
            case "monospaced": title = "Mono"
            default: title = "Default"
            }
            gtk_button_set_label(tc_gtk_button(button), key == selectedCustomFont ? "✓ \(title)" : title)
        }
    }

    private func saveCustomTheme() {
        var config = LinuxCustomThemeStore.shared.config
        config.dialColor = colorValue("dial", fallback: config.dialColor)
        config.dialRimColor = colorValue("rim", fallback: config.dialRimColor)
        config.hourHandColor = colorValue("hour", fallback: config.hourHandColor)
        config.minuteHandColor = colorValue("minute", fallback: config.minuteHandColor)
        config.secondHandColor = colorValue("second", fallback: config.secondHandColor)
        config.centerDotOuterColor = colorValue("centerOuter", fallback: config.centerDotOuterColor)
        config.centerDotInnerColor = colorValue("centerInner", fallback: config.centerDotInnerColor)
        config.numberColor = colorValue("number", fallback: config.numberColor)
        config.tickMarkColor = colorValue("tick", fallback: config.tickMarkColor)
        config.majorTickMarkColor = colorValue("majorTick", fallback: config.majorTickMarkColor)
        config.textPrimaryColor = colorValue("primary", fallback: config.textPrimaryColor)
        config.textSecondaryColor = colorValue("secondary", fallback: config.textSecondaryColor)
        config.dropdownBgColor = colorValue("panel", fallback: config.dropdownBgColor)
        config.dropdownTextColor = colorValue("panelText", fallback: config.dropdownTextColor)
        config.dropdownSubtextColor = colorValue("panelSubtext", fallback: config.dropdownSubtextColor)
        config.dropdownBorderColor = colorValue("panelBorder", fallback: config.dropdownBorderColor)
        config.dropdownDividerColor = colorValue("panelDivider", fallback: config.dropdownDividerColor)
        config.dialRimWidth = numericValue("rimWidth", fallback: config.dialRimWidth, range: 0...20)
        config.hourHandWidth = numericValue("hourWidth", fallback: config.hourHandWidth, range: 1...10)
        config.minuteHandWidth = numericValue("minuteWidth", fallback: config.minuteHandWidth, range: 1...8)
        config.secondHandWidth = numericValue("secondWidth", fallback: config.secondHandWidth, range: 0.5...5)
        config.hasTickMarks = toggleValue("ticks", fallback: config.hasTickMarks)
        config.showNumbers = toggleValue("numbers", fallback: config.showNumbers)
        config.hasDialDecoration = toggleValue("decoration", fallback: config.hasDialDecoration)
        config.handStyleRaw = selectedCustomHandStyle
        config.numberStyleRaw = selectedCustomNumberStyle
        config.numberFontDesignRaw = selectedCustomFont
        let name = customNameEntry.map {
            String(cString: gtk_entry_get_text(tc_gtk_entry($0)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let saved = LinuxCustomThemeStore.shared.save(
            config: config,
            name: (name?.isEmpty == false ? name! : localized(zh: "我的表盘", en: "My Clock Face"))
        )
        owner?.applyCustomTheme(id: saved.id)
        hide()
    }

    private func resetCustomTheme() {
        _ = LinuxCustomThemeStore.shared.resetDraft()
        UserDefaults.standard.remove(.activeCustomThemeId)
        loadCustomThemeValues()
        owner?.resetCustomThemeToClassic()
    }

    private func colorValue(_ key: String, fallback: LinuxThemeColor) -> LinuxThemeColor {
        guard let entry = customEntries[key] else { return fallback }
        return parseHex(String(cString: gtk_entry_get_text(tc_gtk_entry(entry)))) ?? fallback
    }

    private func numericValue(
        _ key: String,
        fallback: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard let entry = customNumericEntries[key],
              let value = Double(String(cString: gtk_entry_get_text(tc_gtk_entry(entry)))) else {
            return fallback
        }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    private func toggleValue(_ key: String, fallback: Bool) -> Bool {
        guard let button = customToggleButtons[key] else { return fallback }
        return gtk_toggle_button_get_active(tc_gtk_toggle_button(button)) != 0
    }

    private func parseHex(_ raw: String) -> LinuxThemeColor? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard value.count == 6 || value.count == 8,
              let number = UInt64(value, radix: 16) else { return nil }
        if value.count == 6 {
            return LinuxThemeColor(
                red: Double((number >> 16) & 0xFF) / 255,
                green: Double((number >> 8) & 0xFF) / 255,
                blue: Double(number & 0xFF) / 255
            )
        }
        return LinuxThemeColor(
            red: Double((number >> 24) & 0xFF) / 255,
            green: Double((number >> 16) & 0xFF) / 255,
            blue: Double((number >> 8) & 0xFF) / 255,
            opacity: Double(number & 0xFF) / 255
        )
    }

    private func hexString(_ color: LinuxThemeColor) -> String {
        let red = Int(min(1, max(0, color.red)) * 255)
        let green = Int(min(1, max(0, color.green)) * 255)
        let blue = Int(min(1, max(0, color.blue)) * 255)
        let alpha = Int(min(1, max(0, color.opacity)) * 255)
        return alpha == 255
            ? String(format: "#%02X%02X%02X", red, green, blue)
            : String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
    }

    private func updateRateWindowButtons() {
        for (value, button) in rateWindowButtons {
            let title = value == 60 ? L10n.shared.tr("rate.1hour") : L10n.shared.tr("rate.\(value)min")
            gtk_button_set_label(
                tc_gtk_button(button),
                value == selectedRateWindow ? "✓  \(title)" : title
            )
        }
    }

    private func runDetection() {
        let summary = PathDetector.runFullDetection()
        for result in summary.results where result.exists {
            if let entry = pathEntries[result.service] {
                gtk_entry_set_text(tc_gtk_entry(entry), result.detectedPath)
            }
        }
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let message = summary.allFound
            ? L10n.shared.tr("settings.detectAllFound", summary.totalCount, time)
            : L10n.shared.tr("settings.detectPartial", summary.foundCount, summary.totalCount, time)
        if let detectionLabel { gtk_label_set_text(tc_gtk_label(detectionLabel), message) }
    }

    private func browse(service: String) {
        guard let window, let entry = pathEntries[service] else { return }
        let current = String(cString: gtk_entry_get_text(tc_gtk_entry(entry)))
        let title = Self.toolOptions.first(where: { $0.service == service })
            .map { "\(L10n.shared.tr("settings.browse")) · \($0.name)" }
            ?? L10n.shared.tr("settings.browse")
        let selected = title.withCString { titlePointer in
            current.withCString { currentPointer in
                tc_gtk_choose_folder(window, titlePointer, currentPointer)
            }
        }
        guard let selected else { return }
        gtk_entry_set_text(tc_gtk_entry(entry), selected)
        tc_g_free(selected)
    }

    private func saveAndClose() {
        let defaults = UserDefaults.standard
        let oldAPIEnabled = defaults.bool(for: .apiServerEnabled, default: true)
        let oldAPIPort = defaults.int(for: .apiServerPort, default: Int(AppConfig.LocalServer.defaultPort))
        let apiEnabled = apiEnabledButton.map {
            gtk_toggle_button_get_active(tc_gtk_toggle_button($0)) != 0
        } ?? true
        let apiPort = apiPortSpin.flatMap {
            Int(String(cString: gtk_entry_get_text(tc_gtk_entry($0))))
        }.map { min(Int(UInt16.max), max(1_024, $0)) } ?? Int(AppConfig.LocalServer.defaultPort)
        defaults.setBool(apiEnabled, for: .apiServerEnabled)
        defaults.setInt(apiPort, for: .apiServerPort)
        if let cursorCloudButton {
            defaults.setBool(
                gtk_toggle_button_get_active(tc_gtk_toggle_button(cursorCloudButton)) != 0,
                for: .cursorCloudFetchEnabled
            )
        }

        var enabled: Set<String> = []
        for (name, button) in toolButtons where
            gtk_toggle_button_get_active(tc_gtk_toggle_button(button)) != 0 {
            enabled.insert(name)
        }
        for option in Self.toolOptions {
            guard let entry = pathEntries[option.service] else { continue }
            let value = String(cString: gtk_entry_get_text(tc_gtk_entry(entry)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { defaults.remove(option.pathKey) }
            else { defaults.setString(value, for: option.pathKey) }
        }

        var burst = thresholdValue(.rateBurst, fallback: 500_000)
        var hot = thresholdValue(.rateHot, fallback: 100_000)
        var active = thresholdValue(.rateActive, fallback: 20_000)
        var calm = thresholdValue(.rateCalm, fallback: 2_000)
        if hot >= burst { hot = max(0, burst - 1) }
        if active >= hot { active = max(0, hot - 1) }
        if calm >= active { calm = max(0, active - 1) }
        if active <= calm { active = calm + 1 }
        if hot <= active { hot = active + 1 }
        if burst <= hot { burst = hot + 1 }
        defaults.setInt(burst, for: .rateBurst)
        defaults.setInt(hot, for: .rateHot)
        defaults.setInt(active, for: .rateActive)
        defaults.setInt(calm, for: .rateCalm)
        model.applyPreferences(enabledTools: enabled, rateWindowMinutes: selectedRateWindow)

        owner?.settingsDidSave(apiChanged: oldAPIEnabled != apiEnabled || oldAPIPort != apiPort)
        hide()
    }

    private func thresholdValue(_ key: SettingsKey, fallback: Int) -> Int {
        guard let spin = thresholdSpins[key] else { return fallback }
        return Int(String(cString: gtk_entry_get_text(tc_gtk_entry(spin)))) ?? fallback
    }

    private func clearWidgetReferences() {
        apiEnabledButton = nil
        apiPortSpin = nil
        cursorCloudButton = nil
        detectionLabel = nil
        toolButtons.removeAll()
        pathEntries.removeAll()
        rateWindowButtons.removeAll()
        thresholdSpins.removeAll()
        customNameEntry = nil
        customEntries.removeAll()
        customNumericEntries.removeAll()
        customToggleButtons.removeAll()
        customHandButtons.removeAll()
        customNumberStyleButtons.removeAll()
        customFontButtons.removeAll()
        pricingModelEntry = nil
        pricingInputEntry = nil
        pricingOutputEntry = nil
        pricingCacheReadEntry = nil
        pricingCacheWriteEntry = nil
        pricingRemoveModels.removeAll()
        sectionRevealers.removeAll()
        sectionButtons.removeAll()
        sectionTitles.removeAll()
    }

    private func localized(zh: String, en: String) -> String {
        L10n.shared.language == .en ? en : zh
    }
}

private func settings(from data: gpointer?) -> LinuxSettingsWindow? {
    guard let data else { return nil }
    return Unmanaged<LinuxSettingsWindow>.fromOpaque(data).takeUnretainedValue()
}

private func linuxSettingsAction(
    _ widget: UnsafeMutablePointer<GtkWidget>?,
    _ data: gpointer?
) {
    guard let widget else { return }
    settings(from: data)?.handleAction(widget: widget)
}

private func linuxPricingRefreshFinished(_ data: gpointer?) -> gboolean {
    settings(from: data)?.pricingRefreshFinished()
    return 0
}

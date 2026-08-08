import Foundation
import CGtk

final class LinuxApp: @unchecked Sendable {
    private let model = LinuxUsageModel()
    private let renderer = LinuxClockRenderer()
    private let weatherService = LinuxWeatherService()
    private var apiServer: LinuxAPIServer?

    private var window: UnsafeMutablePointer<GtkWidget>?
    private var dial: UnsafeMutablePointer<GtkWidget>?
    private var menu: UnsafeMutablePointer<GtkWidget>?
    private var detailsPanel: LinuxDetailsPanel?
    private var themePicker: LinuxThemePicker?
    private var settingsWindow: LinuxSettingsWindow?
    private var themeItems: [LinuxClockTheme: UnsafeMutablePointer<GtkWidget>] = [:]
    private var sizeItems: [LinuxClockSize: UnsafeMutablePointer<GtkWidget>] = [:]
    private var opacityItems: [Int: UnsafeMutablePointer<GtkWidget>] = [:]
    private var timezoneItems: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private var languageItems: [AppLanguage: UnsafeMutablePointer<GtkWidget>] = [:]
    private var leftButtonDown = false
    private var dragStarted = false
    private var pressRootX: Double = 0
    private var pressRootY: Double = 0

    private var windowOpacity: Double = {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: SettingsKey.windowOpacity.rawValue) != nil else { return 1 }
        return min(1, max(0.25, defaults.double(forKey: SettingsKey.windowOpacity.rawValue)))
    }()
    private var alwaysOnTop = UserDefaults.standard.bool(for: .alwaysOnTop)
    private var selectedTimezone = UserDefaults.standard.string(for: .selectedTimezone) ?? "auto"
    private var selectedCity = UserDefaults.standard.string(for: .selectedCity) ?? "auto"
    private var useFahrenheit = UserDefaults.standard.bool(for: .useFahrenheit)

    private static let cityOptions = [
        "auto", "Hong Kong", "Shanghai", "Beijing", "Tokyo", "Singapore", "New York",
    ]

    private static let timezoneOptions: [(label: String, identifier: String)] = [
        ("tz.auto", "auto"),
        ("tz.hongKong", "Asia/Hong_Kong"),
        ("tz.shanghai", "Asia/Shanghai"),
        ("tz.tokyo", "Asia/Tokyo"),
        ("tz.singapore", "Asia/Singapore"),
        ("tz.newYork", "America/New_York"),
        ("tz.london", "Europe/London"),
        ("tz.losAngeles", "America/Los_Angeles"),
    ]

    private var selectedTheme: LinuxClockTheme = {
        if let forced = ProcessInfo.processInfo.environment["TOKENCLOCK_THEME"],
           let theme = LinuxClockTheme(rawValue: forced) {
            return theme
        }
        if let saved = UserDefaults.standard.string(for: .selectedTheme),
           let theme = LinuxClockTheme(rawValue: saved) {
            return theme
        }
        return .classic
    }()

    private var selectedSize: LinuxClockSize = {
        if let forced = ProcessInfo.processInfo.environment["TOKENCLOCK_SIZE"],
           let size = LinuxClockSize(rawValue: forced) {
            return size
        }
        if let saved = UserDefaults.standard.string(for: .clockSize),
           let size = LinuxClockSize(rawValue: saved) {
            return size
        }
        return .medium
    }()

    private lazy var opaque = Unmanaged.passUnretained(self).toOpaque()

    func run() {
        gtk_init(nil, nil)
        autoDetectSizeIfNeeded()
        buildInterface()
        startAPIServerIfEnabled()
        scheduleScan(incremental: false)
        refreshWeather()

        _ = tc_gtk_timeout_add(1_000, linuxClockTick, opaque)
        _ = tc_gtk_timeout_add_seconds(
            guint(max(1, Int(AppConfig.Timers.dataScan))),
            linuxScanTick,
            opaque
        )
        _ = tc_gtk_timeout_add_seconds(
            guint(max(60, Int(AppConfig.Timers.weather))),
            linuxWeatherTick,
            opaque
        )
        gtk_main()
    }

    private func autoDetectSizeIfNeeded() {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_SIZE"] == nil else { return }
        guard !UserDefaults.standard.bool(for: .clockSizeUserChosen) else { return }
        let height = Int(tc_gtk_primary_workarea_height())
        selectedSize = if height < 850 {
            .small
        } else if height < 1_250 {
            .medium
        } else if height < 1_500 {
            .large
        } else {
            .extraLarge
        }
        UserDefaults.standard.setString(selectedSize.rawValue, for: .clockSize)
    }

    private func buildInterface() {
        guard let createdWindow = gtk_window_new(GTK_WINDOW_TOPLEVEL) else { return }
        window = createdWindow
        let diameter = gint(selectedSize.diameter)
        gtk_window_set_title(tc_gtk_window(createdWindow), "TokenClock")
        gtk_window_set_default_size(tc_gtk_window(createdWindow), diameter, diameter)
        gtk_window_set_resizable(tc_gtk_window(createdWindow), 0)
        gtk_window_set_decorated(tc_gtk_window(createdWindow), 0)
        gtk_window_set_keep_above(
            tc_gtk_window(createdWindow),
            alwaysOnTop ? 1 : 0
        )
        gtk_window_set_skip_taskbar_hint(tc_gtk_window(createdWindow), 1)
        gtk_window_set_skip_pager_hint(tc_gtk_window(createdWindow), 1)
        gtk_window_set_position(tc_gtk_window(createdWindow), GTK_WIN_POS_CENTER)
        tc_gtk_prepare_transparent_window(createdWindow)

        if UserDefaults.standard.object(forKey: "TCLinuxWindowX") != nil {
            gtk_window_move(
                tc_gtk_window(createdWindow),
                gint(UserDefaults.standard.integer(forKey: "TCLinuxWindowX")),
                gint(UserDefaults.standard.integer(forKey: "TCLinuxWindowY"))
            )
        }

        guard let createdDial = gtk_drawing_area_new() else { return }
        dial = createdDial
        gtk_widget_set_size_request(createdDial, diameter, diameter)
        gtk_widget_set_app_paintable(createdDial, 1)
        gtk_widget_add_events(
            createdDial,
            gint(
                GDK_BUTTON_PRESS_MASK.rawValue
                    | GDK_BUTTON_RELEASE_MASK.rawValue
                    | GDK_POINTER_MOTION_MASK.rawValue
            )
        )
        gtk_container_add(tc_gtk_container(createdWindow), createdDial)
        tc_gtk_set_fixed_window_size(createdWindow, diameter)

        _ = tc_gtk_on_destroy(createdWindow, linuxDestroy, opaque)
        _ = tc_gtk_on_button_press(createdDial, linuxButtonPress, opaque)
        _ = tc_gtk_on_button_release(createdDial, linuxButtonRelease, opaque)
        _ = tc_gtk_on_motion(createdDial, linuxMotion, opaque)
        _ = tc_gtk_on_draw(createdDial, linuxDraw, opaque)

        detailsPanel = LinuxDetailsPanel(parent: createdWindow)
        detailsPanel?.setOpacity(windowOpacity)
        themePicker = LinuxThemePicker(parent: createdWindow, owner: self)
        settingsWindow = LinuxSettingsWindow(parent: createdWindow, owner: self, model: model)
        buildContextMenu()

        gtk_widget_show_all(createdWindow)
        gtk_widget_set_opacity(createdWindow, windowOpacity)
        detailsPanel?.hide()
        tc_gtk_shape_circle(createdWindow, diameter)
        refreshUI()
    }

    private func buildContextMenu() {
        themeItems.removeAll()
        sizeItems.removeAll()
        opacityItems.removeAll()
        timezoneItems.removeAll()
        languageItems.removeAll()
        guard let root = gtk_menu_new() else { return }
        menu = root

        appendMenuItem(L10n.shared.tr("menu.clockFace"), name: "theme-picker", to: root)

        let savedThemes = LinuxCustomThemeStore.shared.themes
        if !savedThemes.isEmpty {
            let savedRoot = gtk_menu_item_new_with_label(L10n.shared.tr("menu.myClockFaces"))
            let savedMenu = gtk_menu_new()
            gtk_menu_item_set_submenu(tc_gtk_menu_item(savedRoot), savedMenu)
            gtk_menu_shell_append(tc_gtk_menu_shell(root), savedRoot)
            let activeID = UserDefaults.standard.string(for: .activeCustomThemeId)
            for saved in savedThemes {
                let selected = selectedTheme == .custom && activeID == saved.id.uuidString
                let item = gtk_menu_item_new_with_label(
                    menuSelectionLabel(selected, title: saved.name)
                )
                gtk_widget_set_name(item, "custom-theme:\(saved.id.uuidString)")
                _ = tc_gtk_on_activate(item, linuxMenuAction, opaque)
                gtk_menu_shell_append(tc_gtk_menu_shell(savedMenu), item)
            }
        }

        let sizeRoot = gtk_menu_item_new_with_label(L10n.shared.tr("size.title"))
        let sizeMenu = gtk_menu_new()
        gtk_menu_item_set_submenu(tc_gtk_menu_item(sizeRoot), sizeMenu)
        gtk_menu_shell_append(tc_gtk_menu_shell(root), sizeRoot)
        for size in LinuxClockSize.allCases {
            let item = gtk_menu_item_new_with_label(
                menuSelectionLabel(size == selectedSize, title: size.displayName)
            )
            gtk_widget_set_name(item, "size:\(size.rawValue)")
            _ = tc_gtk_on_activate(item, linuxMenuAction, opaque)
            gtk_menu_shell_append(tc_gtk_menu_shell(sizeMenu), item)
            sizeItems[size] = item
        }

        appendMenuItem(
            L10n.shared.tr("menu.api", Int(Self.resolveAPIServerPort())),
            name: "copy-api", to: root
        )
        gtk_menu_shell_append(tc_gtk_menu_shell(root), gtk_separator_menu_item_new())

        let opacityRoot = gtk_menu_item_new_with_label(L10n.shared.tr("menu.opacity"))
        let opacityMenu = gtk_menu_new()
        gtk_menu_item_set_submenu(tc_gtk_menu_item(opacityRoot), opacityMenu)
        gtk_menu_shell_append(tc_gtk_menu_shell(root), opacityRoot)
        for value in [25, 50, 75, 100] {
            let item = gtk_menu_item_new_with_label(
                menuSelectionLabel(Int(windowOpacity * 100) == value, title: "\(value)%")
            )
            gtk_widget_set_name(item, "opacity:\(value)")
            _ = tc_gtk_on_activate(item, linuxMenuAction, opaque)
            gtk_menu_shell_append(tc_gtk_menu_shell(opacityMenu), item)
            opacityItems[value] = item
        }

        appendMenuItem(
            menuSelectionLabel(alwaysOnTop, title: L10n.shared.tr("menu.alwaysOnTop")),
            name: "always-on-top", to: root
        )
        gtk_menu_shell_append(tc_gtk_menu_shell(root), gtk_separator_menu_item_new())

        let temperatureRoot = gtk_menu_item_new_with_label(L10n.shared.tr("menu.temperature"))
        let temperatureMenu = gtk_menu_new()
        gtk_menu_item_set_submenu(tc_gtk_menu_item(temperatureRoot), temperatureMenu)
        gtk_menu_shell_append(tc_gtk_menu_shell(root), temperatureRoot)
        let celsius = gtk_menu_item_new_with_label(
            menuSelectionLabel(!useFahrenheit, title: L10n.shared.tr("menu.celsius"))
        )
        gtk_widget_set_name(celsius, "temperature:c")
        _ = tc_gtk_on_activate(celsius, linuxMenuAction, opaque)
        gtk_menu_shell_append(tc_gtk_menu_shell(temperatureMenu), celsius)
        let fahrenheit = gtk_menu_item_new_with_label(
            menuSelectionLabel(useFahrenheit, title: L10n.shared.tr("menu.fahrenheit"))
        )
        gtk_widget_set_name(fahrenheit, "temperature:f")
        _ = tc_gtk_on_activate(fahrenheit, linuxMenuAction, opaque)
        gtk_menu_shell_append(tc_gtk_menu_shell(temperatureMenu), fahrenheit)

        let cityRoot = gtk_menu_item_new_with_label(L10n.shared.tr("menu.city"))
        let cityMenu = gtk_menu_new()
        gtk_menu_item_set_submenu(tc_gtk_menu_item(cityRoot), cityMenu)
        gtk_menu_shell_append(tc_gtk_menu_shell(root), cityRoot)
        for city in Self.cityOptions {
            let title: String
            if city == "auto" {
                let resolved = weatherService.weather.cityName
                title = resolved.isEmpty
                    ? L10n.shared.tr("menu.cityAutoLocating")
                    : L10n.shared.tr("menu.cityAuto", resolved)
            } else {
                title = city
            }
            let item = gtk_menu_item_new_with_label(
                menuSelectionLabel(selectedCity == city, title: title)
            )
            gtk_widget_set_name(item, "city:\(city)")
            _ = tc_gtk_on_activate(item, linuxMenuAction, opaque)
            gtk_menu_shell_append(tc_gtk_menu_shell(cityMenu), item)
        }
        gtk_menu_shell_append(tc_gtk_menu_shell(root), gtk_separator_menu_item_new())

        let timezoneRoot = gtk_menu_item_new_with_label(L10n.shared.tr("menu.timezone"))
        let timezoneMenu = gtk_menu_new()
        gtk_menu_item_set_submenu(tc_gtk_menu_item(timezoneRoot), timezoneMenu)
        gtk_menu_shell_append(tc_gtk_menu_shell(root), timezoneRoot)
        for option in Self.timezoneOptions {
            let item = gtk_menu_item_new_with_label(
                menuSelectionLabel(
                    selectedTimezone == option.identifier,
                    title: L10n.shared.tr(option.label)
                )
            )
            gtk_widget_set_name(item, "timezone:\(option.identifier)")
            _ = tc_gtk_on_activate(item, linuxMenuAction, opaque)
            gtk_menu_shell_append(tc_gtk_menu_shell(timezoneMenu), item)
            timezoneItems[option.identifier] = item
        }

        let languageRoot = gtk_menu_item_new_with_label(L10n.shared.tr("menu.language"))
        let languageMenu = gtk_menu_new()
        gtk_menu_item_set_submenu(tc_gtk_menu_item(languageRoot), languageMenu)
        gtk_menu_shell_append(tc_gtk_menu_shell(root), languageRoot)
        for language in AppLanguage.allCases {
            let item = gtk_menu_item_new_with_label(
                menuSelectionLabel(language == L10n.shared.language, title: language.displayName)
            )
            gtk_widget_set_name(item, "language:\(language.rawValue)")
            _ = tc_gtk_on_activate(item, linuxMenuAction, opaque)
            gtk_menu_shell_append(tc_gtk_menu_shell(languageMenu), item)
            languageItems[language] = item
        }

        gtk_menu_shell_append(tc_gtk_menu_shell(root), gtk_separator_menu_item_new())
        appendMenuItem(localized(zh: "查看详情", en: "Show Details"), name: "details", to: root)
        appendMenuItem(localized(zh: "刷新数据", en: "Refresh Usage"), name: "refresh", to: root)
        gtk_menu_shell_append(tc_gtk_menu_shell(root), gtk_separator_menu_item_new())
        appendMenuItem(L10n.shared.tr("menu.settings"), name: "settings", to: root)
        gtk_menu_shell_append(tc_gtk_menu_shell(root), gtk_separator_menu_item_new())
        appendMenuItem(
            menuSelectionLabel(LinuxAutostart.isEnabled, title: L10n.shared.tr("menu.launchAtLogin")),
            name: "launch-at-login", to: root
        )
        gtk_menu_shell_append(tc_gtk_menu_shell(root), gtk_separator_menu_item_new())
        appendMenuItem(L10n.shared.tr("menu.about"), name: "about", to: root)
        appendMenuItem(L10n.shared.tr("menu.quit"), name: "quit", to: root)
        gtk_widget_show_all(root)
    }

    private func appendMenuItem(_ title: String, name: String, to menu: UnsafeMutablePointer<GtkWidget>) {
        let item = gtk_menu_item_new_with_label(title)
        gtk_widget_set_name(item, name)
        _ = tc_gtk_on_activate(item, linuxMenuAction, opaque)
        gtk_menu_shell_append(tc_gtk_menu_shell(menu), item)
    }

    private func localized(zh: String, en: String) -> String {
        L10n.shared.language == .en ? en : zh
    }

    private func menuSelectionLabel(_ selected: Bool, title: String) -> String {
        selected ? "✓  \(title)" : "    \(title)"
    }

    fileprivate func scheduleScan(incremental: Bool) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard self.model.scan(incremental: incremental) else { return }
            _ = tc_gtk_idle_add(linuxScanFinished, self.opaque)
        }
    }

    fileprivate func refreshUI() {
        guard let dial else { return }
        updateDetailsPanel()
        gtk_widget_queue_draw(dial)
    }

    private func updateDetailsPanel() {
        detailsPanel?.update(
            tools: model.tools,
            weather: weatherService.weather,
            useFahrenheit: useFahrenheit,
            theme: selectedTheme,
            size: selectedSize
        )
    }

    fileprivate func refreshClock() {
        if let dial { gtk_widget_queue_draw(dial) }
    }

    fileprivate func draw(_ context: OpaquePointer) {
        guard let dial else { return }
        renderer.draw(
            context,
            width: Double(gtk_widget_get_allocated_width(dial)),
            height: Double(gtk_widget_get_allocated_height(dial)),
            snapshot: LinuxClockSnapshot(
                date: Date(),
                timeZone: effectiveTimeZone,
                tools: model.tools,
                weather: weatherService.weather,
                useFahrenheit: useFahrenheit,
                theme: selectedTheme,
                size: selectedSize
            )
        )
    }

    fileprivate func handleButtonPress(event: UnsafeMutablePointer<GdkEventButton>) {
        switch tc_gtk_event_button(event) {
        case 1:
            leftButtonDown = true
            dragStarted = false
            pressRootX = tc_gtk_button_root_x(event)
            pressRootY = tc_gtk_button_root_y(event)
        case 3:
            if let menu { tc_gtk_popup_menu(menu, event) }
        default:
            break
        }
    }

    fileprivate func handleMotion(event: UnsafeMutablePointer<GdkEventMotion>) {
        guard leftButtonDown, !dragStarted else { return }
        let state = tc_gtk_motion_state(event)
        guard state & guint(GDK_BUTTON1_MASK.rawValue) != 0 else { return }
        let x = tc_gtk_motion_root_x(event)
        let y = tc_gtk_motion_root_y(event)
        guard hypot(x - pressRootX, y - pressRootY) >= 5 else { return }
        dragStarted = true
        detailsPanel?.hide()
        if let window {
            tc_gtk_begin_move_at(window, 1, x, y, tc_gtk_motion_time(event))
        }
    }

    fileprivate func handleButtonRelease(event: UnsafeMutablePointer<GdkEventButton>) {
        guard tc_gtk_event_button(event) == 1 else { return }
        let shouldToggle = leftButtonDown && !dragStarted
        leftButtonDown = false
        dragStarted = false
        if shouldToggle { detailsPanel?.toggle() }
    }

    fileprivate func handleMenuAction(widget: UnsafeMutablePointer<GtkWidget>) {
        defer { UserDefaults.standard.synchronize() }
        let name = String(cString: tc_gtk_widget_name(widget))
        if name.hasPrefix("theme:"),
           let theme = LinuxClockTheme(rawValue: String(name.dropFirst("theme:".count))) {
            selectTheme(theme)
            return
        }
        if name.hasPrefix("size:"),
           let size = LinuxClockSize(rawValue: String(name.dropFirst("size:".count))) {
            selectSize(size)
            return
        }
        if name.hasPrefix("opacity:"),
           let percent = Int(name.dropFirst("opacity:".count)) {
            setOpacity(Double(percent) / 100)
            return
        }
        if name.hasPrefix("timezone:") {
            selectTimezone(String(name.dropFirst("timezone:".count)))
            return
        }
        if name.hasPrefix("language:"),
           let language = AppLanguage(rawValue: String(name.dropFirst("language:".count))) {
            selectLanguage(language)
            return
        }
        if name.hasPrefix("temperature:") {
            setFahrenheit(name.hasSuffix(":f"))
            return
        }
        if name.hasPrefix("city:") {
            selectCity(String(name.dropFirst("city:".count)))
            return
        }
        if name.hasPrefix("custom-theme:"),
           let id = UUID(uuidString: String(name.dropFirst("custom-theme:".count))) {
            applyCustomTheme(id: id)
            return
        }
        switch name {
        case "theme-picker": themePicker?.show(selected: selectedTheme)
        case "copy-api":
            let endpoint = Self.apiEndpointURL
            endpoint.withCString { tc_gtk_clipboard_set_text($0) }
            print("[TokenClock] Copied \(endpoint)")
        case "always-on-top": toggleAlwaysOnTop()
        case "details": toggleDetails()
        case "refresh": scheduleScan(incremental: true)
        case "settings": showSettings()
        case "launch-at-login": toggleAutostart()
        case "about":
            if let window {
                if let path = Bundle.module.path(forResource: "glass_disc", ofType: "png") {
                    path.withCString { tc_gtk_show_about(window, "v1.4.0", $0) }
                } else {
                    tc_gtk_show_about(window, "v1.4.0", nil)
                }
            }
        case "quit":
            shutdown()
            gtk_main_quit()
        default: break
        }
    }

    private func selectTheme(_ theme: LinuxClockTheme) {
        selectedTheme = theme
        UserDefaults.standard.setString(theme.rawValue, for: .selectedTheme)
        for (candidate, item) in themeItems {
            gtk_menu_item_set_label(
                tc_gtk_menu_item(item),
                menuSelectionLabel(candidate == theme, title: candidate.displayName)
            )
        }
        print("[TokenClock] Theme changed to \(theme.rawValue)")
        updateDetailsPanel()
        refreshUI()
    }

    func chooseThemeFromPicker(_ theme: LinuxClockTheme) {
        if theme == .custom {
            applyCustomTheme(id: nil)
        } else {
            selectTheme(theme)
        }
    }

    func applyCustomTheme(id: UUID?) {
        if let id {
            guard LinuxCustomThemeStore.shared.apply(id: id) else { return }
        } else {
            UserDefaults.standard.remove(.activeCustomThemeId)
        }
        selectTheme(.custom)
        rebuildContextMenu()
    }

    func customThemeListChanged() {
        if selectedTheme == .custom {
            let active = UserDefaults.standard.string(for: .activeCustomThemeId)
            if active == nil || !LinuxCustomThemeStore.shared.themes.contains(where: { $0.id.uuidString == active }) {
                UserDefaults.standard.remove(.activeCustomThemeId)
                selectTheme(.classic)
            }
        }
        rebuildContextMenu()
    }

    func resetCustomThemeToClassic() {
        UserDefaults.standard.remove(.activeCustomThemeId)
        selectTheme(.classic)
        rebuildContextMenu()
    }

    private func selectSize(_ size: LinuxClockSize) {
        selectedSize = size
        UserDefaults.standard.setString(size.rawValue, for: .clockSize)
        UserDefaults.standard.setBool(true, for: .clockSizeUserChosen)
        for (candidate, item) in sizeItems {
            gtk_menu_item_set_label(
                tc_gtk_menu_item(item),
                menuSelectionLabel(candidate == size, title: candidate.displayName)
            )
        }
        guard let window, let dial else { return }
        let diameter = gint(size.diameter)
        gtk_widget_set_size_request(dial, diameter, diameter)
        tc_gtk_set_fixed_window_size(window, diameter)
        detailsPanel?.hide()
        updateDetailsPanel()
        _ = tc_gtk_idle_add(linuxShapeFinished, opaque)
        refreshUI()
    }

    fileprivate func applyCircularShape() {
        guard let window else { return }
        tc_gtk_shape_circle(window, gint(selectedSize.diameter))
    }

    private func toggleDetails() {
        detailsPanel?.toggle()
    }

    private var effectiveTimeZone: TimeZone {
        selectedTimezone == "auto"
            ? .current
            : (TimeZone(identifier: selectedTimezone) ?? .current)
    }

    private func setOpacity(_ opacity: Double) {
        windowOpacity = min(1, max(0.25, opacity))
        UserDefaults.standard.set(windowOpacity, forKey: SettingsKey.windowOpacity.rawValue)
        if let window { gtk_widget_set_opacity(window, windowOpacity) }
        detailsPanel?.setOpacity(windowOpacity)
        for (value, item) in opacityItems {
            gtk_menu_item_set_label(
                tc_gtk_menu_item(item),
                menuSelectionLabel(value == Int(windowOpacity * 100), title: "\(value)%")
            )
        }
    }

    private func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        UserDefaults.standard.setBool(alwaysOnTop, for: .alwaysOnTop)
        if let window { gtk_window_set_keep_above(tc_gtk_window(window), alwaysOnTop ? 1 : 0) }
        detailsPanel?.setKeepAbove(alwaysOnTop)
        rebuildContextMenu()
    }

    private func selectTimezone(_ identifier: String) {
        selectedTimezone = identifier
        UserDefaults.standard.setString(identifier, for: .selectedTimezone)
        refreshClock()
        rebuildContextMenu()
    }

    private func selectLanguage(_ language: AppLanguage) {
        L10n.shared.language = language
        updateDetailsPanel()
        themePicker?.refreshLanguage()
        settingsWindow?.refreshLanguage()
        rebuildContextMenu()
        refreshClock()
    }

    private func setFahrenheit(_ enabled: Bool) {
        useFahrenheit = enabled
        UserDefaults.standard.setBool(enabled, for: .useFahrenheit)
        refreshUI()
        rebuildContextMenu()
    }

    private func selectCity(_ city: String) {
        selectedCity = city
        UserDefaults.standard.setString(city, for: .selectedCity)
        refreshWeather()
        rebuildContextMenu()
    }

    fileprivate func refreshWeather() {
        weatherService.fetch(city: selectedCity) { [weak self] in
            guard let self else { return }
            _ = tc_gtk_idle_add(linuxWeatherFinished, self.opaque)
        }
    }

    fileprivate func weatherDidFinish() {
        refreshUI()
        rebuildContextMenu()
    }

    private func toggleAutostart() {
        do {
            try LinuxAutostart.setEnabled(!LinuxAutostart.isEnabled)
            UserDefaults.standard.setBool(LinuxAutostart.isEnabled, for: .launchAtLogin)
            rebuildContextMenu()
        } catch {
            guard let window else { return }
            localized(zh: "无法更改开机自启", en: "Unable to change autostart").withCString { title in
                error.localizedDescription.withCString { message in
                    tc_gtk_show_message(window, GTK_MESSAGE_ERROR, title, message)
                }
            }
        }
    }

    private func rebuildContextMenu() {
        let oldMenu = menu
        menu = nil
        buildContextMenu()
        if let oldMenu { gtk_widget_destroy(oldMenu) }
    }

    private func showSettings() {
        settingsWindow?.show()
    }

    func openThemePickerFromSettings() {
        settingsWindow?.hide()
        themePicker?.show(selected: selectedTheme)
    }

    func settingsDidSave(apiChanged: Bool) {
        UserDefaults.standard.synchronize()
        if apiChanged {
            apiServer?.stop()
            apiServer = nil
            startAPIServerIfEnabled()
        }
        scheduleScan(incremental: false)
        refreshUI()
        rebuildContextMenu()
    }

    private static func resolveAPIServerPort() -> UInt16 {
        let raw = UserDefaults.standard.integer(forKey: SettingsKey.apiServerPort.rawValue)
        if raw > 0, raw <= Int(UInt16.max) { return UInt16(raw) }
        return AppConfig.LocalServer.defaultPort
    }

    private static var apiEndpointURL: String {
        "http://localhost:\(resolveAPIServerPort())\(AppConfig.LocalServer.usageEndpoint)"
    }

    private func startAPIServerIfEnabled() {
        guard UserDefaults.standard.bool(for: .apiServerEnabled, default: true) else { return }
        apiServer = LinuxAPIServer(model: model, port: Self.resolveAPIServerPort())
        apiServer?.start()
    }

    fileprivate func shutdown() {
        if let window {
            var x: gint = 0
            var y: gint = 0
            gtk_window_get_position(tc_gtk_window(window), &x, &y)
            UserDefaults.standard.set(Int(x), forKey: "TCLinuxWindowX")
            UserDefaults.standard.set(Int(y), forKey: "TCLinuxWindowY")
        }
        // swift-corelibs-foundation flushes defaults less eagerly than the
        // Darwin implementation, so persist all Linux preferences on exit.
        UserDefaults.standard.synchronize()
        apiServer?.stop()
    }
}

private func app(from data: gpointer?) -> LinuxApp? {
    guard let data else { return nil }
    return Unmanaged<LinuxApp>.fromOpaque(data).takeUnretainedValue()
}

private func linuxDestroy(_ widget: UnsafeMutablePointer<GtkWidget>?, _ data: gpointer?) {
    app(from: data)?.shutdown()
    gtk_main_quit()
}

private func linuxButtonPress(
    _ widget: UnsafeMutablePointer<GtkWidget>?,
    _ event: UnsafeMutablePointer<GdkEventButton>?,
    _ data: gpointer?
) -> gboolean {
    guard let event else { return 0 }
    app(from: data)?.handleButtonPress(event: event)
    return 1
}

private func linuxButtonRelease(
    _ widget: UnsafeMutablePointer<GtkWidget>?,
    _ event: UnsafeMutablePointer<GdkEventButton>?,
    _ data: gpointer?
) -> gboolean {
    guard let event else { return 0 }
    app(from: data)?.handleButtonRelease(event: event)
    return 1
}

private func linuxMotion(
    _ widget: UnsafeMutablePointer<GtkWidget>?,
    _ event: UnsafeMutablePointer<GdkEventMotion>?,
    _ data: gpointer?
) -> gboolean {
    guard let event else { return 0 }
    app(from: data)?.handleMotion(event: event)
    return 1
}

private func linuxMenuAction(_ widget: UnsafeMutablePointer<GtkWidget>?, _ data: gpointer?) {
    guard let widget else { return }
    app(from: data)?.handleMenuAction(widget: widget)
}

private func linuxDraw(
    _ widget: UnsafeMutablePointer<GtkWidget>?,
    _ context: OpaquePointer?,
    _ data: gpointer?
) -> gboolean {
    guard let context else { return 0 }
    app(from: data)?.draw(context)
    return 0
}

private func linuxClockTick(_ data: gpointer?) -> gboolean {
    guard let app = app(from: data) else { return 0 }
    app.refreshClock()
    return 1
}

private func linuxScanTick(_ data: gpointer?) -> gboolean {
    guard let app = app(from: data) else { return 0 }
    app.scheduleScan(incremental: true)
    return 1
}

private func linuxScanFinished(_ data: gpointer?) -> gboolean {
    app(from: data)?.refreshUI()
    return 0
}

private func linuxWeatherTick(_ data: gpointer?) -> gboolean {
    guard let app = app(from: data) else { return 0 }
    app.refreshWeather()
    return 1
}

private func linuxWeatherFinished(_ data: gpointer?) -> gboolean {
    app(from: data)?.weatherDidFinish()
    return 0
}

private func linuxShapeFinished(_ data: gpointer?) -> gboolean {
    app(from: data)?.applyCircularShape()
    return 0
}

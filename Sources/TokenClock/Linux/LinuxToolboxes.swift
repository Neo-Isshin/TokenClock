#if os(Linux)
  import Foundation
  import CGtk

  /// Native GTK frontends for the shared content/tool services. No scan or probe
  /// starts merely because a window is created; actions retain their prior results.
  @MainActor final class LinuxToolboxes {
    let content: UserContentCenter
    lazy var local = LocalToolboxModel()
    let mainland = MainlandReachabilityModel()
    private let parent: UnsafeMutablePointer<GtkWidget>
    private let navigate: (QuickTool) -> Void
    var onContentChange: (([TokenClockNotification]) -> Void)?
    var onNotificationPreferences: ((Set<NotificationCategory>) -> Void)?
    private var secretPattern = ""
    var onQuickActionsChange: (() -> Void)?
    var onNewsBack: (() -> Void)?
    var isNewsVisible: (() -> Bool)?
    private var windows: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private var boxes: [String: UnsafeMutablePointer<GtkWidget>] = [:]
    private var newsRoot: UnsafeMutablePointer<GtkWidget>?
    private var notebookTitle: UnsafeMutablePointer<GtkWidget>?
    private var notebookSelectedRow: UnsafeMutablePointer<GtkWidget>?
    private var notebookBody: UnsafeMutablePointer<GtkWidget>?
    private var rebuilding = false
    private var notebookShowCompleted = false
    private var focusedNewsID: String?
    private var networkTask: Task<Void, Never>?
    private var networkFetcher: NetworkDiagnosticFetcher?
    private var networkRows: [NetworkDiagnosticRow] = []
    private var networkDate: Date?
    private var networkRunning = false
    private var networkGeneration = UUID()
    private var networkStatus = ""
    private var updateURL: URL?
    private var lastLocalSignature = ""
    private var lastMainlandSignature = ""
    private var summaryTools: [ToolUsage] = []
    private var summaryQuotas: [StatusSummaryQuota] = []
    private var summaryActiveIDs: [SubscriptionProvider: String] = [:]
    private var summaryHourly = StatusSummaryHourlyData.empty(day: "")
    private var summaryPrevious = StatusSummaryHourlyData.empty(day: "")
    private var comparison = StatusSummaryComparisonData()
    private var fullDay = false
    private var summaryModels = false
    private var summaryTimeline = false
    private var summaryReloadTask: Task<Void, Never>?
    private lazy var opaque = Unmanaged.passUnretained(self).toOpaque()

    init(
      parent: UnsafeMutablePointer<GtkWidget>, content: UserContentCenter? = nil,
      navigate: @escaping (QuickTool) -> Void
    ) {
      self.content = content ?? UserContentCenter()
      self.parent = parent
      self.navigate = navigate
      tc_gtk_apply_css(
        """
        .tc-toolbox-card { background: alpha(@theme_fg_color,0.035); border:1px solid alpha(@theme_fg_color,0.10);border-radius:12px;padding:12px; }
        .tc-toolbox-heading { font-weight:bold; font-size:14px; }
        .tc-toolbox-muted { opacity:0.68;font-size:10px; }
        .tc-toolbox-action { border-radius:9px;min-height:18px;font-size:11px;padding:3px 8px; }
        .tc-toolbox-row { border-radius:8px;padding:5px; }
        .tc-summary-total { font-size:26px;font-weight:bold; }
        """)
      self.content.onChange = { [weak self] in self?.contentChanged() }
      self.content.news.isPresentationVisible = { [weak self] in self?.isNewsVisible?() ?? false }
      if let data = UserDefaults.standard.data(forKey: "TC_nativeNetworkResult.v1"),
        let cache = try? JSONDecoder().decode(NetworkCache.self, from: data)
      {
        networkRows = cache.rows
        networkDate = cache.date
      }
    }
    func start() { content.start() }
    func stop() {
      content.stop()
      local.stop()
      networkTask?.cancel()
      networkFetcher?.cancel()
      mainland.stop()
      ModelIntegrityLauncher.shared.stop()
      for window in windows.values { gtk_widget_destroy(window) }
      windows.removeAll()
      boxes.removeAll()
      if let newsRoot {
        g_object_unref(UnsafeMutableRawPointer(newsRoot))
        self.newsRoot = nil
      }
    }
    private func contentChanged() {
      let preferences = content.preferences.configuration
      onNotificationPreferences?(preferences.enabled ? preferences.categories : [])
      onContentChange?(content.notices().filter { content.preferences.allows($0) })
      if newsRoot != nil, isNewsVisible?() == true { renderNews() }
      if visible("summary") { renderSummary() }
    }
    func markRead(_ notices: [TokenClockNotification]) {
      content.markRead(notices)
      contentChanged()
    }
    func setViewingNews(_ value: Bool) { content.news.setViewing(value) }
    func open(_ tool: QuickTool) {
      switch tool {
      case .model: showModelDetect()
      case .network: showNetwork()
      case .local: showLocal()
      case .notebook: showNotebook()
      default: navigate(tool)
      }
    }
    private func visible(_ key: String) -> Bool {
      windows[key].map { gtk_widget_get_visible($0) != 0 } ?? false
    }
    private func window(_ key: String, title: String, width: Int = 680, height: Int = 600)
      -> UnsafeMutablePointer<GtkWidget>
    {
      if let window = windows[key], let box = boxes[key] {
        gtk_window_set_title(tc_gtk_window(window), title)
        gtk_window_present(tc_gtk_window(window))
        return box
      }
      let window = gtk_window_new(GTK_WINDOW_TOPLEVEL)!
      let outer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10)!
      let scroll = gtk_scrolled_window_new(nil, nil)!
      windows[key] = window
      boxes[key] = outer
      gtk_widget_set_name(window, "toolbox:" + key)
      gtk_window_set_title(tc_gtk_window(window), title)
      gtk_window_set_default_size(tc_gtk_window(window), gint(width), gint(height))
      gtk_window_set_resizable(tc_gtk_window(window), 1)
      gtk_window_set_transient_for(tc_gtk_window(window), tc_gtk_window(parent))
      gtk_container_set_border_width(tc_gtk_container(outer), 16)
      gtk_scrolled_window_set_policy(
        tc_gtk_scrolled_window(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
      gtk_container_add(tc_gtk_container(scroll), outer)
      gtk_container_add(tc_gtk_container(window), scroll)
      _ = tc_gtk_hide_on_delete(window)
      gtk_widget_show_all(window)
      gtk_window_present(tc_gtk_window(window))
      return outer
    }
    private func clear(_ box: UnsafeMutablePointer<GtkWidget>) { tc_gtk_remove_all_children(box) }
    private func stack(
      _ parent: UnsafeMutablePointer<GtkWidget>, horizontal: Bool = false, spacing: Int32 = 8,
      card: Bool = false
    ) -> UnsafeMutablePointer<GtkWidget> {
      let box = gtk_box_new(
        horizontal ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL, spacing)!
      if card { tc_gtk_add_class(box, "tc-toolbox-card") }
      gtk_box_pack_start(tc_gtk_box(parent), box, 0, 0, 0)
      return box
    }
    @discardableResult private func label(
      _ text: String, _ parent: UnsafeMutablePointer<GtkWidget>, muted: Bool = false,
      heading: Bool = false
    ) -> UnsafeMutablePointer<GtkWidget> {
      let widget = gtk_label_new(text)!
      gtk_label_set_xalign(tc_gtk_label(widget), 0)
      gtk_label_set_line_wrap(tc_gtk_label(widget), 1)
      gtk_label_set_line_wrap_mode(tc_gtk_label(widget), PANGO_WRAP_WORD_CHAR)
      gtk_label_set_selectable(tc_gtk_label(widget), 1)
      if muted { tc_gtk_add_class(widget, "tc-toolbox-muted") }
      if heading { tc_gtk_add_class(widget, "tc-toolbox-heading") }
      gtk_box_pack_start(tc_gtk_box(parent), widget, 0, 0, 0)
      return widget
    }
    @discardableResult private func button(
      _ title: String, _ name: String, _ parent: UnsafeMutablePointer<GtkWidget>,
      hint: String? = nil
    ) -> UnsafeMutablePointer<GtkWidget> {
      let widget = gtk_button_new_with_label(title)!
      gtk_widget_set_name(widget, name)
      tc_gtk_add_class(widget, "tc-toolbox-action")
      gtk_widget_set_tooltip_text(widget, hint ?? title)
      _ = tc_gtk_on_clicked(widget, linuxToolboxClicked, opaque)
      gtk_box_pack_start(tc_gtk_box(parent), widget, 1, 1, 0)
      return widget
    }
    private func entry(
      _ text: String, _ name: String, _ parent: UnsafeMutablePointer<GtkWidget>, placeholder: String
    ) -> UnsafeMutablePointer<GtkWidget> {
      let widget = gtk_entry_new()!
      gtk_widget_set_name(widget, name)
      gtk_entry_set_text(tc_gtk_entry(widget), text)
      gtk_entry_set_placeholder_text(tc_gtk_entry(widget), placeholder)
      gtk_box_pack_start(tc_gtk_box(parent), widget, 0, 0, 0)
      _ = tc_gtk_on_changed(widget, linuxToolboxChanged, opaque)
      return widget
    }
    private func timestamp(_ date: Date?) -> String {
      guard let date else { return toolboxText("尚未检查", "Not checked") }
      let f = DateFormatter()
      f.locale = Locale(identifier: L10n.shared.language.rawValue)
      f.dateStyle = .short
      f.timeStyle = .short
      return toolboxText("检查时间：", "Checked: ") + f.string(from: date)
    }
    private func resetDate(_ date: Date?) -> String {
      guard let date else { return "—" }
      let f = DateFormatter()
      f.locale = Locale(identifier: L10n.shared.language.rawValue)
      f.dateStyle = .short
      f.timeStyle = .short
      return f.string(from: date)
    }
    private func show(_ key: String) {
      if let w = windows[key] {
        gtk_widget_show_all(w)
        gtk_window_present(tc_gtk_window(w))
      }
    }

    func makeNewsWidget() -> UnsafeMutablePointer<GtkWidget> {
      if let newsRoot { return newsRoot }
      let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10)!
      _ = g_object_ref_sink(UnsafeMutableRawPointer(box))
      newsRoot = box
      return box
    }
    func showNews(focused: String? = nil) {
      focusedNewsID = focused
      content.news.refreshIfDue(language: L10n.shared.language.rawValue)
      renderNews()
    }
    private func renderNews() {
      guard let root = newsRoot else { return }
      clear(root)
      let top = stack(root, horizontal: true)
      label(toolboxText("AI速递", "AI digest"), top, heading: true)
      button(toolboxText("返回用量", "Back to usage"), "news:back", top)
      button(toolboxText("刷新", "Refresh"), "news:refresh", top)
      if let date = content.news.cache.refreshedAt { label(timestamp(date), root, muted: true) }
      if !content.news.errorMessage.isEmpty { label(content.news.errorMessage, root, muted: true) }
      if content.news.items.isEmpty {
        label(
          content.news.loading
            ? toolboxText("正在获取速递…", "Loading digest…") : toolboxText("暂无速递", "No digest yet"), root
        )
      }
      let ordered = content.news.items.enumerated().sorted { a, b in
        if a.element.id == focusedNewsID { return true }
        if b.element.id == focusedNewsID { return false }
        return a.offset < b.offset
      }.map(\.element)
      for item in ordered {
        let row = stack(root, card: true)
        let prefix = item.track?.badge ?? toolboxText("【资讯】", "[News] ")
        let headline = stack(row, horizontal: true)
        let image = gtk_image_new()!
        gtk_widget_set_size_request(image, 24, 24)
        if let fallback = Bundle.module.resourceURL?.appendingPathComponent(
          "AilyreNews/ai-digest.png"
        ).path {
          tc_gtk_image_set_file_scaled(image, fallback, 24)
        }
        gtk_box_pack_start(tc_gtk_box(headline), image, 0, 0, 0)
        button(prefix + item.title, "news:item:" + item.id, headline, hint: item.url.absoluteString)
        if let url = item.logoURL {
          _ = g_object_ref(UnsafeMutableRawPointer(image))
          Task { @MainActor in
            defer { g_object_unref(UnsafeMutableRawPointer(image)) }
            if let file = await NewsLogoCache.shared.file(for: url),
              gtk_widget_get_parent(image) != nil
            {
              tc_gtk_image_set_file_scaled(image, file.path, 24)
            }
          }
        }
        if !item.summary.isEmpty { label(item.summary, row, muted: true) }
      }
      button(
        toolboxText("完整内容在 ailyre.com 中 ↗", "Full coverage on ailyre.com ↗"), "news:website", root,
        hint: toolboxText(
          "在默认浏览器打开 Ailyre 新闻页", "Open the full Ailyre news page in your default browser"))
      gtk_widget_show_all(root)
    }
    func showQuickEditor() {
      let box = window(
        "quick", title: toolboxText("快捷按钮", "Quick actions"), width: 440, height: 470)
      clear(box)
      label(
        toolboxText("勾选显示，使用箭头调整顺序。", "Choose visible actions and use the arrows to reorder."), box,
        muted: true)
      let preferences = QuickToolPreferences.shared
      let ordered =
        preferences.order + QuickTool.allCases.filter { !preferences.order.contains($0) }
      for item in ordered {
        let row = stack(box, horizontal: true)
        button(
          (preferences.order.contains(item) ? "☑ " : "☐ ") + item.title,
          "quick:toggle:" + item.rawValue, row, hint: item.hint)
        let up = button("↑", "quick:up:" + item.rawValue, row)
        let down = button("↓", "quick:down:" + item.rawValue, row)
        gtk_widget_set_sensitive(
          up, preferences.order.first != item && preferences.order.contains(item) ? 1 : 0)
        gtk_widget_set_sensitive(
          down, preferences.order.last != item && preferences.order.contains(item) ? 1 : 0)
      }
      show("quick")
    }
    func showNotificationSettings() {
      let box = window(
        "notifications", title: L10n.shared.tr("notification.title"), width: 480, height: 440)
      clear(box)
      let p = content.preferences
      button(
        (p.configuration.enabled ? "☑ " : "☐ ") + toolboxText("启用通知", "Enable notifications"),
        "preferences:enabled", box)
      for category in NotificationCategory.allCases {
        button(
          (p.configuration.categories.contains(category) ? "☑ " : "☐ ") + category.title,
          "preferences:" + category.rawValue, box)
      }
      show("notifications")
    }
    func showNotebook(selected: UUID? = nil) {
      if let selected { content.notebook.selectedID = selected }
      _ = window("notebook", title: toolboxText("行事本", "Notebook"), width: 720, height: 600)
      renderNotebook()
      show("notebook")
    }
    private func renderNotebook() {
      guard let box = boxes["notebook"] else { return }
      rebuilding = true
      defer { rebuilding = false }
      notebookSelectedRow = nil
      clear(box)
      let actions = stack(box, horizontal: true)
      button(toolboxText("新增记录", "New entry"), "notebook:add", actions)
      button(
        notebookShowCompleted
          ? toolboxText("隐藏已完成", "Hide completed") : toolboxText("显示已完成", "Show completed"),
        "notebook:completed", actions)
      for item in content.notebook.entries where notebookShowCompleted || !item.completed {
        let row = stack(box, horizontal: true)
        button(item.completed ? "☑" : "☐", "notebook:done:" + item.id.uuidString, row)
        let title = button(
          item.title.isEmpty ? toolboxText("未命名记录", "Untitled entry") : item.title,
          "notebook:select:" + item.id.uuidString, row)
        if item.id == content.notebook.selectedID { notebookSelectedRow = title }
        if let date = item.remindAt { label(timestamp(date), row, muted: true) }
      }
      guard
        let item = content.notebook.entries.first(where: { $0.id == content.notebook.selectedID })
      else {
        label(toolboxText("新增或选择一条记录。", "Create or select an entry."), box, muted: true)
        gtk_widget_show_all(box)
        return
      }
      let card = stack(box, card: true)
      notebookTitle = entry(
        item.title, "notebook:title", card, placeholder: toolboxText("标题", "Title"))
      let scroll = gtk_scrolled_window_new(nil, nil)!
      let text = gtk_text_view_new()!
      notebookBody = text
      gtk_widget_set_name(text, "notebook:body")
      gtk_text_view_set_wrap_mode(tc_gtk_text_view(text), GTK_WRAP_WORD_CHAR)
      let buffer = gtk_text_view_get_buffer(tc_gtk_text_view(text))!
      gtk_text_buffer_set_text(buffer, item.body, -1)
      gtk_widget_set_size_request(scroll, -1, 180)
      gtk_container_add(tc_gtk_container(scroll), text)
      gtk_box_pack_start(tc_gtk_box(card), scroll, 1, 1, 0)
      _ = tc_gtk_on_text_changed(buffer, linuxNotebookBodyChanged, opaque)
      let controls = stack(card, horizontal: true)
      button(toolboxText("设定提醒…", "Set reminder…"), "notebook:reminder", controls)
      button(toolboxText("清除提醒", "Clear reminder"), "notebook:clear", controls)
      button(toolboxText("删除记录", "Delete entry"), "notebook:delete", controls)
      if let date = item.remindAt { label(timestamp(date), card, muted: true) }
      label(
        toolboxText("自动保存在本机 · 支持纯文本", "Saved automatically on this device · Plain text"), card,
        muted: true)
      if !content.notebook.errorMessage.isEmpty { label(content.notebook.errorMessage, box) }
      gtk_widget_show_all(box)
    }
    func showLocal() {
      _ = window("local", title: toolboxText("本地工具箱", "Local Toolbox"), width: 760, height: 640)
      renderLocal()
      show("local")
    }
    private func renderLocal() {
      guard let box = boxes["local"] else { return }
      clear(box)
      let modes = stack(box, horizontal: true)
      for (key, title) in [
        ("environment", toolboxText("环境冲突", "Environment")),
        ("disk", toolboxText("磁盘占用", "Disk usage")),
        ("secrets", toolboxText("日志泄密", "Secret scan")),
        ("keys", toolboxText("API Key 验活", "API keys")), ("clock", toolboxText("时钟检查", "Clock")),
      ] { button(title, "local:mode:" + key, modes) }
      label(timestamp(local.checkedAt), box, muted: true)
      label(local.status, box)
      let actions = stack(box, horizontal: true)
      button(toolboxText("增量检查", "Incremental check"), "local:run", actions)
      button(toolboxText("全面检查", "Full check"), "local:full", actions)
      button(toolboxText("停止", "Stop"), "local:stop", actions)
      if local.selectedMode == "secrets" {
        _ = entry(
          secretPattern, "local:pattern", box,
          placeholder: toolboxText("额外匹配表达式（可选）", "Additional regular expression (optional)"))
        label(
          toolboxText(
            "只读本地日志，敏感内容脱敏展示，不上传。", "Reads local logs only; findings are masked and never uploaded."
          ), box, muted: true)
      }
      for finding in local.findings {
        let card = stack(box, card: true)
        label(LocalToolboxResultText.localized(finding.title), card, heading: true)
        label(LocalToolboxResultText.localized(finding.detail), card, muted: true)
      }
      for key in local.keys {
        let card = stack(box, card: true)
        label(key.masked + " · " + key.status, card)
        label(key.source + "\n" + key.endpoint, card, muted: true)
      }
      for (index, file) in local.files.enumerated() {
        let card = stack(box, card: true)
        label(
          file.tool + " · "
            + ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file), card)
        label(file.path, card, muted: true)
        if file.eligible {
          button(toolboxText("移入回收站…", "Move to Trash…"), "local:trash:" + String(index), card)
        }
      }
      if !local.cacheError.isEmpty { label(local.cacheError, box, muted: true) }
      gtk_widget_show_all(box)
    }
    private struct NetworkCache: Codable {
      let date: Date
      let rows: [NetworkDiagnosticRow]
    }
    func showNetwork() {
      _ = window("network", title: toolboxText("网络工具箱", "Network Toolbox"), width: 760, height: 690)
      renderNetwork()
      show("network")
    }
    private func networkSummary(_ rows: [NetworkDiagnosticRow]) -> String {
      let exits = Set(rows.filter { $0.category == "exit" }.compactMap(\.ip))
      if rows.isEmpty {
        return toolboxText("点击检测，结果将保留在本机。", "Run checks; results are kept on this device.")
      }
      var issues: [String] = []
      if exits.count > 1 {
        issues.append(toolboxText("出口 IP 不一致，请核对分流策略", "Exit IPs differ; review routing"))
      }
      let groups = Dictionary(
        grouping: rows.filter {
          $0.category == "location" && $0.state == "observed" && $0.ip != nil
        }, by: { $0.ip! })
      if groups.values.contains(where: { Set($0.compactMap(\.country)).count > 1 }) {
        issues.append(
          toolboxText("同一 IP 的落地国家/地区观测不一致", "Country/region sources disagree for the same IP"))
      }
      if !issues.isEmpty {
        return issues.joined(separator: toolboxText("；", "; "))
          + toolboxText("。其余结果见下方。", ". See observations below.")
      }
      if exits.isEmpty {
        return toolboxText(
          "未取得可判断的出口；不能据此判定泄漏或封锁。",
          "No conclusive exit observation; this does not establish a leak or block.")
      }
      let locationCompared = groups.values.contains {
        $0.count >= 2 && Set($0.compactMap(\.country)).count == 1
      }
      return toolboxText("出口 IP 观测一致；", "Exit IP observations match; ")
        + (locationCompared
          ? toolboxText("落地地区对照一致。", "geolocation sources agree. ")
          : toolboxText("落地地区尚无充分对照。", "geolocation comparison is incomplete. "))
        + toolboxText("浏览器泄漏项目请在完整检测页核对。", " Review browser leak checks on the full check page.")
    }
    private func stateTitle(_ value: String) -> String {
      switch value {
      case "observed": return toolboxText("已观测", "Observed")
      case "responded": return toolboxText("已响应", "Responded")
      case "unavailable", "unknown": return toolboxText("未完成", "Incomplete")
      case "configured": return toolboxText("已配置", "Configured")
      default: return value
      }
    }
    private func renderNetwork() {
      guard let box = boxes["network"] else { return }
      clear(box)
      let controls = stack(box, horizontal: true)
      button(toolboxText("检测出口与分流", "Check exit and routing"), "network:run", controls)
      button(toolboxText("浏览器完整检测 ↗", "Full browser check ↗"), "network:browser", controls)
      button(toolboxText("停止", "Stop"), "network:stop", controls)
      label(timestamp(networkDate), box, muted: true)
      label(
        networkRunning ? toolboxText("正在检测…", "Checking…") : networkSummary(networkRows), box,
        heading: true)
      label(
        toolboxText(
          "DNS、WebRTC 与浏览器 DoH 在 Ailyre 检测页验证；下方为本机出口、IPv6、地区和 AI 域名的观测，不把超时判为封锁。",
          "Ailyre's browser check verifies DNS, WebRTC and browser DoH. Below are native exit, IPv6, location and AI-route observations. Timeouts are not classified as blocks."
        ), box, muted: true)
      for row in networkRows {
        let card = stack(box, card: true)
        label(row.label + " · " + stateTitle(row.state), card, heading: true)
        let values = [
          row.ip, row.country, row.region, row.city, row.httpStatus.map { "HTTP \($0)" }, row.note,
        ].compactMap { $0 }.filter { !$0.isEmpty }
        label(
          values.isEmpty
            ? toolboxText("本次未获取可判定的数据。", "No conclusive data for this check.")
            : values.joined(separator: " · "), card, muted: true)
      }
      let mainlandCard = stack(box, card: true)
      label(
        toolboxText("大陆可达性 / GFW参考", "Mainland reachability / GFW reference"), mainlandCard,
        heading: true)
      _ = entry(
        mainland.targetIP, "network:mainland-ip", mainlandCard,
        placeholder: toolboxText("目标公网 IP", "Target public IP"))
      _ = entry(
        mainland.targetPort, "network:mainland-port", mainlandCard,
        placeholder: toolboxText("已开放的服务端口", "Open service port"))
      button(toolboxText("按需多点检测", "Run multi-probe check"), "network:mainland", mainlandCard)
      if let report = mainland.report {
        label(report.summary, mainlandCard)
        for row in report.observations {
          label(
            [
              row.country, row.city, row.carrier ?? row.network,
              row.milliseconds.map { String(format: "%.0f ms", $0) } ?? row.outcome.rawValue,
            ].filter { !$0.isEmpty }.joined(separator: " · "), mainlandCard, muted: true)
        }
      }
      if !mainland.inputError.isEmpty { label(mainland.inputError, mainlandCard) }
      label(
        toolboxText(
          "服务来源：Ailyre、Cloudflare、ipify、ipwho.is、ipapi.co、Globalping。",
          "Services: Ailyre, Cloudflare, ipify, ipwho.is, ipapi.co and Globalping."), box,
        muted: true)
      gtk_widget_show_all(box)
    }
    private func runNetwork() {
      guard !networkRunning else { return }
      networkTask?.cancel()
      networkFetcher?.cancel()
      networkRunning = true
      networkGeneration = UUID()
      let generation = networkGeneration
      let fetcher = NetworkDiagnosticFetcher()
      networkFetcher = fetcher
      renderNetwork()
      networkTask = Task { [weak self] in
        let id = UUID().uuidString
        let exit = await fetcher.fetch(URL(string: "https://www.ailyre.com/cdn-cgi/trace")!)
        let baseline = NetworkDiagnosticParser.trace(exit.data)?.ip
        let result = await NetworkDiagnostics.run(runID: id, baselineIP: baseline, fetcher: fetcher)
        guard !Task.isCancelled, let self, self.networkGeneration == generation else { return }
        fetcher.cancel()
        self.networkRows = result.rows
        self.networkDate = Date()
        self.networkRunning = false
        self.networkFetcher = nil
        let exits = Set(result.rows.filter { $0.category == "exit" }.compactMap(\.ip))
        self.networkStatus =
          exits.count > 1
          ? toolboxText("出口观测不一致，请核对分流策略。", "Exit observations differ; review your routing policy.")
          : (exits.isEmpty
            ? toolboxText(
              "未取得可判断的出口；其余结果见下方。", "No conclusive exit result; see observations below.")
            : toolboxText(
              "出口观测一致；浏览器泄漏项目请在检测页核对。",
              "Exit observations match; review browser leak checks on the check page."))
        if let data = try? JSONEncoder().encode(
          NetworkCache(date: self.networkDate!, rows: result.rows))
        {
          UserDefaults.standard.set(data, forKey: "TC_nativeNetworkResult.v1")
        }
        self.renderNetwork()
      }
    }
    func showUpdates() {
      let box = window(
        "updates", title: L10n.shared.tr("menu.checkUpdate"), width: 500, height: 300)
      clear(box)
      label(toolboxText("正在检查…", "Checking…"), box)
      ReleaseUpdateService.shared.checkNow { [weak self] result in
        Task { @MainActor in
          guard let self, let box = self.boxes["updates"] else { return }
          self.clear(box)
          self.updateURL = nil
          switch result {
          case .available(let version, let url):
            self.label(L10n.shared.tr("update.available", version), box, heading: true)
            self.updateURL = url
          case .current:
            self.label(L10n.shared.tr("update.current"), box, heading: true)
            self.label("TokenClock " + AppConfig.version, box, muted: true)
          case .unavailable:
            self.label(L10n.shared.tr("update.unavailable"), box)
            self.label(L10n.shared.tr("update.unavailableBody"), box, muted: true)
            self.updateURL = ReleaseUpdateService.releasesURL
          }
          if self.updateURL != nil {
            self.button(L10n.shared.tr("update.openRelease"), "update:open", box)
          }
          self.show("updates")
        }
      }
    }
    private func showModelDetect() {
      let box = window("model", title: QuickTool.model.title, width: 500, height: 280)
      clear(box)
      label(toolboxText("正在启动本机检测服务…", "Starting the local check service…"), box)
      ModelIntegrityLauncher.shared.start { [weak self] result in
        Task { @MainActor in
          guard let self, let box = self.boxes["model"] else { return }
          self.clear(box)
          switch result {
          case .success(let url):
            self.label(
              toolboxText(
                "本机服务已就绪。模型检测、API 检测和本机 Codex 均由用户点击后执行。",
                "Local service ready. Session, API and local Codex checks run only after your explicit action."
              ), box)
            self.openURL(url)
          case .failure(let error): self.label(error.localizedDescription, box)
          }
          self.show("model")
        }
      }
    }
    func showSummary(
      tools: [ToolUsage], quotas: [StatusSummaryQuota],
      activeIDs: [SubscriptionProvider: String] = [:]
    ) {
      summaryActiveIDs = activeIDs
      summaryTools = tools
      summaryQuotas = quotas
      _ = window("summary", title: L10n.shared.tr("status.summary"), width: 650, height: 650)
      renderSummary()
      show("summary")
      reloadSummaryHistory()
    }
    func updateSummary(
      tools: [ToolUsage], quotas: [StatusSummaryQuota],
      activeIDs: [SubscriptionProvider: String] = [:]
    ) {
      summaryActiveIDs = activeIDs
      guard visible("summary") else { return }
      if summaryTools != tools || summaryQuotas != quotas {
        summaryTools = tools
        summaryQuotas = quotas
        renderSummary()
        reloadSummaryHistory()
      }
    }
    private func reloadSummaryHistory() {
      summaryReloadTask?.cancel()
      let names = Set(
        summaryTools.filter { $0.measurementUnit == .tokens && $0.measurementScope == .today }.map(
          \.name))
      let day = DateHelper.todayKey()
      summaryReloadTask = Task { [weak self] in
        let result = await Task.detached(priority: .utility) {
          let previous = StatusSummaryComparisonData.previousDay(day) ?? ""
          let today = HourlyHistoryStore.shared.query(day: day)
          let yesterday = HourlyHistoryStore.shared.query(day: previous)
          return (
            StatusSummaryHourlyData.build(today, day: day, tools: names),
            StatusSummaryHourlyData.build(yesterday, day: previous, tools: names),
            StatusSummaryComparisonData.build(
              day: day, today: today, yesterday: yesterday,
              daily: HistoryStore.shared.query(from: previous, through: previous))
          )
        }.value
        guard !Task.isCancelled, let self else { return }
        self.summaryHourly = result.0
        self.summaryPrevious = result.1
        self.comparison = result.2
        self.renderSummary()
      }
    }
    private func renderSummary() {
      guard let box = boxes["summary"] else { return }
      clear(box)
      let includes = UserDefaults.standard.bool(for: .usageIncludesCacheRead)
      let snapshot = StatusSummarySnapshot(tools: summaryTools, includesCache: includes)
      let header = stack(box, horizontal: true)
      let totals = stack(header, card: true)
      let notebook = stack(header, card: true)
      gtk_box_set_child_packing(tc_gtk_box(header), totals, 1, 1, 0, GTK_PACK_START)
      gtk_box_set_child_packing(tc_gtk_box(header), notebook, 1, 1, 0, GTK_PACK_START)
      label(L10n.shared.tr("clock.todayTokens"), totals, muted: true)
      let count = label(TokenFormat.compact(snapshot.totalTokens), totals, heading: true)
      tc_gtk_add_class(count, "tc-summary-total")
      label(
        String(snapshot.totalMessages) + " " + toolboxText("条消息", "messages"), totals, muted: true)
      var cost = CostEstimate.unavailable
      for tool in snapshot.rankedTools { cost.merge(tool.todayCost) }
      label(CostFormat.estimate(cost), totals)
      label(toolboxText("行事本", "Notebook"), notebook, heading: true)
      for item in content.notebook.pendingSummaryEntries.prefix(3) {
        button(
          item.title.isEmpty ? toolboxText("未命名记录", "Untitled entry") : item.title,
          "notebook:select:" + item.id.uuidString, notebook)
      }
      button(toolboxText("打开行事本", "Open notebook"), "open:notebook", notebook)
      let chart = stack(box, card: true)
      button(
        fullDay
          ? toolboxText("24 小时 · 收起为近 6 小时", "24 hours · Collapse to last 6h")
          : toolboxText("近 6 小时 · 展开 24 小时", "Last 6 hours · Expand to 24h"), "summary:hours", chart
      )
      let hours = summaryHourly.chartHours(
        expanded: fullDay, currentHour: Calendar.current.component(.hour, from: Date()),
        previous: summaryPrevious)
      let drawing = gtk_drawing_area_new()!
      gtk_widget_set_size_request(drawing, -1, 95)
      let values = LinuxSummaryDrawing(
        hours: hours.map { ($0.usage.hour, $0.usage.displayedTokens(includingCache: includes)) })
      tc_gtk_store_data(
        drawing, "tc-summary-draw", Unmanaged.passRetained(values).toOpaque(),
        linuxSummaryDrawingReleased)
      _ = tc_gtk_on_draw(
        drawing, linuxSummaryChartDraw, Unmanaged.passUnretained(values).toOpaque())
      gtk_box_pack_start(tc_gtk_box(chart), drawing, 0, 0, 0)
      let comparisonValue = comparison.compare(to: snapshot.rankedTools, includesCache: includes)
      let change =
        comparisonValue.tokenDelta?.percent.map { String(format: "%+.1f%%", $0) }
        ?? toolboxText("同期记录不足", "Not enough comparable history")
      label(
        toolboxText("较昨日同期：", "Versus yesterday at this time: ") + change
          + (comparisonValue.isPartial ? toolboxText(" · 可比记录", " · comparable records") : ""),
        chart, muted: true)
      label(
        toolboxText("缓存读取占比：", "Cache-read share: ")
          + (snapshot.cacheShare.map { String(format: "%.0f%%", $0 * 100) } ?? "—"), chart,
        muted: true)
      let contentRow = stack(box, horizontal: true)
      let quotas = stack(contentRow, card: true)
      let usage = stack(contentRow, card: true)
      gtk_widget_set_size_request(quotas, 190, -1)
      gtk_box_set_child_packing(tc_gtk_box(contentRow), usage, 1, 1, 0, GTK_PACK_START)
      label(toolboxText("订阅额度", "Subscription Quota"), quotas, heading: true)
      if summaryQuotas.isEmpty {
        label(
          toolboxText(
            "尚未取得可用额度；可打开订阅额度重试。", "No quota is available yet. Open Subscription Quota to retry."),
          quotas, muted: true)
      }
      let grid = gtk_grid_new()!
      gtk_grid_set_column_spacing(tc_gtk_grid(grid), 10)
      gtk_grid_set_row_spacing(tc_gtk_grid(grid), 12)
      gtk_box_pack_start(tc_gtk_box(quotas), grid, 0, 0, 0)
      for (index, quota) in summaryQuotas.enumerated() {
        let cell = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)!
        let area = gtk_drawing_area_new()!
        let ringSize =
          summaryQuotas.count == 1
          ? 82 : summaryQuotas.count <= 2 ? 72 : summaryQuotas.count <= 4 ? 60 : 52
        gtk_widget_set_size_request(area, gint(ringSize), gint(ringSize))
        let ring = LinuxSummaryDrawing(indicator: quota.indicator)
        tc_gtk_store_data(
          area, "tc-summary-draw", Unmanaged.passRetained(ring).toOpaque(),
          linuxSummaryDrawingReleased)
        _ = tc_gtk_on_draw(area, linuxSummaryRingDraw, Unmanaged.passUnretained(ring).toOpaque())
        gtk_box_pack_start(tc_gtk_box(cell), area, 0, 0, 0)
        label(quota.displayName, cell)
        if let name = quota.accountName { label(name, cell, muted: true) }
        for reset in quota.resets {
          label(
            L10n.shared.tr(reset.labelKey) + " · " + resetDate(reset.resetsAt), cell, muted: true)
        }
        gtk_grid_attach(tc_gtk_grid(grid), cell, gint(index % 2), gint(index / 2), 1, 1)
      }
      let tabs = stack(usage, horizontal: true)
      button(toolboxText("工具", "Harnesses"), "summary:harnesses", tabs)
      button(toolboxText("模型", "Models"), "summary:models", tabs)
      let columns = stack(usage, horizontal: true, spacing: 5)
      let nameColumn = label(toolboxText("名称", "Name"), columns, muted: true)
      gtk_box_set_child_packing(tc_gtk_box(columns), nameColumn, 1, 1, 0, GTK_PACK_START)
      label(toolboxText("用量", "Tokens"), columns, muted: true)
      label("API eq.", columns, muted: true)
      label("t/s", columns, muted: true)
      if summaryModels {
        for group in UsageAggregator.groupedByModel(
          snapshot.rankedTools, unknownLabel: L10n.shared.tr("detail.unknownModel")
        ).prefix(12) {
          summaryUsageRow(
            name: group.name,
            tokens: group.totalTokens + (includes ? group.totalCacheReadTokens : 0),
            cost: group.totalCost, speed: group.generationSpeed, to: usage)
        }
      } else {
        for tool in snapshot.rankedTools.prefix(12) {
          summaryUsageRow(
            name: tool.name, tokens: snapshot.tokens(for: tool), cost: tool.todayCost,
            speed: GenerationSpeedStore.shared.summary(provider: tool.name), to: usage)
        }
      }
      button(toolboxText("额度时间线", "Quota timeline"), "summary:timeline", box)
      if summaryTimeline {
        for event in StatusSummaryTimeline.events(
          quotas: summaryQuotas, records: SubscriptionAccountStore.shared.records(),
          activeIDs: summaryActiveIDs)
        {
          label(
            event.name + " · " + L10n.shared.tr(event.titleKey) + " · " + resetDate(event.date),
            box, muted: true)
        }
      }
      let tools = stack(box, card: true)
      label(toolboxText("工具箱", "Toolboxes"), tools, heading: true)
      button(toolboxText("编辑按钮", "Edit shortcuts"), "summary:edit", tools)
      for row in stride(from: 0, to: QuickToolPreferences.shared.order.count, by: 4) {
        let h = stack(tools, horizontal: true)
        for tool in QuickToolPreferences.shared.order[
          row..<min(row + 4, QuickToolPreferences.shared.order.count)]
        { button(tool.title, "open:" + tool.rawValue, h, hint: tool.hint) }
      }
      button(toolboxText("Ailyre速递 ↗", "Ailyre AI digest ↗"), "news:website", tools)
      gtk_widget_show_all(box)
    }
    private func summaryUsageRow(
      name: String, tokens: Int, cost: CostEstimate, speed: GenerationSpeed,
      to parent: UnsafeMutablePointer<GtkWidget>
    ) {
      let row = stack(parent, horizontal: true, spacing: 5)
      let title = label(name, row, muted: true)
      gtk_label_set_ellipsize(tc_gtk_label(title), PANGO_ELLIPSIZE_END)
      gtk_widget_set_size_request(title, 85, -1)
      gtk_box_set_child_packing(tc_gtk_box(row), title, 1, 1, 0, GTK_PACK_START)
      let amount = label(TokenFormat.compact(tokens), row, muted: true)
      gtk_widget_set_size_request(amount, 42, -1)
      gtk_label_set_xalign(tc_gtk_label(amount), 1)
      let price = label(CostFormat.estimate(cost), row, muted: true)
      gtk_widget_set_size_request(price, 46, -1)
      gtk_label_set_xalign(tc_gtk_label(price), 1)
      let rate = label(speed.formatted, row, muted: true)
      gtk_widget_set_size_request(rate, 32, -1)
      gtk_label_set_xalign(tc_gtk_label(rate), 1)
      gtk_widget_set_tooltip_text(rate, speed.helpText)
    }
    func tick() {
      if windows["local"] != nil {
        let signature =
          String(local.busy) + local.status + String(local.findings.count)
          + String(local.files.count)
          + String(local.keys.count) + String(describing: local.checkedAt)
        if signature != lastLocalSignature {
          lastLocalSignature = signature
          if visible("local") { renderLocal() }
        }
      }
      let m = String(mainland.running) + String(describing: mainland.report) + mainland.inputError
      if m != lastMainlandSignature {
        lastMainlandSignature = m
        if visible("network") { renderNetwork() }
      }
    }
    private func openURL(_ url: URL) {
      gtk_show_uri_on_window(tc_gtk_window(parent), url.absoluteString, 0, nil)
    }
    fileprivate func changed(_ widget: UnsafeMutablePointer<GtkWidget>) {
      guard !rebuilding else { return }
      let name = String(cString: tc_gtk_widget_name(widget))
      let value = String(cString: gtk_entry_get_text(tc_gtk_entry(widget)))
      switch name {
      case "notebook:title":
        if let id = content.notebook.selectedID {
          content.notebook.update(id, title: value)
          if let row = notebookSelectedRow {
            gtk_button_set_label(
              tc_gtk_button(row), value.isEmpty ? toolboxText("未命名记录", "Untitled entry") : value)
          }
        }
      case "local:pattern": secretPattern = value
      case "network:mainland-ip": mainland.targetIP = value
      case "network:mainland-port": mainland.targetPort = value
      default: break
      }
    }
    fileprivate func bodyChanged() {
      guard !rebuilding, let view = notebookBody, let id = content.notebook.selectedID,
        let buffer = gtk_text_view_get_buffer(tc_gtk_text_view(view))
      else { return }
      var start = GtkTextIter()
      var end = GtkTextIter()
      gtk_text_buffer_get_bounds(buffer, &start, &end)
      if let raw = gtk_text_buffer_get_text(buffer, &start, &end, 1) {
        let text = String(cString: raw)
        g_free(raw)
        content.notebook.update(id, body: text)
      }
    }
    fileprivate func handle(_ widget: UnsafeMutablePointer<GtkWidget>) {
      let name = String(cString: tc_gtk_widget_name(widget))
      let parts = name.split(separator: ":", maxSplits: 2).map(String.init)
      if parts.first == "open", parts.count > 1, let tool = QuickTool(rawValue: parts[1]) {
        open(tool)
        return
      }
      if parts.first == "quick", parts.count == 3, let tool = QuickTool(rawValue: parts[2]) {
        if parts[1] == "toggle" {
          QuickToolPreferences.shared.toggle(tool)
        } else {
          QuickToolPreferences.shared.move(tool, by: parts[1] == "up" ? -1 : 1)
        }
        onQuickActionsChange?()
        showQuickEditor()
        return
      }
      if parts.first == "preferences", parts.count == 2 {
        if parts[1] == "enabled" {
          content.preferences.setEnabled(!content.preferences.configuration.enabled)
        } else if let category = NotificationCategory(rawValue: parts[1]) {
          content.preferences.set(
            category, enabled: !content.preferences.configuration.categories.contains(category))
        }
        showNotificationSettings()
        return
      }
      if parts.first == "notebook", parts.count == 3, let id = UUID(uuidString: parts[2]) {
        if parts[1] == "select" {
          showNotebook(selected: id)
        } else if let entry = content.notebook.entries.first(where: { $0.id == id }) {
          content.notebook.setCompleted(id, !entry.completed)
          renderNotebook()
        }
        return
      }
      switch name {
      case "notebook:add":
        content.notebook.add()
        renderNotebook()
      case "notebook:completed":
        notebookShowCompleted.toggle()
        renderNotebook()
      case "notebook:clear":
        if let id = content.notebook.selectedID {
          content.notebook.setReminder(id, nil)
          renderNotebook()
        }
      case "notebook:delete":
        if let id = content.notebook.selectedID,
          tc_gtk_confirm(
            tc_gtk_window(parent), toolboxText("删除记录？", "Delete entry?"),
            toolboxText("只删除所选行事本记录。", "Only the selected notebook entry will be deleted.")) != 0
        {
          content.notebook.delete(id)
          renderNotebook()
        }
      case "notebook:reminder":
        if let id = content.notebook.selectedID,
          let raw = tc_gtk_prompt_text(
            tc_gtk_window(parent), toolboxText("提醒时间", "Reminder time"), "YYYY-MM-DD HH:mm", "")
        {
          let value = String(cString: raw)
          g_free(raw)
          let f = DateFormatter()
          f.locale = Locale(identifier: "en_US_POSIX")
          f.dateFormat = "yyyy-MM-dd HH:mm"
          f.isLenient = false
          if let date = f.date(from: value), f.string(from: date) == value {
            content.notebook.setReminder(id, date)
            renderNotebook()
          }
        }
      case "local:run", "local:full":
        local.run(local.selectedMode, pattern: secretPattern, full: name == "local:full")
        renderLocal()
      case "local:stop":
        local.stop()
        renderLocal()
      case "update:open": if let updateURL { openURL(updateURL) }
      case "network:run": runNetwork()
      case "network:stop":
        networkTask?.cancel()
        networkFetcher?.cancel()
        networkRunning = false
        mainland.stop()
        renderNetwork()
      case "network:browser":
        openURL(
          URL(
            string: "https://www.ailyre.com/tokenclock/network-check/?lang="
              + L10n.shared.language.rawValue + "#run")!)
      case "network:mainland":
        mainland.start()
        renderNetwork()
      case "news:website": openURL(URL(string: "https://www.ailyre.com/news/")!)
      case "news:refresh":
        content.news.refreshIfDue(language: L10n.shared.language.rawValue, force: true)
      case "news:back": onNewsBack?()
      case "summary:edit": showQuickEditor()
      case "summary:hours":
        fullDay.toggle()
        renderSummary()
      case "summary:harnesses":
        summaryModels = false
        renderSummary()
      case "summary:models":
        summaryModels = true
        renderSummary()
      case "summary:timeline":
        summaryTimeline.toggle()
        renderSummary()
      default:
        if name.hasPrefix("local:mode:") {
          local.selectMode(String(name.dropFirst("local:mode:".count)))
          renderLocal()
        }
        if name.hasPrefix("news:item:"),
          let item = content.news.items.first(where: {
            $0.id == String(name.dropFirst("news:item:".count))
          })
        {
          content.news.markRead(ids: [item.id])
          openURL(item.url)
        }
        if name.hasPrefix("local:trash:"), let index = Int(name.dropFirst("local:trash:".count)),
          local.files.indices.contains(index),
          tc_gtk_confirm(
            tc_gtk_window(parent), toolboxText("移入回收站？", "Move to Trash?"), local.files[index].path)
            != 0
        {
          do {
            try LocalLogScanner.recycle(local.files[index])
            local.run("disk")
          } catch {
            let box = window(
              "error", title: toolboxText("无法清理", "Cleanup unavailable"), width: 460, height: 240)
            clear(box)
            label(error.localizedDescription, box)
            show("error")
          }
        }
      }
    }
  }

  private let linuxToolboxClicked:
    @convention(c) (UnsafeMutablePointer<GtkWidget>?, gpointer?) -> Void = { widget, data in
      guard let widget, let data else { return }
      let owner = Unmanaged<LinuxToolboxes>.fromOpaque(data).takeUnretainedValue()
      let address = UInt(bitPattern: widget)
      MainActor.assumeIsolated {
        owner.handle(UnsafeMutablePointer<GtkWidget>(bitPattern: address)!)
      }
    }
  private let linuxToolboxChanged:
    @convention(c) (UnsafeMutablePointer<GtkWidget>?, gpointer?) -> Void = { widget, data in
      guard let widget, let data else { return }
      let owner = Unmanaged<LinuxToolboxes>.fromOpaque(data).takeUnretainedValue()
      let address = UInt(bitPattern: widget)
      MainActor.assumeIsolated {
        owner.changed(UnsafeMutablePointer<GtkWidget>(bitPattern: address)!)
      }
    }
  private let linuxNotebookBodyChanged:
    @convention(c) (UnsafeMutablePointer<GtkTextBuffer>?, gpointer?) -> Void = { _, data in
      guard let data else { return }
      let owner = Unmanaged<LinuxToolboxes>.fromOpaque(data).takeUnretainedValue()
      MainActor.assumeIsolated { owner.bodyChanged() }
    }

  private final class LinuxSummaryDrawing {
    var hours: [(Int, Int)] = []
    var indicator: DialQuotaIndicator?
    init(hours: [(Int, Int)]) { self.hours = hours }
    init(indicator: DialQuotaIndicator) { self.indicator = indicator }
  }
  private let linuxSummaryDrawingReleased: @convention(c) (gpointer?) -> Void = { data in
    if let data { Unmanaged<LinuxSummaryDrawing>.fromOpaque(data).release() }
  }
  private let linuxSummaryChartDraw:
    @convention(c) (UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?) -> gboolean = {
      widget, cr, data in
      guard let widget, let cr, let data else { return 0 }
      let state = Unmanaged<LinuxSummaryDrawing>.fromOpaque(data).takeUnretainedValue()
      let width = Double(gtk_widget_get_allocated_width(widget))
      let height = Double(gtk_widget_get_allocated_height(widget))
      let maximum = Double(state.hours.map(\.1).max() ?? 1)
      let step = width / Double(max(1, state.hours.count))
      for (index, hour) in state.hours.enumerated() {
        let h = Double(hour.1) / max(1, maximum) * (height - 22)
        cairo_set_source_rgba(cr, 0.14, 0.65, 0.75, 0.8)
        cairo_rectangle(cr, Double(index) * step + 2, height - 18 - h, max(2, step - 4), h)
        cairo_fill(cr)
        cairo_set_source_rgba(cr, 0.45, 0.45, 0.45, 1)
        cairo_move_to(cr, Double(index) * step + 2, height - 3)
        cairo_set_font_size(cr, 9)
        String(format: "%02d", hour.0).withCString { cairo_show_text(cr, $0) }
      }
      return 0
    }
  private let linuxSummaryRingDraw:
    @convention(c) (UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?) -> gboolean = {
      widget, cr, data in
      guard let widget, let cr, let data,
        let indicator = Unmanaged<LinuxSummaryDrawing>.fromOpaque(data).takeUnretainedValue()
          .indicator
      else { return 0 }
      let side = Double(
        min(gtk_widget_get_allocated_width(widget), gtk_widget_get_allocated_height(widget)))
      let center = side / 2
      let colors: [(Double, Double, Double)] = [
        (0.26, 0.62, 0.57), (0.56, 0.42, 0.82), (0.88, 0.56, 0.23),
      ]
      let values =
        [indicator.outerRemainingPercent]
        + [indicator.innerRemainingPercent, indicator.thirdRemainingPercent].compactMap { $0 }
      for (index, value) in values.enumerated() {
        let radius = center - 5 - Double(index) * 6
        let defaults: [SubscriptionProvider: (Double, Double, Double)] = [
          .codex: (0.06, 0.64, 0.50), .claude: (0.85, 0.40, 0.28), .antigravity: (0.55, 0.36, 0.96),
          .cursor: (0.10, 0.62, 0.92), .grokBot: (0.39, 0.40, 0.95), .zhipu: (0.35, 0.35, 0.35),
        ]
        let color = index == 0 ? (defaults[indicator.provider] ?? colors[0]) : colors[index]
        cairo_set_line_width(cr, index == 0 ? 4 : 2)
        cairo_set_source_rgba(cr, color.0, color.1, color.2, 0.15)
        cairo_arc(cr, center, center, radius, 0, 2 * Double.pi)
        cairo_stroke(cr)
        cairo_set_source_rgba(cr, color.0, color.1, color.2, 0.85)
        cairo_arc(
          cr, center, center, radius, -Double.pi / 2, -Double.pi / 2 + 2 * Double.pi * value / 100)
        cairo_stroke(cr)
      }
      let label = QuotaCenterLabel(remaining: indicator.outerRemainingPercent)
      var foreground = GdkRGBA()
      gtk_style_context_get_color(
        gtk_widget_get_style_context(widget), GTK_STATE_FLAG_NORMAL, &foreground)
      cairo_set_source_rgba(cr, foreground.red, foreground.green, foreground.blue, foreground.alpha)
      cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
      cairo_set_font_size(cr, 11)
      var number = cairo_text_extents_t()
      label.text.withCString { cairo_text_extents(cr, $0, &number) }
      var percent = cairo_text_extents_t()
      if label.showsPercent {
        cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
        cairo_set_font_size(cr, 8)
        "%".withCString { cairo_text_extents(cr, $0, &percent) }
      }
      let start = center - (number.x_advance + percent.x_advance) / 2
      cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
      cairo_set_font_size(cr, 11)
      cairo_move_to(cr, start, center + 4)
      label.text.withCString { cairo_show_text(cr, $0) }
      if label.showsPercent {
        cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
        cairo_set_font_size(cr, 8)
        cairo_move_to(cr, start + number.x_advance, center + 4)
        "%".withCString { cairo_show_text(cr, $0) }
      }
      return 0
    }
#endif

#if os(Linux)
  import XCTest
  import Foundation
  import CGtk
  @testable import TokenClock

  @MainActor final class LinuxToolboxInteractionTests: XCTestCase {
    private func fixture() throws -> (
      LinuxToolboxes, UserContentCenter, UnsafeMutablePointer<GtkWidget>, URL, String
    ) {
      guard gtk_init_check(nil, nil) != 0 else {
        throw XCTSkip("Run with Xvfb or a desktop session")
      }
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let suite = "TokenClock.NativeGTK." + UUID().uuidString
      let defaults = UserDefaults(suiteName: suite)!
      let content = UserContentCenter(
        defaults: defaults, notebookURL: directory.appendingPathComponent("notebook.json"))
      let parent = try XCTUnwrap(gtk_window_new(GTK_WINDOW_TOPLEVEL))
      return (
        LinuxToolboxes(parent: parent, content: content, navigate: { _ in }), content, parent,
        directory, suite
      )
    }
    private func click(_ name: String) throws {
      let widget = try XCTUnwrap(tc_gtk_find_window(name), name)
      gtk_button_clicked(tc_gtk_button(widget))
    }
    func testNotebookSignalsEditAndPersistTheSelectedEntry() async throws {
      let (tools, content, parent, folder, suite) = try fixture()
      defer {
        tools.stop()
        gtk_widget_destroy(parent)
        try? FileManager.default.removeItem(at: folder)
        UserDefaults.standard.removePersistentDomain(forName: suite)
      }
      tools.showNotebook()
      try click("notebook:add")
      let entry = try XCTUnwrap(content.notebook.entries.first)
      let title = try XCTUnwrap(tc_gtk_find_window("notebook:title"))
      gtk_entry_set_text(tc_gtk_entry(title), "Native 中文 reminder")
      let body = try XCTUnwrap(tc_gtk_find_window("notebook:body"))
      let buffer = try XCTUnwrap(gtk_text_view_get_buffer(tc_gtk_text_view(body)))
      gtk_text_buffer_set_text(buffer, "Line one\n第二行", -1)
      content.notebook.flush()
      let saved = try JSONDecoder().decode(
        [NotebookEntry].self, from: Data(contentsOf: folder.appendingPathComponent("notebook.json"))
      )
      XCTAssertEqual(saved.first?.id, entry.id)
      XCTAssertEqual(saved.first?.title, "Native 中文 reminder")
      XCTAssertEqual(saved.first?.body, "Line one\n第二行")
    }
    func testOpeningToolsDoesNotStartAProbeAndEmptySummaryIsSafe() async throws {
      let (tools, _, parent, folder, suite) = try fixture()
      defer {
        tools.stop()
        gtk_widget_destroy(parent)
        try? FileManager.default.removeItem(at: folder)
        UserDefaults.standard.removePersistentDomain(forName: suite)
      }
      tools.local = LocalToolboxModel(directory: folder)
      tools.showLocal()
      XCTAssertFalse(tools.local.busy)
      tools.showNetwork()
      XCTAssertNotNil(tc_gtk_find_window("network:run"))
      XCTAssertFalse(tools.mainland.running)
      tools.showSummary(tools: [], quotas: [])
      try click("summary:hours")
      try click("summary:models")
      try click("summary:timeline")
      XCTAssertNotNil(tc_gtk_find_window("toolbox:summary"))
    }
    func testNativeQuickActionButtonsPersistVisibilityAndOrder() async throws {
      let (tools, _, parent, folder, suite) = try fixture()
      let preferences = QuickToolPreferences.shared
      let original = preferences.order
      defer {
        preferences.order = original
        tools.stop()
        gtk_widget_destroy(parent)
        try? FileManager.default.removeItem(at: folder)
        UserDefaults.standard.removePersistentDomain(forName: suite)
      }
      preferences.order = [.model, .network, .quota, .history]
      tools.showQuickEditor()
      try click("quick:down:model")
      XCTAssertEqual(preferences.order.first, .network)
      try click("quick:toggle:quota")
      XCTAssertFalse(preferences.order.contains(.quota))
      XCTAssertEqual(
        UserDefaults.standard.stringArray(forKey: "toolbox.quickOrder"),
        preferences.order.map(\.rawValue))
    }
  }
#endif

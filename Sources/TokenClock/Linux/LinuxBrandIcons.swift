import Foundation
import CGtk

enum LinuxBrandIcons {
    static func label(_ value: String, size: Int32 = 16) -> UnsafeMutablePointer<GtkWidget>? {
        if let parts = BrandIconCatalog.labelParts(value), let url = BrandIconCatalog.url(forKey: parts.key) {
            return tc_gtk_brand_label(url.path, parts.prefix, parts.text, size)
        }
        let label = gtk_label_new(value)
        gtk_label_set_xalign(tc_gtk_label(label), 0)
        gtk_label_set_ellipsize(tc_gtk_label(label), PANGO_ELLIPSIZE_END)
        return label
    }

    @discardableResult
    static func draw(_ context: OpaquePointer, name: String, x: Double, y: Double, size: Double) -> Bool {
        guard let key = BrandIconCatalog.key(for: name), let url = BrandIconCatalog.url(forKey: key) else { return false }
        tc_cairo_draw_brand_icon(context, url.path, x, y, size)
        return true
    }
}

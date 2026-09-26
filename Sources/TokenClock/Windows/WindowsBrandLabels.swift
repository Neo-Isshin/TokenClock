import Foundation
import Win32Shim

func brand_add_static(_ d: UnsafeMutableRawPointer?, _ text: String, _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32) {
    dlg_add_static(d, BrandIconCatalog.nativeLabel(text), x, y, w, h)
}
func brand_add_static_id(_ d: UnsafeMutableRawPointer?, _ id: Int32, _ text: String, _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32) -> UnsafeMutableRawPointer? {
    dlg_add_static_id(d, id, BrandIconCatalog.nativeLabel(text), x, y, w, h)
}
func brand_add_title(_ d: UnsafeMutableRawPointer?, _ text: String, _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32) {
    dlg_add_title(d, BrandIconCatalog.nativeLabel(text), x, y, w, h)
}
func brand_add_subtitle(_ d: UnsafeMutableRawPointer?, _ text: String, _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32) {
    dlg_add_subtitle(d, BrandIconCatalog.nativeLabel(text), x, y, w, h)
}
func brand_add_section(_ d: UnsafeMutableRawPointer?, _ text: String, _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32) {
    dlg_add_section(d, BrandIconCatalog.nativeLabel(text), x, y, w, h)
}
func brand_add_check(_ d: UnsafeMutableRawPointer?, _ id: Int32, _ text: String, _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32, _ checked: Int32) {
    dlg_add_check(d, id, BrandIconCatalog.nativeLabel(text), x, y, w, h, checked)
}

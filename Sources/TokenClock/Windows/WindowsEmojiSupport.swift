#if os(Windows)
import Win32Shim

enum WindowsEmojiSupport {
    static func hasColorIcon(for text: String) -> Bool {
        text.withCString { win_color_icon_supported_utf8($0) != 0 }
    }
}
#endif

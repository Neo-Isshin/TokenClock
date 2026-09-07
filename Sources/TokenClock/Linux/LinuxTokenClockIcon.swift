import Foundation
import CGtk

private final class LinuxTokenClockIconContext {
    let icon: TokenClockIcon
    init(_ icon: TokenClockIcon) { self.icon = icon }
}

enum LinuxTokenClockIconRenderer {
    static func widget(
        displayName: String,
        fallbackEmoji: String,
        size: gint
    ) -> UnsafeMutablePointer<GtkWidget>? {
        guard let icon = TokenClockIcon.resolve(displayName: displayName) else {
            return gtk_label_new(fallbackEmoji)
        }
        guard let area = gtk_drawing_area_new() else { return nil }
        gtk_widget_set_size_request(area, size, size)
        let data = Unmanaged.passRetained(LinuxTokenClockIconContext(icon)).toOpaque()
        _ = tc_gtk_on_draw(area, linuxTokenClockIconDraw, data)
        _ = tc_gtk_on_destroy(area, linuxTokenClockIconDestroy, data)
        return area
    }

    static func draw(
        _ icon: TokenClockIcon,
        context: OpaquePointer,
        centerX: Double,
        centerY: Double,
        size: Double,
        color: GdkRGBA
    ) {
        let unit = size / 24
        cairo_save(context)
        cairo_translate(context, centerX, centerY)
        cairo_scale(context, unit, unit)
        cairo_set_source_rgba(context, color.red, color.green, color.blue, color.alpha)
        cairo_set_line_cap(context, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(context, CAIRO_LINE_JOIN_ROUND)

        func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, width: Double = 1.6, alpha: Double = 1) {
            cairo_save(context)
            cairo_set_source_rgba(context, color.red, color.green, color.blue, color.alpha * alpha)
            cairo_set_line_width(context, width)
            cairo_move_to(context, x1, y1); cairo_line_to(context, x2, y2); cairo_stroke(context)
            cairo_restore(context)
        }
        func polygon(_ points: [(Double, Double)], fill: Bool = false) {
            guard let first = points.first else { return }
            cairo_move_to(context, first.0, first.1)
            for point in points.dropFirst() { cairo_line_to(context, point.0, point.1) }
            cairo_close_path(context)
            if fill { cairo_fill(context) } else { cairo_set_line_width(context, 1.55); cairo_stroke(context) }
        }
        func ellipse(_ x: Double, _ y: Double, _ rx: Double, _ ry: Double, fill: Bool = false, width: Double = 1.4, alpha: Double = 1) {
            cairo_save(context)
            cairo_set_source_rgba(context, color.red, color.green, color.blue, color.alpha * alpha)
            cairo_translate(context, x, y); cairo_scale(context, rx, ry); cairo_arc(context, 0, 0, 1, 0, .pi * 2)
            if fill { cairo_fill(context) } else { cairo_set_line_width(context, width / max(rx, ry)); cairo_stroke(context) }
            cairo_restore(context)
        }
        func qwen(prompt: Bool) {
            let base = [(0.0,-9.55),(6.45,-5.85),(4.65,-2.8),(0.0,-5.48),(-2.65,-3.95),(-4.42,-7.02)]
            for turn in 0..<3 {
                let a = Double(turn) * 2 * .pi / 3
                polygon(base.map { ($0.0 * cos(a) - $0.1 * sin(a), $0.0 * sin(a) + $0.1 * cos(a)) }, fill: true)
            }
            if prompt {
                line(-2.85,-2.2,-0.65,-0.1,width:1.35); line(-0.65,-0.1,-2.85,2,width:1.35); line(0.25,2,2.95,2,width:1.35)
            }
        }
        func blackHole(offsetX: Double = 0, offsetY: Double = 0, scale: Double = 1) {
            cairo_save(context)
            cairo_translate(context, offsetX, offsetY); cairo_scale(context, scale, scale); cairo_rotate(context, -9 * .pi / 180)
            cairo_set_line_width(context, 1.35)
            cairo_set_source_rgba(context, color.red, color.green, color.blue, color.alpha * 0.72)
            cairo_move_to(context,-8,-1.1); cairo_curve_to(context,-7,-9,7,-9,8,-1.1); cairo_stroke(context)
            cairo_set_source_rgba(context, color.red, color.green, color.blue, color.alpha * 0.45)
            cairo_move_to(context,-8,1.1); cairo_curve_to(context,-7,9,7,9,8,1.1); cairo_stroke(context)
            cairo_set_source_rgba(context, color.red, color.green, color.blue, color.alpha)
            cairo_set_line_width(context,1.75); cairo_move_to(context,-10,-0.8); cairo_curve_to(context,-5,-2.35,5,-2.35,10,-0.8); cairo_stroke(context)
            cairo_set_source_rgba(context, color.red, color.green, color.blue, color.alpha * 0.58)
            cairo_set_line_width(context,1.2); cairo_move_to(context,-10,1.1); cairo_curve_to(context,-5,2.7,5,2.7,10,1.1); cairo_stroke(context)
            cairo_set_source_rgba(context, color.red, color.green, color.blue, color.alpha)
            cairo_arc(context,0,0,4.2,0,.pi*2); cairo_fill(context)
            cairo_restore(context)
        }

        switch icon {
        case .toolCodex:
            polygon([(-4,-8),(4,-8),(8,-4),(8,4),(4,8),(-4,8),(-8,4),(-8,-4)])
            line(-3.4,-3.2,0,0,width:1.7); line(0,0,-3.4,3.2,width:1.7); line(0.9,3.2,4.5,3.2,width:1.7)
        case .toolCursorAgent:
            polygon([(0,-9),(8,-4.5),(8,4.5),(0,9),(-8,4.5),(-8,-4.5)])
            polygon([(-4.65,-3.6),(4.65,-3.6),(0,4.25)])
            line(0,-9,-4.65,-3.6); line(0,-9,4.65,-3.6); line(-8,-4.5,-4.65,-3.6); line(8,-4.5,4.65,-3.6)
            line(-8,4.5,0,4.25); line(8,4.5,0,4.25); line(0,9,0,4.25)
        case .toolAntigravity:
            cairo_set_line_width(context,4.2); cairo_move_to(context,-8,7); cairo_curve_to(context,-6.2,-7,6.2,-7,8,7); cairo_stroke(context)
            line(-5.5,9,5.5,9,width:1.5,alpha:0.2)
        case .toolQwenCode: qwen(prompt: true)
        case .modelQwen: qwen(prompt: false)
        case .toolGrokCLI:
            blackHole(offsetX:1.5,offsetY:-1.5,scale:0.78)
            line(-9.3,4.7,-6.95,6.85); line(-6.95,6.85,-9.3,9); line(-5.9,9,-2.5,9)
        case .toolGrokBot:
            blackHole(offsetX:1.5,offsetY:-1.5,scale:0.78)
            polygon([(-10,4),(-2,4),(-2,9),(-7.5,9),(-9.5,11),(-9.5,9),(-10,9)])
        case .modelGrok: blackHole()
        case .toolCline:
            cairo_set_line_width(context,1.65); cairo_arc(context,0,0,8,.pi/4,.pi/4 + 3 * .pi / 2); cairo_stroke(context)
            line(2.6,-3.6,6.2,0); line(6.2,0,2.6,3.6); line(-4,-3.5,-0.9,-3.5,width:1.4); line(-4,0,0.2,0,width:1.4); line(-4,3.5,-0.9,3.5,width:1.4)
        case .modelOpenAIChatGPT:
            for turn in 0..<6 {
                cairo_save(context); cairo_rotate(context, Double(turn) * Double.pi / 3); ellipse(0,-3.5,3.5,4.5,width:1.45); cairo_restore(context)
            }
            polygon([(0,-3.9),(3.4,-2),(3.4,2),(0,3.9),(-3.4,2),(-3.4,-2)])
        case .modelMiniMax:
            let points=[(-9.0,0.0),(-6.6,0.0),(-4.9,-5.2),(-1.85,5.2),(1.0,-3.1),(3.35,3.1),(5.1,0.0),(9.0,0.0)]
            cairo_set_line_width(context,1.65); cairo_move_to(context,points[0].0,points[0].1)
            for point in points.dropFirst() { cairo_line_to(context,point.0,point.1) }; cairo_stroke(context)
        }
        cairo_restore(context)
    }
}

private func linuxTokenClockIconDraw(
    _ widget: UnsafeMutablePointer<GtkWidget>?,
    _ context: OpaquePointer?,
    _ data: gpointer?
) -> gboolean {
    guard let widget, let context, let data else { return 0 }
    let holder = Unmanaged<LinuxTokenClockIconContext>.fromOpaque(data).takeUnretainedValue()
    var color = GdkRGBA()
    gtk_style_context_get_color(gtk_widget_get_style_context(widget), GTK_STATE_FLAG_NORMAL, &color)
    let width = Double(gtk_widget_get_allocated_width(widget))
    let height = Double(gtk_widget_get_allocated_height(widget))
    LinuxTokenClockIconRenderer.draw(
        holder.icon, context: context,
        centerX: width / 2, centerY: height / 2,
        size: min(width, height), color: color
    )
    return 0
}

private func linuxTokenClockIconDestroy(
    _ widget: UnsafeMutablePointer<GtkWidget>?,
    _ data: gpointer?
) {
    guard let data else { return }
    Unmanaged<LinuxTokenClockIconContext>.fromOpaque(data).release()
}

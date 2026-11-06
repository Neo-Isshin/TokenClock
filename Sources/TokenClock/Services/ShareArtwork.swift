#if os(macOS)
import AppKit
import ImageIO

@MainActor enum ShareArtwork {
    static let scenes = ["alpine","lake","forest","valley"]
    private static let cache: NSCache<NSString,NSImage> = { let c=NSCache<NSString,NSImage>();c.countLimit=3;return c }()
    static func image(_ name: String) -> NSImage? {
        if let image=cache.object(forKey:name as NSString){return image}
        let ext=name=="ailyre" ? "png":"jpg"
        guard let root=Bundle.module.resourceURL?.appendingPathComponent("ShareArtwork"),let image=NSImage(contentsOf:root.appendingPathComponent(name+"."+ext)) else{return nil}
        cache.setObject(image,forKey:name as NSString);return image
    }
    static func imported(_ url: URL) -> NSImage? {
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),
              let cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:1800,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else{return nil}
        return NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height))
    }
}
#endif

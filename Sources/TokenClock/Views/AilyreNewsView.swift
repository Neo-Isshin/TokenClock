#if os(macOS)
import SwiftUI
import AppKit

private enum AilyreNewsArtwork {
    @MainActor static let image: NSImage? = Bundle.module.resourceURL
        .flatMap { NSImage(contentsOf: $0.appendingPathComponent("AilyreNews/ai-digest.png")) }
}
struct AilyreNewsMark: View {
    var template = false
    var body: some View {
        if let image = AilyreNewsArtwork.image {
            Image(nsImage: image).resizable().renderingMode(template ? .template : .original).scaledToFit()
                .accessibilityHidden(true)
        } else { Image(systemName: "newspaper").accessibilityHidden(true) }
    }
}

struct AilyreNewsView: View {
    @ObservedObject var news: AilyreNewsService
    var textColor: Color = .primary
    var focusedID: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if news.loading { ProgressView().controlSize(.mini) }
                Text(status).font(.system(size: 9)).foregroundStyle(textColor.opacity(0.6))
                Spacer()
                Link(destination: URL(string: "https://www.ailyre.com/news/")!) {
                    HStack(spacing: 6) {
                        Text(toolboxText("完整内容在 ailyre.com 中", "Full coverage on ailyre.com"))
                            .lineLimit(1).minimumScaleFactor(0.85)
                        Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
                    }.font(.system(size: 10, weight: .medium)).frame(minHeight: 18).padding(.horizontal, 4)
                }
                .foregroundStyle(textColor.opacity(0.85)).buttonStyle(.bordered).controlSize(.small)
                .instantHint(toolboxText("在默认浏览器打开 Ailyre 完整速递", "Open all Ailyre news in your default browser"))

            }.padding(.horizontal, 14).padding(.vertical, 8)
            if !news.errorMessage.isEmpty {
                Text(news.errorMessage).font(.system(size: 10)).foregroundStyle(textColor.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 8)
            }
            if news.items.isEmpty {
                VStack(spacing: 10) {
                    AilyreNewsMark().frame(width: 36, height: 44).opacity(0.75)
                    Text(news.loading ? toolboxText("正在获取 AI速递…", "Loading AI digest…") : toolboxText("暂时没有速递", "No digest yet"))
                        .font(.system(size: 11)).foregroundStyle(textColor.opacity(0.7))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 9) {
                            ForEach(news.items) { item in article(item).id(item.id) }
                        }.padding(.horizontal, 12).padding(.bottom, 12)
                    }
                    .onAppear { if let focusedID { reader.scrollTo(focusedID, anchor: .top) } }
                    .onChange(of: focusedID) { value in if let value { reader.scrollTo(value, anchor: .top) } }
                }
            }
        }.environment(\.locale, Locale(identifier:L10n.shared.language.rawValue)).accessibilityIdentifier("ai-digest-panel")
    }
    private var status: String {
        guard let date = news.cache.refreshedAt else { return toolboxText("每 2 小时检查一次", "Checked every 2 hours") }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: L10n.shared.language.rawValue)
        formatter.dateStyle = .none; formatter.timeStyle = .short
        return toolboxText("最近更新 ", "Updated ") + formatter.string(from: date)
    }
    private func article(_ item: AilyreNewsItem) -> some View {
        Button { NSWorkspace.shared.open(item.url) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 4) {
                    AilyreArticleLogo(url: item.logoURL).frame(width: 16, height: 16)
                    Text((item.track.map { $0.badge + " " } ?? "") + item.title)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(3).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.up.right").font(.system(size: 8)).opacity(0.5).padding(.top, 3)
                }
                Text(item.summary).font(.system(size: 10.5)).lineLimit(6).multilineTextAlignment(.leading).opacity(0.72)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let date = item.publishedAt {
                    Text(date, format: .dateTime.month().day().hour().minute()).font(.system(size: 9)).opacity(0.5)
                }
            }.foregroundStyle(textColor).padding(11)
                .background(textColor.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(textColor.opacity(0.08), lineWidth: 0.5))
        }.buttonStyle(.plain).instantHint(toolboxText("在 Ailyre 查看详情与来源", "Open details and sources on Ailyre"))
    }
}

@MainActor private final class AilyreArticleLogoCache {
    static let shared = AilyreArticleLogoCache()
    private let images = NSCache<NSURL, NSImage>()
    private var requests: [URL: Task<NSImage?, Never>] = [:]
    init() { images.countLimit = 64; images.totalCostLimit = 4 * 1024 * 1024 }
    func image(for url: URL) async -> NSImage? {
        guard AilyreFeedParser.safeLogoURL(url.absoluteString) != nil else { return nil }
        if let image = images.object(forKey: url as NSURL) { return image }
        if let request = requests[url] { return await request.value }
        let request = Task { @MainActor () -> NSImage? in
            let transport = NetworkDiagnosticFetcher(maximumBodyBytes: 128 * 1024, userAgent: "TokenClock/" + AppConfig.version + " AI-Digest")
            let reply = await transport.fetch(url); transport.cancel()
            guard reply.status == 200, !reply.limited else { return nil }
            return NSImage(data: reply.data)
        }
        requests[url] = request
        let image = await request.value
        requests.removeValue(forKey: url)
        if let image { images.setObject(image, forKey: url as NSURL, cost: max(1, Int(image.size.width * image.size.height * 4))) }
        return image
    }
}
private struct AilyreArticleLogo: View {
    let url: URL?
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "building.2").font(.system(size: 11)).opacity(0.45) }
        }.accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url else { return }
            let loaded = await AilyreArticleLogoCache.shared.image(for: url)
            if !Task.isCancelled { image = loaded }
        }
    }
}
#endif

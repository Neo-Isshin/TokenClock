#if os(Linux)
import Foundation
import CSQLite

@main
struct LinuxCatalogAudit {
    static func main() {
        let summary = PathDetector.runFullDetection()
        print("service\tdeclared\tpathExists\tparserReadable\tsource\tpath\tparserInput")
        for provider in LinuxProviderCatalog.Provider.allCases {
            let entry = LinuxProviderCatalog.entry(for: provider)
            guard let result = summary.results.first(where: { $0.service == entry.service }) else { continue }
            print([
                entry.displayName,
                String(result.catalogDeclared),
                String(result.pathExists),
                String(result.parserReadable),
                result.source.rawValue,
                result.detectedPath,
                entry.parserInput,
            ].joined(separator: "\t"))
        }
        fputs(
            "declared=\(summary.declaredCount) paths=\(summary.existingPathCount) readable=\(summary.foundCount) total=\(summary.totalCount)\n",
            stderr
        )
    }
}
#endif

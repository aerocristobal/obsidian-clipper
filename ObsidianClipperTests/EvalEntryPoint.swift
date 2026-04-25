import Foundation
@testable import ClipperExtension

/// Per-branch extraction adapter for the eval harness.
///
/// **Spike A — Readability.js + linkedom in JavaScriptCore.**
///
/// This branch routes through `JSCReadabilityExtractor`, which loads a bundled
/// `readability-bundle.js` (Mozilla's Readability + linkedom) into a shared
/// JSContext and parses each fixture's HTML there. The article HTML returned
/// by Readability is then fed to the existing `HTMLToMarkdown.convert(_:)`
/// string overload to produce the markdown the eval harness scores.
///
/// Falls back to the master Swift `ReadabilityExtractor` if JSC fails (bundle
/// missing, JS exception, or Readability returns null).
enum EvalEntryPoint {

    struct EvalResult {
        let title: String
        let markdown: String
        let imageMarkerCount: Int?
        let approach: String
    }

    static let approachName: String = "readability-jsc"

    static func extract(html: String, baseURL: URL?) -> EvalResult {
        // 1. Inject [[IMG:N]] markers into the *original* HTML. We do this
        //    before sending to Readability.js so image positions can survive
        //    the cleanup pass — Readability strips/rewrites <img> tags, but
        //    the markers live as plain text inside <p> elements that
        //    Readability preserves.
        let markerResult = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: baseURL)
        let markedHTML = markerResult.html

        // 2. Run Readability.js via JSC.
        if let jsc = JSCReadabilityExtractor.extract(html: markedHTML, url: baseURL) {
            // Convert article HTML → markdown using the existing string parser.
            let candidate = HTMLToMarkdown.convert(jsc.content)

            if candidate.filter({ !$0.isWhitespace }).count >= 100 {
                let surviving = HTMLToMarkdown.findMarkerIndices(in: candidate)
                return EvalResult(
                    title: jsc.title,
                    markdown: candidate,
                    imageMarkerCount: surviving.count,
                    approach: approachName
                )
            }
            // Fall through to the full-HTML fallback below — Readability
            // returned a too-short result.
        }

        // 3. Fallback path: try the master Swift ReadabilityExtractor, then
        //    full-HTML conversion. Mirrors what `ShareViewController` does
        //    when extraction is too short.
        if let r = ReadabilityExtractor.extract(html: markedHTML, url: baseURL) {
            let candidate = HTMLToMarkdown.convert(node: r.articleNode)
            if candidate.filter({ !$0.isWhitespace }).count >= 100 {
                let surviving = HTMLToMarkdown.findMarkerIndices(in: candidate)
                return EvalResult(
                    title: r.title ?? "",
                    markdown: candidate,
                    imageMarkerCount: surviving.count,
                    approach: approachName
                )
            }
        }

        let fallbackMarkdown = HTMLToMarkdown.convert(markedHTML)
        return EvalResult(
            title: "",
            markdown: fallbackMarkdown,
            imageMarkerCount: HTMLToMarkdown.findMarkerIndices(in: fallbackMarkdown).count,
            approach: approachName
        )
    }
}

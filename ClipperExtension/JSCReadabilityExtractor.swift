import Foundation
import JavaScriptCore

#if canImport(Darwin)
import Darwin
#endif

/// Bridge to Mozilla's Readability.js + linkedom hosted in JavaScriptCore.
///
/// The bundled JS (built from `ClipperExtension/Resources/readability-bundle/`)
/// exposes a single global `ReadabilityKit.extractArticle(html, url)` that
/// returns a JSON-serialized result string (or null).
///
/// Spike A — see `eval/readability-jsc/notes.md`.
///
/// Threading: the underlying `JSContext` is *not* thread-safe. We lazily build
/// a single shared context behind a serial queue. All public calls hop onto
/// that queue. JSC startup is ~80ms; subsequent calls reuse the context.
enum JSCReadabilityExtractor {

    struct Result {
        let title: String
        let content: String   // article HTML (Readability's serialized output)
        let excerpt: String
        let siteName: String
        let byline: String
    }

    // MARK: - Shared context

    /// Serial queue that owns the JSContext. JSC isn't thread-safe; serialize
    /// every access through here.
    private static let queue = DispatchQueue(label: "com.obsidian.clipper.jsc-readability")

    /// Lazily-initialized context + memory delta from cold start. Captured so
    /// we only pay the ~80ms init cost once per extension launch.
    private static var sharedContext: JSContext?
    private static var initLogged = false

    // MARK: - Public API

    /// Run Readability.js against `html`. Returns nil if the bundle fails to
    /// load, the JS function throws, or Readability decides there's no article.
    static func extract(html: String, url: URL?) -> Result? {
        return queue.sync {
            guard let ctx = ensureContext() else { return nil }

            guard let kit = ctx.objectForKeyedSubscript("ReadabilityKit"),
                  !kit.isUndefined,
                  let fn = kit.objectForKeyedSubscript("extractArticle"),
                  !fn.isUndefined else {
                NSLog("[JSCReadability] ReadabilityKit.extractArticle is not defined")
                return nil
            }

            let urlArg: Any = url?.absoluteString ?? NSNull()
            guard let returned = fn.call(withArguments: [html, urlArg]) else {
                NSLog("[JSCReadability] call returned nil JSValue")
                return nil
            }

            if let exc = ctx.exception {
                NSLog("[JSCReadability] JS exception: \(exc.toString() ?? "<unknown>")")
                ctx.exception = nil
                return nil
            }

            if returned.isNull || returned.isUndefined { return nil }

            guard let jsonString = returned.toString(),
                  let data = jsonString.data(using: .utf8) else {
                return nil
            }

            do {
                guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }
                if let err = dict["__error"] as? String {
                    NSLog("[JSCReadability] bundle error: \(err)")
                    return nil
                }
                return Result(
                    title: (dict["title"] as? String) ?? "",
                    content: (dict["content"] as? String) ?? "",
                    excerpt: (dict["excerpt"] as? String) ?? "",
                    siteName: (dict["siteName"] as? String) ?? "",
                    byline: (dict["byline"] as? String) ?? ""
                )
            } catch {
                NSLog("[JSCReadability] JSON parse failed: \(error)")
                return nil
            }
        }
    }

    // MARK: - Context init

    /// Build the shared JSContext on first use. Loads the bundled JS file and
    /// installs a console.log shim so JS-side `console.log` is visible via
    /// NSLog (debug only).
    private static func ensureContext() -> JSContext? {
        if let existing = sharedContext { return existing }

        let memBefore = residentMemoryBytes()

        guard let ctx = JSContext() else {
            NSLog("[JSCReadability] failed to create JSContext")
            return nil
        }
        ctx.exceptionHandler = { _, exc in
            NSLog("[JSCReadability] uncaught: \(exc?.toString() ?? "?")")
        }

        // Console shim — JSC has no `console` global by default.
        let consoleLog: @convention(block) (String) -> Void = { msg in
            #if DEBUG
            NSLog("[JSC console] \(msg)")
            #endif
        }
        let console = JSValue(newObjectIn: ctx)
        console?.setObject(unsafeBitCast(consoleLog, to: AnyObject.self), forKeyedSubscript: "log" as NSString)
        console?.setObject(unsafeBitCast(consoleLog, to: AnyObject.self), forKeyedSubscript: "error" as NSString)
        console?.setObject(unsafeBitCast(consoleLog, to: AnyObject.self), forKeyedSubscript: "warn" as NSString)
        ctx.setObject(console, forKeyedSubscript: "console" as NSString)

        // atob/btoa polyfills — JSC's bare JSContext has no DOM globals, but
        // the bundled `htmlparser2` entity decoder calls `atob` (with a
        // fallback to Node's `Buffer.from`, which we also lack). Implement
        // base64 encode/decode via Foundation.
        let atob: @convention(block) (String) -> String = { input in
            // atob takes a base64-encoded ASCII string and returns the
            // "binary" string (each byte as a code unit 0–255).
            guard let data = Data(base64Encoded: input, options: .ignoreUnknownCharacters) else {
                return ""
            }
            // Map bytes to UInt16 code units in [0, 255] — matches JS `atob`.
            return String(decoding: data.map { UInt16($0) }, as: UTF16.self)
        }
        let btoa: @convention(block) (String) -> String = { input in
            // btoa takes a "binary" string and returns the base64 encoding.
            // Each code unit must fit in a byte; otherwise behavior is "throw"
            // in browsers — we just truncate, which is fine for our usage.
            let bytes: [UInt8] = input.unicodeScalars.map { UInt8(min(0xFF, $0.value)) }
            return Data(bytes).base64EncodedString()
        }
        ctx.setObject(unsafeBitCast(atob, to: AnyObject.self), forKeyedSubscript: "atob" as NSString)
        ctx.setObject(unsafeBitCast(btoa, to: AnyObject.self), forKeyedSubscript: "btoa" as NSString)

        guard let bundleURL = locateBundle() else {
            NSLog("[JSCReadability] readability-bundle.js not found in any bundle")
            return nil
        }

        let scriptStart = Date()
        do {
            let script = try String(contentsOf: bundleURL, encoding: .utf8)
            ctx.evaluateScript(script, withSourceURL: bundleURL)
            if let exc = ctx.exception {
                NSLog("[JSCReadability] bundle eval threw: \(exc.toString() ?? "?")")
                ctx.exception = nil
                return nil
            }
        } catch {
            NSLog("[JSCReadability] read bundle failed: \(error)")
            return nil
        }
        let scriptMs = Date().timeIntervalSince(scriptStart) * 1000.0

        let memAfter = residentMemoryBytes()

        if !initLogged {
            initLogged = true
            let deltaMB = Double(memAfter &- memBefore) / (1024.0 * 1024.0)
            NSLog("[JSCReadability] cold init: bundle=\(scriptMs.rounded())ms residentΔ=\(String(format: "%.1f", deltaMB))MB before=\(memBefore) after=\(memAfter)")
        }

        sharedContext = ctx
        return ctx
    }

    /// Locate `readability-bundle.js`. We try the ClipperExtension bundle
    /// first (production share-extension launch), then `Bundle.main`, then
    /// every loaded bundle (xctest fallback — the test bundle gets the
    /// resource because we add it to the test target).
    private static func locateBundle() -> URL? {
        // 1. Same bundle as this class (ClipperExtension or test bundle).
        let myBundle = Bundle(for: BundleAnchor.self)
        if let u = myBundle.url(forResource: "readability-bundle", withExtension: "js") {
            return u
        }
        // 2. Bundle.main.
        if let u = Bundle.main.url(forResource: "readability-bundle", withExtension: "js") {
            return u
        }
        // 3. All loaded bundles.
        for b in Bundle.allBundles + Bundle.allFrameworks {
            if let u = b.url(forResource: "readability-bundle", withExtension: "js") {
                return u
            }
        }
        return nil
    }

    // MARK: - Memory

    /// Resident memory in bytes via `mach_task_basic_info`. Used for the
    /// init-time logging only — production code shouldn't depend on this.
    private static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reb in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reb, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }
}

/// Class anchor for `Bundle(for:)` — `enum`s can't be passed there.
private final class BundleAnchor {}

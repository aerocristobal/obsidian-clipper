// Bundle entry point for the Readability + linkedom JSC bridge.
//
// Exposes a single `extractArticle(html, url)` function on the global IIFE
// namespace `ReadabilityKit`. The bundled file is loaded into a JSContext on
// the Swift side; see ClipperExtension/JSCReadabilityExtractor.swift.
//
// Returns a JSON-serialized string (or null) so the Swift bridge can decode
// it without poking at JSValue properties one-by-one.

import { parseHTML } from "linkedom";
import { Readability } from "@mozilla/readability";

function extractArticle(html, url) {
    try {
        const dom = parseHTML(html);
        const doc = dom.document;

        // Readability needs a documentURI / baseURI for resolving relative
        // <img>/<a> hrefs. linkedom doesn't set this from the HTML alone, so
        // inject a <base> tag if a URL was supplied.
        if (url && doc && doc.head) {
            const base = doc.createElement("base");
            base.setAttribute("href", url);
            doc.head.insertBefore(base, doc.head.firstChild);
        }

        // Readability mutates the document during parse(). That's fine — we
        // throw `dom` away on the next call.
        const reader = new Readability(doc, {
            // Keep classes off output: HTMLToMarkdown ignores them anyway and
            // they bloat the article HTML.
            keepClasses: false,
            // Don't strip our [[IMG:N]] markers if/when the caller passes
            // markered HTML in. Default Readability sometimes nukes <img> tags
            // it can't resolve; the markers live in plain text inside <p>s,
            // so they survive most cleanup, but flag this for the integration
            // notes.
        });
        const article = reader.parse();

        if (!article) return null;

        return JSON.stringify({
            title: article.title || "",
            content: article.content || "",
            excerpt: article.excerpt || "",
            siteName: article.siteName || "",
            byline: article.byline || "",
            length: article.length || 0,
        });
    } catch (e) {
        // Surface the error message via the return so Swift can log it.
        return JSON.stringify({ __error: String(e && e.message || e) });
    }
}

// Expose on the IIFE global so JSContext can reach it as
// `ReadabilityKit.extractArticle(...)`.
export { extractArticle };

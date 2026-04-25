import Foundation
import SwiftSoup

/// Bridges SwiftSoup's HTML5-conformant parser to the existing `HTMLNode`
/// tree used by `ReadabilityExtractor` and `HTMLToMarkdown`.
///
/// This is the spike-C parser swap: SwiftSoup parses the HTML, then we
/// translate its DOM into the project's bespoke `HTMLNode` so that all
/// downstream scoring and markdown conversion work unchanged.
///
/// Why an adapter rather than a direct migration: `HTMLNode` is the DOM
/// type that the entire Readability pipeline + `HTMLToMarkdown` walks.
/// Replacing it would touch hundreds of lines and conflate the parser-
/// swap with a tree-API rewrite. The adapter localizes the change.
enum SwiftSoupAdapter {

    /// Parse `html` with SwiftSoup, then convert the result into the
    /// project's `HTMLNode` tree. Returns `nil` only if the parse itself
    /// throws (rare — SwiftSoup is tolerant).
    ///
    /// The returned root is an `HTMLNode` element with tag `"document"`,
    /// matching the byte parser's contract. Parent pointers are wired up
    /// before return so `node.parent` works for the rest of the pipeline.
    static func parse(html: String) -> HTMLNode? {
        do {
            let document = try SwiftSoup.parse(html)
            // Walk SwiftSoup's children of <#document> directly so the
            // returned root mirrors the byte parser's `document` element
            // (whose children are <html>, comments, etc., NOT a single
            // wrapper). SwiftSoup's `Document` is an `Element` whose
            // children are typically `<html>`.
            let children = convertChildren(of: document)
            let root = HTMLNode(
                kind: .element(tag: "document", attributes: []),
                children: children
            )
            setParents(root)
            return root
        } catch {
            return nil
        }
    }

    // MARK: - Conversion

    private static func convertChildren(of node: Node) -> [HTMLNode] {
        var result: [HTMLNode] = []
        result.reserveCapacity(node.getChildNodes().count)
        for child in node.getChildNodes() {
            if let converted = convert(node: child) {
                result.append(converted)
            }
        }
        return result
    }

    /// Convert a single SwiftSoup `Node`. Returns `nil` for node types we
    /// don't surface (Comment, DocumentType, XmlDeclaration) — the existing
    /// byte parser drops these as well.
    private static func convert(node: Node) -> HTMLNode? {
        if let element = node as? Element {
            // Skip the synthetic `#root` if it ever appears as a child;
            // its children are what we want.
            let tag = element.tagNameNormal() // already lowercased
            let attrs: [(name: String, value: String)] = {
                guard let attributes = element.getAttributes() else { return [] }
                var out: [(name: String, value: String)] = []
                out.reserveCapacity(attributes.size())
                for attr in attributes {
                    out.append((name: attr.getKey().lowercased(), value: attr.getValue()))
                }
                return out
            }()

            let children = convertChildren(of: element)
            return HTMLNode(
                kind: .element(tag: tag, attributes: attrs),
                children: children
            )
        }

        if let text = node as? TextNode {
            // `getWholeText()` returns the raw text exactly as it sits in
            // the DOM (entity-decoded by SwiftSoup, whitespace preserved).
            // The shipped pipeline collapses whitespace at render time
            // (see `HTMLToMarkdown.collapseWhitespace`), so we mirror the
            // byte parser's behavior of handing off raw text here.
            return HTMLNode(kind: .text(text.getWholeText()))
        }

        if let data = node as? DataNode {
            // `<script>` / `<style>` raw-text content. The byte parser
            // attaches a single child text node containing the raw body;
            // we preserve that shape so anything that walks `<script>`
            // children (rare, but present in a few tests) sees the same
            // structure.
            return HTMLNode(kind: .text(data.getWholeData()))
        }

        // Comments, doctypes, XML declarations: drop them, matching the
        // byte parser's `skipComment`/`skipDeclaration` behavior.
        return nil
    }

    /// Wire up parent pointers across the converted tree. `HTMLNode.parent`
    /// is `weak`, so this is the standard one-shot post-build pass.
    private static func setParents(_ node: HTMLNode) {
        for child in node.children {
            child.parent = node
            setParents(child)
        }
    }
}

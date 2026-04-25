import XCTest
@testable import ClipperExtension

/// Eval harness: runs the corpus fixtures through `EvalEntryPoint.extract`,
/// scores against per-fixture `expected.json` criteria, and writes:
/// - `eval/<approach>/<fixture>.md` (raw markdown output)
/// - `eval/<approach>/summary.json` (per-fixture pass/fail + timings)
///
/// Each spike branch overrides `EvalEntryPoint.extract` (and `approachName`)
/// to route through its approach. The harness is identical across branches.
///
/// Run:
///   xcodebuild ... -only-testing:ObsidianClipperTests/ExtractionEvalTests test
final class ExtractionEvalTests: XCTestCase {

    // MARK: - Criteria types

    private struct ExpectedCriteria: Decodable {
        let title_contains: String?
        let must_contain: [String]
        let must_not_contain: [String]
        let min_body_chars: Int
        let max_total_images: Int?
        let ocr_must_not_contain: [String]?
    }

    private struct FixtureResult {
        let fixture: String
        let approach: String
        var titleOK: Bool
        var mustContainPassed: Int
        var mustContainTotal: Int
        var mustNotContainPassed: Int
        var mustNotContainTotal: Int
        var bodyCharsOK: Bool
        var bodyChars: Int
        var imageCountOK: Bool
        var imageCount: Int?
        var durationMs: Double
        var allPassed: Bool {
            titleOK
                && mustContainPassed == mustContainTotal
                && mustNotContainPassed == mustNotContainTotal
                && bodyCharsOK
                && imageCountOK
        }
    }

    // MARK: - Paths

    /// Repo root, derived from the `#filePath` of this source file. The test
    /// file lives at `<repo>/ObsidianClipperTests/ExtractionEvalTests.swift`,
    /// so two parent levels up is the repo.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var corpusDir: URL {
        repoRoot.appendingPathComponent("Tests/Fixtures/extraction-corpus", isDirectory: true)
    }

    private var outputDir: URL {
        repoRoot
            .appendingPathComponent("eval", isDirectory: true)
            .appendingPathComponent(EvalEntryPoint.approachName, isDirectory: true)
    }

    // MARK: - Test entry point

    /// Single test case that iterates all fixtures so output is a single
    /// summary block. Individual fixtures are reported via XCTAttachment-
    /// style stdout lines AND the summary.json artifact.
    func testCorpusExtraction() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let fixtures = try discoverFixtures()
        XCTAssertFalse(fixtures.isEmpty, "No fixtures found in \(corpusDir.path)")

        var results: [FixtureResult] = []
        for slug in fixtures {
            let result = try runFixture(slug: slug)
            results.append(result)
            print(formatFixtureLine(result))
        }

        // Write summary.json
        try writeSummary(results)

        // Print final markdown table to stdout so it's readable in xcodebuild output
        print("")
        print(renderTable(results))
        print("")

        // The harness DOES NOT XCTFail on per-criterion failures — that's the
        // whole point of an eval. We only fail if no fixtures ran or the IO
        // pipeline broke. The summary.json captures pass/fail per fixture.
    }

    // MARK: - Fixture discovery

    private func discoverFixtures() throws -> [String] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: corpusDir.path)
        let slugs = contents
            .filter { $0.hasSuffix(".html") }
            .map { String($0.dropLast(".html".count)) }
            .sorted()
        return slugs
    }

    // MARK: - Per-fixture runner

    private func runFixture(slug: String) throws -> FixtureResult {
        let htmlURL = corpusDir.appendingPathComponent("\(slug).html")
        let expectedURL = corpusDir.appendingPathComponent("\(slug).expected.json")
        let urlURL = corpusDir.appendingPathComponent("\(slug).url")

        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        let expected = try JSONDecoder().decode(
            ExpectedCriteria.self,
            from: try Data(contentsOf: expectedURL)
        )
        let baseURLString = (try? String(contentsOf: urlURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = baseURLString.flatMap { URL(string: $0) }

        let start = Date()
        let result = EvalEntryPoint.extract(html: html, baseURL: baseURL)
        let durationMs = Date().timeIntervalSince(start) * 1000.0

        // Save raw markdown
        let mdURL = outputDir.appendingPathComponent("\(slug).md")
        try result.markdown.data(using: .utf8)?.write(to: mdURL)

        // Score
        let titleOK: Bool
        if let needle = expected.title_contains {
            titleOK = result.title.localizedCaseInsensitiveContains(needle)
        } else {
            titleOK = true
        }

        var mcPass = 0
        for needle in expected.must_contain where result.markdown.contains(needle) {
            mcPass += 1
        }

        var mncPass = 0
        for needle in expected.must_not_contain where !result.markdown.contains(needle) {
            mncPass += 1
        }

        let bodyChars = result.markdown.filter { !$0.isWhitespace }.count
        let bodyOK = bodyChars >= expected.min_body_chars

        let imageCount = result.imageMarkerCount
        let imageOK: Bool
        if let cap = expected.max_total_images, let got = imageCount {
            imageOK = got <= cap
        } else {
            imageOK = true
        }

        return FixtureResult(
            fixture: slug,
            approach: result.approach,
            titleOK: titleOK,
            mustContainPassed: mcPass,
            mustContainTotal: expected.must_contain.count,
            mustNotContainPassed: mncPass,
            mustNotContainTotal: expected.must_not_contain.count,
            bodyCharsOK: bodyOK,
            bodyChars: bodyChars,
            imageCountOK: imageOK,
            imageCount: imageCount,
            durationMs: durationMs
        )
    }

    // MARK: - Reporting

    private func formatFixtureLine(_ r: FixtureResult) -> String {
        let mark = r.allPassed ? "✓" : "✗"
        return "[\(mark)] \(r.fixture): mc=\(r.mustContainPassed)/\(r.mustContainTotal) "
            + "mnc=\(r.mustNotContainPassed)/\(r.mustNotContainTotal) "
            + "title=\(r.titleOK ? "OK" : "MISS") "
            + "body=\(r.bodyChars)c"
            + (r.bodyCharsOK ? "" : "(short)")
            + " imgs=\(r.imageCount.map(String.init) ?? "n/a")"
            + (r.imageCountOK ? "" : "(over cap)")
            + " \(String(format: "%.1f", r.durationMs))ms"
    }

    private func renderTable(_ results: [FixtureResult]) -> String {
        var s = "## Eval results — approach: \(EvalEntryPoint.approachName)\n\n"
        s += "| Fixture | Pass | Title | Body chars | Must-contain | Must-not | Imgs | Time |\n"
        s += "|---|---|---|---|---|---|---|---|\n"
        for r in results {
            let pass = r.allPassed ? "✓" : "✗"
            s += "| \(r.fixture) | \(pass) | \(r.titleOK ? "✓" : "✗") "
            s += "| \(r.bodyChars)\(r.bodyCharsOK ? "" : "❌") "
            s += "| \(r.mustContainPassed)/\(r.mustContainTotal) "
            s += "| \(r.mustNotContainPassed)/\(r.mustNotContainTotal) "
            s += "| \(r.imageCount.map(String.init) ?? "—")\(r.imageCountOK ? "" : "❌") "
            s += "| \(String(format: "%.0f", r.durationMs))ms |\n"
        }
        return s
    }

    private func writeSummary(_ results: [FixtureResult]) throws {
        // Hand-roll the JSON to keep it dependency-free and stable.
        var rows: [String] = []
        for r in results {
            let row = """
              {
                "fixture": "\(r.fixture)",
                "approach": "\(r.approach)",
                "all_passed": \(r.allPassed),
                "title_ok": \(r.titleOK),
                "must_contain_passed": \(r.mustContainPassed),
                "must_contain_total": \(r.mustContainTotal),
                "must_not_contain_passed": \(r.mustNotContainPassed),
                "must_not_contain_total": \(r.mustNotContainTotal),
                "body_chars": \(r.bodyChars),
                "body_chars_ok": \(r.bodyCharsOK),
                "image_count": \(r.imageCount.map(String.init) ?? "null"),
                "image_count_ok": \(r.imageCountOK),
                "duration_ms": \(String(format: "%.2f", r.durationMs))
              }
            """
            rows.append(row)
        }
        let json = """
        {
          "approach": "\(EvalEntryPoint.approachName)",
          "fixtures": [
        \(rows.joined(separator: ",\n"))
          ]
        }

        """
        let summaryURL = outputDir.appendingPathComponent("summary.json")
        try json.data(using: .utf8)?.write(to: summaryURL)
    }
}

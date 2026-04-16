import XCTest
@testable import ClipperExtension

final class ReadabilityExtractorTests: XCTestCase {

    // MARK: - Article Extraction from Realistic Page

    func testExtractsArticleFromRealisticPage() {
        let html = """
        <html><head><title>Great Article | Example News</title>
        <meta property="og:title" content="Great Article">
        <meta property="og:site_name" content="Example News">
        <meta name="description" content="A short summary of the article.">
        </head><body>
        <nav><ul><li><a href="/">Home</a></li><li><a href="/news">News</a></li></ul></nav>
        <div id="sidebar" class="sidebar-widget">
            <h3>Trending</h3>
            <ul><li><a href="/trending1">Trending 1</a></li><li><a href="/trending2">Trending 2</a></li></ul>
        </div>
        <article class="post-content">
            <h1>Great Article</h1>
            <p>This is the first paragraph of a very interesting article about technology and
            its impact on society. It contains enough text to be considered real content, with
            commas, periods, and other punctuation that indicate prose.</p>
            <p>The second paragraph continues the discussion with more detail, expanding on the
            themes introduced above. Multiple paragraphs with substantial text help the scoring
            algorithm identify this as the main content area of the page.</p>
            <p>A third paragraph adds even more depth to the article, discussing related topics
            and providing examples that illustrate the main points being made. This is clearly
            the body of an article, not navigation or sidebar content.</p>
        </article>
        <footer><p>Copyright 2024 Example News</p><a href="/privacy">Privacy Policy</a></footer>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: URL(string: "https://example.com/article"))

        XCTAssertNotNil(result, "Should extract article content")

        guard let result = result else { return }

        // Should contain the article paragraphs
        XCTAssertTrue(result.articleHTML.contains("first paragraph"), "Should contain article text")
        XCTAssertTrue(result.articleHTML.contains("second paragraph"), "Should contain second paragraph")
        XCTAssertTrue(result.articleHTML.contains("third paragraph"), "Should contain third paragraph")

        // Should NOT contain navigation or footer
        XCTAssertFalse(result.articleHTML.contains("Trending"), "Should not contain sidebar")
        XCTAssertFalse(result.articleHTML.contains("Privacy Policy"), "Should not contain footer")
        XCTAssertFalse(result.articleHTML.contains("Home"), "Should not contain nav links")
    }

    // MARK: - Graceful Fallback on No Clear Article

    func testFallbackGracefullyOnNoClearArticle() {
        let html = """
        <html><body>
        <div><p>Short text.</p></div>
        <div><p>Another short bit.</p></div>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)

        // Should return nil or very low-quality result since there's no clear article
        // The pipeline will fall back to full HTML in this case
        if let result = result {
            // If it does return something, it should not crash
            XCTAssertFalse(result.articleHTML.isEmpty, "If returned, should have some content")
        }
    }

    // MARK: - Title Extraction

    func testTitleExtractionFromOGTitle() {
        let html = """
        <html><head>
        <title>Article Title | Site Name</title>
        <meta property="og:title" content="Article Title">
        </head><body>
        <article>
            <h1>Article Title</h1>
            <p>Long paragraph with enough text to be scored as content. This paragraph has
            commas, and enough words to pass the minimum threshold for content detection in the
            readability algorithm. It really needs to be reasonably long to be scored.</p>
        </article>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertEqual(result?.title, "Article Title", "Should prefer og:title")
    }

    func testTitleExtractionFromH1() {
        let html = """
        <html><head><title>Site Name</title></head><body>
        <article>
            <h1>The Real Article Title</h1>
            <p>Long paragraph with enough text to be scored as content. This paragraph has
            commas, and enough words to pass the minimum threshold for content detection in the
            readability algorithm. It really needs to be reasonably long to be scored well.</p>
        </article>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertEqual(result?.title, "The Real Article Title", "Should extract title from h1")
    }

    func testTitleExtractionFromTitleTag() {
        let html = """
        <html><head><title>Page Title | News Site</title></head><body>
        <div class="content">
            <p>Long paragraph with enough text to be scored as content. This paragraph has
            commas, and enough words to pass the minimum threshold for content detection in the
            readability algorithm. It really needs to be reasonably long to be scored well.</p>
        </div>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        // Should clean the title by removing " | News Site"
        XCTAssertEqual(result?.title, "Page Title", "Should clean title tag by removing site name suffix")
    }

    // MARK: - Link Density Calculation

    func testHighLinkDensityElementsScoreLow() {
        let html = """
        <html><body>
        <div class="navigation">
            <a href="/1">Link One</a> <a href="/2">Link Two</a> <a href="/3">Link Three</a>
            <a href="/4">Link Four</a> <a href="/5">Link Five</a> <a href="/6">Link Six</a>
        </div>
        <article class="article-content">
            <p>This is a long article paragraph with lots of text and very few links. The content
            ratio should be much higher here, with prose-like text that includes commas, periods,
            and natural language patterns that the algorithm can detect as real content.</p>
            <p>Another paragraph continues the article discussion with even more detailed text
            that adds to the overall content score. Multiple paragraphs like this ensure the
            scoring algorithm properly identifies this as the main content.</p>
        </article>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(result)
        // The article should win over the navigation div
        XCTAssertTrue(result?.articleHTML.contains("long article paragraph") == true,
                      "Article content should be selected over high-link-density navigation")
        XCTAssertFalse(result?.articleHTML.contains("Link One") == true,
                       "Navigation links should not be in the extracted content")
    }

    // MARK: - Script/Style/Nav Stripping

    func testScriptStyleNavStripping() {
        let html = """
        <html><body>
        <script>var x = 1; alert('hello');</script>
        <style>.foo { color: red; }</style>
        <nav><a href="/">Home</a><a href="/about">About</a></nav>
        <article>
            <p>This is the actual article content that should remain after preprocessing strips
            out all the script tags, style tags, and navigation elements. The content here is
            real prose with natural language patterns, commas, and enough length to score well.</p>
        </article>
        <footer>Footer content with copyright notices</footer>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(result)

        guard let html = result?.articleHTML else { return }

        XCTAssertFalse(html.contains("alert"), "Script content should be stripped")
        XCTAssertFalse(html.contains("color: red"), "Style content should be stripped")
        XCTAssertFalse(html.contains("About"), "Nav content should be stripped")
        XCTAssertTrue(html.contains("actual article content"), "Article should remain")
    }

    // MARK: - ID/Class Scoring

    func testPositiveClassNamesBoostScore() {
        let html = """
        <html><body>
        <div class="sidebar related-posts">
            <p>Some sidebar text with links and short content. Not very useful for the reader,
            mostly promotional material.</p>
        </div>
        <div class="article-body content-main">
            <p>The main article body with detailed information about the topic. This content
            is rich in prose, includes commas, and represents the primary content that a user
            would want to read when visiting this page. It spans multiple sentences.</p>
            <p>Continuing with more relevant content that adds depth and detail to the article.
            This second paragraph reinforces the scoring with additional text length.</p>
        </div>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.articleHTML.contains("main article body") == true,
                      "Content-positive class should win: \(result?.articleHTML ?? "nil")")
    }

    func testNegativeClassNamesPenalizeScore() {
        let html = """
        <html><body>
        <div class="comment-section social-share">
            <p>User comment here, not part of the article. Some discussion text that might
            look like content but should be penalized due to the negative class names.</p>
        </div>
        <div id="post-body">
            <p>Real article text that should be selected over the comment section. This is
            the actual content of the page with natural language, commas, periods, and enough
            text to be identified as the main body by the scoring algorithm.</p>
            <p>Additional paragraph providing more context and detail about the subject being
            discussed in this article, further boosting its content score.</p>
        </div>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.articleHTML.contains("Real article text") == true,
                      "Post body should win over comment section")
    }

    // MARK: - Metadata Extraction

    func testSiteNameExtraction() {
        let html = """
        <html><head>
        <meta property="og:site_name" content="My Tech Blog">
        </head><body>
        <article>
            <p>Article content with enough text to pass the content threshold and be scored as
            the main article body. Contains natural language with commas, and prose-like patterns
            that the algorithm recognizes as real content.</p>
        </article>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertEqual(result?.siteName, "My Tech Blog")
    }

    func testExcerptFromMetaDescription() {
        let html = """
        <html><head>
        <meta name="description" content="A brief summary of this article for search engines.">
        </head><body>
        <article>
            <p>Full article content goes here with enough text to pass the minimum threshold.
            This is the body of the article with natural language, commas, and sufficient length
            for the scoring algorithm to identify it correctly.</p>
        </article>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertEqual(result?.excerpt, "A brief summary of this article for search engines.")
    }

    // MARK: - Hidden Element Removal

    func testHiddenElementsAreRemoved() {
        let html = """
        <html><body>
        <div style="display:none"><p>Hidden popup content that should be removed.</p></div>
        <div aria-hidden="true"><p>Screen reader hidden content.</p></div>
        <article>
            <p>Visible article content that should survive preprocessing. Contains natural
            language with commas, prose patterns, and sufficient length for the algorithm to
            properly score and select this as the main content area.</p>
        </article>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.articleHTML.contains("Hidden popup") == true)
        XCTAssertFalse(result?.articleHTML.contains("Screen reader hidden") == true)
        XCTAssertTrue(result?.articleHTML.contains("Visible article content") == true)
    }

    // MARK: - HTML Entity Handling

    func testHTMLEntityDecoding() {
        let html = """
        <html><body>
        <article>
            <p>Text with &amp; ampersand, &lt;angle brackets&gt;, &quot;quotes&quot;, and
            special characters like &ndash; dash, &mdash; em dash, &hellip; ellipsis. Also
            numeric entities like &#169; copyright and hex &#x2603; snowman. This paragraph
            has plenty of content length for proper scoring with commas and natural prose.</p>
        </article>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(result)

        guard let articleHTML = result?.articleHTML else { return }

        XCTAssertTrue(articleHTML.contains("&"), "Should decode &amp;")
        XCTAssertTrue(articleHTML.contains("<angle brackets>"), "Should decode &lt; and &gt;")
        XCTAssertTrue(articleHTML.contains("\u{2013}"), "Should decode &ndash;")
    }

    // MARK: - Minimum Content Threshold

    func testVeryShortContentReturnsNil() {
        let html = """
        <html><body><div><p>Hi.</p></div></body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        // With very short content, the extractor should return nil (score too low)
        // so the pipeline falls back to full HTML
        XCTAssertNil(result, "Very short content should not produce a result")
    }

    // MARK: - Empty/Malformed HTML

    func testEmptyHTMLReturnsNil() {
        let result = ReadabilityExtractor.extract(html: "", url: nil)
        XCTAssertNil(result)
    }

    func testMalformedHTMLDoesNotCrash() {
        let html = """
        <html><body>
        <div class="content">
            <p>Unclosed paragraph that never gets a closing tag
            <p>Another paragraph without closing the first
            <div>Nested div <span>with unclosed span
            <p>And more text that has enough content to be scored by the algorithm, with
            commas, natural language, and sufficient length for proper detection. The parser
            should handle this malformed markup without crashing or hanging.</p>
        </div>
        </body></html>
        """

        // Should not crash
        let result = ReadabilityExtractor.extract(html: html, url: nil)
        // Just verify it doesn't crash — result may or may not be nil
        _ = result
    }

    // MARK: - Self-closing Tags

    func testSelfClosingTagHandling() {
        let html = """
        <html><head>
        <meta charset="utf-8">
        <link rel="stylesheet" href="style.css">
        </head><body>
        <article>
            <p>Text before image.</p>
            <img src="photo.jpg" alt="A photo">
            <br>
            <hr>
            <p>Text after image with enough content to pass the threshold. This paragraph
            contains natural language, commas, and sufficient length for the scoring algorithm
            to properly identify the article container.</p>
        </article>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(result)
        // Should handle self-closing tags without breaking the parse tree
        XCTAssertTrue(result?.articleHTML.contains("Text before image") == true)
        XCTAssertTrue(result?.articleHTML.contains("Text after image") == true)
    }

    // MARK: - Article Tag Bonus

    func testArticleTagGetsScoreBonus() {
        let html = """
        <html><body>
        <div class="wrapper">
            <p>Some wrapper text that has a decent amount of content. This paragraph provides
            enough text to potentially score in the algorithm, with commas and natural prose.</p>
        </div>
        <article>
            <p>Article content that should benefit from the article tag bonus in scoring.
            This text is the primary content, with commas, and adequate length.</p>
        </article>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.articleHTML.contains("article tag bonus") == true,
                      "Article tag should get score bonus and win")
    }

    // MARK: - Image Marker Preservation

    func testImageMarkersSurviveExtraction() {
        let html = """
        <html><body>
        <nav><a href="/">Home</a></nav>
        <article class="post-content">
            <h1>Photo Essay</h1>
            <p>This is a detailed article with inline images. The first paragraph has enough
            text to score well, with commas, natural prose, and sufficient length for the
            scoring algorithm to identify this as the main content area of the page.</p>
            [[IMG:0]]
            <p>After the first image, the article continues with more content. This second
            paragraph provides additional detail and context about the photographs shown,
            describing what they depict and why they matter.</p>
            [[IMG:1]]
            <p>The final paragraph wraps up the photo essay with concluding thoughts about
            the collection of images and their significance in the broader context.</p>
        </article>
        <footer><p>Copyright 2024</p></footer>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: nil)
        XCTAssertNotNil(result, "Should extract article")

        guard let result = result else { return }

        XCTAssertTrue(result.articleHTML.contains("[[IMG:0]]"),
                      "First image marker should survive extraction, got: \(result.articleHTML)")
        XCTAssertTrue(result.articleHTML.contains("[[IMG:1]]"),
                      "Second image marker should survive extraction, got: \(result.articleHTML)")
        XCTAssertTrue(result.articleHTML.contains("detailed article"),
                      "First paragraph should be present")
        XCTAssertTrue(result.articleHTML.contains("final paragraph"),
                      "Last paragraph should be present")
    }

    // MARK: - Multi-Paragraph Article Extraction

    func testExtractsFullArticleNotJustHeader() {
        let html = """
        <html><head><title>News Article | Daily News</title></head><body>
        <header class="site-header"><a href="/">Daily News</a></header>
        <nav><ul><li><a href="/politics">Politics</a></li></ul></nav>
        <div class="article-wrapper">
            <article>
                <h1>Major Event Unfolds</h1>
                <p class="byline">By Jane Reporter, April 15, 2024</p>
                <p>The first paragraph of this news article describes a major event that
                has been unfolding over the past week. Officials confirmed the details
                in a press conference held earlier today, marking a significant development.</p>
                <p>In the second paragraph, experts provide their analysis of the situation,
                offering context about why this matters and what the potential consequences
                might be for stakeholders across multiple sectors of the economy.</p>
                <p>The third paragraph includes quotes from key figures involved in the
                story, giving readers direct insight into the perspectives of those most
                affected by these developments and their plans going forward.</p>
                <p>Finally, the fourth paragraph outlines the next steps expected in this
                ongoing situation, including upcoming meetings, deadlines, and milestones
                that will determine the ultimate outcome of these events.</p>
            </article>
        </div>
        <aside class="sidebar"><h3>Related Stories</h3><ul>
            <li><a href="/story1">Related 1</a></li>
            <li><a href="/story2">Related 2</a></li>
        </ul></aside>
        <footer><p>Copyright Daily News 2024</p></footer>
        </body></html>
        """

        let result = ReadabilityExtractor.extract(html: html, url: URL(string: "https://dailynews.example.com/article"))
        XCTAssertNotNil(result, "Should extract article content")

        guard let result = result else { return }

        // ALL four body paragraphs must be present — not just the header
        XCTAssertTrue(result.articleHTML.contains("first paragraph"),
                      "Should contain first paragraph")
        XCTAssertTrue(result.articleHTML.contains("second paragraph"),
                      "Should contain second paragraph")
        XCTAssertTrue(result.articleHTML.contains("third paragraph"),
                      "Should contain third paragraph")
        XCTAssertTrue(result.articleHTML.contains("fourth paragraph"),
                      "Should contain fourth paragraph")

        // Should NOT contain sidebar or navigation
        XCTAssertFalse(result.articleHTML.contains("Related Stories"),
                       "Should not contain sidebar")
        XCTAssertFalse(result.articleHTML.contains("Politics"),
                       "Should not contain navigation")

        // The 100-char check should pass easily with this much content
        let nonWhitespace = result.articleHTML.filter { !$0.isWhitespace }.count
        XCTAssertGreaterThan(nonWhitespace, 100,
                            "Article should have well over 100 non-whitespace chars")
    }
}

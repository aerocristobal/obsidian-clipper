# Spike B — JSON-LD / Schema.org fast path

Run: `spike/jsonld-fastpath` branch, atop `spike/eval-harness`.
Date: 2026-04-25
iOS Simulator: iPhone 17, iOS 26.4.1

## Pass rate: 3/6 (vs master 2/6) — net **+1**

| Fixture | Master | Fastpath | Path taken | Δ time |
|---|---|---|---|---|
| electrek-bluetti | ✗ | ✗ | fell through (no `articleBody`) | identical |
| fnn-ai-productivity | ✓ | ✓ | fell through (no `articleBody`) | identical |
| fnn-ex-feds | ✗ | ✗ | fell through (no `articleBody`) | identical |
| fnn-fbi | ✗ | ✗ | fell through (no `articleBody`) | identical |
| wired-anthropic | ✗ | **✓** | **JSON-LD fired** (plain text) | **428ms → 10ms** (~40× faster) |
| wired-michael | ✓ | ✓ | **JSON-LD fired** (plain text) | **475ms → 15ms** (~30× faster) |

## Per-fixture analysis

### Wired (both fixtures) — fast path fires

Both Wired articles ship a single `<script type="application/ld+json">` block
containing a `NewsArticle` with a populated `articleBody` field (~5 KB plain
text, single-`\n` paragraph separators). No HTML inside the body — the
publisher emits a clean text run.

- **wired-anthropic** flips ✗ → ✓: master's Readability picked up recirc/
  related-content cards alongside the body, leading to `must_contain` misses
  and `must_not` bleed-through. The fast path returns exactly the article
  body — no recirc, all canaries pass.
- **wired-michael** stays ✓ but produces a tighter body (4103c vs 9273c);
  master's body included headers / pull quotes that JSON-LD's `articleBody`
  omits. The eval criteria only require >= 1500c, so both pass.
- **No images preserved** in either Wired fast-path output — `articleBody`
  is plain text, so there are no `<img>` tags to extract markers from.
  This matches the master observation (`wired-*` had `images=0` already).

### FNN (3 fixtures) — fast path **does not** fire

All three FNN fixtures contain a `NewsArticle` JSON-LD entry, but **no
`articleBody` field**. Headline / publisher / dates are present but not the
content body. We fall through to Readability — output is byte-identical to
master.

### Electrek (1 fixture) — fast path does not fire

Electrek emits `Article`, `NewsArticle`, `WebPage`, `ImageObject`, etc., but
no `articleBody` field on any of them. Falls through to Readability,
byte-identical to master (passes 2/2 must-contain but trips one
must-not-contain on the "Subscribe to Electrek" recirc text — same as master).

## Coverage stats

- **Fixtures with JSON-LD blocks present:** 6/6 (every fixture)
- **Fixtures with a NewsArticle / Article / BlogPosting `@type`:** 6/6
- **Fixtures where `articleBody` is populated (>= 500 chars):** 2/6
  (both Wired)
- **Fast-path fired:** 2/6 — exactly matches `articleBody` availability
- **Fall-through correctness:** 4/4 byte-identical to master output

## Body-quality observations

1. **Wired's `articleBody` is plain text, not HTML.** Inline links, italics,
   and pull quotes are flattened. Acceptable for a clip — the eval canaries
   pass — but inline link preservation will require either a different
   Wired-specific extraction or stitching links from the DOM after the fact.
2. **Wired's body uses single `\n` between paragraphs** (not `\n\n`). The
   plain-text → HTML wrapper handles this by falling back to single-newline
   splits when no double-newline is present.
3. **FNN appears to use `articleBody` only on opinion pieces / press
   releases** (not on regular news articles). Generalizing the spike past
   our 6-fixture corpus would need a wider sample.
4. **No headline-only matches in our corpus needed OG fallback** — every
   fixture either had a usable JSON-LD body or fell through cleanly.
   OG-body fallback was deliberately skipped (per spec: `og:description` is
   never long enough to qualify as a body).

## Performance

| Fixture | Master | Fastpath | Speedup |
|---|---|---|---|
| wired-anthropic | 428ms | 10ms | ~42× |
| wired-michael | 475ms | 15ms | ~32× |

JSON-LD parse + plain-text wrap + markdown convert is dominated by the
markdown converter for plain-text bodies, which is fed an article-only
`<p>...</p>` shell. No Readability scoring, no full-DOM walk.

## Risks / caveats

- **No image preservation when body is plain text.** If a publisher's
  `articleBody` is HTML (e.g. with `<img>` tags), the marker pipeline will
  pick them up — but for the 2 fixtures where this fired, there are no
  inline images. We'd need a fixture with HTML `articleBody` to verify the
  HTML branch end-to-end.
- **Title trust.** We trust `headline` from JSON-LD verbatim (with HTML
  entity decoding). If a publisher mis-encodes their headline this could
  ship a malformed title. Negligible risk in practice — we only saw one
  numeric entity (`&#8217;`) across 6 fixtures and it decoded cleanly.
- **`articleBody` is sometimes truncated** by publishers (paywalls, "read
  the full article on…"). Our threshold (500 chars default) defends against
  the obvious truncation but not against silent shortening. A future
  improvement is to compare body length against page-text length and fall
  back if the JSON-LD body is suspiciously short.

## Recommendation

**Merge as fast-path-on-top-of-current-Readability** (the layout used by
this spike).

Reasons:

1. **Strict positive value when it fires.** wired-anthropic flipped a fail
   to a pass, wired-michael stays passing, and 30–40× faster.
2. **Zero-risk fall-through.** Non-Wired fixtures produced byte-identical
   output to master. There's no scenario in our corpus where the fast path
   degrades extraction.
3. **Cheap.** ~150 LOC of Swift, two regex passes + JSONSerialization, no
   new dependencies. Negligible memory cost (regex on the raw HTML, not a
   second DOM parse).
4. **Aligns with publisher intent.** When the publisher *tells* us what
   their article body is via Schema.org, we should believe them rather
   than re-deriving it heuristically.

Recommended follow-ups (out of scope for this spike):

- Add 5–10 more fixtures to confirm fast-path coverage on news sites that
  *do* embed `articleBody` (NYT, Reuters, AP). The corpus skew toward
  publishers without `articleBody` understates the win.
- HTML-`articleBody` fixture for the marker-injection branch (verify image
  preservation when bodies arrive as HTML).
- Consider stitching in the lede image (`image` field on the JSON-LD
  Article) when the body has zero images — Wired articles always have a
  hero image and currently we lose it.

# Master baseline — extraction eval results

Run: spike/eval-harness branch, identical pipeline to current `main`.
Date: 2026-04-25

| Fixture | Pass | Title | Body chars | Must-contain | Must-not | Imgs | Time |
|---|---|---|---|---|---|---|---|
| electrek-bluetti | ✗ | ✓ | 5662 | 2/2 | 0/1 | 7 | 103ms |
| fnn-ai-productivity | ✓ | ✓ | 6954 | 1/1 | 2/2 | 0 | 90ms |
| fnn-ex-feds | ✗ | ✓ | 948 | 0/1 | 3/3 | 0 | 74ms |
| fnn-fbi | ✗ | ✓ | 764 (short) | 0/2 | 2/3 | 0 | 53ms |
| wired-anthropic | ✗ | ✓ | 2918 | 0/1 | 1/2 | 0 | 428ms |
| wired-michael | ✓ | ✓ | 9273 | 1/1 | 1/1 | 0 | 475ms |

## Pass rate: 2/6 (33%)

## Notes

- `wired-anthropic`: extracts ~3KB of *something* but body canary not present
  (likely still picking recirc cards over body). Also fails 1 must-not (recirc
  bleed-through).
- `fnn-fbi`: the previous-session whole-word fix on `scoreElement` was not
  sufficient. Body is only 764 chars and canaries don't match — recirc/sidebar
  is still winning on FNN.
- `fnn-ex-feds`: 948 chars, body canary missing. Probably the recirc wins
  again, or the article body Entry-content is being post-processed away.
- `electrek-bluetti`: content extracts (2/2 must-contain), but pulls in the
  "Subscribe to Electrek on Google News" phrase that's outside the article
  body (must-not failed).
- `wired-michael`: passes — 9KB body, canary present. The Wired layout that
  worked on this one is a different shape than `wired-anthropic`.

## Image counts
Image count is "markers surviving Readability" — proxy for "what would be
downloaded". 7 for electrek (article body has many product images);
0 for the rest because recirc-only extractions strip the article images.

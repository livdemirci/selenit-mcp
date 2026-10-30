## Head-to-head: Selenit MCP vs Playwright MCP

- model: `google/gemma-4-e4b` (temperature 0, thinking off, max_tokens 1200)
- runs per site: 1, step budget: 16, tool-output cap per call: 2,000 chars
- date: 2026-10-30T18:33:59Z
- task (identical for both): open the site, search for a term, report the first result heading as `title | url`

| Tool | Tasks passed | Median steps | Median time | Median tool-output chars | Median tokens (prompt+completion) | Tokens / step |
|---|---|---|---|---|---|---|
| selenit | 2/5 | 3.0 | 67.7s | 6000 | 16576 | 5225 |
| playwright | 0/5 | 3.0 | 100.4s | 751 | 18234 | 5896 |

### Per task

| Site | Tool | Result | Reason | Steps | Time |
|---|---|---|---|---|---|
| wikipedia | selenit | PASS | verified | 4 | 71.9s |
| wikipedia | playwright | FAIL | empty_answer | 16 | 391.0s |
| npm | selenit | PASS | verified | 3 | 53.7s |
| npm | playwright | FAIL | not_completed | 3 | 76.4s |
| github | selenit | FAIL | hallucinated | 3 | 61.0s |
| github | playwright | FAIL | not_completed | 11 | 302.4s |
| hurriyet | selenit | FAIL | empty_answer | 10 | 494.6s |
| hurriyet | playwright | FAIL | not_completed | 3 | 100.4s |
| trendyol | selenit | FAIL | hallucinated | 3 | 67.7s |
| trendyol | playwright | FAIL | not_completed | 2 | 40.6s |

Failures are reported, not hidden: every row above is a real headless run on a live site.
Single-run numbers are noisy; use `KOSUM=3` for medians you would quote publicly.
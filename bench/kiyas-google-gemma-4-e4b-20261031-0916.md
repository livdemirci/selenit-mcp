## Head-to-head: Selenit MCP vs Playwright MCP

- model: `google/gemma-4-e4b` (temperature 0, thinking off, max_tokens 1200)
- runs per site: 1, step budget: 16, tool-output cap per call: 2,000 chars
- date: 2026-10-31T06:20:13Z
- task (identical for both): open the site, search for a term, report the first result heading as `title | url`

| Tool | Tasks passed | Median steps | Median time | Median tool-output chars | Median tokens (prompt+completion) | Tokens / step |
|---|---|---|---|---|---|---|
| selenit | 1/1 | 9.0 | 95.9s | 10220 | 48578 | 5398 |
| playwright | 0/1 | 3.0 | 60.3s | 838 | 17328 | 5776 |

### Per task

| Site | Tool | Result | Reason | Steps | Time |
|---|---|---|---|---|---|
| trendyol | selenit | PASS | verified | 9 | 95.9s |
| trendyol | playwright | FAIL | page_unreadable | 3 | 60.3s |

Failures are reported, not hidden: every row above is a real headless run on a live site.
Single-run numbers are noisy; use `KOSUM=3` for medians you would quote publicly.
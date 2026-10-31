## Head-to-head: Selenit MCP vs Playwright MCP

- model: `google/gemma-4-e4b` (temperature 0, thinking off, max_tokens 1200)
- runs per site: 1, step budget: 16, tool-output cap per call: 2,000 chars
- date: 2026-10-31T06:15:01Z
- task (identical for both): open the site, search for a term, report the first result heading as `title | url`

| Tool | Tasks passed | Median steps | Median time | Median tool-output chars | Median tokens (prompt+completion) | Tokens / step |
|---|---|---|---|---|---|---|
| selenit | 0/1 | 5.0 | 18.4s | 8177 | 25136 | 5027 |
| playwright | 1/1 | 3.0 | 57.4s | 938 | 17334 | 5778 |

### Per task

| Site | Tool | Result | Reason | Steps | Time |
|---|---|---|---|---|---|
| trendyol | selenit | FAIL | hallucinated | 5 | 18.4s |
| trendyol | playwright | PASS | verified | 3 | 57.4s |

Failures are reported, not hidden: every row above is a real headless run on a live site.
Single-run numbers are noisy; use `KOSUM=3` for medians you would quote publicly.
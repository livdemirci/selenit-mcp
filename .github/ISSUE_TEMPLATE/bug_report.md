---
name: Bug report
about: Something behaves wrong on a real site or in a benchmark run
labels: bug
---

## What happened

<!-- One paragraph. What did you ask the agent to do, what did it do instead? -->

## Environment

- `npx selenit-mcp doctor` output:
```
paste here
```
- OS + version:
- Ruby version (`ruby -v`):
- Chrome version:
- Model + runtime (e.g. `google/gemma-4-e4b` on LM Studio 0.3.x, thinking off):
- `BROWSER_MODE` (managed / existing / auto) and port:

## Evidence

Attach the failing tool trace and the snapshot the model saw. Redact cookies and tokens — the audit
log already masks password-like arguments.

```
tool call → tool output (first ~20 lines)
```

## Reproduction

1.
2.
3.

Expected:

Actual:

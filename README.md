# selenit-mcp

[![npm](https://img.shields.io/npm/v/selenit-mcp.svg)](https://www.npmjs.com/package/selenit-mcp)
[![license](https://img.shields.io/npm/l/selenit-mcp.svg)](LICENSE)

**A Selenium-based browser MCP server built for small local models — tuned and benchmarked on Gemma E4B.**

Most browser MCP servers are designed for large cloud models: rich accessibility trees, verbose
output, plenty of tokens to spare. `selenit-mcp` goes the other way. It emits compact,
reference-based page dumps (`e1`, `e2`, …), guards against the failure modes small models
actually hit, and attaches to a real Chrome over CDP — so a 4B model running locally can
navigate, fill forms, and complete multi-step tasks without drowning in context.

> 🇹🇷 Turkish documentation (detailed engineering log): [TURKCE.md](TURKCE.md)

## Why Gemma E4B

| Design choice | Problem it solves for small models |
|---|---|
| Compact dumps (~1–4 KB, max 40 elements) | Gemma E4B has a small context; raw HTML or full a11y trees blow it up |
| `e1`-style refs, renewed per snapshot | No CSS selectors to invent; fewer hallucinated locators |
| Loop guard (same call 3× → warning, not execution) | Stops the classic scroll/read/snapshot death spiral |
| Modal focus, overlay priority, row/card context | `Save` buttons in a dialog, `Add to cart` on product cards stay distinguishable |
| Explicit waits + Turkish/English actionable errors | "ref is renewed every snapshot", "element is covered", "alert is open" |
| Auto-recovery from JS alerts, stale elements, covered elements | The run continues instead of collapsing mid-task |

**Measured on Gemma E4B** (`google/gemma-4-e4b`, 20 tools, max_tokens 800): **17/17 tasks passed**,
1–7 steps and 22–78 s per task, ~13 min total. With thinking disabled (`BENCH_THINKING=0`) the
per-step cost dropped ~2.3×, and the real-site Trendyol cart task passed in 13 steps (~439 s);
that discovery replays deterministically in ~30 s with no model at all.

## How it works

1. Chrome is launched with `--remote-debugging-port=<port>` and **stays open** (detached).
2. Every later tool call attaches to the existing Chrome via CDP (`debugger_address`) — no new
   browser per call.
3. The page dump marks only visible/interactive elements with `data-tw-ref` and produces short text.
4. Session, window, and cookies persist across calls.

### Two Chrome modes

| | Managed (isolated) | Existing (your session) |
|---|---|---|
| How | Agent launches Chrome with `--user-data-dir=artifacts/chrome-profile-<port>` | Chrome must already run with `--remote-debugging-port` |
| Pro | Never touches your tabs/cookies | Reuses your logged-in session |
| When | Automation, testing, assistant chat | Continuing work in a portal you are signed into |

`BROWSER_MODE=managed|existing|auto` (default `auto`: attach if the port is open, otherwise launch).

### Port separation

| Consumer | Port | Profile |
|---|---|---|
| OpenCode (this assistant) | `19417` | `artifacts/chrome-profile-19417` |
| LM Studio plugin | `19419` | `artifacts/chrome-profile-19419` |
| Benchmark / replay | `19420` | `artifacts/chrome-profile-19420` |
| selenit / your own Chrome | `19218` | your own profile |

Two servers attaching to the same port will fight over the same Chrome — give every browser MCP
its own port.

> **Warning:** port 19218 is the one selenit uses. If you do not want an agent driving your own
> browser, use a separate port (recommended: **19419**). A normally started Chrome cannot be
> attached to later; remote debugging is mandatory.

## Tools (23)

| Tool | Description |
|---|---|
| `browser_navigate` | Go to a URL, return a compact dump |
| `browser_snapshot` | List interactive elements (`e1`, `e2`, …) |
| `browser_dom` | Compact DOM read: header (URL/title/modal/alert ~400 chars) or element list via `q` — lighter than snapshot |
| `browser_click` | Click by `ref`, CSS `selector`, or visible `text` |
| `browser_find` | Find an element by text, return a clickable ref (long pages) |
| `browser_read` | Read visible page text (summary/translation) |
| `browser_type` | Type into a field (`submit: true` → Enter) |
| `browser_select` | Choose an option from a dropdown |
| `browser_alert` | Read/dismiss a JS alert (`text` reads+closes, `peek` leaves it open) |
| `browser_scroll` | Scroll the page (down/up/top/bottom) |
| `browser_frame` | Enter an iframe / return to the main frame |
| `browser_upload` | Provide a local path to a file input |
| `browser_hover` | Hover an element (menus) |
| `browser_press_key` | enter, tab, escape, arrowdown, … |
| `browser_resize` | Set the window size (consistent rendering) |
| `browser_monitor` | WebDriver BiDi network monitor: requests/responses/console (`action: start/check/wait/stop`, `filter`) |
| `browser_wait_for` | Explicit wait: text, selector, URL, disappearance, element count, or download (`type`) |
| `browser_screenshot` | Save a PNG, return the path |
| `browser_evaluate` | Run JS in the page (result truncated) |
| `browser_history` | back / forward / reload |
| `browser_tabs` | list / switch / close |
| `browser_status` | Connection status |
| `browser_close` | Close the session |

### Safety nets

- **Loop warning:** the same tool+arguments arriving a third time is not executed; a warning is returned.
- **Actionable errors:** "refs are renewed every snapshot", "element is covered", "alert is open";
  a wrong tag on `browser_select` says `this element is not a <select> but a <button>`, and an
  invalid CSS selector returns an example-based hint.
- **Alert hygiene:** `navigate` dismisses an open JS alert; `snapshot`/`read` report it.
- **Shadow DOM:** the dump walks open shadow roots; ref resolution is done in JS (Selenium CSS
  search does not cross shadow boundaries).
- **Modal focus:** while `role=dialog` / `aria-modal` is open, only modal content is listed.
  Modals that carry no role (e.g. `class*="modal|dialog|popup"` covering the screen centre) are
  detected too.
- **Overlay priority:** content of `position:fixed` + high-z-index layers (cookie bars, notices)
  is listed first so the model can dismiss it.
- **Row/card context:** buttons inside table rows are shown as `Edit | 10 · Ada Lovelace · London`;
  repeated `Add to cart` buttons as `Add to cart | CEPFİT Boostar … · 57.97 TL`.
- **Explicit waits:** click/type/select/iframe/download use `Selenium::WebDriver::Wait` (visibility,
  clickability, URL, text, file state). No fixed `sleep`; implicit wait is `0`. Timeouts return a
  message stating what was expected.
- **Lazy load:** if `browser_find` fails, the page is scrolled, DOM/text growth is awaited, and the
  search repeats (max `BROWSER_MCP_LAZY_SCROLLS`, default 8).
- **Downloads:** `browser_wait_for(type: "download", text: "report.pdf")` reads Chrome's
  `downloads-manager` shadow root, waits for `IN_PROGRESS` to finish, and returns the file path.
- **After-click wait:** URL changes are polled briefly with explicit waits; if a new tab opened,
  the correct 0-based index is suggested and a `TABS` line is added while multiple tabs exist.
- **Dump priority (form → primary action → overlay → card → rest):** the element budget is spent
  on the controls whose absence is fatal, not on DOM order.
  - Form fields (`input`, `textarea`, `select`) come first. Measured on n11.com: a content-dense
    home page has **485 interactive elements**; card-first ordering filled all 40 slots with product
    cards and the header **search box never appeared in the dump at all**.
  - Primary action buttons (`Sepete Ekle` / `Add to cart` / `Buy now` / `Save` / `Submit`, plus
    `add-to-cart` / `primary` class hints) come second. Measured on an n11 product page:
    recommendation carousels consumed every slot and the page's own cart button
    (`BUTTON.add-to-cart-btn`) was missing; after the fix it is `e2`.
- **Settle after navigate:** `document.body` existing does not mean the SPA finished rendering, so
  `navigate` polls the interactive-element count until **two consecutive samples agree** (ceiling
  ~0.9 s). Measured on n11: without it the navigate dump omitted the search box while a snapshot
  one second later included it — the model only ever sees the first dump.
- **JS-driven submit escalation:** `submit: true` climbs a ladder and stops when the URL changes —
  1) `Enter`, 2) closest form `requestSubmit()` or nearest submit-like control clicked via **JS**
  (works on `<i>` icons and overlay-covered nodes where Selenium click refuses), 3) **URL scheme**:
  try `/arama?q=`, `/search?q=`, `/?s=`, `/search?s=` and accept the first that both changes the URL
  and yields a populated body (≥10 interactive elements, so a soft-404 page of chrome is rejected).
  Measured on n11.com: no `<form>`, no button, no suggestion list, and both Selenium `send_keys(:enter)`
  and a hand-dispatched native `KeyboardEvent` were swallowed; only `/arama?q=bluetooth+kulaklik`
  produced results (42 product links).

### `browser_wait_for` types

| `type` | Waits for | Fields |
|---|---|---|
| `text` (default) | Text in the page body | `text` |
| `selector` | A CSS selector to become visible | `selector` |
| `url` | A URL fragment | `value` or `text` |
| `gone` | A selector to disappear | `selector` |
| `count` | At least N visible elements | `selector`, `value` |
| `load` | `document.readyState == complete` | — |
| `download` | Chrome download state + file | `text` (file-name fragment) |

## Policy and audit

```bash
BROWSER_MCP_ALLOWED_HOSTS="example.com,portal.company.com"   # empty = all
BROWSER_MCP_REQUIRE_APPROVAL=true                            # require confirmation for risky actions
BROWSER_MCP_ALLOW_DATA=true                                  # allow data: URLs (default true)
```

With `BROWSER_MCP_REQUIRE_APPROVAL=true`, buttons labelled delete/pay/send do not run without
`confirm=true`; the model has to ask you first.

Every tool call is appended to `artifacts/audit-YYYYMMDD.jsonl` (passwords/tokens masked, long
text truncated).

## Install

**One command** — checks/installs Ruby, the gem and Chrome, then registers the MCP server:

```bash
curl -fsSL https://raw.githubusercontent.com/livdemirci/selenit-mcp/main/install.sh | bash
```

If Ruby 3.2+ is already present (or you prefer npm only):

```bash
npx -y selenit-mcp setup lmstudio --install     # ruby+gem+Chrome check/install + config
npx -y selenit-mcp doctor                       # report ruby/gem/Chrome/config/port
```

`--install` attempts `brew install ruby` / `gem install selenium-webdriver` when something is
missing; add `--install-chrome` to also install Chrome via Homebrew. Without `--install`, `setup`
only writes the config and tells you what is missing.

**npm only** — Ruby sources ship inside the package:

```bash
gem install selenium-webdriver        # requirement (not bundled)
npx selenit-mcp                        # stdio MCP server — prints a "ready" line
```

MCP client config: `"command": "npx", "args": ["-y", "selenit-mcp"]`. Set `SLENIT_RUBY` in `env`
to pin a specific Ruby.

**From source:**

```bash
git clone https://github.com/livdemirci/selenit-mcp.git
cd selenit-mcp
gem install selenium-webdriver
ruby bin/selenit-mcp
```

Requirements: Ruby 3.2+, Google Chrome, and the `selenium-webdriver` gem.

### Client configuration

Claude Desktop / any MCP client (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "selenit-browser": {
      "command": "npx",
      "args": ["-y", "selenit-mcp"],
      "env": { "BROWSER_MCP_PORT": "19419", "BROWSER_MCP_MAX_ELEMENTS": "20" }
    }
  }
}
```

LM Studio — let the package write the entry itself (it resolves the absolute Ruby path, the
package path, and backs up your existing config):

```bash
npx -y selenit-mcp setup lmstudio                 # default port 19419
npx -y selenit-mcp setup lmstudio --port 19418 --max-elements 20
npx -y selenit-mcp setup print                    # JSON only, paste it yourself
```

Then restart LM Studio (or toggle **Integrations**). Manual equivalent — an absolute Ruby path
and `cwd` are required because a GUI-launched LM Studio may not have rbenv shims on `PATH`:

```json
{
  "mcpServers": {
    "selenit-browser": {
      "command": "/Users/you/.rbenv/versions/3.4.8/bin/ruby",
      "args": ["/path/to/selenit-mcp/server.rb"],
      "cwd": "/path/to/selenit-mcp",
      "env": { "BROWSER_MCP_PORT": "19419", "BROWSER_MCP_MAX_ELEMENTS": "40" }
    }
  }
}
```

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `BROWSER_MCP_PORT` | `19218` | CDP port (19419 recommended) |
| `BROWSER_MODE` | `auto` | `managed` / `existing` / `auto` |
| `BROWSER_MCP_PROFILE_DIR` | `artifacts/chrome-profile-<port>` | Managed profile directory |
| `BROWSER_MCP_MAX_ELEMENTS` | `40` | Max elements per dump (20–40 for Gemma) |
| `BROWSER_MCP_HEADLESS` | `false` | Headless managed browser |
| `BROWSER_MCP_WAIT` | `10` | Default explicit wait timeout (s) |
| `BROWSER_MCP_LAZY_SCROLLS` | `8` | Lazy-load scroll attempts for `browser_find` |
| `BROWSER_MCP_DOWNLOAD_DIR` | `artifacts/downloads-<port>` | Managed download directory |
| `BROWSER_MCP_SCREENSHOT_DIR` | `./screenshots` | Screenshot directory |
| `BROWSER_MCP_ARTIFACT_DIR` | `./artifacts` | Audit log directory |
| `BROWSER_MCP_ATTACH_TIMEOUT` | `13` | Attach upper bound; restarts an isolated Chrome on hang |
| `BROWSER_MCP_FAILFAST` | `1.25` | Reject a missing selector this fast when the page is loaded |
| `BROWSER_MCP_TOAST_WAIT` | `0.6` | Post-action toast harvest window (`0` disables) |

## Testing and benchmarking

```bash
python3 testapp/server.py 8765 &        # local scenario pages
ruby smoke_test.rb                      # 32/32 checks
ruby replay.rb filter                   # scenario replay (real site scenarios too)
```

`benchmark.rb` feeds the tool schemas to LM Studio's local OpenAI-compatible API, executes the
model's calls against the real MCP server, and verifies the resulting page state:

```bash
ruby benchmark.rb                      # all tasks
ruby benchmark.rb deep select          # selected tasks
BENCH_MODEL=google/gemma-4-e4b BENCH_MAX_STEPS=10 ruby benchmark.rb
BENCH_THINKING=0 BENCH_MAX_TOKENS=1600 ruby benchmark.rb sepet
```

Hard scenarios in `testapp/`: `login`, `filter`, `frame`, `shadow`, `upload`, `newtab`, `dynamic`,
`download`.

### Measured results (Gemma E4B, 17 tasks)

| Task | Steps | Time | Task | Steps | Time |
|---|---|---|---|---|---|
| link | 2 | 28s | login | 4 | 43s |
| form | 3 | 52s | filter | 5 | 69s |
| wiki | 4 | 46s | frame | 7 | 76s |
| hn | 1 | 22s | shadow | 4 | 54s |
| deep | 3 | 30s | upload | 4 | 64s |
| read | 2 | 36s | newtab | 5 | 68s |
| select | 2 | 25s | dynamic | 5 | 78s |
| alert | 3 | 32s | stale | 3 | 35s |
| download | 3 | 34s | — | — | — |

Real-site task `sepet` (Trendyol: search → sort by lowest price → add to cart → verify price in the
cart): **1/1 passed** with Gemma E4B, thinking off, 13 steps (~439 s); replay without a model ~30 s.

## Explore → freeze → replay

So the LLM does not pay on every run, a successful exploration becomes deterministic:

1. `benchmark.rb` saves the steps and a durable CSS selector per element into `scenarios/<task>.json`
   (`shadow::host||inner` for shadow DOM).
2. `replay.rb` replays the same steps **without a model** and applies the same check.
3. `export_rspec.rb` converts the scenario into a Selenium + RSpec spec with Page Objects and shared
   explicit waits (`try_for`), runnable in CI or from selenit (F11).

```bash
ruby replay.rb filter                 # model-free replay
ruby export_rspec.rb filter           # generates spec/generated/filter_spec.rb
BROWSER_MCP_PORT=19419 rspec spec/generated/filter_spec.rb
```

All 18 scenarios replay model-free in ~60 s total; the 17 generated specs pass in ~6.7 s.

## Honest comparison with Playwright MCP

**Where this server wins**

| Topic | This server | Playwright MCP |
|---|---|---|
| Attaching to an existing browser | CDP attach to your open Chrome (the selenit F11 approach) | Manages its own browser instance |
| Small-model (4B) efficiency | 40-element ref list, ~4 KB cap, row/card context, modal focus | Large a11y tree, more tokens |
| Audit / safety | `audit-*.jsonl` + host allowlist + approval for risky actions | Policies live in the client |
| Loop protection | Same call 3× → warning, never locks up | None |
| Discovery → regression | `scenarios/*.json` → `replay.rb` → `export_rspec.rb` | None (needs a model/scenario each run) |
| Shadow DOM / iframes | Dumps + refs + `browser_frame`, `shadow::host||inner` selectors | Supported (ref-based) |
| Waiting / downloads | Condition-based explicit waits, lazy-load sweep, download state | Strong auto-waiting; no explicit download-completion wait |
| Network observation | `browser_monitor` (WebDriver BiDi): requests/responses/console + filter | Richer interception (mocking/aborting) |

**Where Playwright MCP wins**

- Trace viewer, video/screenshot artifacts; request mocking (BiDi `browser_monitor` only observes).
- Multiple browsers (Firefox/WebKit), mature auto-waiting, less discipline needed with large cloud models.
- Bigger ecosystem and maintenance continuity.

Summary: for **general-purpose cloud models with rich artifacts**, Playwright MCP is stronger. For
**small local models + an existing session + auditing + deterministic regression**, this server fits better.

## Tips for Gemma E4B

- Ask for **one step** at a time: `browser_navigate` → `browser_snapshot` → `browser_click`.
- Prefer `ref` (`e3`); give a CSS selector only when necessary.
- On long pages use `browser_find` or `browser_read`; never ask for full HTML.
- Keep `BROWSER_MCP_MAX_ELEMENTS` between 20 and 40.
- Short system prompt:

```text
You are an agent doing browser automation. Call one tool per step.
Use browser_snapshot to understand the page and select elements by refs like e1, e2.
Never request long HTML or full page text; answer briefly.
```

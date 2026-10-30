# selenit-mcp

**Browser automation built for small local models.**
Selenium-powered MCP server · compact `e1`-style snapshots · loop protection · deterministic replay · attaches to your own Chrome.

[![npm](https://img.shields.io/npm/v/selenit-mcp.svg)](https://www.npmjs.com/package/selenit-mcp)
[![license](https://img.shields.io/npm/l/selenit-mcp.svg)](LICENSE)
[![Ruby 3.2+](https://img.shields.io/badge/ruby-3.2%2B-CC342D)](https://www.ruby-lang.org)
[![MCP](https://img.shields.io/badge/MCP-23%20tools-blue)](https://modelcontextprotocol.io)

Most browser MCP servers are designed for large cloud models: rich accessibility trees, verbose
output, plenty of tokens to spare. `selenit-mcp` goes the other way. It emits compact,
reference-based page dumps (`e1`, `e2`, …), guards against the failure modes small models
actually hit, and attaches to a real Chrome over CDP — so a 4B model running locally can
navigate, fill forms, and complete multi-step tasks without drowning in context.

> 🇹🇷 Turkish documentation (detailed engineering log): [TURKCE.md](TURKCE.md)

## Contents

- [Head-to-head benchmark](#head-to-head-benchmark-against-playwright-mcp)
- [Quick start](#quick-start)
- [Why small models need a different tool surface](#why-small-models-need-a-different-tool-surface)
- [Tools](#tools-23)
- [Safety nets](#safety-nets)
- [Explore → freeze → replay](#explore--freeze--replay)
- [Policy and audit](#policy-and-audit)
- [Configuration](#configuration)
- [Reproducing the benchmark](#reproducing-the-benchmark)
- [Honest comparison with Playwright MCP](#honest-comparison-with-playwright-mcp)

## Head-to-head benchmark against Playwright MCP

Same model, same machine, same task, same scoring rule, both tools with their own native tool
surface. Task: *open the site, search for a term, report the first result heading as
`title | url`*. A run passes only if a claimed heading's words actually exist in the live page
text — invented headings are counted as failures, not successes.

<!-- BENCH:BEGIN -->
**Run 2026-10-30 · `google/gemma-4-e4b` (LM Studio, temperature 0, thinking off, max_tokens 1200, 16-step budget, 1 run per site, tool-output cap 2,000 chars/call)**

| Tool | Tasks passed | Median steps | Median time | Median tool-output chars | Median tokens (prompt + completion) | Tokens / step |
|---|---|---|---|---|---|---|
| **selenit-mcp** | **2/5** | 3.0 | 67.7 s | 6,000 | 15,542 + 1,034 = **16,576** | 5,225 |
| Playwright MCP | **0/5** | 3.0 | 100.4 s | 751 | 16,363 + 1,871 = **18,234** | 5,896 |

| Site | Selenit | Playwright MCP | What happened |
|---|---|---|---|
| Wikipedia (EN) | **PASS** 4 steps, 72 s | FAIL 16 steps, 391 s | Playwright targeted `searchbox "Search Wikipe…"` and its `browser_type` errored 9 times on the same target — never answered. |
| npm (EN) | **PASS** 3 steps, 54 s | FAIL 3 steps, 76 s | Playwright waited for a search field that the SPA injects; gave up and reported it could not proceed. |
| GitHub (EN) | FAIL 3 steps, 61 s — *hallucinated* | FAIL 11 steps, 302 s | Selenit claimed "Repository search results · GitHub" — that page text did not exist. Caught by the scorer, not hidden. |
| Hürriyet (TR) | FAIL 10 steps, 495 s | FAIL 3 steps, 100 s | Selenit burned the whole step budget returning an empty answer. |
| Trendyol (TR) | FAIL 3 steps, 68 s — *hallucinated* | FAIL 2 steps, 41 s | Selenit claimed an "Arama Sonuçları - Trendyol" heading that was not on the page. |

**What this run actually shows.** Selenit completed 2 of 5 tasks where Playwright MCP completed 0 —
the gap is real and it is largest exactly where small models break down: when a tool call errors,
Playwright's surface lets the model retry the same target until the step budget is gone (16 steps,
391 s on Wikipedia), while Selenit's loop guard turns the third identical call into a directive and
the model stops. But **2/5 is not a good result**. Four of the five real-site tasks are unsolved by at
least one side, two Selenit "answers" were fabricated titles (correctly scored as failures), and the
Turkish sites — which need SPA-ready search fields and bot-wall handling — failed on both sides.
Total tokens are within 10% of each other, so this run does **not** support a "Selenit uses fewer
tokens" claim either.

The honest reading: on a 4B model, a tool surface that guards against loops buys task completion, but
it does not yet make live-site search reliable. Treat 2/5 vs 0/5 as a direction, not a verdict, and
re-run with `KOSUM=3` before quoting it anywhere.

Compare with the earlier 5-site run on a large model (`deepseek-v4.1-flash`, `bench/kiyas-deepseek-adil.json`):
**5/5 vs 1/5**, median 4.8 vs 9.2 steps. Same direction, much stronger signal — the tool-surface
effect matters more for weaker models, but a stronger model can still complete the task through a
worse surface.
<!-- BENCH:END -->

**Read this honestly.** These are small-N runs on live websites the author does not control:
site markup changes, rate limits and bot walls move the numbers, and a single run is noisy. Use
`KOSUM=3` for medians you intend to quote. The benchmark does **not** claim Selenium beats
Playwright in general — it claims that a tool surface designed *for* small models changes task
success rate and token burn.

Token accounting: both sides use LM Studio's `usage.prompt_tokens` / `usage.completion_tokens`,
summed over every step of a task. The per-call tool output fed back to the model is capped at
2,000 characters on both sides, so neither side is penalised by a harness limit the other does
not have.

Reported in [this Medium article](https://medium.com/@livdemirci/selenit-mcp-vs-playwright-mcp-what-changes-when-you-design-for-small-models-26a15ab36d5b).

## Quick start

**One command** — checks/installs Ruby, the gem and Chrome, then registers the MCP server:

```bash
curl -fsSL https://raw.githubusercontent.com/livdemirci/selenit-mcp/main/install.sh | bash
```

If Ruby 3.2+ is already present (or you prefer npm only):

```bash
npx -y selenit-mcp setup lmstudio --install     # ruby+gem+Chrome check/install + config
npx -y selenit-mcp doctor                       # report ruby/gem/Chrome/config/port
```

**npm only** — Ruby sources ship inside the package:

```bash
gem install selenium-webdriver        # requirement (not bundled)
npx selenit-mcp                       # stdio MCP server — prints a "ready" line
```

MCP client config: `"command": "npx", "args": ["-y", "selenit-mcp"]`. Set `SELENIT_RUBY` in `env`
to pin a specific Ruby.

**From source:**

```bash
git clone https://github.com/livdemirci/selenit-mcp.git
cd selenit-mcp
gem install selenium-webdriver
ruby bin/selenit-mcp
```

Requirements: Ruby 3.2+, Google Chrome, and the `selenium-webdriver` gem. macOS and Linux are
tested; Windows is not — see [ROADMAP.md](ROADMAP.md).

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

### Two Chrome modes

| | Managed (isolated) | Existing (your session) |
|---|---|---|
| How | Agent launches Chrome with `--user-data-dir=artifacts/chrome-profile-<port>` | Chrome must already run with `--remote-debugging-port` |
| Pro | Never touches your tabs/cookies | Reuses your logged-in session |
| When | Automation, testing, assistant chat | Continuing work in a portal you are signed into |

`BROWSER_MODE=managed|existing|auto` (default `auto`: attach if the port is open, otherwise launch).

### Port separation

Two MCP servers attaching to the same CDP port fight over the same Chrome — give each its own port.

| Consumer | Port | Profile |
|---|---|---|
| Your assistant / coding agent | `19417` | `artifacts/chrome-profile-19417` |
| LM Studio plugin | `19419` | `artifacts/chrome-profile-19419` |
| Benchmark / replay | `19420` | `artifacts/chrome-profile-19420` |
| selenit / your own Chrome | `19218` | your own profile |

> **Warning:** port 19218 is the one selenit uses. If you do not want an agent driving your own
> browser, use a separate port (recommended: **19419**). A normally started Chrome cannot be
> attached to later; remote debugging is mandatory.

## Why small models need a different tool surface

| Design choice | Problem it solves for small models |
|---|---|
| Compact dumps (~1–4 KB, max 40 elements) | Gemma E4B has a small context; raw HTML or full a11y trees blow it up |
| `e1`-style refs, renewed per snapshot | No CSS selectors to invent; fewer hallucinated locators |
| Loop guard (same call 3× → warning, not execution) | Stops the classic scroll/read/snapshot death spiral |
| Modal focus, overlay priority, row/card context | `Save` buttons in a dialog, `Add to cart` on product cards stay distinguishable |
| Explicit waits + actionable errors | "ref is renewed every snapshot", "element is covered", "alert is open" |
| Auto-recovery from JS alerts, stale elements, covered elements | The run continues instead of collapsing mid-task |

**Measured on Gemma E4B** (`google/gemma-4-e4b`, 20 tools, max_tokens 800): **17/17 tasks passed**,
1–7 steps and 22–78 s per task, ~13 min total. Thinking is off by default
(`BENCH_THINKING=0`; set `1` to enable): the per-step cost dropped ~2.3×, and the real-site
Trendyol cart task passed in 13 steps (~439 s);
that discovery replays deterministically in ~30 s with no model at all.

## How it works

1. Chrome is launched with `--remote-debugging-port=<port>` and **stays open** (detached).
2. Every later tool call attaches to the existing Chrome via CDP (`debugger_address`) — no new
   browser per call.
3. The page dump marks only visible/interactive elements with `data-tw-ref` and produces short text.
4. Session, window, and cookies persist across calls.

## Tools (23)

| Tool | Description |
|---|---|
| `browser_navigate` | Go to a URL, return a compact dump (waits out bot-check interstitials) |
| `browser_snapshot` | List interactive elements (`e1`, `e2`, …) |
| `browser_dom` | Compact DOM read: header (URL/title/modal/alert ~400 chars) or element list via `q` — lighter than snapshot |
| `browser_click` | Click by `ref`, CSS `selector`, or visible `text` (`selector` + `text` narrows a repeated list) |
| `browser_find` | Find an element by text, return a clickable ref (long pages) |
| `browser_read` | Read visible page text (summary/translation) |
| `browser_type` | Type into a field (`submit: true` → Enter) |
| `browser_select` | Choose an option from a dropdown (native `<select>` or custom combobox/menu) |
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

- **Loop warning:** the same tool+arguments arriving a third time is not executed **when the result
  and page state (URL + text hash) are unchanged**; legitimate repetition (`+` four times, paging)
  is allowed, and read-only tools (`snapshot`, `dom`, `read`, `find`, `wait_for`, `status`,
  `screenshot`, `evaluate`) are exempt. The response carries the page title/URL plus a *directive*
  telling the model what to do instead (stop and answer, stop scrolling, try another element) rather
  than the old generic "try browser_snapshot" — which, on a `browser_snapshot` loop, told the model
  to repeat the very call that was looping. Measured on n11: the old wording let Gemma repeat
  `browser_snapshot` 6× for 128 s and never answer; with the directive it stopped and answered
  correctly in 3 steps.
- **Bot-check interstitials:** if `navigate` lands on a "Just a moment / Bir dakika lütfen /
  Checking your browser" screen, it waits up to `BROWSER_MCP_CHALLENGE_WAIT` (default 20 s) for the
  content to appear and only then returns the dump; otherwise it explains what to do.
- **Hidden duplicates:** when a CSS selector matches several nodes, the first *visible* one is used
  (menus often contain hidden copies of the same link).
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
  repeated `Add to cart` buttons as `Add to cart | CEPFİT Boostar … · 57.97 TL`. Card detection
  does not rely on class names alone: the nearest ancestor that shows a price-like string
  (`1.234,56 TL`, `$19.99`, …) and has at most 4 controls is used.
- **Control priority:** sort/filter controls (`aria-haspopup`, `role=combobox`, text/class
  containing `sort|filtre|filter`) are listed before product cards, so a 40-item dump still
  contains "Sort by".
- **Custom dropdowns:** `browser_select` also handles comboboxes that are not `<select>`
  (`role=combobox`, `b-select`, `dropdown`): it opens the widget, matches the option text and
  clicks it; on a miss it lists the visible options.
- **Controlled inputs:** `browser_type` falls back to the native value setter + `input`/`change`
  events when a React/Vue field swallows keystrokes; number fields are blurred to commit.
- **Explicit waits:** click/type/select/iframe/download use `Selenium::WebDriver::Wait` (visibility,
  clickability, URL, text, file state). No fixed `sleep`; implicit wait is `0`. Timeouts return a
  message stating what was expected.
- **Lazy load:** if `browser_find` fails, the page is scrolled, DOM/text growth is awaited, and the
  search repeats (max `BROWSER_MCP_LAZY_SCROLLS`, default 8).
- **Downloads:** `browser_wait_for(type: "download", text: "report.pdf")` reads Chrome's
  `downloads-manager` shadow root, waits for `IN_PROGRESS` to finish, and returns the file path.
- **After-click wait:** URL changes are polled briefly with explicit waits; if a new tab opened,
  the correct 0-based index is suggested and a `TABS` line is added while multiple tabs exist.
- **Dump priority (form → sort/filter → primary action → overlay → card → rest):** the element budget is spent
  on the controls whose absence is fatal, not on DOM order.
  - Form fields (`input`, `textarea`, `select`) come first. Measured on n11.com: a content-dense
    home page has **485 interactive elements**; card-first ordering filled all 40 slots with product
    cards and the header **search box never appeared in the dump at all**.
  - Sort/filter controls (`aria-haspopup`, `role=combobox`, text/class containing `sort|filtre|filter`)
    come next. Measured on Boyner: the 20k-product category page pushed "Önerilen Sıralama" past the
    40-item budget, so the model could never sort.
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
- **Search affordances that are not `<input>`:** some sites open search as an overlay, so no visible
  `<input>` exists until you click a text-less icon button. Measured on Trendyol: the control is
  `button[data-testid="suggestion-placeholder"]` (aria-label "Open search"); clicking it injects the
  real `<input>`. `birincil_eylem` therefore treats `data-testid` / `aria-label` / `class` matching
  `search|suggestion-placeholder|search-icon` as primary **even with no text**, otherwise the button
  is ranked behind product cards and never enters the dump. After the fix it is `e1`:
  `e1 button Ürün, kategori veya marka ara`.
- **`browser_dom` modal flag matches `snapshot.js`:** the DOM summary used to report
  `modal: !!document.querySelector("[class*=modal i],[class*=dialog i],[role=dialog]")` — presence
  only, no visibility or geometry. Measured on Trendyol: a hidden `modal`-classed node made
  `modal: true` while the real candidate was a 474×40 px cookie link that does not cover the screen
  centre, so the model was told a modal was open and chose the wrong strategy. Both code paths now
  require: visible (rect > 0, not `display:none` / `visibility:hidden` / `opacity:0`), covers
  `elementFromPoint(centre)`, and contains ≥1 visible interactive child.
- **Overlay-gated inputs (`pointer-events: none`):** some sites render the search field with
  `pointer-events: none` and put a plain `DIV` on top of it; clicking that DIV unhides the real
  field. Measured on Hepsiburada: input rect 418×52, `display: inline-block`, `opacity: 1`, yet
  `pointerEvents: none` and `elementFromPoint(centre)` returned `DIV.initialComponent-…`, so
  Selenium `send_keys` raised `ElementNotInteractableError`. Fixed by `type_click_ac` (click the
  covering node, then re-resolve the ref — the click rewrites the DOM, so the old element handle goes
  stale) plus `js_yaz` (native prototype `value` setter + `input`/`change` events, required by
  React/Vue-controlled fields). After the overlay opens, a real `Enter` works and is preferred over
  URL guessing.
- **`browser_read` prefers the main content over the page chrome:** `body.innerText` starts with the
  header/nav, so the `max` character budget was consumed by menu links before any result appeared.
  Measured on Hepsiburada: `browser_read` returned only "Siparişlerim / Kampanyalar / Hepsiburada
  Premium…" — zero product names — while `[class*="productList"]` held an 8 509-character real
  listing. `read` now tries `[class*=productList]`, `[class*=product-list]`, `[class*=searchResult]`,
  `main`, `[role=main]`, `#content` first and uses the container text when it exceeds 200 chars.
  After the fix the same call starts with `Pensan Büro Mavi Tükenmez Kalem…`.
- **`browser_read` appends a DURUM (status) line:** result/item count plus remaining scroll distance,
  so the model does not have to scroll to discover what it already has. Measured on n11: Gemma
  scrolled 3× (third blocked by the loop guard) before reading the price that was already in the
  `browser_type` output — the status line makes that information explicit.
- **URL-scheme fallback must validate the destination, not just the URL:** `submit_via_url` accepted
  any candidate that changed the URL and had ≥10 interactive elements. Measured on Hepsiburada:
  `/arama?q=kilim` is a **404 page** with 21 category links, and `/?s=kilim` renders the **home page**
  with 124 product links — both passed the old check. Now each candidate is rejected when
  `hata_sayfasi?` matches (title or first 400 chars of body: `404`, `bulunamadı`, `sayfamız yok`,
  `not found`) **and** unless `arama_terimi_sayfada?` finds a token of the query in the first 3 000
  chars of body text. The working schemes found so far: `/arama?q=` (n11), `/sr?q=` (Trendyol),
  `/ara?q=` (Hepsiburada — note the single **r**), `/search?q=` (GitHub), `wiki/` (Wikipedia).

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

## Explore → freeze → replay

So the LLM does not pay on every run, a successful exploration becomes deterministic:

1. `benchmark.rb` saves the steps and a durable CSS selector per element into `scenarios/<task>.json`
   (`shadow::host||inner` for shadow DOM).
2. `replay.rb` replays the same steps **without a model** and applies the same check.
3. `export_rspec.rb` converts the scenario into a Selenium + RSpec spec with Page Objects and shared
   explicit waits (`try_for`), runnable in CI.

```bash
ruby replay.rb filter                 # model-free replay
ruby export_rspec.rb filter           # generates spec/generated/filter_spec.rb
BROWSER_MCP_PORT=19419 rspec spec/generated/filter_spec.rb
```

All 18 scenarios replay model-free in ~60 s total; the 17 generated specs pass in ~6.7 s.

## Policy and audit

```bash
BROWSER_MCP_ALLOWED_HOSTS="example.com,portal.company.com"   # empty = all
BROWSER_MCP_REQUIRE_APPROVAL=true                            # require confirmation for risky actions
BROWSER_MCP_ALLOW_DATA=true                                  # allow data: URLs (default true)
```

With `BROWSER_MCP_REQUIRE_APPROVAL=true`, buttons labelled delete/pay/send do not run without
`confirm=true`; the model has to ask you first.

Every tool call is appended to `artifacts/audit-YYYYMMDD.jsonl` (passwords/tokens masked, long
text truncated). See [SECURITY.md](SECURITY.md) for the threat model.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `BROWSER_MCP_PORT` | `19218` | CDP port (19419 recommended) |
| `BROWSER_MODE` | `auto` | `managed` / `existing` / `auto` |
| `BROWSER_MCP_PROFILE_DIR` | `artifacts/chrome-profile-<port>` | Managed profile directory |
| `BROWSER_MCP_MAX_ELEMENTS` | `40` | Max elements per dump (20–40 for Gemma) |
| `BROWSER_MCP_HEADLESS` | `false` | Headless managed browser |
| `BROWSER_MCP_WAIT` | `10` | Default explicit wait timeout (s) |
| `BROWSER_MCP_CHALLENGE_WAIT` | `20` | Max wait for a bot-check interstitial to clear (s; `0` disables) |
| `BROWSER_MCP_LAZY_SCROLLS` | `8` | Lazy-load scroll attempts for `browser_find` |
| `BROWSER_MCP_DOWNLOAD_DIR` | `artifacts/downloads-<port>` | Managed download directory |
| `BROWSER_MCP_SCREENSHOT_DIR` | `./screenshots` | Screenshot directory |
| `BROWSER_MCP_ARTIFACT_DIR` | `./artifacts` | Audit log directory |
| `BROWSER_MCP_ATTACH_TIMEOUT` | `13` | Attach upper bound; restarts an isolated Chrome on hang |
| `BROWSER_MCP_FAILFAST` | `1.25` | Reject a missing selector this fast when the page is loaded |
| `BROWSER_MCP_TOAST_WAIT` | `0.6` | Post-action toast harvest window (`0` disables) |

## Reproducing the benchmark

```bash
# 1) local scenario pages + unit checks (no model needed)
python3 testapp/server.py 8765 &
ruby smoke_test.rb                      # 38/38 checks

# 2) head-to-head against Playwright MCP (needs LM Studio's OpenAI-compatible server on :1234
#    and Node/npx for @playwright/mcp)
KOSUM=1 ruby kiyas.rb                   # 5 live sites, ~20 min
KOSUM=3 SITE_FILTER=wikipedia ruby kiyas.rb
BENCH_MODEL=minicpm5-2b ruby kiyas.rb
```

`kiyas.rb` writes `bench/kiyas-<model>-<timestamp>.json` (every step's trace, the page text used for
scoring, and token counts) plus a paste-ready `.md` summary. Failures are preserved in the JSON — the
suite never silently drops a bad run.

`benchmark.rb` runs the task set against LM Studio without the comparison side:

```bash
ruby benchmark.rb                      # all tasks
ruby benchmark.rb deep select          # selected tasks
BENCH_MODEL=google/gemma-4-e4b BENCH_MAX_STEPS=10 ruby benchmark.rb
BENCH_THINKING=0 BENCH_MAX_TOKENS=1600 ruby benchmark.rb sepet
```

Hard scenarios in `testapp/`: `login`, `filter`, `frame`, `shadow`, `upload`, `newtab`, `dynamic`,
`download`.

### Measured results (Gemma E4B, 17 local tasks)

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

## Honest comparison with Playwright MCP

**Where this server wins**

| Topic | This server | Playwright MCP |
|---|---|---|
| Attaching to an existing browser | CDP attach to your open Chrome | Manages its own browser instance |
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

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Especially useful right now:
benchmark runs on models we have not measured yet (Qwen 3.5 4B/9B, LFM 1.7B, Hermes), Windows
install reports, and real-site failure traces with the JSON attached.

## License

MIT — see [LICENSE](LICENSE).

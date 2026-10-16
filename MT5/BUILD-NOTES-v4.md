# GeneralMacro.mq5 v4.00 — Build Notes
Date: 2026-10-16. File: `GeneralMacro.mq5` (1,977 lines, single self-contained EA).
Base: `GoldMacroStandalone.mq5` v2.00 (795 lines) + design in `general-macro-ea-update-plan-2026-10-16.md` (§3, §4b).
**It places no orders.** It is a bias + framework + gate dashboard, exactly like the original.

> ⚠️ **2.00 vs 3.10 caveat:** this build is based on the **2.00 source Mazi provided and directed us to build on**. The compiled .ex5 he runs reports v3.10; if that build contains changes not present in the 2.00 source, they are NOT in v4.00. Reconcile by diffing behavior on a gold chart (bias calls should match v2.00 exactly; see "Backward compatibility").

---

## 1. What was kept from v2.00 (verbatim or near-verbatim)
- **Gold factor engine, untouched:** the same 8 factors (DXY 2.0 inverse, US 10Y ^TNX 2.0 inverse, 13-wk bill ^IRX 1.0 inverse, USDJPY 1.0 inverse, VIX 0.75 direct, SPY 0.5 inverse, WTI 0.35 direct, Silver 0.5 direct), the same noise band (0.12%, 5-day ×1.4), the same 1d/5d-agreement scoring (`ScoreFac`), thresholds ±0.28, conviction formula (|norm|/0.9 × 100), and the same caps: NEUTRAL ≤ 40, DXY/yields disagreement ≤ 55, news blackout ≤ 25, dollar-squeeze −0.75 raw, hawkish/dovish surprise tilt ±0.55 (prints from the last 6h).
- **Chicago clock + DST code**, the 6 PM CT (Asia) / 7 AM CT (pre-NY) fetch schedule, weekend skips, Refresh button, bias-change Alert, 20s timer.
- **WebRequest layer** (`HttpGet`/`FetchYahoo`/`ParseCloses`/`Pct`), JSON helpers, ISO date parsing, surprise classifier.
- **Panel helpers** (`Rect`/`Lab`/`Wrap`) and the panel's visual style.
- **Publishing:** `GoldBias_*` GlobalVariables and `gold_bias.ini` — see §6 for when they are written.

## 2. What was added
- **Currency legs (8):** USD, EUR, GBP, JPY, CHF, CAD, AUD, NZD, each with a price score + ladder value → total strength.
- **On-dashboard Strength Ladder** with +/− buttons per currency row, persisted in GlobalVariables (see §5). *Spec change during the build, at Mazi's direction: the ladder.csv idea was dropped entirely — no file reading anywhere in v4.00.*
- **Pair bias engine** for any watchlist symbol from its two currency legs; XAUUSD keeps the gold factor engine as primary.
- **Technical/framework layer** (per symbol, D1, from terminal history): BB(100) + SMA(200) wall, band-to-band Fibonacci (50 / 61.8 / 78.6), regime label, opportunity-zone flag, failure-forecast stop, two targets, live R:R, 0–4 confluence score.
- **The gate (Why/Where/When/What)** for the chart symbol with a SETUP VALID / NO TRADE verdict naming the first failing leg.
- **Risk block:** conviction grades (A/B/C) → risk % tiers, broker-tick-based position sizing, max-exposure ledger over open positions, worst-case vs firm daily-loss limit.
- **Watchlist dashboard:** all watchlist pairs ranked on one panel; chart-symbol detail (framework + gate + risk) below it.
- **Per-pair news blackout:** the calendar country filter was widened from USD/CNY/EUR to all G10 (USD, EUR, GBP, JPY, CHF, CAD, AUD, NZD, CNY).
- **`general_macro.ini`** + per-symbol GlobalVariables (see §6).

## 3. What changed vs v2.00 (behavioral notes)
- `FetchNews` now fills a shared global calendar (`g_news`) with all G10 high-impact events. **Gold parity is preserved deliberately:** `ApplyNewsAndBias` skips every non-USD/CNY/EUR event, so the gold next-event, blackout, and surprise tilt see exactly the event set v2.00 saw. Per-pair blackout/conviction caps use the wider set.
- Panel prefix changed `GMB_` → `GM_` so v4 never collides with v2/v3 objects on the same chart.
- Panel defaults widened/tallened (430×420 → 520×1060) to fit the watchlist + ladder + framework + gate + risk blocks. Adjust `InpWidth`/`InpPanelH` if it crowds a small screen.
- On non-gold charts, the playbook block shows generic pair lines (blackout warning, session lines, macro side, regime-change warning) instead of the gold-specific `BuildPlaybook` text, which still drives gold charts and `gold_bias.ini`.
- Technicals, gate, and ladder effects refresh on the 20s timer; Yahoo/calendar fetches still happen only on the schedule, on attach, or on Refresh.

## 4. Formulas (the definitions this build implements)
- **Factor/currency agreement score:** s1 = SignMove(pct1d, direction, 0.12), s5 = SignMove(pct5d, direction, 0.168). If both 0 → 0; if one is 0 → the other; if they agree → that sign; if they disagree → 0.
- **Currency price score:** agreement score of the currency's USD cross on Yahoo daily closes — EURUSD (EUR up = cross up), GBPUSD, AUDUSD, NZDUSD direct; USDJPY, USDCHF, USDCAD inverted (cross up = that currency weakens); USD uses DXY. USD and JPY snapshots are reused from the gold factor fetches when fresh (saves duplicate calls).
- **Currency strength** = price score (−1..+1) + ladder (−2..+2), clamped to −3..+3.
- **Pair bias:** diff = strength(base) − strength(quote) ∈ −6..+6; norm = diff / 6; LONG if norm ≥ +0.28, SHORT if norm ≤ −0.28, else NEUTRAL (same thresholds as gold). Conviction = min(100, |norm| / 0.9 × 100), NEUTRAL capped at 40, pair-blackout capped at 25.
- **Bands:** basis = SMA of the last 100 **closed** D1 closes; upper/lower = basis ± 2 × population stdev of those closes. SMA200 over the last 200 closed closes. Basis slope compares vs the basis 5 bars earlier (±1% of band range = flat). Price = live bid.
- **Regime:** price > basis = bull, < basis = bear (tie → slope). "REGIME CHANGE" flag when price is beyond SMA200 against the regime (bull but below the 200, or bear but above it); the label also calls out the "deep correction" zone between the 100 and the 200.
- **Fib (band-to-band):** bull — drawn lower band → upper band: fib50 = lower + 0.500R, fib61.8 = lower + 0.382R, fib78.6 = lower + 0.214R (R = upper − lower). Bear mirrored from the upper band. fib50 == basis by construction (the book's drawn-correctly check; it is confluence point #3).
- **Zone:** bull — IN ZONE (BUY) when fib78.6 ≤ price ≤ fib50; OVERSHOT when price < fib78.6; otherwise NO TRADE (mid-range). Bear mirrored.
- **Entry reference:** live price when price is in/past the zone, else fib50 (the zone edge the trade would trigger at).
- **Stop (failure forecast):** re-anchor the fib with its 50% on the traded level (fib78.6); stop sits beyond the extended grid's 61.8 line (0.118R past the level) plus 0.05R breathing room → **stop = fib78.6 ∓ 0.168R**. Never on the level itself.
- **Targets:** T1 = opposite band. T2 = projected 78.6 of the grid shifted onto the opposite band = opposite band ± 0.286R. RR1/RR2 are measured from the entry reference to T1/T2 over the stop distance.
- **Confluence (0–4):** (1) price within 10% of R of a band; (2) price within 10% of R of a fib level; (3) |basis − fib50| ≤ 2% of R; (4) SMA200 on the regime's side.
- **Grade mapping:** **A** = confluence ≥ 3 AND conviction ≥ 55. **B** = confluence ≥ 2 AND conviction ≥ 40. **C** = any other graded setup. No D1 data → no grade.
- **Watchlist rank:** |diff| × 2 if in-zone, else |diff| × 1. For XAUUSD (no ladder diff) the base is 2 + 4 × conviction/100 (range 2–6, comparable to FX diffs).
- **Size:** lots = floor-to-step( risk% × equity ÷ (stop distance ÷ tick size × tick value) ), using `SYMBOL_TRADE_TICK_VALUE/TICK_SIZE` and the symbol's volume min/max/step — so JPY pairs and XAUUSD contract sizes come from the broker, not pip tables.
- **Exposure ledger:** Σ over open positions **with a stop** of |open − SL| ÷ tick size × tick value × volume, as % of equity. Positions without a stop are counted and flagged, never treated as zero risk.

## 5. The ladder (how it works now)
- The panel's ladder section lists all 8 currencies **ranked by total strength**, showing price score (`px`), ladder value (`lad`), and total (`tot`) per row, with **− / + buttons** on each row (range −2..+2, step 1).
- A click updates the value **immediately**, saves it to GlobalVariable `GeneralMacro_Ladder_<CCY>`, stamps `GeneralMacro_LadderStamp` with the click time, and re-derives strengths → pair biases → gate → panel. A plain refresh/timer redraw never touches the stamp.
- **Persistence:** values survive re-attach, terminal restart, and input changes. The `InpLadder*` inputs are **first-run defaults only** — they seed the GlobalVariables the very first time the EA runs; after that, saved values win and the inputs are ignored. To force a reset: delete the `GeneralMacro_Ladder_*` GlobalVariables (MT5 → Tools → Global Variables) and re-attach.
- **Staleness (WHY gate):** if the stamp is more than **8 days** old, the panel flags "STALE" and the WHY leg fails for FX pairs ("ladder STALE — update it with the dashboard buttons"). Gold's WHY does not depend on the ladder (its engine is the factor model); the USD ladder still shows for context.

## 6. Publishing / backward compatibility
- **Always (chart symbol):** `GeneralMacro_<SYM>_BiasN`, `GeneralMacro_<SYM>_Conviction`, `GeneralMacro_<SYM>_Blackout` GlobalVariables (`<SYM>` = chart symbol with non-alphanumerics replaced by `_`), plus `general_macro.ini` in Common Files with every watchlist row (`<SYM>_bias/_bias_n/_conviction/_gap/_zone/_grade/_blackout`), the ladder stamp/stale flag, and all `ladder_<CCY>` values.
- **Gold charts only (chart symbol contains XAU/GOLD):** the legacy `GoldBias_N`, `GoldBias_Conviction`, `GoldBias_NewsBlackout`, `GoldBias_NewsRisk`, `GoldBias_MinutesToNews` GlobalVariables and the **unchanged** `gold_bias.ini` key set — so anything already consuming the v2/v3 outputs keeps working when v4 sits on the gold chart.
- Gold bias parity: on XAUUSD, the displayed bias/conviction/playbook come from the untouched factor engine — v4's gold calls should match v2.00's on the same data.

## 7. Inputs (full list, with defaults)
**Schedule (America/Chicago)** — `InpUsePcLocalAsChicago` true; `InpAsiaHour` 18; `InpNyHour` 7; `InpTimerSec` 20; `InpFetchOnAttach` true; `InpAlertOnUpdate` true.
**News** — `InpBlackoutBeforeMin` 20; `InpBlackoutAfterMin` 15.
**Strength Ladder** — `InpLadderUSD/EUR/GBP/JPY/CHF/CAD/AUD/NZD` all 0 (first-run defaults only, −2..+2).
**Watchlist** — `InpWatchlist` = `XAUUSD,EURUSD,GBPUSD,USDJPY,USDCAD,USDCHF` (max 8 symbols; the chart symbol is auto-added if missing; broker suffixes are auto-resolved, e.g. input `XAUUSD` finds `XAUUSD.pro`).
**Framework** — `InpMinRR` 2.0 (WHAT leg requires RR2 ≥ this).
**Risk** — `InpRiskA` 1.0 (% equity); `InpRiskB` 0.5; `InpRiskC` 0.0 (C = skip); `InpMaxExposurePct` 6.0; `InpFirmDailyLossPct` 5.0.
  - Why 6% and not Jamaal's 30%: the book's 30% max-exposure / 4-2-1 tiers are written for **personal capital**. On a prop account the binding constraint is the firm's daily/total loss limit — breaching it ends the account (it already cost one ACG account). 6% total open risk with A=1.0% / B=0.5% keeps a full book of stopped-out trades inside a typical 5% daily limit with room to spare. Raise it only on a personal account, deliberately.
**Dashboard** — `InpCorner` left-upper; `InpX` 12; `InpY` 24; `InpWidth` 520; `InpPanelH` 1060; `InpShowFactors` true.

## 8. Install steps
1. Copy `GeneralMacro.mq5` into the terminal's `MQL5/Experts/` folder and compile in MetaEditor (F7) — expect 0 errors (see §10 for the verification status).
2. In MT5: Tools → Options → Expert Advisors → tick "Allow WebRequest for listed URL" and add both:
   - `https://query1.finance.yahoo.com`
   - `https://nfs.faireconomy.media`
3. Attach to a chart (any watchlist symbol; attach to XAUUSD if you want the legacy `GoldBias_*` outputs published). AutoTrading can stay OFF — the EA never trades.
4. First run: the ladder seeds from the `InpLadder*` defaults (all 0). Set the week's ladder with the on-screen +/− buttons — that also starts the staleness clock.
5. Optional: confirm `general_macro.ini` appears in the terminal's Common Files folder after the first successful fetch.

## 9. Known limitations
- **The ladder is manual by design.** MQL5 cannot read central-bank language or data-string trends; the fundamental ranking is Mazi's weekly judgment, entered on the dashboard. The price score confirms or contradicts it — a ladder/price disagreement is information, not a bug.
- **RR honesty note:** under band-to-band geometry, RR to T1 (opposite band) from a fib-50 entry is structurally < 2 — the book's 1:2.5–1:6 figures correspond to deep-zone entries measured to the **extended** target. The WHAT gate therefore tests **RR2** (extended target) against `InpMinRR`; RR1 is displayed alongside for honesty.
- **Data dependence:** Yahoo daily closes drive factors/legs (same as v2.00) — a Yahoo outage degrades biases to stale, it does not fabricate them. The technical layer needs ≥ 201 closed D1 bars in the terminal per symbol; new/illiquid symbols show "no D1 history" and fail the gate's WHERE/WHAT legs.
- **News feed:** the faireconomy weekly JSON is the only calendar source (same as v2.00). Surprise classification (hawkish/dovish) is title-keyword based and USD-centric in origin; it feeds only the gold tilt, as before.
- **Exposure ledger** can only sum positions that have stops, and the "worst case vs firm daily limit" line compares open risk to the limit — it does not track the firm's actual day-start balance or floating P&L rules.
- **Crosses outside the 8 ladder currencies** (e.g. SEK, NOK, MXN pairs) get no bias ("-") — their legs aren't scored.
- One panel instance per chart; attaching v4 to several charts duplicates fetches (harmless, same as v2.00 behavior).

## 10. Verification status (honest)
- No MQL5 compiler exists on the build VM, so **this file has not been compiled**. What was done instead: a full static pass — brace/paren/bracket balance verified programmatically (195/195, 1020/1020, 250/250 after stripping strings/comments), no duplicate function definitions, every called function resolves to a definition or a known MQL5 builtin, zero leftover references to the dropped CSV design, and a manual re-read of every function for API signatures and array-indexing direction (CopyRates output is explicitly series-indexed; all SMA/band loops index closed bars 1..N).
- First compile in MetaEditor is still required; treat any warning about the inherited unused `localish` variable in `ApplyNewsAndBias` as expected (it is in v2.00 as well, verbatim).

## 11. Design decisions made where the plan was silent
1. **Pair normalization:** diff/6 against the gold ±0.28 thresholds (plan said "same thresholds style" without a scale).
2. **Closed-bar technicals:** bands/MAs use closed D1 bars only, price is live bid — avoids the forming bar repainting the regime intraday.
3. **Failure-forecast constants:** stop = traded level ∓ (0.118R + 0.05R); T2 = opposite band ± 0.286R — the shifted-grid readings of the book's method, documented in §4.
4. **WHAT gate uses RR2** (see §9) with `InpMinRR` adjustable.
5. **Gold watchlist rank** uses a conviction-scaled base (2–6) since gold has no ladder diff.
6. **Ladder seeding:** first-run inputs → GlobalVariables; stamp initialized at first run (documented in §5) — the alternative (stale until first click) would fail every WHY gate on a fresh install.
7. **Session range-breakout layer** (plan §3D) is represented as guidance lines + the framework veto in the gate, not a separate range-box module — the gate's WHERE/WHEN legs are the enforcement point; a per-symbol session-range box is a v4.1 candidate.

---

# v4.1 — 2026-10-16 (`#property version "4.10"`, 2,790 lines)

Built after Mazi compiled v4.0 and attached it to EURUSD. His test proved the D1 framework layer end-to-end (BB100/fib/regime/zone/confluence all real values), and exposed exactly what this revision fixes. **This section supersedes the v4.0 notes wherever they conflict** — most importantly §5 (the manual ladder is gone) and the pair-normalization line in §4.

## 12.1 Problem 1 — every fetch failed on his terminal, invisibly
On Mazi's terminal all WebRequest sources failed (panel status "error", all factors "—", all price scores 0, gaps +0.0) — almost certainly the WebRequest allowlist on that terminal, but v4.0 gave no way to tell from the chart. v4.1 adds **fetch diagnostics**:
- A `fetch:` line sits high on the panel (directly under the gold-engine regime line, always on screen — the v4.0 error label sat at the panel's bottom edge, off-screen on his chart). Format: `fetch: yahoo 9/15 | ff OK | fred 6/7 | ecb 2/2`; on failure the last error leads so width truncation can never eat it: `fetch: err 4060 http -1 @nfs.faireconomy.media | yahoo 0/15 | ff FAIL | ...`. **Err 4060 = the URL is not on the terminal's WebRequest allowlist** — that one number is the whole diagnosis in the common case.
- `HttpGet` now records every failure (error code, HTTP code, host) into a persistent string that survives redraws until a fully clean cycle clears it. The same line is written to `general_macro.ini` as `fetch_diag=`.
- Line color: muted = all sources answered, amber = partial cycle, red = a source is down.
- **Degradation change:** v4.0 halted the whole cycle when Yahoo failed. v4.1 now proceeds whenever *any* source lives (calendar, FRED, or ECB): framework, gate, fund scores and pair news stay honest, and the panel says which input is stale. It only shows the hard "error" state when literally nothing answered.

## 12.2 Problem 2 — stray objects rendering the literal text "Label"
MQL5 births every `OBJ_LABEL` with the literal text `"Label"` (and `OBJ_TEXT` with `"Text"`). In v4.0 the ladder buttons and the Refresh button only received their text inside the creation branch, so any interrupted create/set sequence left a default-text object on the chart forever. v4.1 fixes all three layers:
- `Lab()` sets the text **first, in the same call sequence as creation**, and ends with a read-back repair (`ObjectGetString` ≠ intended → set again).
- The Refresh button's text is now set on **every** draw, not only at creation.
- A **scrub** runs at init and at the top of every draw: any `GM_`-prefixed label/text object still showing `"Label"`/`"Text"` is blanked and parked at the panel origin (the draw that follows re-sets every owned label anyway). The scrub also **deletes orphaned v4.0 ladder buttons** (`GM_lp*`/`GM_lm*`) if a crashed v4.0 ever left them behind.

## 12.3 SPEC CHANGE — the manual ladder is REMOVED (Mazi, 2026-10-16)
Mazi's words: *"i do not need to manually nudge so let the system do the whole lifting based on actual data."* Deleted entirely: the −/+ button objects and their click handling, `GeneralMacro_Ladder_<CCY>` persistence, `GeneralMacro_LadderStamp`, the `InpLadder*` seed inputs, and every staleness concept tied to them. What remains is the part he liked — the on-screen **ranking table**, now a pure readout:
- Ladder rows read **`px + fund = tot`**: price score (−1..+1) plus the fundamental data-trend score (−3..+3) = total strength, clamped −4..+4, ranked by total.
- **Strength is 100% data-driven.** There is no manual component anywhere in the EA.
- **WHY gate:** the ladder-stale hard fail is gone. Freshness = fundamental data for either leg scored from a fetch within the last 24h. If fundamentals are stale, WHY shows `CAUTION: fundamentals stale - price-led read` but does **not** hard-fail — price may be the only live input through no fault of the setup, and there is no manual stamp left to blame. A NEUTRAL bias still fails WHY, as before.
- §7's input list changes accordingly: the entire "Strength Ladder" group no longer exists; `InpPanelH` default is now **1120** (diagnostics line + two per-pair lines added height).

## 12.4 The fundamental trend engine (Jamaal, TTFX Vol. 1 Ch. 9)
The book's method, mechanized: *don't trade the data — trade the direction the data confirms. One print is a data point; a string of prints is a trend; watch for the turn.* Each of the 8 currencies gets a **FUND score** from the recent string of actuals in its core monthly indicators: inflation (CPI, + PCE for USD), employment (jobs, unemployment), growth (GDP), retail, PMI, and policy-rate direction.

**Sources (all key-less WebRequest GETs; every failure degrades gracefully):**
1. **FRED graph CSV** — `https://fred.stlouisfed.org/graph/fredgraph.csv?id=<SERIES>` (USD depth, ~1100 days): `CPIAUCSL` → YoY %, `PCEPILFE` → YoY %, `UNRATE` → level, `PAYEMS` → monthly change, `RSXFS` → level, `GDP` → quarterly % change, `FEDFUNDS` → level (policy-rate direction).
2. **ECB SDW CSV** — `https://data-api.ecb.europa.eu/service/data/...` (EUR): HICP annual rate (`ICP / M.U2.N.000000.EUR.ANR`) and the MRO policy rate (`FM / M.U2.EUR.4F.G_N_A.SV_CNP`). Implemented defensively: the parser keys off the `TIME_PERIOD`/`OBS_VALUE` header columns, and any failure — unknown key, format drift, empty reply — marks the ECB source off for that cycle (`ecb 0/2` on the fetch line), never a crash. EUR then falls back to accumulated calendar prints.
3. **ForexFactory accumulation (universal)** — the existing faireconomy parse now also records history: for **every** high- or medium-impact event of the 8 currencies with a parseable actual, a point `release-day, currency, indicator_key, actual` is appended to **`ff_history.csv`** (Common Files, format exactly `date,currency,indicator_key,actual`, deduped by date+currency+indicator — a revised value replaces the old one). Each event also seeds its feed `previous` value as the prior point, dated ~30 days earlier (monthly-cadence approximation). The `g_news` set used for blackouts/gold parity is unchanged (high-impact only); accumulation is a side channel of the same parse.
   - `indicator_key` is normalized from the title by keyword: cpi / pce / jobs (nonfarm, payrolls, employment change) / unemp (unemployment, jobless, claims) / gdp / retail / pmi / rate (rate decisions, cash rate, federal funds, …). Actuals like `3.1%`, `215K`, `-0.2%`, `1.2M` are parsed to plain numbers (K/M/B expanded) so a string of prints stays unit-consistent.
   - Series from different sources are **never mixed** (FRED CPI is YoY %; a calendar CPI print may be m/m %). Scoring picks the deepest series per indicator, ties broken fred > ecb > ff.

**Trend / turn scoring (per series, ≥ 2 points to score at all):** flat prints neither extend nor break a run. Using the sequence of nonzero changes:
- Trailing run ≥ 2 in the latest direction → that direction. If the run is young (≤ 2) and replaced an opposite run of ≥ 2 → **TURN** flagged (the book's "two consecutive against the run = new direction forming").
- Latest print against a run of ≥ 3 → **TURN** flagged, direction **keeps** the run's sign ("once is noise").
- Latest print against a run of 2, or no run → direction 0.
- Policy-rate series score on level changes: most recent change is the stance (hike +, cut −); a hold changes nothing; a change against the previous change, within the recent prints, is a TURN.

**Sign mapping (indicator direction → currency strength) and weights:** CPI ↑ → + (hawkish pressure), weight 2.0 · PCE ↑ → +, 1.0 · jobs ↑ → +, 2.0 · unemployment ↑ → −, 1.5 · GDP ↑ → +, 1.0 · retail ↑ → +, 0.75 · PMI ↑ → +, 0.75 · rate hike → + / cut → −, 2.0.
**Currency FUND = 3 × weighted mean of its scored indicator directions → −3..+3.** A currency needs **≥ 2 scored indicators**; below that its ladder row shows **`bldg`** (building) and fundamentals contribute 0 — missing data is never displayed as a neutral 0. A `!` after a fund value means one of its core series flagged a TURN.

**Pair bias v4.1** = tot(base) − tot(quote), totals now spanning −4..+4 per leg, so the same normalize-and-threshold approach is rescaled: `norm = diff / 8`, read against the same ±0.28 thresholds and conviction formula as gold. (The FX watchlist rank base stays |diff|; the gold rank base was rescaled to 2.5 + 5.5 × conv/100 to stay comparable on the wider diff range.) XAUUSD keeps the gold factor engine as primary and now also prints the USD leg's FUND beside it (framework line `fund XAU engine   USD +x.x`, and the WHY line).

## 12.5 Per-pair news (chart-pair section)
Two new lines under the framework block:
- `news USD: Core CPI m/m Tue 13:30 (2d 4h)  |  EUR: Main Refinancing Rate Thu 12:15 (3d 1h)` — the next high-impact event **for each leg**, with weekday/time (terminal-local) and a countdown.
- `fund EUR +1.5   USD bldg  |  tilt hawkish / none` — each leg's FUND (or `bldg`) plus its latest surprise tilt (hawkish/dovish balance of that currency's prints in the last 6h, the gold engine's window). For gold: `fund XAU engine   USD <score>` with the gold set's tilt on the left.
Watchlist rows gained a compact fund marker per row: `f^` (base leg's FUND beats quote's by > 0.75), `fv` (reverse), `f-` (no edge), `f?` (neither leg scored yet); for gold it reads the USD leg.

## 12.6 Install changes
Allowlist is now **four** URLs (Tools → Options → Expert Advisors):
- `https://query1.finance.yahoo.com`
- `https://nfs.faireconomy.media`
- `https://fred.stlouisfed.org` *(new)*
- `https://data-api.ecb.europa.eu` *(new)*
Everything else from §8 stands. First run: expect most non-USD/EUR currencies to read `bldg` (see limitations); USD scores immediately from FRED depth, EUR from ECB if the SDW keys answer.

## 12.7 Honest limitations (v4.1)
- **FF-only currencies build slowly.** GBP, JPY, CHF, CAD, AUD and NZD have no key-less history source in this design, so their FUND is built purely from accumulated calendar prints: this week's prints plus one seeded `previous` point per indicator at first, strengthening over the **first weeks** of running the EA as `ff_history.csv` grows. Until a currency reaches 2 scored indicators it honestly reads `bldg` and pair bias leans on price alone.
- **Indicator-key mixing:** one key can collect sibling prints (e.g. CPI m/m and CPI y/y both land under `cpi`; claims and the unemployment rate both land under `unemp`). Their change-signs usually agree over a run, but the series is a blend, not a single statistical release.
- **The `previous` seed date is approximate** (~30 days before the release; quarterly GDP is really ~90). It orders the seed before the print, which is all the trend math needs, but the stored date is not the true prior release date.
- **ECB keys are best-effort.** If the SDW key or the csvdata format has drifted, the fetch line shows `ecb 0/2` and EUR runs on accumulated prints — by design, not a bug to chase.
- FRED's rate input is `FEDFUNDS` (monthly average effective rate), a smoothed proxy for the policy stance, not the target-range midpoint.
- The surprise tilt stays title-keyword based (as in v2.00) — it colors the per-leg tilt text and the gold engine only; FUND scoring never uses forecast-vs-actual surprises, only the string of actuals, per the book.

## 12.8 Verification status (v4.1, honest — same caveat as §10)
Still **not compiled** (no MQL5 compiler on the build VM). Static pass repeated after all edits: brace/paren/bracket balance **277/277, 1454/1454, 438/438** (string/comment-aware stripper); **no duplicate function definitions**; **every called function resolves** to a definition or a known MQL5 builtin; **zero order-placement functions** (guide-only, as always); grep-verified zero remaining references to the removed ladder mechanics (`InpLadder*`, `LadderClick`, `LoadLadder`, `UpdateLadderAge`, `GeneralMacro_Ladder*`, `GM_lp/lm` creation). First MetaEditor compile remains Mazi's step; the inherited unused-`localish` warning from v2.00 (§10) still applies.

---

# 13. v4.2 (2026-10-16) — ECB fix, stray-label round 2, fund cross-check, plain words

Four fixes from Mazi's live v4.1 test on XAUUSD + EURUSD. `#property version` is now `"4.20"`; the panel title reads `GENERAL MACRO BIAS v4.2`. Panel height default rose 1120 → 1160 (fund-check + legend lines). Everything from §12 stands except where this section overrides it.

## 13.1 Problem 1 — ECB fetch: HTTP 400 → series keys corrected

**Root cause:** the request *shape* was right; the **series keys were malformed**.
- **HICP:** v4.1 sent `ICP / M.U2.N.000000.EUR.ANR`. In the ICP data structure the fifth dimension is **not** the currency — the documented euro-area HICP annual-rate-of-change series is **`ICP.M.U2.N.000000.4.ANR`** (SDW series catalogue: unit PCCH, "HICP — Overall index, Annual rate of change"). ECB answered the bad key with 400.
- **Policy rate:** v4.1's monthly `FM / M.U2.EUR.4F.G_N_A.SV_CNP` is replaced by the documented key-rate series **`FM.B.U2.EUR.4F.KR.MRR_FR.LEV`** (main refinancing operations, level).

**Verified URLs (the exact strings the EA now requests; the builder appends `?format=csvdata&startPeriod=2022-01`):**
- `https://data-api.ecb.europa.eu/service/data/FM/B.U2.EUR.4F.KR.MRR_FR.LEV` — **VERIFIED HTTP 200** with parseable SDMX-CSV: header row contains `TIME_PERIOD` and `OBS_VALUE`; data rows print **on rate-change dates only** (evidence: `2025-02-05 → 2.9`, `2025-03-12 → 2.65`, `2025-04-23 → 2.4`, `2025-06-11 → 2.15`, `2026-06-17 → 2.4`, `2026-09-16 → 2.65`). Change-date-only rows suit the fund engine's rate scoring exactly — every point is a level change.
- `https://data-api.ecb.europa.eu/service/data/ICP/M.U2.N.000000.4.ANR` — key corrected per the ECB SDW series documentation (two independent documentary sources agree on the key). A live 200 for this exact URL could **not** be re-confirmed from the build environment: this VM's egress proxy drops `data-api.ecb.europa.eu` for curl entirely (empty replies — the same proxy passes FRED with 200), and the single browser-fetch attempt for the ICP URL hit a transport error. First live confirmation therefore happens on Mazi's terminal, where the host demonstrably answers (v4.1 got a real HTTP 400 from it). If the key were still wrong, the failure mode is the designed one: fetch line shows `ecb 1/2`, EUR keeps HICP `bldg` and builds from accumulated calendar prints instead.

Parsing is unchanged (header-driven off `TIME_PERIOD`/`OBS_VALUE`); §12.7's "ECB keys are best-effort" limitation is narrowed, not removed.

## 13.2 Problem 2 — the two "Label" objects: namespace-blind delete sweep

The strays persisted under v4.1 at the same spot in both screenshots: immediately below the last watchlist row, i.e. **the two unused watchlist slots (rows 7–8 of 8; only 6 pairs are configured, so those slots' resting text is blank)**. Identification is positional and structural: every other panel object is rewritten with non-empty text on every draw, and those slots are the only objects in either build whose resting text should be empty. The v4.1 scrub could not clear them because it only **blanked** objects carrying this build's own `GM_` prefix and only label/text types — orphans left by the earlier v4.0 build under a name/type outside that scope survived every draw.

v4.2 adds `ScrubAllStrayObjects()`, run at `OnInit` and at the start of every `DrawPanel`, **before** the v4.1 scrub: it sweeps **all** chart objects (any prefix, including none) of type `OBJ_LABEL`, `OBJ_TEXT` or `OBJ_BUTTON` whose text is exactly `"Label"` or `"Text"` (MQL5's birth strings) and **deletes** them. It cannot eat a live panel object: no panel string of this EA ever equals those two words, the Refresh button reads "Refresh now", and `DrawPanel` recreates anything it owns on the same pass. The v4.1 creation fixes stay (Lab sets text in the creation sequence + read-back repair; button text re-set every draw).

## 13.3 Fix 3 — fund cross-check: fundamentals veto the factor weather (XAUUSD)

The contradiction Mazi spotted — headline **LONG 49/100** while the ladder showed USD strongest (px −1, **fund +2.1**, tot +1.1) — came from two clocks disagreeing: the gold factor engine reads 1–5 day price *weather* (it saw a risk-off day: VIX up, DXY down on the day), while USD FUND reads *months* of data trending stronger. New function `ApplyFundCrossCheck()`, called in the fetch cycle right after `ComputeFundScores()` and before `ComputeAllPairs()`, so the result flows into the pair state, Publish, both INIs and the alert text consistently:

- Gold **LONG** and USD FUND **≥ +1.5** → **opposed**: conviction capped at **40** (mirroring the existing dollar/yields disagreement cap), and the panel prints directly under the headline, in amber: `CAUTION: USD data trend strong (+2.1) - gold longs fight the fundamentals` (actual fund value interpolated).
- Gold **SHORT** and USD FUND **≤ −1.5** → opposed, mirrored: `CAUTION: USD data trend weak (-2.1) - gold shorts fight the fundamentals`, cap 40.
- Strong **aligned** trend (LONG with fund ≤ −1.5, SHORT with fund ≥ +1.5) → muted line `USD data trend aligned (+/-x.x)`, no cap change.
- Fund between −1.5 and +1.5, NEUTRAL bias, or USD FUND unscored (`bldg`) → no line, no cap.

The state is published in `general_macro.ini` as `fund_check=opposed|aligned|neutral`. This is Jamaal's hierarchy applied literally: fundamentals decide the direction; short-horizon factor weather cannot silently override a strong opposing data trend — it can still speak, but it speaks with a cap and a warning label.

## 13.4 Fix 4 — plain words instead of factor glyphs

Mazi: *"i do not understand the factor up and down."* The v4.1 watchlist markers are gone from every panel string:
- `f^` → **`fund+`** (the months-long data trend favors the pair's base side), `fv` → **`fund-`**, `f-` → **`fund flat`**, `f?` → **`fund n/a`**. (Thresholds unchanged: ±0.75 on the leg diff; ±0.5 on the USD leg for gold.)
- The XAUUSD watchlist phrase `gap factors` → **`gold-engine gap`** (gold's read comes from the factor engine, not a leg difference; FX rows keep `gap +1.1` style numbers).
- **New legend line at the very bottom of the panel:** `px=price trend (days) | fund=data trend (months) | tot=combined | !=turn in the data` — the `!` is the TURN flag already shown on ladder fund values (e.g. `fund +2.1!`).
- Ladder header aligned to the same words: `(px + fund = tot - computed from data, no manual input)`.
- To fit the fund-check line (new row under the headline at +56), every panel row below it shifted down 16px; `InpPanelH` default 1120 → 1160 also absorbs the legend.

## 13.5 Verification status (v4.2, honest — same caveat as §10/§12.8)

Still **not compiled** (no MQL5 compiler on the build VM). Static pass after all edits: brace/paren/bracket balance **286/286, 1483/1483, 440/440** (string/comment-aware stripper); **102 functions, no duplicate definitions**; every called function resolves to a definition or a standard MQL5 builtin (the checker flags only genuine MT5 API names — `WebRequest`, `MathSqrt`, `MathFloor`, `PositionGetSymbol`, `SymbolName`, `SymbolsTotal`, `StringGetCharacter`); **zero order-placement functions**; **zero `f^`-style markers left in any panel string literal** (the old glyphs survive only in explanatory comments); both new functions (`ScrubAllStrayObjects`, `ApplyFundCrossCheck`) defined once and wired (OnInit + DrawPanel; fetch cycle after `ComputeFundScores`). ECB FM URL verified live per §13.1; the ICP URL's live check is the one open item, with its designed graceful fallback. First MetaEditor compile remains Mazi's step.

---

# 14. v4.3 (2026-10-16) — USTEC/US30 become full citizens; GOLD FACTORS block leaves the panel

Two changes, both at Mazi's direction. `#property version` is now `"4.30"`; the panel title reads `GENERAL MACRO BIAS v4.3`. The watchlist default now includes the indices: `XAUUSD,EURUSD,GBPUSD,USDJPY,USDCAD,USDCHF,USTEC,US30` (8 = the BuildPairs cap).

## 14.1 Index citizens (USTEC / US30)

In v4.2 the index rows rendered dead (`- 0 mid-range gap +0.0 fund n/a`) because indices have no currency legs — `SplitPair` fails on them and the bias machinery had nothing to read. v4.3 gives each index its own leg (`IdxLeg g_idx[2]`, [0] = USTEC, [1] = US30) and copies the computed state onto the pair row, so watchlist rendering, ranking, grading, the INI and the gate all treat an index exactly like a pair.

**Detection** — `IndexKind(sym)`: keyword match on the uppercased symbol, run on the watchlist name first and then on the resolved broker symbol (brokers prefix/suffix freely: `USTEC.cash`, `US30Cash`, `NAS100_m` all land). Nasdaq family: `USTEC, USTECH, NAS100, NASDAQ, US100, NQ100`, plus bare `NQ` only as an exact symbol or `NQ.`/`NQ-`/`NQ_` prefixed (a loose `NQ` substring would be too collision-prone). Dow family: `US30, DJ30, DJI, WS30, DOW`, plus exact `DIA`. No FX pair or XAUUSD trips either family (verified mentally against the currency set — e.g. `USDJPY` contains neither `DJI` nor `DOW` as a substring); gold wins ties. An index pair carries `base = "USD"`, `quote = ""`, so `PairNewsState` matches USD events only and the per-leg detail collapses to the USD leg.

**Price score (px)** — Yahoo `QQQ` (fallback `^IXIC`) for USTEC, `DIA` (fallback `^DJI`) for US30, fetched through the standard `FetchYahoo` path inside the cycle (so the fetch diagnostics count them like any other Yahoo call — expect the yahoo counter to rise by up to 4). Scoring is the currency `AgreeScore` machinery **verbatim**: 1d/5d agreement, `NOISE` / `NOISE*1.4` bands, `likes_up = true`. px therefore sits on the same **−1..+1** scale as a currency's `price_score`; as with currencies, the −3..+3 range of the total is carried by FUND, which is what keeps `tot` directly comparable to a currency's `strength`.

**Fund** — `fund := USD FUND + rates overlay`. An index has no central bank of its own; the US data trend is its macro driver, so it inherits the USD currency FUND wholesale. The overlay uses the already-fetched `^TNX` gold factor's 5-day move (no new fetch, and the gold factor itself is only *read*, never altered): TNX 5d ≥ **+1.5%** (yields rising fast) → **−1.0** for USTEC, **−0.5** for US30; TNX 5d ≤ **−1.5%** → the mirror **+1.0 / +0.5**; between the bands, 0. Growth/tech takes double the Dow's dose because it is more rate-sensitive. The result is clamped to **−3..+3**. If the USD FUND is still `bldg`, the index FUND is `bldg` too — the overlay alone never fabricates a score.

**Total + bias** — `tot = px + fund`, clamped **−4..+4** (the exact currency-strength arithmetic; an unscored fund contributes 0, as with currencies). Bias mapping: a pair's diff is a difference of two −4..+4 legs (span −8..+8, normalized `diff/8`); a single asset's tot spans −4..+4, so the equivalent normalization is **`norm = tot / 4`**, which lands on the same −1..+1 normalized range and is read against the same **±0.28** thresholds with the same conviction formula (`|norm|/0.9 × 100`, NEUTRAL capped at 40). `tot` is also stored in the pair's `diff`, so the INI gap field, the rank key (`|diff| × in-zone`) and the alert path all work unchanged. The watchlist gap slot shows **`idx +x.x`** — wording that never implies a two-leg difference. The fund marker reads the index's own fund (USD fund + overlay) against the same ±0.5 band gold uses.

**Risk sentiment gauge** — new panel line with the regime lines: `risk sentiment: RISK-ON / RISK-OFF / MIXED / n/a`, from the two index px scores: both **≥ +1** → RISK-ON; both **≤ −1** → RISK-OFF; both scored but split or flat → MIXED; either unscored → n/a. (With the AgreeScore scale, ±1 means both horizons agree — the gauge fires only on a clean two-horizon move in both indices.) The line also shows the two px values. Written to `general_macro.ini` as `risk_sentiment=`, alongside per-index `index_USTEC_px/fund/tot` and `index_US30_px/fund/tot` lines. **Deliberate:** in v4.3 the gauge is display-only — it feeds no bias, no gate leg, no size and specifically **not** the gold engine. Whether sentiment should ever tilt a read is a separate decision, not smuggled in here.

**Index charts** — attach the EA to a USTEC/US30 chart (any broker spelling above) and everything works off MT5 price history exactly as for pairs: `ComputeTech` was already symbol-generic, so BB(100)/band-fib/zone/confluence/plan, the headline (index bias + conviction from tot), Publish and grading are unchanged code paths. The gate on an index chart: **WHY** = index bias + tot with its px/fund decomposition and USD-fund freshness; **WHERE** = the D1 zone vs the bias, as pairs; **WHEN** = USD high-impact events only (the index's "pair news" is the USD leg — blackout and next-event lines read the USD calendar); **WHAT** = stop/T2/RR + size from the broker's tick value for that index symbol, as pairs. The per-pair news line shows `news USD: ...` (one leg); the fund line shows `fund USD +x.x -> index +y.y (USD fund + rates overlay)`. Position sizing on index CFDs inherits whatever contract size the broker quotes — check the WHAT line's size text on first use, as with any new symbol.

**Gold parity is untouched** — proven, not asserted: `BuildFactors` (the factor table: symbols, fallbacks, signs, weights), `ScoreFac`, `Regime`, `ApplyNewsAndBias`, `BuildPlaybook`, `ApplyFundCrossCheck`, `PublishLegacy` and `WriteIni` are **byte-identical** to the v4.2 file (diffed function-by-function against the pre-edit backup). The SPY factor is unchanged; the only contact with the gold engine is *reading* the TNX factor's snapshot for the index overlay.

## 14.2 GOLD FACTORS block removed from the panel (display only)

The `GOLD FACTORS (XAU leg)` section — the eight rows listing each factor's 1d/5d % moves plus the Gold context row — no longer renders, and the `InpShowFactors` input is gone with it. This is a **display-only removal at Mazi's direction**: the factor engine computes exactly as before (scores, bias, conviction, caps, cross-check, legacy `GlobalVariable`s, `gold_bias.ini`, the per-pair detail in `general_macro.ini` — all unchanged; §14.1's parity diff covers the code). To keep an upgraded chart clean, `DrawPanel` explicitly deletes the old block's objects (`GM_fh`, `GM_f0`–`GM_f7`, `GM_gg`) on every draw — the stray-object scrub discipline applied to our own retired furniture, so no ghost rows can linger from v4.2.

**Panel geometry:** the freed block (~150px) is reclaimed and the new sentiment line (+18px) absorbed: every row below the regime line shifted +18, the playbook moved up into the freed space (845), and the `InpPanelH` default drops **1160 → 1000**. (A saved `.set` with the old height still works — the panel just has extra empty tail room.)

## 14.3 Verification status (v4.3, honest — same caveat as §10/§12.8/§13.5)

Still **not compiled** (no MQL5 compiler on the build VM). Static pass after all edits: brace/paren/bracket balance **300/300, 1574/1574, 525/525** (string/comment-aware stripper); **106 function definitions** (v4.2's 102 + `IndexKind`, `BuildIndexLegs`, `FetchIndexLegs`, `ComputeIndexLegs`), **no duplicates**; every called function resolves to a definition or a standard MQL5 builtin (the checker flags only `ObjectGetInteger` / `ObjectName` — genuine MT5 API names, flagged identically on the v4.2 file); **zero order-placement functions** (grep for OrderSend/CTrade/MqlTradeRequest: none); grep-verified zero remaining references to `InpShowFactors` or the `GOLD FACTORS` panel header outside the removal comment. First MetaEditor compile remains Mazi's step.

---

# 15. v4.4 (2026-10-16) — PLAYBOOK block leaves the panel; dash shrunk to fit

One change, at Mazi's direction: *"Remove the last block after the Risk and reduce the dash to fit the current content."* `#property version` is now `"4.40"`; the panel title reads `GENERAL MACRO BIAS v4.4`.

## 15.1 Playbook block removed from the panel (display only)

The block under RISK — the up-to-five wrapped lines at `InpY+845 + i*15` (gold's session/macro lines, or the pair flavour: blackout warning, Asia/pre-NY briefings, "Macro: favor longs off support…", the 200-day-wall line) — no longer renders, and the inline line-building code that fed labels `GM_p0`–`GM_p4` is gone with it. This is a **display-only removal**: `BuildPlaybook()` still computes `g_play` every cycle and the `playbook=` line still lands in `gold_bias.ini` exactly as before — the computation, the data and the INI output were not touched. (The pair-flavour lines were built inline in `DrawPanel` and existed only on the panel; the blackout they announced is still carried by the news line and the gate's WHEN leg.) Following the v4.3 retired-furniture pattern, `DrawPanel` now explicitly deletes `GM_p0`–`GM_p4` on every draw, so an upgraded chart shows no ghost rows. The legend and "Guide only" single lines stay — they were never part of the block.

## 15.2 Panel height 1000 → 918 — the anchor math

Nothing above RISK moved: the last fixed content is still `rk3` at `InpY+815` (font 8, ≈11px line → bottom edge ≈ `InpY+826`). The three tail lines are anchored to `InpPanelH` (legend `H−68`, guide `H−48`, error `H−28`), so they ride up automatically with the shrink. New default **918**:

- legend at `InpY+850` — **24px below rk3's bottom edge** (no overlap; the playbook's 845 start is vacated),
- guide at `InpY+870`, error line at `InpY+890`,
- panel bottom at `InpY+918` → **28px below the error line, the same bottom margin as v4.3** (1000 − 972 = 28).

Total reclaimed: 82px of dead tail. (A saved `.set` with the old height still works — the tail lines anchor to whatever height is set; the panel just keeps the extra empty room.)

## 15.3 Verification status (v4.4, honest — same caveat as §10/§12.8/§13.5/§14.3)

Still **not compiled** (no MQL5 compiler on the build VM). Static pass after all edits: brace/paren/bracket balance **296/296, 1563/1563, 514/514** (string/comment-aware stripper; the deltas vs v4.3's 300/1574/525 are exactly the removed block's own braces/parens/brackets); **106 function definitions, no duplicates** (unchanged count — no function added or removed); every called function resolves to a definition or a standard MQL5 builtin (the checker flags only `AccountInfoDouble`, `ArraySize`, `DoubleToString`, `FileIsEnding`, `TimeToString` — genuine MT5 API names its allowlist lacks, all in untouched engine code); **zero order-placement functions**; grep-verified the only remaining `PREF "p"` reference is the `ObjectDelete` cleanup loop, with no `pl[]`/`np` leftovers, and `BuildPlaybook` / `g_play` / the INI `playbook=` write intact. Diffed against the pre-edit v4.3 file: the change surface is exactly four hunks — the version string, the `InpPanelH` default, the panel title, and the DrawPanel playbook block — everything else byte-identical, so gold-engine parity (§14.1) carries over untouched. First MetaEditor compile remains Mazi's step.

---

# 16. v4.5 (2026-10-16) — panel height auto-fits; the empty black tail is gone

One fix, from Mazi's live v4.4 screenshot: *"i want that empty black space gone"* — the bottom ~40% of his panel was empty black. `#property version` is now `"4.50"`; the panel title reads `GENERAL MACRO BIAS v4.5`.

## 16.1 Root cause — a stale saved input, not the layout

v4.4's default height was already correct (918, §15.2) on paper. But MT5 **preserves the previous EA instance's input values** when an EA is recompiled/re-attached on the same chart, so Mazi's terminal kept the height saved from an older build (1160, the v4.2 default) and never saw the new default. Because the background rectangle and the three bottom lines (legend `H−68`, guide `H−48`, error `H−28`) all keyed off `InpPanelH`, the whole panel — empty tail included — obediently rendered at the stale height. Any future default change would have hit the same trap, so the height no longer comes from an input at all.

## 16.2 The fix — fitted height, computed in code

- New `#define PANEL_FIT_H 918` beside the other layout constants, with a comment tying it to the v4.4 geometry it encodes: last fixed row `rk3` at `InpY+815`, legend at `FIT−68` (+850), guide at `FIT−48` (+870), error line at `FIT−28` (+890), panel bottom at +918. If rows are ever added to or removed from the layout, this one number is the adjustment point.
- `DrawPanel` opens with `const int fitH = PANEL_FIT_H;` and **everything that used `InpPanelH` now uses `fitH`**: the background `Rect`, the legend label, the "Guide only" label, and the conditional error label. Grep-verified: `InpPanelH` no longer drives any drawing.
- `InpPanelH` itself is **kept in the input list, default 918, and ignored**. It is retained purely so old `.set` files and saved chart templates load without shifting the positions of the inputs that follow it; its comment says so on its face (`legacy (v4.5): … this value is IGNORED`). Whatever stale value a terminal has preserved for it — 1160 included — now has no effect: the panel is always exactly as tall as its content.
- Nothing else moved: engine, fund engine, gate, ladder, watchlist, indices, risk block, diagnostics and both stray-object scrubs are byte-identical outside the height plumbing.

## 16.3 Verification status (v4.5, honest — same caveat as §10/§12.8/§13.5/§14.3/§15.3)

Still **not compiled** (no MQL5 compiler on the build VM). Static pass after all edits: brace/paren/bracket balance **296/296, 1563/1563, 514/514** — identical to v4.4, as expected, since the edits swap identifiers and add comments only; **106 function definitions, each exactly once, no duplicates** (unchanged count); every called function resolves to a definition or a standard MQL5 builtin (the checker flags only `MathFloor`, `ObjectsTotal`, `PositionGetDouble`, `StringGetCharacter`, `StringToUpper`, `SymbolName`, `SymbolsTotal` — genuine MT5 API names its allowlist lacks, all in untouched code); **zero order-placement functions**. First MetaEditor compile remains Mazi's step — and on his chart this build should finally show the panel ending right under the RISK block, whatever his saved inputs say.

---

# 17. v4.6 (2026-10-16) — every line fits the ACTUAL panel width

One fix, from Mazi's live v4.5 screenshot: *"i see some words are getting cut out... like the <== ch, fu at the top etc"* — the CAUTION line ended at "gold longs fight the fu", the watchlist chart marker at "<<== ch", rk3 at "vs firm daily limi". `#property version` is now `"4.60"`; the panel title reads `GENERAL MACRO BIAS v4.6`.

## 17.1 Root cause — designed at 520, running at 430

The v4.x layout was designed against the `InpWidth` default of **520**, but MT5 preserves the previous instance's inputs across recompiles (the same trap as the height, §16.1), so Mazi's terminal kept the width saved from the original v2.00-era EA: **430**. Every hard-coded `Wrap()` limit (84 for the fetch diagnostic / pair news / fund lines, 76 for rk2, 74 for the gate texts) plus several unwrapped strings were sized for 520 and simply ran out of panel at 430, clipping mid-word at the background rectangle's edge. The fix does not touch `InpWidth`'s default — it makes every line's budget a function of the width the panel actually has, so the display is correct at 430, at 520, and at any saved width in between.

## 17.2 The fix — a character budget, applied everywhere

- **New helper `CharBudget()`**: `(int)MathFloor((InpWidth − 28) / 6.0)`, clamped to [48, 96]. The −28 is the panel's left offset (14) plus a matching right margin; 6.0px per char at font size 8 is deliberately conservative (covers DPI scaling). At 430 → **67**; at 520 → **82**. `DrawPanel` computes `cb` once per draw.
- **Every `Wrap()` in `DrawPanel` is now budget-relative** — no numeric limits remain (grep-verified): fetch diagnostic `fd`, pair news `k7` (both variants) and fund line `k8` wrap at `cb`; gate lines `g1`–`g4` wrap at **`cb − 16`** (the eight `"WHY    OK    "`-style prefixes all measure exactly **13** chars, and `Wrap()` appends `"..."` (+3) when it truncates — 13 + (cb−16) + 3 = cb, so a rendered gate line, prefix included, can never exceed the budget); rk2 wraps at `cb − 4`. The news titles' `Trunc(..., 20)` semantics are unchanged; the composed lines pass through the budget wrap as before.
- **CAUTION strings shortened** (in `ApplyFundCrossCheck`, the only engine-adjacent text touched — wording only, the cap/logic is untouched): strong `"CAUTION: USD data trend strong (+x.x) - gold longs fight the fundamentals"` (73 chars) → `"CAUTION: strong USD data trend (+x.x) - gold longs against it"` (**61**); weak mirrored → **60**. The aligned variant (29) already fit and is unchanged.
- **Watchlist chart marker moved**: the row format is now `%-10s %-7s %3d  %-10s %s %s` over `sym + " <<"` — the marker sits directly after the symbol name (`XAUUSD <<  LONG ...`) instead of at the end of the row, and the trailing word `chart` is dropped. Gold chart row renders **56** chars (worst variant — NEUTRAL/100/OVERSHOT/fund flat — 60).
- **rk3 shortened and wrapped**: `"worst case if all stops hit: -x.x% of equity vs firm daily limit y.y% (inside limit)"` (84 chars) → `"worst case all stops hit: -x.x% vs firm daily limit y.y% (inside/OVER)"`, wrapped at `cb`. Raw maximum is **65** over a value sweep with the code's own inside/OVER comparison — the wrap never even triggers at 430.
- **Ladder header shortened**: `"STRENGTH LADDER  (px + fund = tot - computed from data, no manual input)"` (72) → `"STRENGTH LADDER  (px + fund = tot - from data)"` (**46**).

**Worst-case rendered lengths at width 430 (budget 67)** — caution strong 61 · caution weak 60 · watchlist gold chart row 56 (worst variant 60) · gate WHY ≤ 67 by construction (13 prefix + cb−16 wrap + 3 ellipsis; the longest real WHY texts — index stale-caution at 83 raw, gold NEUTRAL+FAIL at 73 raw — both render exactly 67) · rk2 ≤ 66 · rk3 65 · ladder header 46. All ≤ 67.

**Noted but deliberately NOT touched (outside this fix's scope):** two unwrapped lines can still exceed the budget — the `k6` "plan:" line (~71 chars with gold-length prices and two RR values) and the bottom legend (84 chars — it exceeds even the 520 budget of 82, so it has clipped at the designed width all along). Shortening either means dropping information (the second RR, legend terms); flagged here for a separate decision rather than silently folded in.

## 17.3 Verification status (v4.6, honest — same caveat as §10/§12.8/§13.5/§14.3/§15.3/§16.3)

Still **not compiled** (no MQL5 compiler on the build VM). Static pass after all edits: brace/paren/bracket balance **297/297, 1572/1572, 514/514** (string/comment-aware stripper; deltas vs v4.5 are exactly the added `CharBudget` body and wrap calls); function-definition count rose by exactly one over the v4.5 file under an identical count (`CharBudget`), **no duplicates**; every called function resolves to a definition or a standard MQL5 builtin (the checker flags only `MathSqrt` — a genuine MT5 API name in untouched BB code, present identically in v4.5); **zero order-placement functions**. Grep-verified: no `Wrap()` call anywhere in the file still carries a numeric limit. Diffed against the pre-edit v4.5 file: the change surface is exactly the version string, the panel title, the two CAUTION strings, `CharBudget` + its `cb` hookup, the watchlist row formatter, the ladder header, and the `fd`/`k7`/`k8`/`g1`–`g4`/`rk2`/`rk3` wrap sites — everything else byte-identical, so gold-engine parity (§14.1) carries over untouched. First MetaEditor compile remains Mazi's step.

---

# 18. v4.7 (2026-10-16) — the last two clippers fixed: plan line + legend

The two lines §17.2 flagged and deliberately left — the `k6` "plan:" line and the bottom legend — are fixed, at Mazi's approval. `#property version` is now `"4.70"`; the panel title reads `GENERAL MACRO BIAS v4.7`. Display formatting only: no engine/scoring/gate/risk computation changed, `PANEL_FIT_H` untouched, line count unchanged.

## 18.1 The plan line (`k6`) — tightened format, all values kept

Old format: `plan: entry %s  stop %s  T1 %s  T2 %s  RR %.2f/%.2f` — 43 fixed/RR chars + 4 prices, i.e. **71 chars** at gold's 7-char prices, over the 430-width budget of 67. New format: **`plan: entry %s stop %s T1 %s T2 %s R:R %.1f`** — single spaces, 31 fixed chars + 4 prices + the RR digits. All five values still print: entry, stop, T1, T2, RR — with the same computed values as before (`t.entry/t.stop/t.t1/t.t2` untouched).

**Which RR:** the old line printed the pair `rr1/rr2` (to-T1 / to-T2). The tightened line prints the single headline R:R = **rr2**, the to-T2 (extended-target) figure — the same number the gate's WHAT leg enforces (`t.rr2 >= InpMinRR`; its failure text quotes rr2) and the figure the framework's 1:2.5–1:6 convention refers to — now at one decimal. rr1 is not lost from the panel: the WHAT gate line still prints the full `stop … T1 … T2 … RR %.2f/%.2f size …` text. Precision note: at one decimal the plan line shows R:R 1.4 where the WHAT line shows 1.40 — display rounding only, no computed value changed.

**Worst-case proof per asset class** (prices via `FmtPrice` = `DoubleToString(v, SYMBOL_DIGITS)`; RR < 10 renders 3 chars at `%.1f`):

| Asset class | Price shape | Chars each | Plan line total |
|---|---|---|---|
| Gold (XAUUSD) | 4245.61 | 7 | **62** |
| Gold, 5-digit integer part | 10245.61 | 8 | **66** |
| FX majors, 5 decimals | 1.14740 | 7 | **62** |
| USDJPY, 3 decimals | 156.789 | 7 | **62** |
| Indices (USTEC/US30), 2 decimals | 25432.10 | 8 | **66** |
| Absolute ceiling (8-char prices AND rr2 ≥ 10.0, i.e. a 4-char "12.3") | — | 8 | **67** |

Every case ≤ the 430 budget of 67. The composed string additionally passes through `Wrap(..., cb)` as a backstop — since even the pathological ceiling lands exactly at budget (and `Wrap` only truncates above it), the backstop cannot trigger for any class above; it exists so an exotic broker price format can never shear a number mid-string, it can only ever abbreviate with "…" in a case that cannot currently occur.

## 18.2 The legend (`lg`) — 84 → 60 chars

Old: `px=price trend (days) | fund=data trend (months) | tot=combined | !=turn in the data` (**84** — over budget even at the designed 520 width, 82, so it had clipped all along). New: **`px=price (days) | fund=data (months) | tot=combined | !=turn`** (**60**). Every term survives; the days-vs-months distinction — px is the price trend over days, fund the data trend over months, the legend's whole point — is preserved verbatim inside the parentheses.

## 18.3 Verification status (v4.7, honest — same caveat as §10/§12.8/§13.5/§14.3/§15.3/§16.3/§17.3)

Still **not compiled** (no MQL5 compiler on the build VM). Static pass after all edits: brace/paren/bracket balance **297/297, 1573/1573, 514/514** (string/comment-aware stripper; the single added paren pair vs v4.6 is the `Wrap()` call now around the plan string; braces/brackets identical); **107 function definitions, no duplicates** — unchanged count, verified with the same counter run against the v4.6 file; every called function resolves to a definition or a standard MQL5 builtin (the checker flags only `ArraySetAsSeries`, `CharArrayToString`, `ObjectsDeleteAll` — genuine MT5 API names its allowlist lacks, counted identically in the untouched v4.6 file); **zero order-placement functions**. Diffed against the pre-edit v4.6 file: the change surface is exactly four hunks — the version string, the panel title, the `k6` plan line (plus its explanatory comment), and the legend string (plus its comment) — everything else byte-identical, so gold-engine parity (§14.1) carries over untouched. With §17 + §18, **every line on the panel now provably fits the actual panel width** — at Mazi's 430 the budget is 67 and the worst rendered line on the dash is 67 only in the unreachable ceiling case. First MetaEditor compile remains Mazi's step.

---

# 19. v4.8 (2026-10-16) — FRED history for every currency; the ECB feed is gone

From Mazi's live dash: *"the other pairs are not uploading their fund, it is showing fund bldg, can we use another sources for those?"* `#property version` is now `"4.80"`; the panel title reads `GENERAL MACRO BIAS v4.8`.

## 19.1 Problem — FUND was a USD-only privilege

By the v4.1 design (§12.4), the only history sources were FRED (USD) and the ECB SDW (EUR). Every other currency's FUND could come only from ForexFactory print accumulation into `ff_history.csv` — a store that starts empty and needs weeks of prints before any currency reaches the ≥2-scored-indicators bar. And the ECB feed never once answered on Mazi's terminal (`ecb 0/2` in every screenshot since v4.1), so in practice **only USD ever lit up**; EUR, GBP, JPY, CHF, CAD, AUD and NZD sat at `bldg` and their pair biases leaned on price alone.

## 19.2 The fix — one FRED map for the whole ladder (`FetchFredIntl`)

FRED carries OECD / Eurostat / central-bank series for all eight ladder currencies on the same key-less `fredgraph.csv` endpoint USD already used. New `FetchFredIntl()` runs beside `FetchFred()` in the fetch cycle, driven by a 23-row map (currency, indicator key, series ID, transform kind), reusing `FetchFredCsv` and the **same transform math** as the USD branches: kind 0 = level as-is, kind 1 = YoY % from a monthly index (lag 12), kind 2 = q/q % from a quarterly level. Series land in the same `FSerIdx(ccy, key, "fred")` store, so scoring, sign maps, weights (CPI/jobs/rate 2.0, unemp 1.5, GDP/PCE 1.0, retail/PMI 0.75), TURN logic and the ≥2-indicator `bldg` rule are literally the USD code paths. `BestFundDir` still picks **one** series per (currency, indicator) — deepest first, ties now fred > ff — so where FRED covers a slot, accumulated calendar prints only ever fill the slots FRED doesn't (no double counting); USD's FRED map is byte-identical to v4.7 (diffed). The fred diagnostics counter now covers up to 30 series (7 USD + 23 intl), so the fetch line grows to e.g. `fred 29/30`.

**Verification method:** every ID below was curled live from the build VM against `fredgraph.csv` before being wired. "Obs" = usable observations inside the EA's own window (the ~1100 days `FetchFredCsv` requests); the wiring bar was ≥8. "Pts" = points after the transform (what the string scorer sees). Anything that failed the bar was **not** wired — see §19.4.

| Ccy | Indicator | FRED series | Transform | Obs | Pts | Last obs |
|---|---|---|---|---|---|---|
| EUR | cpi | `CP0000EZ19M086NEST` (Eurostat HICP index, EA19) | YoY % (lag 12) | 36 | 24 | 2026-09-01 |
| EUR | rate | `ECBMRRFR` (ECB main refinancing rate, daily) | level | 1101 | 1101 | 2026-10-16 |
| EUR | gdp | `CLVMNACSCAB1GQEA19` (real GDP level, EA19) | q/q % | 11 | 10 | 2026-04-01 |
| GBP | cpi | `GBRCPIALLMINMEI` (OECD CPI index) | YoY % (lag 12) | 18 | 6 | **2025-03-01 ⚠** |
| GBP | unemp | `LRHUTTTTGBM156S` (OECD harmonized %) | level | 33 | 33 | 2026-06-01 |
| GBP | rate | `IR3TIB01GBM156N` (3M interbank %) | level | 27 | 27 | **2026-01-01 ⚠** |
| GBP | gdp | `NAEXKP01GBQ657S` (GDP volume growth) | level (already q/q %) | 11 | 11 | 2026-04-01 |
| JPY | unemp | `LRHUTTTTJPM156S` | level | 35 | 35 | 2026-08-01 |
| JPY | rate | `IR3TIB01JPM156N` (3M interbank %) | level | 34 | 34 | 2026-08-01 |
| JPY | gdp | `NAEXKP01JPQ657S` | level (already q/q %) | 11 | 11 | 2026-04-01 |
| CHF | cpi | `CHECPIALLMINMEI` (OECD CPI index) | YoY % (lag 12) | 19 | 7 | **2025-04-01 ⚠** |
| CHF | rate | `IR3TIB01CHM156N` (3M interbank %) | level | 35 | 35 | 2026-09-01 |
| CHF | gdp | `CLVMNACSCAB1GQCH` (real GDP level) | q/q % | 11 | 10 | 2026-04-01 |
| CAD | cpi | `CANCPIALLMINMEI` (OECD CPI index) | YoY % (lag 12) | 18 | 6 | **2025-03-01 ⚠** |
| CAD | unemp | `LRHUTTTTCAM156S` | level | 35 | 35 | 2026-08-01 |
| CAD | rate | `IR3TIB01CAM156N` (3M interbank %) | level | 35 | 35 | 2026-09-01 |
| CAD | gdp | `NAEXKP01CAQ657S` | level (already q/q %) | 11 | 11 | 2026-04-01 |
| AUD | unemp | `LRHUTTTTAUM156S` | level | 35 | 35 | 2026-08-01 |
| AUD | rate | `IR3TIB01AUM156N` (3M interbank %) | level | 34 | 34 | 2026-08-01 |
| AUD | gdp | `NAEXKP01AUQ657S` | level (already q/q %) | 11 | 11 | 2026-04-01 |
| NZD | unemp | `LRHUTTTTNZQ156S` (quarterly) | level | 11 | 11 | 2026-04-01 |
| NZD | rate | `IR3TIB01NZM156N` (3M interbank %) | level | 35 | 35 | 2026-09-01 |
| NZD | gdp | `NAEXKP01NZQ657S` | level (already q/q %) | 11 | 11 | 2026-04-01 |

Net effect: **every non-USD currency reaches ≥3 scored FRED indicators on the first fetch** — FUND lights up across the ladder immediately instead of after weeks of accumulation.

## 19.3 EUR migrated; the ECB SDW fetch is removed entirely

FRED's EUR coverage verified stronger than the ECB feed ever was (the `ECBMRRFR` values match §13.1's SDW evidence point-for-point — 2.15 in Jun 2025, 2.65 in Sep 2026 — from the host that has answered all along). So: `FetchEcbCsv` and `FetchEcb` are deleted, the call site is replaced by `FetchFredIntl()`, the `g_d_ecb_*` counters and the `| ecb x/y` diagnostics slot are gone (fetch line: `fetch: yahoo … | ff OK | fred 29/30`), the degradation check and `CcySourceLive` no longer reference ECB (`CcySourceLive` is now uniform for all currencies: FRED answered, or the calendar parse produced prints), and the allowlist drops to **three** URLs — `data-api.ecb.europa.eu` can be removed from Tools → Options → Expert Advisors (leaving it there is harmless). The `BestFundDir` tie-break priority simplifies to fred > ff; no reachable state changes (no series can carry src `"ecb"` anymore — `ff_history.csv` stores points, not sources).

## 19.4 What did NOT verify — and stays on accumulation, said plainly

- **CPI for JPY, AUD, NZD:** the OECD index series are dead at the source (`JPNCPIALLMINMEI` ends 2021-06; the AUD/NZD IDs return nothing; the `CPALTT01` growth variants end 2021–2025 with <8 in-window points). No live FRED CPI was found for these three → their `cpi` slot keeps building from calendar prints (monthly for JPY, quarterly for AUD/NZD), and takes over only if it ever grows deeper than nothing — it starts as the only series in the slot, so it scores as soon as it has 2 points.
- **Unemployment for EUR and CHF:** no FRED series passed the bar (euro-area guesses return nothing or end in 2020; the Swiss harmonized series ends 2023-12 with 3 in-window points). Both stay on accumulation; EUR/CHF FUND does not need them (3 scored FRED indicators each already).
- **Retail (all intl) and jobs/pmi (all currencies incl. USD):** no clean verified FRED series found (retail patterns probed return nothing). Unchanged from v4.1: accumulation-only slots.
- **True policy rates for GBP/JPY/CHF/CAD/AUD/NZD:** the OECD `IRSTCB01` central-bank-rate family is gone from FRED (IDs return empty or end 2023-12). The wired substitute is the 3-month interbank rate (`IR3TIB01`) — the same stance-proxy trick `FEDFUNDS` already plays for USD: a market rate that follows the policy path, scored on level changes exactly like a policy series. It can drift a few bp without a policy move; treat a lone intl `rate` direction as softer evidence than EUR's real `ECBMRRFR` steps or a calendar rate print (which still wins the slot if the accumulated series grows deeper).
- **⚠ Frozen CPI strings (GBP/CHF/CAD):** the OECD CPI index series stop at Mar–Apr 2025 (the source froze them; the matching `CPALTT01` growth series end the same months). They pass the verification bar on real history, so they are wired — but their YoY strings (6–7 points) end ~18 months ago, and FRED will never extend them. Accumulated CPI prints pass them in depth within ~6–7 monthly prints and take the slot over automatically. Until then those three currencies' CPI direction is honest history, honestly stale — flagged here and in the code comment rather than hidden.
- **⚠ GBP rate lag:** `IR3TIB01GBM156N` currently ends 2026-01 (27 obs) while its siblings reach Aug–Sep 2026 — an OECD reporting lag on this one series; it still clears the bar and its string direction (easing through the BoE's Dec-2025 cut) is real.

## 19.5 Cadence honesty

OECD/FRED foreign series lag their reference period by ~1–2 months (unemployment and interbank rates), a quarter or more for GDP (latest GDP prints are Q2-2026, dated 2026-04-01). That lag is inherent to a months-long trend string and is accepted by design — the same trade the USD FRED block already makes — and is recorded in a comment on `FetchFredIntl`. No panel surface was added for it (Mazi's dash is full; the fetch line's counters already say whether FRED answered).

## 19.6 Verification status (v4.8, honest — same caveat as §10/§12.8/§13.5/§14.3/§15.3/§16.3/§17.3)

Still **not compiled** (no MQL5 compiler on the build VM). Static pass after all edits: brace/paren/bracket balance **301/301, 1520/1520, 510/510** (string/comment-aware stripper; deltas vs v4.7 are the removed ECB parser block minus the new `FetchFredIntl`); **106 function definitions, no duplicates** (v4.7's 107 − `FetchEcbCsv` − `FetchEcb` + `FetchFredIntl`); every called function resolves to a definition or a standard MQL5 builtin (the checker flags only `ChartSetInteger`, `StringToLower`, `TimeLocal` — genuine MT5 API names in untouched code, counted identically in the v4.7 file); **zero order-placement functions**; grep-verified zero remaining code references to the ECB feed (the surviving "ECB" strings are the migration comments and the `ECBMRRFR` series ID). Diffed against the pre-edit v4.7 file: the change surface is exactly the header allowlist comment, the version string, the panel title, the `FSeries` source comment, the removed `g_d_ecb_*` globals, the fetch-cycle reset/call/degradation lines, `BuildFetchDiag`, the `BestFundDir` tie-break, `CcySourceLive`, and the ECB block → `FetchFredIntl` replacement — everything else byte-identical, so gold-engine parity (§14.1) and the USD FRED map carry over untouched (function-level md5 parity check on `FetchFred`, `BuildFactors`, `ScoreFac`, `Regime`, `ApplyNewsAndBias`, `BuildPlaybook`, `ApplyFundCrossCheck`, `PublishLegacy`, `WriteIni`: all identical). Every wired series was verified live per §19.2's method; the first on-terminal confirmation (fetch line showing `fred` with a high ok-count and the ladder's `bldg` rows replaced by numbers) happens on Mazi's next compile + attach. First MetaEditor compile remains Mazi's step.

---

# 20. v4.9 (2026-10-16) — the MT5 built-in calendar becomes the third fund source

From Mazi, after v4.8: *"what about pulling the data from calendar for those currencies"* — approved as v4.9. `#property version` is now `"4.90"`; the panel title reads `GENERAL MACRO BIAS v4.9`.

## 20.1 Why — the gaps FRED cannot fill

v4.8's FRED map left four honest holes (§19.4): **no living FRED series at all** for JPY/AUD/NZD CPI and EUR/CHF unemployment, and **frozen** CPI index series for GBP/CHF/CAD (source stopped Mar–Apr 2025, 6–7 YoY points, never to extend). Those slots could only grow from faireconomy print accumulation — weeks to months. The terminal's own economic-calendar database, by contrast, holds months of ACTUAL prints for exactly those releases, readable through the MQL5 Calendar API with **no WebRequest and no allowlist entry** — if the broker feeds the database. `FetchCalendarIntl()` (called in the fetch cycle beside `FetchFredIntl`) mines it as a third source, registered in the same `FSer` store under src `"cal"`, so scoring, sign maps, weights, TURN logic and the ≥2-indicator `bldg` rule are the shared code paths — nothing about FUND math changed.

## 20.2 How it works

- **Enumeration:** `CalendarEventsByCurrency(<code>)` per ladder currency (all eight, USD included — see §20.4). Each event is classified once by `CalClassify` into an indicator key + variant tier; **one event per (currency, indicator)** is selected — highest tier, then the *shortest name* (at equal tier the un-prefixed aggregate release, `CPI (YoY)`, beats a national one, `German CPI (YoY)`; EUR enumeration returns national eurozone releases alongside the aggregates), then lowest event id, so the pick is deterministic. A series is that one `event_id` end-to-end — variants can never blend inside a string.
- **History:** `CalendarValueHistoryByEvent(event_id, from, now)` over the same ~1100-day window the FRED fetches use (anchored to `TimeCurrent()`, the calendar's own clock basis). Only values with an actual present and `datetime <= now` are kept — no forecasts, no scheduled futures.
- **Values:** read via the documented accessors (`HasActualValue()` / `GetActualValue()`), never raw-long division. A % release (CPI/GDP/retail) is stored as the % number itself — *exactly* the treatment the faireconomy accumulation gives prints (§12.4), because the string scorer reads only the direction sequence of a print string and one event never changes its units mid-string.
- **Revisions:** the calendar can carry an original plus revisions for one reporting period. Points are keyed by the value's `period` floored to the day (release day when no period is set) and within a period the highest `revision` wins — a revision REPLACES its original in the string (the revision-wins rule `FSerAdd` already applies), independent of the order values come back in.
- **Precedence:** `BestFundDir` still picks ONE series per slot, deepest first — the only edit is the tie-break priority, now **fred (3) > cal (2) > ff (1)** (a real history source beats accumulated prints on a tie; depth always beats priority). No double counting is possible: one slot, one series.

## 20.3 The event-name match table (`CalClassify`)

Names are lowercased; first matching branch wins; tiers are variant preference within the slot (higher wins).

| Key | Trigger keywords (name contains) | Tiering | Exclusions |
|---|---|---|---|
| cpi | `cpi`, `consumer price`, `inflation rate` | headline YoY 3 · core YoY 2 · headline other 1 · core other 0 | `expectation…` rejected; `core`/`trimmed`/`median` count as core; PCE names match no trigger (by design — USD `pce` stays FRED-only) |
| unemp | `unemployment rate`, `jobless rate` (tier 2); any other `unemployment`/`jobless` (tier 1) | the rate itself beats national change releases | claimed BEFORE jobs, so `Unemployment Rate` can never become a jobs series |
| jobs | `nonfarm`, `non-farm`, `non farm`, `payroll` (tier 3); `employment change`, `claimant count` (tier 2, = GBP's jobs read); any other `employment` (tier 1) | ADP print forced to tier 0 (fallback only) | `…cost index` rejected (Employment Cost Index is wages) |
| rate | `interest rate`, `rate decision`, `policy rate`, `bank rate`, `cash rate`, `overnight rate`, `refinancing rate`, `federal funds`, `official rate`, `key rate`, `repo rate`, `facility rate` | `interest rate decision` 3, other policy phrases 2 | only policy phrases trigger — no bare-`rate` statistics can slip in |
| gdp | `gdp`, `gross domestic` | q/q 3 · unspecified/y/y 2 · m/m 1; `prelim`/`flash` docked 1 (clamped ≥ 0) | `deflator`, `price index` rejected (price series, not growth) |
| retail | `retail sales` | m/m 2 · other 1; `core`/`ex auto` docked 1 (clamped ≥ 0) | — |
| pmi | `pmi`, `purchasing managers` | composite 3 · services / `non-manufacturing` 2 · manufacturing 1 · other 0; `prelim`/`flash` docked 1 (clamped ≥ 0) | `non-manufacturing` is tested as services before manufacturing can claim it |

## 20.4 Precedence outcomes for the known cases (first cycle, broker calendar permitting)

- **JPY cpi** — FRED slot empty, ff starts empty: cal is the only history → fills immediately (~36 monthly prints in the window from the single chosen CPI event).
- **GBP / CHF / CAD cpi vs the frozen FRED strings** — the FRED strings hold 6 / 7 / 6 YoY points ending Mar–Apr 2025; a headline calendar CPI event holds ~36 prints in the same window, so **cal wins on depth the first cycle it runs** — it does not need to "catch up". The frozen FRED strings stay in the store, simply not picked.
- **EUR unemp** — no FRED series exists: the euro-area `Unemployment Rate` event fills the slot, becoming EUR's 4th scored indicator (FRED already gave it 3).
- **CHF unemp** — same fill via the Swiss unemployment-rate event (any name containing `unemployment rate`, e.g. a SECO-prefixed variant, tiers 2).
- **AUD / NZD cpi** — quarterly YoY CPI events give ~12 points each in the window: both slots fill immediately instead of accumulating for a year.
- **USD** — enumerated too; FRED mostly keeps its slots (unemp ~36 vs ~36 points → fred on tie-break; gdp → fred on tie; rate: FEDFUNDS' 36 monthly levels beat ~24 decision prints on depth). One honest exception: **USD cpi** — a calendar YoY CPI event carries ~36 prints vs FRED's 24 YoY points, so cal wins that slot on depth. Both are YoY % strings scored by the identical code path; the calendar's are the actual release prints.
- Everywhere: ff accumulation still only fills slots no history source covers, and a release is never scored twice.

## 20.5 Diagnostics — the `cal` slot

The fetch line gains a fourth slot: `fetch: yahoo 17/17 | ff OK | fred 29/30 | cal 41/45`. `n` = (currency, indicator) slots whose selected event yielded a usable cal series (≥ 2 dated actual points); `m` = slots attempted (an event was selected and its history pulled). When enumeration finds nothing for ANY ladder currency — the broker feeds no calendar — the slot reads **`cal n/a`** and the source marks itself unavailable for that cycle (recomputed fresh every cycle). Cal state deliberately does **not** feed the line's health coloring: a calendar-less broker is a legitimate state, not a fetch failure. Length: the composed example above is 51 chars, inside the 67-char budget at Mazi's saved 430 width — no slot label needed shortening (the line still wraps via `Wrap(cb)` when the last-error prefix leads, same as before). Two liveness hooks treat cal as a real source: the fetch cycle's any-data check and `CcySourceLive` (so a terminal where ONLY the calendar works still stamps FUND fresh instead of cautioning stale forever). No INI/GV format changed; `fetch_diag=` in `general_macro.ini` simply carries the longer line.

## 20.6 API-usage risks — stated plainly (this code has never been compiled)

1. **Member names come from MetaQuotes documentation, not from a compile.** Used: `CalendarEventsByCurrency`, `CalendarValueHistoryByEvent`, `MqlCalendarEvent.id` / `.name`, and `MqlCalendarValue.datetime` / `.period` / `.revision` with `HasActualValue()` / `GetActualValue()`. If any member differs in Mazi's build, the first MetaEditor compile points at the new block and only the new block.
2. **Value-time timezone basis is unverifiable offline.** Calendar datetimes may ride on trade-server time rather than GMT. The reader only orders points, floors them to days, and rejects future values, anchored to `TimeCurrent()` to stay on the calendar's own basis — all tolerant of a few hours either way.
3. **`GetActualValue()` scale.** It returns the published number in the event's own units (e.g. a payroll print in thousands). Direction-only scoring makes the absolute scale immaterial *within one event*; a feed that changed units mid-series for a single event would corrupt that one string — no such case is known, and the same exposure exists for the ff accumulation today.
4. **Event names are localized** to the terminal's display language. The keyword table is English (Mazi's terminal language). A non-English terminal would match little or nothing, and cal would read empty/`n/a` per currency — degraded, never wrong.
5. **Broker coverage is the real unknown** — some brokers serve a full calendar, some an empty one. That is precisely what the `cal n/m` (or `n/a`) slot reports on the first run; absence changes nothing else (§20.5).

## 20.7 Verification status (v4.9, honest — same caveat as §10/§12.8/§13.5/§14.3/§15.3/§16.3/§17.3/§19.6)

Still **not compiled** (no MQL5 compiler on the build VM). Static pass after all edits: brace/paren/bracket balance **320/320, 1670/1670, 553/553** (string/comment-aware stripper; deltas vs v4.8 are the new calendar block plus the diagnostics/reset edits); function definitions **109 by this build's counter, no duplicates** (the v4.8 file through the same counter reads 107; +2 = `CalClassify`, `FetchCalendarIntl`); every called name resolves to a definition or a standard MQL5 builtin — the checker flags only `HasActualValue` / `GetActualValue` (the `MqlCalendarValue` accessor methods, called on struct elements) plus the same three genuine builtins it flags on the v4.8 file (`GlobalVariableSet`, `ObjectsDeleteAll`, `TimeToString`, in untouched code); **zero order-placement functions**. Change surface, diffed against the pre-edit v4.8 file: header allowlist comment, version string, panel title, the `FSeries` source comment, the `g_d_cal_*` globals, the fetch-cycle reset/call/any-data lines, `BuildFetchDiag`, the `BestFundDir` tie-break values, `CcySourceLive`, and the new `CalClassify` + `FetchCalendarIntl` block — everything else byte-identical, proven by function-level md5 parity on 20 untouched functions (`FetchFred`, `FetchFredIntl`, `BuildFactors`, `ScoreFac`, `Regime`, `ApplyNewsAndBias`, `BuildPlaybook`, `ApplyFundCrossCheck`, `PublishLegacy`, `WriteIni`, `FSerScoreSeries`, `ComputeFundScores`, `FSerIdx`, `FSerAdd`, `LoadFFHistory`, `SaveFFHistory`, `FetchNews`, `ComputeIndexLegs`, `ComputeStrengths`, `EvaluateGate`: all identical). First MetaEditor compile — and the first on-terminal read of the `cal` slot, which settles the broker-coverage question — remains Mazi's step.

# 21. v4.91 (2026-10-16) — calendar API compile fixes

Mazi's first MetaEditor compile of v4.9 returned 11 errors / 1 warning, ALL inside the new calendar block (FetchCalendarIntl) — the §20.6 API-risk flag materialized. Fixes verified against the official MQL5 book/articles before applying:
1. `CalendarEventsByCurrency` does not exist — the enumeration function is `CalendarEventByCurrency(currency, events[])` (singular "Event"). Call fixed.
2. `MqlCalendarValue` has NO `datetime` member — the release-time field is `time` (struct: id, event_id, time, period, revision, actual_value, ...). Three `.datetime` reads replaced with `.time`.
3. Everything else the compile flagged was cascade from those two. `CalendarValueHistoryByEvent(id, values[], from, to)` argument order was confirmed correct as written; `HasActualValue()/GetActualValue()`, `.period`, `.revision` all confirmed real.
Version "4.91", panel title v4.91. No logic changes.

# Asian Session Logic — EA vs Industry Best Practices

**Purpose:** Compare our EA's Asian model with established gold (XAUUSD) Asian session strategies. Informs dual-platform (MT5 + cTrader) implementation.

---

## 1. Executive Summary

| Aspect | Our EA Logic | Industry Best Practice | Verdict |
|--------|--------------|------------------------|---------|
| **Core concept** | Sweep → close back inside → trade to midline | Liquidity sweep / Judas Swing / Range fade | ✅ **Aligned** |
| **Range definition** | High/low from window | Absolute wicks, session high/low | ✅ **Aligned** |
| **Time window** | 19:00–23:00 broker time | 00:00–06:00 UTC typical | ⚠️ **Needs timezone mapping** |
| **Entry timing** | Next candle after close-back-inside | Wait for candle close, avoid chasing | ✅ **Aligned** |
| **Targets** | TP1 = midline, TP2 = opposite extreme | Midline / VWAP reversion | ✅ **Aligned** |
| **SL placement** | Below sweep low / above sweep high | Beyond trap wicks, invalidation | ✅ **Aligned** |
| **Risk %** | 0.5% default | 0.25–0.75% | ✅ **Aligned** |
| **Spread buffer** | 1–2 pips | 5–10 pips for Asian thin liquidity | ⚠️ **Consider increasing** |

**Bottom line:** Our sweep → mean-reversion logic matches the dominant institutional narrative (liquidity sweep / Judas Swing). Main gaps: timezone alignment, optional range validation, and spread buffer for Asian thin liquidity.

---

## 2. Industry Framework (Gold Asian Session)

### 2.1 Session Structure (UTC Reference)

| Event | UTC Time | Significance |
|-------|----------|--------------|
| Daily reset | 00:00 | Initial Balance begins |
| Tokyo open | ~00:00 | First meaningful Asia liquidity |
| **Shanghai Gold Exchange (SGE) open** | **01:30** | **Critical pivot** — often 30–40 pip move, sets directional bias |
| Best trading window | 01:30–03:30 | Shanghai + initial price discovery |
| Liquidity box build | 00:00–06:00 | Standard "Asian range" definition |
| **Pre-London fakeout (Judas Swing)** | **~07:00** | Institutions sweep stops before London |

### 2.2 The "Liquidity Box" Concept

- **Definition:** Session high and low from 00:00–06:00 UTC (or equivalent broker time).
- **Psychology:** Buy stops above high, sell stops below low = liquidity for institutions.
- **Use:** Map where stops sit; anticipate sweeps (fakeouts) that trigger them, then reversal.

### 2.3 Three Entry Models (Industry)

1. **Range Fade** — Rejections at box edges, target midline. Limit orders at edges.
2. **Midline Reversion** — Scalps back to VWAP/midline after overextension.
3. **Break & Retest** — Wait for breakout, retest, then enter (London continuation anchor).

**Our EA:** Implements a **sweep + range fade** hybrid: sweep breaks the box, closes back inside, we enter toward midline. This is the "liquidity sweep" / "Judas Swing" play.

---

## 3. Detailed Comparison

### 3.1 Range Definition

| Our EA | Industry | Recommendation |
|--------|----------|----------------|
| `asiaHigh` = highest high, `asiaLow` = lowest low | Use absolute wicks (highs/lows) | ✅ Same — we use wicks |
| Single window (19:00–23:00) | Often 00:00–06:00 UTC | Map broker time → UTC; document clearly |
| No "touch both sides" filter | Some require price to touch both boundaries ≥2× | Optional: add `rangeValid` = (touchesHigh≥2 AND touchesLow≥2) |

### 3.2 Sweep Detection

| Our EA | Industry | Recommendation |
|--------|----------|----------------|
| High > asiaHigh, then close < asiaHigh (bullish sweep) | "Judas Swing" — fake breakout, pin bar, reversal | ✅ Logic matches |
| Low < asiaLow, then close > asiaLow (bearish sweep) | Same | ✅ Logic matches |
| sweepLow = min(low) of sweep candles | Stops beyond "trap wicks" | ✅ Use full sweep range (recommended) |
| Enter on next candle open | "Wait for candle to close" — don't chase | ✅ Bar-close logic — correct |

### 3.3 Targets

| Our EA | Industry | Recommendation |
|--------|----------|----------------|
| TP1 = asiaMid | Midline / VWAP reversion | ✅ Aligned |
| TP2 = asiaLow (long) / asiaHigh (short) | Opposite edge or runner | ✅ Aligned |
| Partial close at TP1 | — | Good for locking profit |

### 3.4 Risk & Stops

| Our EA | Industry | Recommendation |
|--------|----------|----------------|
| SL beyond sweep low/high + 1–2 pip buffer | 5–10 pip extra for Asian spread volatility | ⚠️ **Increase buffer to 5–10 pips** for XAUUSD |
| 0.5% risk | 0.25–0.75% | ✅ Fine |

---

## 4. Time Window Mapping (Critical)

**Industry standard (UTC):** Asian range = 00:00–06:00 UTC.

**Our spec:** 19:00–23:00 **broker time**.

Broker time varies:
- **GMT+2** (e.g. ICMarkets): 19:00 = 17:00 UTC, 23:00 = 21:00 UTC → range 17:00–21:00 UTC (pre-Asia)
- **GMT+3** (e.g. some ECN): 19:00 = 16:00 UTC, 23:00 = 20:00 UTC
- **Server = UTC**: 19:00 = 19:00 UTC, 23:00 = 23:00 UTC → overlaps Tokyo close, misses Shanghai open

**Recommendation for gold:**

| Option | Range Build (broker) | Trade Window (broker) | Notes |
|--------|---------------------|------------------------|------|
| **A: UTC-aligned** | 00:00–06:00 if server=UTC | 06:00–08:00 (pre-London sweep zone) | Matches industry; requires UTC or configurable offset |
| **B: User-defined** | Configurable start/end | Configurable | Most flexible; user sets based on broker |
| **C: Sydney–Tokyo** | e.g. 22:00–02:00 UTC | 02:00–06:00 | Covers Sydney + Tokyo |

**For EA:** Add `BrokerUTCoffset` (or auto-detect) and document that 00:00–06:00 UTC is the "gold standard" for Asian range. Allow override for broker time.

---

## 5. Optional Enhancements (From Industry)

| Enhancement | Description | EA Feasibility |
|-------------|-------------|----------------|
| **Shanghai filter** | Avoid new entries 01:30–02:00 UTC (SGE open volatility) or use as bias | Easy — time filter |
| **Range validation** | Require price to touch both asiaHigh and asiaLow ≥2 times | Medium — count touches in window |
| **VWAP** | Use VWAP instead of simple midline for TP1 | Medium — need tick/volume data |
| **Pin bar confirmation** | Sweep candle has long wick (e.g. body < 30% of range) | Easy — candle shape filter |
| **AUD/USD filter** | Correlation filter (advanced) | Hard — multi-symbol |

---

## 6. Recommended EA Logic Adjustments

### 6.1 Apply Now (High Impact)

1. **Sweep extreme:** Use `min(low)` / `max(high)` of all candles in sweep (not just sweep candle). ✅ Already in spec as optional — **make it default**.
2. **Spread buffer:** Increase from 1–2 to **5–10 pips** for XAUUSD Asian session (configurable).
3. **Timezone:** Add `BrokerUTCoffset` input; document that range 00:00–06:00 UTC is recommended for gold.

### 6.2 Optional (Medium Impact)

4. **Range validation:** Add `RequireRangeTouches` (default 2) — both boundaries must be touched at least N times.
5. **Pin bar filter:** Optional `RequireSweepPinBar` — sweep candle body < X% of full range.

### 6.3 Future (Lower Priority)

6. Shanghai time filter (avoid or favor 01:30 UTC).
7. VWAP-based midline (if volume available).

---

## 7. Updated Asia Logic (Consolidated)

```
// Range build (configurable; recommend 00:00-06:00 UTC equivalent)
asiaHigh = highest high in [rangeStart, rangeEnd]
asiaLow  = lowest low in [rangeStart, rangeEnd]
asiaMid  = (asiaHigh + asiaLow) / 2

// Optional: range valid only if both sides touched >= 2 times
rangeValid = (count(touch asiaHigh) >= 2) AND (count(touch asiaLow) >= 2)

// Sweep detection (after range build, before trade window end)
Bullish: high > asiaHigh, then close < asiaHigh
         sweepLow = min(low) of candles from first break to close-back-inside
Bearish: low < asiaLow, then close > asiaLow
         sweepHigh = max(high) of candles from first break to close-back-inside

// Entry
- On close-back-inside candle close: prepare order
- Enter at NEXT candle open
- SL: beyond sweep extreme + SweepBufferPips (default 5-10 for XAUUSD)
- TP1: asiaMid
- TP2: asiaLow (long) / asiaHigh (short)
```

---

## 8. References

- FXNX: XAUUSD Asian Session — Trading the Accumulation Phase
- Industry: Liquidity sweep / Judas Swing (07:00 UTC pre-London)
- Shanghai Gold Exchange: 01:30 UTC open as key pivot
- Risk: 0.25–0.75%, 1:2–1:3 R:R, 45% win rate acceptable

---

*Document version: 1.0 — For MT5 and cTrader implementation*

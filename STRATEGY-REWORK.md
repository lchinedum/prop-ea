# XAUUSD Session Strategy — Rework v2

**Purpose:** Simpler, clearer approach. Fix display issues and align with industry practice.

---

## 1. What Was Wrong (v1)

| Issue | Cause |
|-------|--------|
| "Asia Range: 5005.74" (single value) | Panel format unclear or truncation; confusing display |
| Too many overlapping levels | Asia + London + Prev Day all visible → clutter |
| Session times feel off | 19:00–23:00 broker time ≠ industry 00:00–06:00 UTC |
| NY signals firing too early | Displacement logic on single candle, no confirmation |
| Indicator "does not feel correct" | Logic scattered, hard to trust what you see |

---

## 2. Rework Principles

1. **One primary range at a time** — Show the range that matters for the current session.
2. **Clear session phases** — Building / Ready / Active / Closed.
3. **Industry-aligned times** — Option for UTC-based Asia (00:00–06:00).
4. **Robust range calculation** — Use `CopyRates` instead of bar iteration.
5. **Readable panel** — H / M / L on separate lines, no ambiguity.

---

## 3. Simplified Session Model

### Asia (Liquidity Sweep)

| Phase | Time (broker) | What shows |
|-------|----------------|------------|
| **Build** | 19:00–23:00 (or 00:00–06:00 UTC) | "Asia: Building..." |
| **Ready** | 23:00–02:00 | Asia H/M/L, "Wait for sweep" |
| **Active** | Sweep + close-back | Signal + SL/TP |
| **Closed** | After 02:00 | Asia levels kept for reference |

### NY (Displacement)

| Phase | Time | What shows |
|-------|------|------------|
| **Build** | 02:00–07:30 | London range builds |
| **Active** | 07:30–11:00 | Sweep + strong candle = signal |
| **Closed** | After 11:00 | Levels for reference |

---

## 4. Display Rules (Indicator)

- **Asia H / M / L** — Always show when valid (from last completed Asia session).
- **London H / L** — Show only during/after London (02:00–06:00).
- **Prev Day H / L** — Always show (thin, reference).
- **Info panel** — One line per level, e.g.:
  ```
  Asia H: 5010.50  M: 4989.50  L: 4974.50
  London: 5002.30 - 4985.10
  Prev: 5020.00 / 4960.00
  Phase: NY Active | No signal
  ```

---

## 5. Range Calculation (Robust)

Use `CopyRates` with explicit time range instead of iterating OnCalculate arrays:

```cpp
// Get bars from session window
int barStart = iBarShift(_Symbol, PERIOD_M5, rangeStart);
int barEnd   = iBarShift(_Symbol, PERIOD_M5, rangeEnd);
int count    = barStart - barEnd + 1;
if(count > 0) {
   CopyHigh/CopyLow from barEnd, count bars
   Compute high/low from those bars
}
```

This avoids series-index confusion and handles gaps.

---

## 6. Signal Logic (Stricter)

### Asia
- Sweep above → close back below Asia High → BUY (unchanged).
- Sweep below → close back above Asia Low → SELL (unchanged).
- **Add:** Require sweep candle to have wick (body < 70% of range) — filters chop.

### NY
- **Add:** Sweep must occur *before* displacement candle (not same candle).
- **Add:** Displacement = first strong candle *after* sweep; entry on retrace.
- Current: single-candle sweep+displacement → too loose.

---

## 7. Configurable Time Modes

| Mode | Asia Range | Use case |
|------|------------|----------|
| **Broker** | 19:00–23:00 | Default, broker server time |
| **UTC** | 00:00–06:00 | Industry standard (if broker = UTC) |
| **Custom** | User start/end | Any broker |

---

*Rework v2 — Apply to indicator first, then EA*

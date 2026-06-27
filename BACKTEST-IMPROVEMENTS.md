# Backtest Improvement Guide

## Critical: History Quality (31% in your test)

**Your backtest showed 31% history quality** — results are unreliable until this is fixed.

### How to improve:
1. **MT5 Strategy Tester** → Right-click symbol → "Refresh" to download more data
2. Use **"Every tick"** or **"1 minute OHLC"** model (not "Open prices only")
3. Extend the date range in **Tools → History Center** for XAUUSD M5
4. Re-run backtest — aim for **90%+ history quality**

---

## Strategy Tester Settings

| Setting | Recommendation |
|---------|----------------|
| **Timeframe** | M5 (EA uses M5 internally; chart can be M5) |
| **Model** | Every tick or 1 min OHLC |
| **Deposit** | 10,000+ for realistic lot sizing |
| **Spread** | Current or fixed (e.g. 30 for gold) |

---

## New EA Improvements (v1.1)

### 1. Quality filters (reduce bad trades)
- **Asia range min 15 pips** — skip choppy, tight ranges
- **Asia range max 80 pips** — skip wide ranges (SL too far)
- **Asia min RR 1:1** — skip setups where TP is closer than SL
- **Asia max SL 50 pips** — skip trades with very wide stops
- **Require both sides touched** — range must have tested high and low

### 2. Risk reduction
- Risk per trade: 0.5% → **0.35%**
- Daily loss limit: 3% → **2%**
- Drawdown limit: 10% → **8%**

### 3. Session toggles
- **Trade Asia** / **Trade NY** — disable one session to test which performs better

---

## Optimization Suggestions

1. **Test Asia-only vs NY-only** — one session may be more profitable
2. **Optimize Asia range hours** — try 00:00–06:00 UTC equivalent for your broker
3. **Optimize InpAsiaRangeMinPips** (10–25) and **InpAsiaRangeMaxPips** (60–100)
4. **Optimize InpAsiaMinRR** (0.5–1.5) — higher = fewer but better trades
5. **Optimize InpSweepBufferPips** (3–10) — gold can need more buffer

---

## If Still Losing

1. **Improve history quality first** — non-negotiable
2. **Trade Asia only** — often cleaner than NY for this strategy
3. **Increase InpAsiaMinRR to 1.5** — only take 1:1.5+ setups
4. **Reduce InpAsiaRangeMaxPips to 60** — avoid wide, volatile ranges
5. **Set InpAsiaRequireBothSides = true** — filter one-sided ranges

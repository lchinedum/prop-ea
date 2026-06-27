# XAUUSD Session-Based EA — Logic Specification

**Purpose:** Formal EA logic in platform-agnostic form. Ready for MT5 (MQL5) or cTrader (C#) implementation.

---

## 1. Core Constraints

| Parameter | Value | Notes |
|-----------|-------|-------|
| **Symbol** | XAUUSD | Single-symbol EA |
| **Max trades per day** | 2 | 1 per session block |
| **Asia trades per day** | 1 | Hard cap |
| **NY trades per day** | 1 | Hard cap |
| **Risk per trade** | Configurable % of balance | e.g. 0.5% |
| **Daily loss limit** | Configurable % (e.g. 3–5%) | Disables new entries if breached |
| **Account drawdown limit** | Configurable % | Disables EA until manual re-enable |

### Session Windows (broker time)

| Session | Start | End | Purpose |
|---------|-------|-----|---------|
| **Asia range build** | 19:00 | 23:00 | Build asiaHigh, asiaLow, asiaMid |
| **Asia trade window** | 23:00 | End of Asia range build window + N hours | Sweep detection & entries |
| **London range build** | 02:00 | 06:00 | Build londonHigh, londonLow |
| **NY trade window** | 07:30 | 11:00 | Sweep detection & entries |

**Note (Gold best practice):** Industry standard for XAUUSD Asian range is 00:00–06:00 UTC. If broker server ≠ UTC, use `BrokerUTCoffset` to align. Shanghai Gold Exchange opens 01:30 UTC — often a key pivot.

### Hard Filters (must all pass for any trade)

1. Current time is inside the relevant session window
2. No existing trade in that session today
3. Daily closed + floating PnL > −X% (daily loss limit)
4. Account drawdown < Y% (drawdown limit)
5. No pending orders that would violate session limits

---

## 2. Asia Model — Logic Flow

### 2.1 Range Definition

**When:** During Asia range build window (e.g. 19:00–23:00)

**At bar close of 23:00 (or last bar of window):**

```
asiaHigh  = highest high from 19:00 to 23:00
asiaLow   = lowest low from 19:00 to 23:00
asiaMid   = (asiaHigh + asiaLow) / 2
```

Store these for the current trading day. They remain valid until next day reset.

**Optional (industry):** Require `rangeValid` = price touched both asiaHigh and asiaLow at least 2× each — filters weak/ranging sessions.

---

### 2.2 Sweep Detection

**When:** After 23:00, within Asia trade window (e.g. 23:00–02:00 or configurable)

**Bullish sweep:**

1. At least one candle has `high > asiaHigh` (sweep above)
2. On the **current** or **next** candle: `close < asiaHigh` (close back inside range)
3. The sweep candle’s low = `sweepLow` (lowest low of the sweep move)

**Bearish sweep:**

1. At least one candle has `low < asiaLow` (sweep below)
2. On the **current** or **next** candle: `close > asiaLow` (close back inside range)
3. The sweep candle’s high = `sweepHigh` (highest high of the sweep move)

**Sweep low/high (recommended):**  
Use the extreme of **all** candles involved in the sweep (industry best practice — stops beyond trap wicks):
- Bullish: `sweepLow = min(low)` of candles from first candle above asiaHigh until close back inside
- Bearish: `sweepHigh = max(high)` of candles from first candle below asiaLow until close back inside

---

### 2.3 Entry Trigger (Asia)

**On the candle that closes back inside the range:**

**Bullish setup (sweep above → buy the dip):**

- **Action:** Place BUY on next candle open
- **SL:** Below `sweepLow` (add buffer — **5–10 pips** for XAUUSD Asian thin liquidity)
- **TP1:** `asiaMid`
- **TP2 (optional runner):** `asiaHigh` (target up)

**Bearish setup (sweep below → sell the rally):**

- **Action:** Place SELL on next candle open
- **SL:** Above `sweepHigh` (add buffer — 5–10 pips for XAUUSD)
- **TP1:** `asiaMid`
- **TP2 (optional runner):** `asiaLow` (target down)

**Entry timing:** Enter at the open of the first candle **after** the “close back inside” candle.

---

### 2.4 Risk & Management (Asia)

- **Lot size:** `lotSize = f(SL_distance, riskPercent, balance)`  
  - Standard: `lotSize = (balance * riskPercent/100) / (SL_distance_pips * pipValue)`
- **Optional:** Move SL to breakeven when price reaches `asiaMid` (Asia)
- **Optional:** Move SL to breakeven when 1R in profit (NY)
- **Optional:** Partial close at TP1 (e.g. 50%), let remainder run to TP2 (Asia)

---

## 3. NY Model — Logic Flow

### 3.1 Key Levels

**Available at NY window start (07:30):**

| Level | Source |
|-------|--------|
| `asiaHigh` | From Asia range (19:00–23:00) |
| `asiaLow` | From Asia range |
| `londonHigh` | Highest high from 02:00–06:00 |
| `londonLow` | Lowest low from 02:00–06:00 |
| `prevDayHigh` | Previous daily candle high |
| `prevDayLow` | Previous daily candle low |

---

### 3.2 Sweep Detection (NY)

**When:** During NY trade window (07:30–11:00)

**Bullish setup:**

1. Price makes a low that breaks at least one of: `asiaLow`, `londonLow`, `prevDayLow`
2. After the sweep, a **strong bullish candle** forms:
   - Body size > X% of recent range (configurable, e.g. 50–70%)
   - Close near high (e.g. top 25% of candle)

**Bearish setup:**

1. Price makes a high that breaks at least one of: `asiaHigh`, `londonHigh`, `prevDayHigh`
2. After the sweep, a **strong bearish candle** forms:
   - Body size > X% of recent range
   - Close near low (e.g. bottom 25% of candle)

---

### 3.3 Displacement Candle

**Definition:** The first strong opposite candle after the sweep.

**Bullish displacement:**

- First candle after sweep low that:
  - Is bullish (close > open)
  - Body size > N pips (configurable)
  - Closes above a minor structure (e.g. last swing high on lower TF, or simple threshold)

**Bearish displacement:**

- First candle after sweep high that:
  - Is bearish (close < open)
  - Body size > N pips
  - Closes below a minor structure

---

### 3.4 Entry Zone (NY)

**Bullish:**

- **Entry:** 50% retracement of displacement candle body, or small FVG below it
- **Simplified for EA:** Entry = `displacementCandle.open + (displacementCandle.close - displacementCandle.open) * 0.5`
- **SL:** Below sweep low (with buffer)

**Bearish:**

- **Entry:** 50% retracement of displacement candle body, or small FVG above it
- **Simplified:** Entry = `displacementCandle.close + (displacementCandle.open - displacementCandle.close) * 0.5`
- **SL:** Above sweep high (with buffer)

**Order type:** Limit order at entry level, or market when price retraces to entry zone (with tolerance in pips).

---

### 3.5 Targets (NY)

- **Primary:** Fixed RR (e.g. 1:2 or 1:3) from entry
- **Optional:** Target next liquidity:
  - Equal highs / equal lows
  - Asia or London opposite extreme

---

## 4. Daily Logic & Safety

### 4.1 New Day Reset

**At broker day change (e.g. 00:00 or configurable):**

1. Reset `asiaTradesToday = 0`
2. Reset `nyTradesToday = 0`
3. Recalculate `prevDayHigh`, `prevDayLow` from previous daily candle
4. Clear stored Asia/London range (or keep for reference if needed)

---

### 4.2 Per-Session Guards

- If `asiaTradesToday >= 1` → no new Asia entries
- If `nyTradesToday >= 1` → no new NY entries

---

### 4.3 Risk Guardrails

**Daily loss limit:**

```
dailyPnL = sum(closed trades today) + sum(floating PnL today)
if dailyPnL <= -dailyLossPercent% of balance:
    disable new entries for the day
```

**Account drawdown limit:**

```
drawdown = (balance - equity) / balance * 100
if drawdown >= drawdownLimitPercent:
    disable EA entirely until manually re-enabled
```

---

## 5. State Variables (EA Internal)

| Variable | Type | Reset |
|----------|------|-------|
| `asiaHigh`, `asiaLow`, `asiaMid` | double | New day |
| `londonHigh`, `londonLow` | double | New day |
| `prevDayHigh`, `prevDayLow` | double | New day |
| `asiaTradesToday` | int | New day |
| `nyTradesToday` | int | New day |
| `sweepLow`, `sweepHigh` | double | Per setup |
| `displacementCandle` | OHLC struct | Per setup |
| `dailyPnL` | double | Recalculated each tick/bar |
| `eaDisabled` | bool | Manual only |

---

## 6. Configurable Inputs (Suggested)

| Input | Default | Description |
|-------|---------|-------------|
| `RiskPercent` | 0.5 | Risk per trade (% of balance) |
| `DailyLossLimitPercent` | 3.0 | Max daily loss before disabling |
| `DrawdownLimitPercent` | 10.0 | Max drawdown before EA disable |
| `AsiaRangeStart` | 19 | Hour (broker time) |
| `AsiaRangeEnd` | 23 | Hour |
| `AsiaTradeWindowEnd` | 2 | Hour (next day) |
| `LondonStart` | 2 | Hour |
| `LondonEnd` | 6 | Hour |
| `NYStart` | 7 | Hour, 30 min = 7.5 |
| `NYEnd` | 11 | Hour |
| `SweepBufferPips` | 5 | Buffer beyond sweep high/low for SL (5–10 for XAUUSD Asian) |
| `BrokerUTCoffset` | 0 | Hours offset if broker time ≠ UTC (for Asia range alignment) |
| `DisplacementMinPips` | 10 | Min body size for displacement candle |
| `StrongCandleBodyPercent` | 50 | Min body % of range for NY setup |
| `TP1_RR` (NY) | 2.0 | Risk:reward for NY TP |
| `UseTP2_Asia` | true | Use runner to opposite extreme |
| `PartialClosePercent_Asia` | 50 | % to close at TP1 |

---

## 7. Implementation Notes

### MT5 (MQL5)

- Use `iHigh`, `iLow`, `iClose`, `iOpen` with `PERIOD_M1` or `PERIOD_M5` for range and sweep logic
- `SymbolInfoDouble(_Symbol, SYMBOL_POINT)` for pip/point conversion
- `OrderSend` for market/limit orders
- `OnTick` or `OnTimer` for logic; consider bar-close logic to avoid repainting

### cTrader (C#)

- `Bars` API for OHLC
- `ExecuteMarketOrder` / `ExecuteLimitOrder`
- `OnBar` / `OnTick` for event-driven logic
- `Symbol.PipSize` for pip calculations

### General

- Prefer **bar-close** logic to avoid repainting (e.g. check conditions on closed candle, enter on next open)
- Use **broker server time** for session windows
- Handle **spread** in SL/TP placement (e.g. add spread to SL buffer for sells)

---

*Document version: 1.0 — Ready for MT5 or cTrader implementation*

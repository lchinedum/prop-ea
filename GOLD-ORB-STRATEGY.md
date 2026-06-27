# Gold Dual Session Opening Range Breakout (ORB) Strategy

**Source:** London-New York Dual Session Breakout (quantitative, backtested)  
**Target:** 2+ trades daily on XAUUSD  
**Best for:** 5-minute or 15-minute charts

---

## 1. Core Concept

Capture price momentum at the **first 15 minutes** of two major sessions:
- **London:** 08:00–08:15 UTC (3:00–3:15 New York time)
- **New York:** 14:30–14:45 UTC (9:30–9:45 New York time)

Enter when price **breaks out** of the range with a candle close (not just a wick).

---

## 2. Session Windows (UTC)

| Session | Range Build | Trade Window |
|---------|-------------|--------------|
| **London** | 08:00–08:15 UTC | 08:15–12:00 UTC |
| **New York** | 14:30–14:45 UTC | 14:45–18:00 UTC |

---

## 3. Rules (Per Session)

### 3.1 Range Build
- Record **high** and **low** of the first 15 minutes
- Range must be ≥ **minimum size** (e.g. 2 points for gold, or 20 pips)
- One range per session per day

### 3.2 Entry
- **Long:** Candle **closes** above range high (with optional EMA filter)
- **Short:** Candle **closes** below range low (with optional EMA filter)
- **Confirmation:** Previous candle was inside range (prev close ≤ high for long, prev close ≥ low for short)

### 3.3 Stop Loss
- **Long:** Range low − **1 × range height**
- **Short:** Range high + **1 × range height**

### 3.4 Take Profit
- **Long:** Range high + **2 × range height** (2:1 RR)
- **Short:** Range low − **2 × range height** (2:1 RR)

### 3.4b Trailing Stop (Optional)
- **8 pips** (or configurable) trailing after entry

### 3.5 Filters
- **EMA filter:** Only long when price > 200 EMA (5-min), only short when price < 200 EMA
- **Min range:** Skip if range < 2 points (or 20 pips for gold)
- **One trade per session:** Max 1 London, 1 NY per day

---

## 4. Indicator Outputs

- **London ORB:** High/low lines (08:00–08:15 UTC)
- **NY ORB:** High/low lines (14:30–14:45 UTC)
- **SL/TP levels:** When breakout detected
- **Phase:** "London ORB building" / "London trade" / "NY ORB building" / "NY trade"
- **Signal arrows:** Green (long) / Red (short) on breakout

---

## 5. Timezone (Broker Offset)

- **Broker UTC+2:** Set offset = 2 → London 10:00–10:15 broker, NY 16:30–16:45 broker
- **Broker = UTC:** London 08:00–08:15, NY 14:30–14:45

---

## 6. References

- GoldPIPHub: London Breakout Strategy
- FMZ: London-New York Dual Session Breakout Trailing Stop
- United Kings: XAUUSD Session Strategy Playbook

*Strategy version 1.0 — For MT5 indicator*

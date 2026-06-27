# XAUUSD Session Indicator

Visual indicator for the **best gold strategy** in Asian and NY sessions — liquidity sweep + displacement.

**Platforms:** MT5 (`MT5/XAUUSD_Session_Indicator.mq5`) | cTrader (`cTrader/XAUUSD_Session_Indicator.cs`)

## What It Shows

### Levels (horizontal lines)
| Level | Color | Description |
|-------|-------|-------------|
| **Asia High** | Blue | Session high (19:00–23:00) |
| **Asia Low** | Crimson | Session low |
| **Asia Mid** | Gold | Midline — TP1 target |
| **London High/Low** | Gray | London range (02:00–06:00) |
| **Prev Day H/L** | Dark gray | Previous daily high/low |

### Signals
- **Green arrow ↑** — Asia BUY (sweep above → close back inside)
- **Red arrow ↓** — Asia SELL (sweep below → close back inside)
- **NY BUY/SELL** — Sweep + strong displacement candle

### Info Panel (top-left)
- Current time
- Asia range levels
- London range
- Prev day levels
- **Active signal** with SL, TP1, TP2 when setup triggers

## Installation

1. Copy `XAUUSD_Session_Indicator.mq5` to `MQL5/Indicators/`
2. Compile in MetaEditor (F7)
3. Attach to **XAUUSD M5** chart
4. Adjust session hours if your broker uses different timezone

## Session Times (broker time)

| Session | Default | Purpose |
|---------|---------|---------|
| Asia range | 19:00–23:00 | Build liquidity box |
| Asia trade | 23:00–02:00 | Sweep detection window |
| London | 02:00–06:00 | London range |
| NY | 07:30–11:00 | Displacement setups |

## Strategy Logic (Manual Trading)

### Asia setup
1. Wait for **sweep** (price breaks Asia high or low)
2. Wait for **close back inside** the range
3. **BUY** if swept above → SL below sweep low, TP1=midline, TP2=Asia high
4. **SELL** if swept below → SL above sweep high, TP1=midline, TP2=Asia low

### NY setup
1. Price **sweeps** Asia/London/PrevDay low or high
2. **Strong opposite candle** (body > 50% of range, > 10 pips)
3. **BUY** on sweep low + bullish candle
4. **SELL** on sweep high + bearish candle

## Tips

- Use **M5** timeframe — best for gold session strategy
- Adjust hours for your broker (e.g. GMT+2: 19:00 = 17:00 UTC)
- Industry standard Asia range: 00:00–06:00 UTC
- Enable **Alert on signal** for notifications

//+------------------------------------------------------------------+
//| Scalper_EA.mq5                                                    |
//| Matches chart annotations: EMA(7), EMA(21), pivot breaks,        |
//| measured move, EMA7 lower-high / higher-low, pullbacks.            |
//| One position at a time. Modes: full Scalper rules OR Simple trend |
//| (H1 bull + M1 pullback, long-only, fixed SL/TP).                    |
//+------------------------------------------------------------------+
#property copyright "Scalper EA"
#property version   "5.41"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Inlined: VolumeBreakoutFilter (relative tick-volume + candle strength)
//+------------------------------------------------------------------+
bool VBF_SpreadOK(const int maxSpreadPoints)
{
   if(maxSpreadPoints <= 0) return true;
   return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= maxSpreadPoints;
}

double VBF_AvgTickVolume(const string sym, const ENUM_TIMEFRAMES tf, const int shiftStart, const int period)
{
   if(period <= 0) return 0.0;
   long sum = 0;
   int count = 0;
   int bars = iBars(sym, tf);
   for(int i = shiftStart; i < shiftStart + period && i < bars; i++)
   {
      sum += (long)iTickVolume(sym, tf, i);
      count++;
   }
   return (count > 0) ? ((double)sum / (double)count) : 0.0;
}

bool VBF_PassesRelativeVolume(const string sym, const ENUM_TIMEFRAMES tf, const datetime signalBarTime,
                              const int avgPeriod, const double minRelMult)
{
   if(minRelMult <= 0.0 || avgPeriod <= 0) return true;
   int shSig = iBarShift(sym, tf, signalBarTime, false);
   if(shSig < 0) return false;
   long volSig = (long)iTickVolume(sym, tf, shSig);
   double avgVol = VBF_AvgTickVolume(sym, tf, shSig + 1, avgPeriod);
   if(avgVol <= 0.0) return (volSig > 0);
   return ((double)volSig >= avgVol * minRelMult);
}

bool VBF_PassesRisingVolume(const string sym, const ENUM_TIMEFRAMES tf, const datetime signalBarTime)
{
   int shSig = iBarShift(sym, tf, signalBarTime, false);
   if(shSig < 0) return false;
   int shPrev = shSig + 1;
   if(shPrev >= iBars(sym, tf)) return false;
   long volSig  = (long)iTickVolume(sym, tf, shSig);
   long volPrev = (long)iTickVolume(sym, tf, shPrev);
   return (volSig > volPrev);
}

bool VBF_PassesCandleStrength(const string sym, const ENUM_TIMEFRAMES tf, const datetime signalBarTime,
                              const bool isLong, const double minCloseFrac)
{
   if(minCloseFrac <= 0.0 || minCloseFrac >= 1.0) return true;
   int sh = iBarShift(sym, tf, signalBarTime, false);
   if(sh < 0) return false;
   double hi = iHigh(sym, tf, sh);
   double lo = iLow(sym, tf, sh);
   double cl = iClose(sym, tf, sh);
   double range = hi - lo;
   if(range <= 0.0) return true;
   double pos = (cl - lo) / range;
   if(isLong) return (pos >= minCloseFrac);
   return (pos <= (1.0 - minCloseFrac));
}

bool VBF_PassesBreakoutVolume(const string sym, const ENUM_TIMEFRAMES tf, const datetime signalBarTime,
                              const bool isLong,
                              const bool useFilter,
                              const int avgPeriod,
                              const double minRelMult,
                              const bool requireRising,
                              const bool useCandleStrength,
                              const double minCloseFrac)
{
   if(!useFilter) return true;
   if(signalBarTime <= 0) return false;
   if(requireRising && !VBF_PassesRisingVolume(sym, tf, signalBarTime)) return false;
   if(!VBF_PassesRelativeVolume(sym, tf, signalBarTime, avgPeriod, minRelMult)) return false;
   if(useCandleStrength && !VBF_PassesCandleStrength(sym, tf, signalBarTime, isLong, minCloseFrac)) return false;
   return true;
}

//--- General
input string   InpGeneral  = "=== General ===";
enum ENUM_EA_MODE
{
   MODE_SCALPER = 0,       // chart TF: multi-strategy scalper logic below
   MODE_SIMPLE_TREND = 1   // H1 EMA bull + M1 pullback to slow EMA; long only; fixed SL/TP
};
input ENUM_EA_MODE InpMode = MODE_SCALPER;
input ulong    InpMagic    = 20260410;
input string   InpComment  = "Scalper";
input double   InpLots     = 1.0;
input int      InpSlippage = 30;
input int      InpMaxSpread = 0;              // 0 = off

input string   InpVolHdr   = "=== Volume-confirmed breakout (CFD) ===";
input bool     InpUseVolumeFilter      = true;
input int      InpVolAvgPeriod         = 20;
input double   InpVolMinRelMult        = 1.5;
input bool     InpVolRequireRising     = true;
input bool     InpVolUseCandleStrength = true;
input double   InpVolMinCloseFrac      = 0.70;

//--- Risk / chop control (reduces whipsaw & huge SL trades on XAU M1)
input string   InpRisk     = "=== Risk & session filters ===";
input bool     InpUseHTFRegime = true;        // M15: buys only if EMAfast>EMAslow; sells only if EMAfast<EMAslow
input ENUM_TIMEFRAMES InpHTF_Regime = PERIOD_M15;
input int      InpHTF_MinSepPts = 20;        // min |fast−slow| on M15 (points); 0 = sign only
input bool     InpRequireH1SameDirection = true; // also require H1 EMA7>EMA21 for buys, reverse for sells (stops shorts in H1 bull)
input bool     InpRequireChartEMAOrder = true; // chart TF: buy only if EMAfast>EMAslow; sell only if EMAfast<EMAslow
input double   InpMinRewardRisk = 1.0;       // min TP distance / SL distance (0 = skip check)
input int      InpMinRiskPoints = 100;       // min entry→SL distance (points); blocks tiny/nonsense stops (0=off)
input int      InpCooldownAfterCloseSec = 600; // pause after each close (0=off)
input int      InpMinSecondsBetweenEntries = 600; // min gap after any new position opens (0=off)
input int      InpMaxTradesPerDay = 10;      // max new entries per server day (0=off)
input int      InpMaxConsecLosses = 3;       // after this many losses in a row, pause (0=off)
input int      InpLossStreakCooldownSec = 3600; // pause length after loss streak (sec)
input double   InpMaxDailyLossMoney = 0.0;   // stop new entries if today’s net P/L <= -this (0=off)
input int      InpATR_Period = 14;
input int      InpMinATRPoints = 0;           // skip dead volatility; XAU M1 often 150–500+ (0=off)
input int      InpMaxRiskPoints = 500;       // max entry→SL distance (points); 0=off — caps outlier risk (tune to broker)

input string   InpBE       = "=== Breakeven (open position) ===";
input int      InpBE_TriggerPts = 120;       // move SL when profit >= this (points); 0=off
input int      InpBE_OffsetPts = 15;        // new SL = entry +/- this (points); locks small profit

input string   InpEMAs     = "=== EMAs (screenshots) ===";
input int      InpEMA_Fast = 7;
input int      InpEMA_Slow = 21;

//--- Which setups to use (disable all but one to test)
input string   InpStrat    = "=== Strategies ===";
input bool     InpSell_PivotCloseBelowLow = false;  // counter-trend; needs HTF+max risk or off
input bool     InpBuy_PivotCloseAboveHigh = false;
input bool     InpSell_MeasuredBreakdown  = false;
input bool     InpBuy_MeasuredBreakout    = false;
input bool     InpSell_EMA7LowerHigh      = false; // off by default: main source of sells-into-rallies on XAU
input bool     InpBuy_EMA7HigherLow       = true;
input bool     InpSell_PullbackBearish    = false; // off by default: use with H1 regime + backtest
input bool     InpBuy_PullbackBullish     = true;

//--- Pivot (most recent low / high)
input string   InpPv       = "=== Pivot break (close past swing) ===";
input int      InpPv_Lookback = 18;
input int      InpPv_Depth  = 22;
input bool     InpPv_UseMeasuredTP = true;        // TP = 1:1 from swing extreme to entry (as in pic)
input int      InpPv_SL_BufferPts = 25;

//--- Measured move (horizontal break)
input string   InpM        = "=== Measured horizontal break ===";
input int      InpM_Lookback = 15;
input int      InpM_BufferPts = 5;
input int      InpM_SL_LongPts  = 15;
input int      InpM_SL_ShortPts = 15;

//--- EMA7 reversal (lower high / higher low)
input string   InpE7       = "=== EMA7 first break + structure ===";
input int      InpE7_MinTrendBars = 5;
input int      InpE7_SwingLookback = 25;
input int      InpE7_SL_BufferPts = 25;
input double   InpE7_TP_RMultiple = 1.5;

//--- Pullback
input string   InpPb       = "=== Pullback to EMAs ===";
input int      InpPb_TouchPts = 18;
input int      InpPb_SlopeBars = 2;
input int      InpPb_RangeBars = 10;
input int      InpPb_SL_BufferPts = 25;
input double   InpPb_TP_RMultiple = 1.5;

//--- Simple trend mode (used when InpMode = Simple trend)
input string   InpSimpleHdr = "=== Simple trend mode only ===";
input int      InpSimple_SL_Points = 200;
input int      InpSimple_TP_Points = 300;
input int      InpSimple_PullbackTouchPts = 25;

CTrade   g_trade;
int      g_hEMA_Fast = INVALID_HANDLE;
int      g_hEMA_Slow = INVALID_HANDLE;
int      g_hHTFFast = INVALID_HANDLE;
int      g_hHTFSlow = INVALID_HANDLE;
int      g_hH1Fast = INVALID_HANDLE;
int      g_hH1Slow = INVALID_HANDLE;
int      g_hM1Fast = INVALID_HANDLE;
int      g_hM1Slow = INVALID_HANDLE;
int      g_hATR = INVALID_HANDLE;
datetime g_cooldown_until = 0;
datetime g_next_entry_earliest = 0;
datetime g_entries_day = 0;
int      g_entries_today = 0;
int      g_consec_losses = 0;

enum ENUM_S7S { S7S_IDLE = 0, S7S_WAIT_LH, S7S_ARMED };
ENUM_S7S g_s7s = S7S_IDLE;
double   g_s7s_sh = 0, g_s7s_sl = 0, g_s7s_min = 0, g_s7s_maxh = 0;
int      g_s7s_wait = 0;
datetime g_s7s_t = 0;

enum ENUM_S7B { S7B_IDLE = 0, S7B_WAIT_HL, S7B_ARMED };
ENUM_S7B g_s7b = S7B_IDLE;
double   g_s7b_sl = 0, g_s7b_sh = 0, g_s7b_max = 0, g_s7b_minl = 0;
int      g_s7b_wait = 0;
datetime g_s7b_t = 0;

//+------------------------------------------------------------------+
void SetFilling()
{
   long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fm & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

double Pt() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
double Np(const double p) { return NormalizeDouble(p, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)); }

bool StopsOK(const bool buy, const double sl, const double tp)
{
   long lv = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(lv <= 0) return true;
   double d = (double)lv * Pt();
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(buy)
   {
      if(sl > 0 && (ask - sl) < d) return false;
      if(tp > 0 && (tp - ask) < d) return false;
   }
   else
   {
      if(sl > 0 && (sl - bid) < d) return false;
      if(tp > 0 && (bid - tp) < d) return false;
   }
   return true;
}

bool EntryRiskOK(const bool buy, const double sl)
{
   double entry = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double distPts = MathAbs(entry - sl) / Pt();
   if(InpMinRiskPoints > 0 && distPts < (double)InpMinRiskPoints) return false;
   if(InpMaxRiskPoints <= 0) return true;
   return (distPts <= (double)InpMaxRiskPoints);
}

bool RewardRiskOK(const bool buy, const double sl, const double tp)
{
   if(InpMinRewardRisk <= 0.0 || tp <= 0.0) return true;
   double entry = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double risk = buy ? (entry - sl) : (sl - entry);
   double reward = buy ? (tp - entry) : (entry - tp);
   if(risk <= 0.0) return false;
   return (reward / risk >= InpMinRewardRisk - 1e-9);
}

bool ChartTrendAligned(const bool wantBuy, const double &ef[], const double &es[])
{
   if(!InpRequireChartEMAOrder) return true;
   if((int)ArraySize(ef) < 2 || (int)ArraySize(es) < 2) return false;
   if(wantBuy) return (ef[1] > es[1]);
   return (ef[1] < es[1]);
}

datetime DayStart(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return StructToTime(dt);
}

bool DailyLossLimitHit()
{
   if(InpMaxDailyLossMoney <= 0.0) return false;
   datetime from = DayStart(TimeCurrent());
   if(!HistorySelect(from, TimeCurrent())) return false;
   double net = 0.0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != (long)InpMagic) continue;
      net += HistoryDealGetDouble(d, DEAL_PROFIT);
      net += HistoryDealGetDouble(d, DEAL_SWAP);
      net += HistoryDealGetDouble(d, DEAL_COMMISSION);
   }
   return (net <= -InpMaxDailyLossMoney);
}

void ManageBreakeven()
{
   if(InpBE_TriggerPts <= 0) return;
   double pt = Pt();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(type == POSITION_TYPE_BUY)
      {
         double profitPts = (bid - open) / pt;
         if(profitPts < (double)InpBE_TriggerPts) continue;
         double newSL = Np(open - (double)InpBE_OffsetPts * pt);
         if(sl >= newSL - pt * 0.25) continue;
         if(newSL >= bid - pt) continue;
         if(!StopsOK(true, newSL, tp)) continue;
         g_trade.PositionModify(ticket, newSL, tp);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profitPts = (open - ask) / pt;
         if(profitPts < (double)InpBE_TriggerPts) continue;
         double newSL = Np(open + (double)InpBE_OffsetPts * pt);
         if(sl <= newSL + pt * 0.25) continue;
         if(newSL <= ask + pt) continue;
         if(!StopsOK(false, newSL, tp)) continue;
         g_trade.PositionModify(ticket, newSL, tp);
      }
   }
}

bool OpenBuy(const double sl, const double tp)
{
   if(!EntryRiskOK(true, sl)) return false;
   if(!RewardRiskOK(true, sl, tp)) return false;
   if(!StopsOK(true, sl, tp)) return false;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   return g_trade.Buy(InpLots, _Symbol, ask, Np(sl), Np(tp), InpComment);
}

bool OpenSell(const double sl, const double tp)
{
   if(!EntryRiskOK(false, sl)) return false;
   if(!RewardRiskOK(false, sl, tp)) return false;
   if(!StopsOK(false, sl, tp)) return false;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return g_trade.Sell(InpLots, _Symbol, bid, Np(sl), Np(tp), InpComment);
}

int CountOurPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      n++;
   }
   return n;
}

bool NewBar()
{
   static datetime last = 0;
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t == 0 || t == last) return false;
   last = t;
   return true;
}

bool NewBarM1()
{
   static datetime last = 0;
   datetime t = iTime(_Symbol, PERIOD_M1, 0);
   if(t == 0 || t == last) return false;
   last = t;
   return true;
}

bool SpreadOK()
{
   if(InpMaxSpread <= 0) return true;
   return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpread;
}

bool BreakoutVolumeOK(const bool isLong)
{
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 1);
   return VBF_PassesBreakoutVolume(_Symbol, PERIOD_CURRENT, t, isLong,
      InpUseVolumeFilter, InpVolAvgPeriod, InpVolMinRelMult, InpVolRequireRising,
      InpVolUseCandleStrength, InpVolMinCloseFrac);
}

bool VolatilityOK()
{
   if(InpMinATRPoints <= 0 || g_hATR == INVALID_HANDLE) return true;
   double a[];
   ArraySetAsSeries(a, true);
   if(CopyBuffer(g_hATR, 0, 1, 1, a) != 1) return false;
   return (a[0] >= (double)InpMinATRPoints * Pt());
}

bool CooldownOK()
{
   return (TimeCurrent() >= g_cooldown_until);
}

void ResetDailyTradeCount()
{
   datetime ds = DayStart(TimeCurrent());
   if(g_entries_day != ds)
   {
      g_entries_day = ds;
      g_entries_today = 0;
   }
}

bool EntrySpacingOK()
{
   if(InpMinSecondsBetweenEntries > 0 && TimeCurrent() < g_next_entry_earliest) return false;
   if(InpMaxTradesPerDay > 0 && g_entries_today >= InpMaxTradesPerDay) return false;
   return true;
}

bool EMAStackBuyOK(const int hFast, const int hSlow)
{
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE) return false;
   double hf[], hs[];
   ArraySetAsSeries(hf, true);
   ArraySetAsSeries(hs, true);
   if(CopyBuffer(hFast, 0, 0, 3, hf) < 3 || CopyBuffer(hSlow, 0, 0, 3, hs) < 3) return false;
   double sep = (hf[1] - hs[1]) / Pt();
   if(InpHTF_MinSepPts <= 0) return (sep > 0.0);
   return (sep >= (double)InpHTF_MinSepPts);
}

bool EMAStackSellOK(const int hFast, const int hSlow)
{
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE) return false;
   double hf[], hs[];
   ArraySetAsSeries(hf, true);
   ArraySetAsSeries(hs, true);
   if(CopyBuffer(hFast, 0, 0, 3, hf) < 3 || CopyBuffer(hSlow, 0, 0, 3, hs) < 3) return false;
   double sep = (hs[1] - hf[1]) / Pt();
   if(InpHTF_MinSepPts <= 0) return (sep > 0.0);
   return (sep >= (double)InpHTF_MinSepPts);
}

// M15 (and optional H1) must agree: stops “M15 bearish / H1 bullish” shorts into M1 rallies
bool RegimeAllowsBuy()
{
   if(!InpUseHTFRegime && !InpRequireH1SameDirection) return true;
   if(InpUseHTFRegime)
   {
      if(!EMAStackBuyOK(g_hHTFFast, g_hHTFSlow)) return false;
   }
   if(InpRequireH1SameDirection)
   {
      if(!EMAStackBuyOK(g_hH1Fast, g_hH1Slow)) return false;
   }
   return true;
}

bool RegimeAllowsSell()
{
   if(!InpUseHTFRegime && !InpRequireH1SameDirection) return true;
   if(InpUseHTFRegime)
   {
      if(!EMAStackSellOK(g_hHTFFast, g_hHTFSlow)) return false;
   }
   if(InpRequireH1SameDirection)
   {
      if(!EMAStackSellOK(g_hH1Fast, g_hH1Slow)) return false;
   }
   return true;
}

bool CopyEma(const int h, const int n, double &b[])
{
   ArraySetAsSeries(b, true);
   return CopyBuffer(h, 0, 0, n, b) == n;
}

double HH(const int from, const int bars)
{
   if(bars <= 0) return 0;
   double m = 0; bool f = true;
   for(int i = from; i < from + bars && i < 10000; i++)
   {
      double x = iHigh(_Symbol, PERIOD_CURRENT, i);
      if(f || x > m) { m = x; f = false; }
   }
   return m;
}

double LL(const int from, const int bars)
{
   if(bars <= 0) return 0;
   double m = 0; bool f = true;
   for(int i = from; i < from + bars && i < 10000; i++)
   {
      double x = iLow(_Symbol, PERIOD_CURRENT, i);
      if(f || x < m) { m = x; f = false; }
   }
   return m;
}

int IdxHH(const int from, const int bars)
{
   if(bars <= 0) return from;
   double mx = -1; int ix = from;
   for(int i = from; i < from + bars && i < 10000; i++)
   {
      double x = iHigh(_Symbol, PERIOD_CURRENT, i);
      if(mx < 0 || x >= mx) { mx = x; ix = i; }
   }
   return ix;
}

int IdxLL(const int from, const int bars)
{
   if(bars <= 0) return from;
   double mn = 1e100; int ix = from;
   for(int i = from; i < from + bars && i < 10000; i++)
   {
      double x = iLow(_Symbol, PERIOD_CURRENT, i);
      if(x <= mn) { mn = x; ix = i; }
   }
   return ix;
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpEMA_Fast < 1 || InpEMA_Slow < 1 || InpEMA_Fast >= InpEMA_Slow)
      return INIT_PARAMETERS_INCORRECT;
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints((uint)InpSlippage);
   SetFilling();
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(InpLots < mn || InpLots > mx || st <= 0) return INIT_PARAMETERS_INCORRECT;

   if(InpMode == MODE_SIMPLE_TREND)
   {
      g_hH1Fast = iMA(_Symbol, PERIOD_H1, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
      g_hH1Slow = iMA(_Symbol, PERIOD_H1, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
      g_hM1Fast = iMA(_Symbol, PERIOD_M1, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
      g_hM1Slow = iMA(_Symbol, PERIOD_M1, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
      if(g_hH1Fast == INVALID_HANDLE || g_hH1Slow == INVALID_HANDLE) return INIT_FAILED;
      if(g_hM1Fast == INVALID_HANDLE || g_hM1Slow == INVALID_HANDLE) return INIT_FAILED;
      g_hATR = iATR(_Symbol, PERIOD_M1, InpATR_Period);
      if(g_hATR == INVALID_HANDLE) return INIT_FAILED;
      return INIT_SUCCEEDED;
   }

   g_hEMA_Fast = iMA(_Symbol, PERIOD_CURRENT, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMA_Slow = iMA(_Symbol, PERIOD_CURRENT, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hEMA_Fast == INVALID_HANDLE || g_hEMA_Slow == INVALID_HANDLE) return INIT_FAILED;

   g_hATR = iATR(_Symbol, PERIOD_CURRENT, InpATR_Period);
   if(g_hATR == INVALID_HANDLE) return INIT_FAILED;

   if(InpUseHTFRegime)
   {
      g_hHTFFast = iMA(_Symbol, InpHTF_Regime, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
      g_hHTFSlow = iMA(_Symbol, InpHTF_Regime, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
      if(g_hHTFFast == INVALID_HANDLE || g_hHTFSlow == INVALID_HANDLE) return INIT_FAILED;
   }
   if(InpRequireH1SameDirection)
   {
      g_hH1Fast = iMA(_Symbol, PERIOD_H1, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
      g_hH1Slow = iMA(_Symbol, PERIOD_H1, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
      if(g_hH1Fast == INVALID_HANDLE || g_hH1Slow == INVALID_HANDLE) return INIT_FAILED;
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_hEMA_Fast != INVALID_HANDLE) IndicatorRelease(g_hEMA_Fast);
   if(g_hEMA_Slow != INVALID_HANDLE) IndicatorRelease(g_hEMA_Slow);
   if(g_hHTFFast != INVALID_HANDLE) IndicatorRelease(g_hHTFFast);
   if(g_hHTFSlow != INVALID_HANDLE) IndicatorRelease(g_hHTFSlow);
   if(g_hH1Fast != INVALID_HANDLE) IndicatorRelease(g_hH1Fast);
   if(g_hH1Slow != INVALID_HANDLE) IndicatorRelease(g_hH1Slow);
   if(g_hM1Fast != INVALID_HANDLE) IndicatorRelease(g_hM1Fast);
   if(g_hM1Slow != INVALID_HANDLE) IndicatorRelease(g_hM1Slow);
   if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.symbol != _Symbol) return;
   ulong deal = trans.deal;
   if(deal == 0) return;
   if(HistoryDealGetInteger(deal, DEAL_MAGIC) != (long)InpMagic) return;

   long entryKind = HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entryKind == DEAL_ENTRY_IN)
   {
      if(InpMinSecondsBetweenEntries > 0)
         g_next_entry_earliest = TimeCurrent() + InpMinSecondsBetweenEntries;
      datetime ds = DayStart(TimeCurrent());
      if(g_entries_day != ds)
      {
         g_entries_day = ds;
         g_entries_today = 0;
      }
      g_entries_today++;
      return;
   }
   if(entryKind != DEAL_ENTRY_OUT) return;

   datetime now = TimeCurrent();
   datetime until = now;
   if(InpCooldownAfterCloseSec > 0)
      until = now + InpCooldownAfterCloseSec;

   double pnl = HistoryDealGetDouble(deal, DEAL_PROFIT)
              + HistoryDealGetDouble(deal, DEAL_SWAP)
              + HistoryDealGetDouble(deal, DEAL_COMMISSION);
   if(pnl < 0.0)
   {
      g_consec_losses++;
      if(InpMaxConsecLosses > 0 && g_consec_losses >= InpMaxConsecLosses)
      {
         datetime st = now + InpLossStreakCooldownSec;
         if(st > until) until = st;
         g_consec_losses = 0;
      }
   }
   else
      g_consec_losses = 0;

   g_cooldown_until = until;
}

//+------------------------------------------------------------------+
// SELL: close below most recent low (older bars than peak)
//+------------------------------------------------------------------+
bool TrySell_PivotBelowLow(const double &ef[], const double &es[])
{
   int pl = MathMax(5, InpPv_Lookback);
   int dd = MathMax(5, InpPv_Depth);
   if((int)ArraySize(ef) < pl + dd + 5) return false;
   if(ef[1] <= es[1]) return false;

   int pk = IdxHH(2, pl);
   double recent_low = LL(pk + 1, dd);
   double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   if(c1 >= recent_low) return false;
   if(!BreakoutVolumeOK(false)) return false;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double swing_high = HH(1, pl);
   double sl = swing_high + InpPv_SL_BufferPts * Pt();

   double tp;
   if(InpPv_UseMeasuredTP)
   {
      double risk = swing_high - bid;
      if(risk <= 0) return false;
      tp = bid - risk;
   }
   else
   {
      double r = sl - bid;
      if(r <= 0) return false;
      tp = bid - r * InpE7_TP_RMultiple;
   }
   return OpenSell(sl, tp);
}

//+------------------------------------------------------------------+
// BUY: close above most recent high (mirror)
//+------------------------------------------------------------------+
bool TryBuy_PivotAboveHigh(const double &ef[], const double &es[])
{
   int pl = MathMax(5, InpPv_Lookback);
   int dd = MathMax(5, InpPv_Depth);
   if((int)ArraySize(ef) < pl + dd + 5) return false;
   if(ef[1] >= es[1]) return false;

   int tr = IdxLL(2, pl);
   double recent_high = HH(tr + 1, dd);
   double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   if(c1 <= recent_high) return false;
   if(!BreakoutVolumeOK(true)) return false;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double swing_low = LL(1, pl);
   double sl = swing_low - InpPv_SL_BufferPts * Pt();

   double tp;
   if(InpPv_UseMeasuredTP)
   {
      double risk = ask - swing_low;
      if(risk <= 0) return false;
      tp = ask + risk;
   }
   else
   {
      double r = ask - sl;
      if(r <= 0) return false;
      tp = ask + r * InpE7_TP_RMultiple;
   }
   return OpenBuy(sl, tp);
}

//+------------------------------------------------------------------+
bool TrySell_MeasuredBreakdown(const double &ef[], const double &es[])
{
   int L = MathMax(3, InpM_Lookback);
   if((int)ArraySize(ef) < L + 3) return false;
   double S = LL(2, L);
   double E = es[1];
   double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double b = InpM_BufferPts * Pt();
   if(c1 >= S - b) return false;
   if(E <= S) return false;
   if(!BreakoutVolumeOK(false)) return false;
   double tp = S - (E - S);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = S + InpM_SL_ShortPts * Pt();
   if(sl <= bid) return false;
   if(tp >= bid - Pt()) return false;
   return OpenSell(sl, tp);
}

bool TryBuy_MeasuredBreakout(const double &ef[], const double &es[])
{
   int L = MathMax(3, InpM_Lookback);
   if((int)ArraySize(ef) < L + 3) return false;
   double R = HH(2, L);
   double E = es[1];
   double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double b = InpM_BufferPts * Pt();
   if(c1 <= R + b) return false;
   if(E >= R) return false;
   if(!BreakoutVolumeOK(true)) return false;
   double tp = R + (R - E);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = R - InpM_SL_LongPts * Pt();
   if(sl >= ask) return false;
   if(tp <= ask + Pt()) return false;
   return OpenBuy(sl, tp);
}

//+------------------------------------------------------------------+
void UpdateSell_EMA7LowerHigh(const double &ef[])
{
   int need = InpE7_SwingLookback + InpE7_MinTrendBars + 5;
   if((int)ArraySize(ef) < need) return;
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 1);
   if(t == g_s7s_t) return;
   g_s7s_t = t;

   bool firstBelow = (iClose(_Symbol, PERIOD_CURRENT, 1) < ef[1]) &&
                     (iClose(_Symbol, PERIOD_CURRENT, 2) >= ef[2]);
   int ab = 0;
   for(int i = 2; i < 2 + InpE7_MinTrendBars + 40; i++)
   {
      if(i >= (int)ArraySize(ef)) break;
      if(iClose(_Symbol, PERIOD_CURRENT, i) >= ef[i]) ab++;
      else break;
   }

   if(g_s7s == S7S_IDLE && firstBelow && ab >= InpE7_MinTrendBars)
   {
      g_s7s_sh = HH(2, InpE7_SwingLookback);
      g_s7s_min = iLow(_Symbol, PERIOD_CURRENT, 1);
      g_s7s_maxh = -1e100;
      g_s7s_wait = 0;
      g_s7s = S7S_WAIT_LH;
      return;
   }
   if(g_s7s == S7S_WAIT_LH)
   {
      g_s7s_wait++;
      g_s7s_maxh = MathMax(g_s7s_maxh, iHigh(_Symbol, PERIOD_CURRENT, 1));
      g_s7s_min = MathMin(g_s7s_min, iLow(_Symbol, PERIOD_CURRENT, 1));
      if(g_s7s_wait >= 2 && g_s7s_maxh < g_s7s_sh && g_s7s_min < g_s7s_sh)
      {
         g_s7s_sl = g_s7s_min;
         g_s7s = S7S_ARMED;
      }
   }
}

bool TrySell_EMA7LowerHigh()
{
   if(g_s7s != S7S_ARMED) return false;
   if(iClose(_Symbol, PERIOD_CURRENT, 1) >= g_s7s_sl) return false;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = g_s7s_sh + InpE7_SL_BufferPts * Pt();
   double r = sl - bid;
   if(r <= 0) return false;
   bool ok = OpenSell(sl, bid - r * InpE7_TP_RMultiple);
   if(ok)
   {
      g_s7s = S7S_IDLE;
      g_s7s_sh = g_s7s_sl = 0;
   }
   return ok;
}

void UpdateBuy_EMA7HigherLow(const double &ef[])
{
   int need = InpE7_SwingLookback + InpE7_MinTrendBars + 5;
   if((int)ArraySize(ef) < need) return;
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 1);
   if(t == g_s7b_t) return;
   g_s7b_t = t;

   bool firstAbove = (iClose(_Symbol, PERIOD_CURRENT, 1) > ef[1]) &&
                     (iClose(_Symbol, PERIOD_CURRENT, 2) <= ef[2]);
   int bl = 0;
   for(int i = 2; i < 2 + InpE7_MinTrendBars + 40; i++)
   {
      if(i >= (int)ArraySize(ef)) break;
      if(iClose(_Symbol, PERIOD_CURRENT, i) < ef[i]) bl++;
      else break;
   }

   if(g_s7b == S7B_IDLE && firstAbove && bl >= InpE7_MinTrendBars)
   {
      g_s7b_sl = LL(2, InpE7_SwingLookback);
      g_s7b_max = iHigh(_Symbol, PERIOD_CURRENT, 1);
      g_s7b_minl = 1e100;
      g_s7b_wait = 0;
      g_s7b = S7B_WAIT_HL;
      return;
   }
   if(g_s7b == S7B_WAIT_HL)
   {
      g_s7b_wait++;
      g_s7b_minl = MathMin(g_s7b_minl, iLow(_Symbol, PERIOD_CURRENT, 1));
      g_s7b_max = MathMax(g_s7b_max, iHigh(_Symbol, PERIOD_CURRENT, 1));
      if(g_s7b_wait >= 2 && g_s7b_minl > g_s7b_sl && g_s7b_max > g_s7b_sl)
      {
         g_s7b_sh = g_s7b_max;
         g_s7b = S7B_ARMED;
      }
   }
}

bool TryBuy_EMA7HigherLow()
{
   if(g_s7b != S7B_ARMED) return false;
   if(iClose(_Symbol, PERIOD_CURRENT, 1) <= g_s7b_sh) return false;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = g_s7b_sl - InpE7_SL_BufferPts * Pt();
   double r = ask - sl;
   if(r <= 0) return false;
   bool ok = OpenBuy(sl, ask + r * InpE7_TP_RMultiple);
   if(ok)
   {
      g_s7b = S7B_IDLE;
      g_s7b_sl = g_s7b_sh = 0;
   }
   return ok;
}

//+------------------------------------------------------------------+
bool TrySell_PullbackBearish(const double &ef[], const double &es[])
{
   int need = MathMax(InpPb_RangeBars + 5, InpPb_SlopeBars + 5);
   if((int)ArraySize(ef) < need) return false;
   if(ef[1] >= es[1]) return false;

   int s = MathMax(1, InpPb_SlopeBars);
   if(!(ef[1] < ef[1 + s] && es[1] < es[1 + s])) return false;

   double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double h1 = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double o1 = iOpen(_Symbol, PERIOD_CURRENT, 1);
   if(c1 >= ef[1] || c1 >= es[1]) return false;

   double pl = LL(2, InpPb_RangeBars);
   if(h1 <= pl + Pt() * 2) return false;

   double tol = InpPb_TouchPts * Pt();
   bool t1 = (h1 >= ef[1] - tol && h1 <= ef[1] + tol);
   bool t2 = (h1 >= es[1] - tol && h1 <= es[1] + tol);
   if(!t1 && !t2) return false;
   if(h1 > es[1] + tol * 1.5) return false;
   if(c1 >= o1) return false;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = h1 + InpPb_SL_BufferPts * Pt();
   double r = sl - bid;
   if(r <= 0) return false;
   return OpenSell(sl, bid - r * InpPb_TP_RMultiple);
}

bool TryBuy_PullbackBullish(const double &ef[], const double &es[])
{
   int need = MathMax(InpPb_RangeBars + 5, InpPb_SlopeBars + 5);
   if((int)ArraySize(ef) < need) return false;
   if(ef[1] <= es[1]) return false;

   int s = MathMax(1, InpPb_SlopeBars);
   if(!(ef[1] > ef[1 + s] && es[1] > es[1 + s])) return false;

   double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double l1 = iLow(_Symbol, PERIOD_CURRENT, 1);
   double o1 = iOpen(_Symbol, PERIOD_CURRENT, 1);
   if(c1 <= ef[1] || c1 <= es[1]) return false;

   double ph = HH(2, InpPb_RangeBars);
   if(l1 >= ph - Pt() * 2) return false;

   double tol = InpPb_TouchPts * Pt();
   bool t1 = (l1 <= ef[1] + tol && l1 >= ef[1] - tol);
   bool t2 = (l1 <= es[1] + tol && l1 >= es[1] - tol);
   if(!t1 && !t2) return false;
   if(l1 < es[1] - tol * 1.5) return false;
   if(c1 <= o1) return false;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = l1 - InpPb_SL_BufferPts * Pt();
   double r = ask - sl;
   if(r <= 0) return false;
   return OpenBuy(sl, ask + r * InpPb_TP_RMultiple);
}

//+------------------------------------------------------------------+
// Simple trend: H1 bullish stack + M1 pullback to slow EMA (long only)
//+------------------------------------------------------------------+
bool SimpleH1Bullish()
{
   if(g_hH1Fast == INVALID_HANDLE || g_hH1Slow == INVALID_HANDLE) return false;
   double f[], s[];
   ArraySetAsSeries(f, true);
   ArraySetAsSeries(s, true);
   if(CopyBuffer(g_hH1Fast, 0, 0, 2, f) < 2 || CopyBuffer(g_hH1Slow, 0, 0, 2, s) < 2) return false;
   return (f[1] > s[1]);
}

bool TrySimpleTrendBuy()
{
   if(!SimpleH1Bullish()) return false;
   double mf[], ms[];
   ArraySetAsSeries(mf, true);
   ArraySetAsSeries(ms, true);
   if(CopyBuffer(g_hM1Fast, 0, 0, 3, mf) < 3 || CopyBuffer(g_hM1Slow, 0, 0, 3, ms) < 3) return false;
   if(mf[1] <= ms[1]) return false;
   double tol = (double)InpSimple_PullbackTouchPts * Pt();
   double l1 = iLow(_Symbol, PERIOD_M1, 1);
   double c1 = iClose(_Symbol, PERIOD_M1, 1);
   if(l1 > ms[1] + tol) return false;
   if(c1 < ms[1]) return false;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = ask - (double)InpSimple_SL_Points * Pt();
   double tp = ask + (double)InpSimple_TP_Points * Pt();
   return OpenBuy(sl, tp);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManageBreakeven();

   if(InpMode == MODE_SIMPLE_TREND)
   {
      if(!NewBarM1()) return;
      ResetDailyTradeCount();
      if(!SpreadOK()) return;
      if(!CooldownOK()) return;
      if(!EntrySpacingOK()) return;
      if(DailyLossLimitHit()) return;
      if(!VolatilityOK()) return;
      if(CountOurPositions() > 0) return;
      TrySimpleTrendBuy();
      return;
   }

   if(!NewBar()) return;
   ResetDailyTradeCount();
   if(!SpreadOK()) return;
   if(!CooldownOK()) return;
   if(!EntrySpacingOK()) return;
   if(DailyLossLimitHit()) return;
   if(!VolatilityOK()) return;
   if(CountOurPositions() > 0) return;

   const int nb = 200;
   double ef[], es[];
   if(!CopyEma(g_hEMA_Fast, nb, ef) || !CopyEma(g_hEMA_Slow, nb, es))
      return;

   UpdateSell_EMA7LowerHigh(ef);
   UpdateBuy_EMA7HigherLow(ef);

   // Priority: measured → EMA7 structure → pivot → pullback. HTF + chart EMA order filter each side.
   if(InpSell_MeasuredBreakdown && RegimeAllowsSell() && ChartTrendAligned(false, ef, es) && TrySell_MeasuredBreakdown(ef, es)) return;
   if(CountOurPositions() > 0) return;
   if(InpBuy_MeasuredBreakout && RegimeAllowsBuy() && ChartTrendAligned(true, ef, es) && TryBuy_MeasuredBreakout(ef, es)) return;
   if(CountOurPositions() > 0) return;

   if(InpSell_EMA7LowerHigh && RegimeAllowsSell() && ChartTrendAligned(false, ef, es) && TrySell_EMA7LowerHigh()) return;
   if(CountOurPositions() > 0) return;
   if(InpBuy_EMA7HigherLow && RegimeAllowsBuy() && ChartTrendAligned(true, ef, es) && TryBuy_EMA7HigherLow()) return;
   if(CountOurPositions() > 0) return;

   if(InpSell_PivotCloseBelowLow && RegimeAllowsSell() && ChartTrendAligned(false, ef, es) && TrySell_PivotBelowLow(ef, es)) return;
   if(CountOurPositions() > 0) return;
   if(InpBuy_PivotCloseAboveHigh && RegimeAllowsBuy() && ChartTrendAligned(true, ef, es) && TryBuy_PivotAboveHigh(ef, es)) return;
   if(CountOurPositions() > 0) return;

   if(InpSell_PullbackBearish && RegimeAllowsSell() && ChartTrendAligned(false, ef, es) && TrySell_PullbackBearish(ef, es)) return;
   if(CountOurPositions() > 0) return;
   if(InpBuy_PullbackBullish && RegimeAllowsBuy() && ChartTrendAligned(true, ef, es) && TryBuy_PullbackBullish(ef, es)) return;
}

//+------------------------------------------------------------------+

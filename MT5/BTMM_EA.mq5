//+------------------------------------------------------------------+
//| BTMM_EA.mq5                                                      |
//| Zeke Trading — BTMM multi-TF strategy (desktop MT5)              |
//| H4 bias | H1 TDI/MACD/structure | M15 trendline + iCB1 entry    |
//+------------------------------------------------------------------+
#property copyright "Zeke Trading"
#property version   "1.01"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== General ==="
input ulong    InpMagic              = 20260625;
input string   InpComment            = "BTMM";
input int      InpSlippage           = 30;
input int      InpMaxSpread          = 0;          // 0 = off

input group "=== BTMM EMAs (chart display) ==="
input bool     InpShowBTMM_EMAs      = true;
input int      InpEMA_21             = 21;
input int      InpEMA_50             = 50;
input int      InpEMA_200            = 200;
input int      InpEMA_800            = 800;
input ENUM_TIMEFRAMES InpEMA_DisplayTF = PERIOD_H1;

input group "=== Timeframes ==="
input ENUM_TIMEFRAMES InpTF_Direction  = PERIOD_H4;  // 21/50 EMA + OB + CB1
input ENUM_TIMEFRAMES InpTF_Confirm    = PERIOD_H1;  // MACD, TDI, structure, CISD
input ENUM_TIMEFRAMES InpTF_Entry      = PERIOD_M15; // trendline + iCB1
input ENUM_TIMEFRAMES InpTF_EntryAlt   = PERIOD_M30; // alternate entry TF
input bool     InpUseAltEntryTF        = true;

input group "=== H1 MACD (default 12/26/9) ==="
input int      InpMACD_Fast            = 12;
input int      InpMACD_Slow            = 26;
input int      InpMACD_Signal          = 9;
input bool     InpMACD_RequireCross    = false;      // false = histogram above/below zero

input group "=== TDI (H1 extremes) ==="
input int      InpTDI_RSI_Period       = 13;
input int      InpTDI_PriceMA          = 2;
input int      InpTDI_SignalMA         = 7;
input int      InpTDI_MarketBase       = 34;
input double   InpTDI_LowLevel         = 32.0;     // low-of-week zone
input double   InpTDI_HighLevel        = 68.0;     // high-of-week zone
input double   InpTDI_LevelTol         = 4.0;      // points tolerance on TDI scale

input group "=== M15 double zigzag / trendline ==="
input int      InpZZ_SlowPeriod        = 60;
input int      InpZZ_FastPeriod        = 30;
input int      InpZZ_DeviationPts      = 5;
input int      InpZZ_Backstep          = 3;
input int      InpSwingLookback        = 120;

input group "=== H4 direction lock ==="
input bool     InpRequireOrderBlock    = true;
input bool     InpRequireH4_CISD       = true;
input bool     InpRequireH4_Engulf     = true;
input int      InpOB_Lookback          = 20;
input double   InpOB_ATR_Mult          = 0.8;

input group "=== H1 confirmations at entry ==="
input bool     InpRequireH1_CISD       = true;
input bool     InpRequireH1_MACD       = true;
input bool     InpRequireH1_Structure  = true;
input bool     InpRequireTrendlineBreak = true;
input bool     InpRequire_iCB1         = true;

input group "=== Risk ==="
input double   InpRiskPercent          = 0.5;
input double   InpRewardRisk           = 2.0;
input double   InpSL_BufferPips        = 15.0;
input double   InpMinSLPips            = 10.0;
input double   InpMaxLots              = 5.0;
input int      InpMaxTradesPerDay      = 4;
input int      InpCooldownSec          = 600;
input double   InpMaxDailyLossPct      = 2.0;
input double   InpMaxDailyProfitPct    = 4.0;

input group "=== Dashboard & chart objects ==="
input bool     InpShowDashboard        = true;
input bool     InpDrawTrendline        = true;     // plot M15 zigzag trendline on chart
input int      InpDashCorner           = 0;
input int      InpDashX                = 10;
input int      InpDashY                = 20;
input int      InpDashFontSize         = 9;
input bool     InpDebugLog             = true;

//+------------------------------------------------------------------+
enum ENUM_BTMM_DIR
{
   BTMM_NONE = 0,
   BTMM_BULL = 1,
   BTMM_BEAR = -1
};

struct SSwingPt
{
   bool     valid;
   datetime time;
   double   price;
   int      barShift;
};

struct STrendLine
{
   bool     valid;
   double   slope;       // price per second
   double   anchorPrice;
   datetime anchorTime;
   SSwingPt ptSlow;
   SSwingPt ptFast;
};

struct SBTMMState
{
   ENUM_BTMM_DIR h4Dir;
   ENUM_BTMM_DIR h1Struct;
   double        tdiPrice;
   double        macdHist;
   bool          h4OB;
   bool          h4CISD;
   bool          h4Engulf;
   bool          h1CISD;
   bool          h1MacdOK;
   bool          tlBreak;
   bool          iCB1Ready;
   string        status;
   string        blockReason;
};

CTrade         g_trade;
SBTMMState     g_state;
string         g_dashPrefix = "BTMM_";
string         g_tlPrefix   = "BTMM_TL_";
string         g_logMsg = "Initializing";
bool           g_logIsError = false;

int            g_totalTrades = 0;
int            g_wins = 0;
int            g_losses = 0;
double         g_netPL = 0.0;
STrendLine     g_activeTL;

int            g_hEma21_Disp = INVALID_HANDLE;
int            g_hEma50_Disp = INVALID_HANDLE;
int            g_hEma200_Disp = INVALID_HANDLE;
int            g_hEma800_Disp = INVALID_HANDLE;
int            g_hEma21_H4 = INVALID_HANDLE;
int            g_hEma50_H4 = INVALID_HANDLE;
int            g_hMacd_H1 = INVALID_HANDLE;

datetime       g_lastEntryBar = 0;
datetime       g_lastEntryTime = 0;
int            g_entriesToday = 0;
int            g_lastDay = -1;
double         g_pipSize = 0.0;

//+------------------------------------------------------------------+
double Pt() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }

double GetPipSize()
{
   double pt = Pt();
   if(pt <= 0.0) return 0.0;
   int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digs == 3 || digs == 5) return pt * 10.0;
   return pt;
}

double PipToPrice(const double pips) { return pips * g_pipSize; }

double Np(const double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

void Dbg(const string msg)
{
   if(InpDebugLog) Print("BTMM: ", msg);
}

void SetLog(const string msg, const bool isError)
{
   g_logMsg = msg;
   g_logIsError = isError;
   if(isError) Print("BTMM: ", msg);
}

void SetLogOk(const string msg) { SetLog(msg, false); }

bool Buf1(const int handle, const int shift, double &val)
{
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(handle, 0, shift, 1, b) != 1) return false;
   val = b[0];
   return true;
}

bool SpreadOK()
{
   if(InpMaxSpread <= 0) return true;
   return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpread;
}

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

//+------------------------------------------------------------------+
//| Price action helpers                                             |
//+------------------------------------------------------------------+
bool PA_BullishEngulfing(const string sym, const ENUM_TIMEFRAMES tf, const int sh)
{
   double o1 = iOpen(sym, tf, sh), c1 = iClose(sym, tf, sh);
   double o2 = iOpen(sym, tf, sh + 1), c2 = iClose(sym, tf, sh + 1);
   if(c2 >= o2) return false;
   if(c1 <= o1) return false;
   return (c1 >= o2 && o1 <= c2 && (c1 - o1) > (o2 - c2));
}

bool PA_BearishEngulfing(const string sym, const ENUM_TIMEFRAMES tf, const int sh)
{
   double o1 = iOpen(sym, tf, sh), c1 = iClose(sym, tf, sh);
   double o2 = iOpen(sym, tf, sh + 1), c2 = iClose(sym, tf, sh + 1);
   if(c2 <= o2) return false;
   if(c1 >= o1) return false;
   return (o1 >= c2 && c1 <= o2 && (o1 - c1) > (c2 - o2));
}

double PA_ATR(const string sym, const ENUM_TIMEFRAMES tf, const int period, const int shift)
{
   int h = iATR(sym, tf, period);
   if(h == INVALID_HANDLE) return 0.0;
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(h, 0, shift, 1, b) != 1)
   {
      IndicatorRelease(h);
      return 0.0;
   }
   double v = b[0];
   IndicatorRelease(h);
   return v;
}

//+------------------------------------------------------------------+
//| TDI — RSI + price line (SMA on RSI)                              |
//+------------------------------------------------------------------+
double CalcRSI(const string sym, const ENUM_TIMEFRAMES tf, const int period, const int shift)
{
   int bars = iBars(sym, tf);
   if(shift + period + 2 >= bars) return 50.0;

   double gain = 0.0, loss = 0.0;
   for(int i = shift + 1; i <= shift + period; i++)
   {
      double ch = iClose(sym, tf, i - 1) - iClose(sym, tf, i);
      if(ch > 0.0) gain += ch;
      else loss -= ch;
   }
   if(loss <= 0.0) return 100.0;
   double rs = (gain / (double)period) / (loss / (double)period);
   return 100.0 - 100.0 / (1.0 + rs);
}

double SMA_OnSeries(const string sym, const ENUM_TIMEFRAMES tf, const int rsiPeriod,
                    const int maPeriod, const int shift)
{
   double sum = 0.0;
   for(int i = 0; i < maPeriod; i++)
      sum += CalcRSI(sym, tf, rsiPeriod, shift + i);
   return sum / (double)maPeriod;
}

double TDI_PriceLine(const string sym, const ENUM_TIMEFRAMES tf, const int shift)
{
   return SMA_OnSeries(sym, tf, InpTDI_RSI_Period, InpTDI_PriceMA, shift);
}

bool TDI_AtLowExtreme(const string sym, const ENUM_TIMEFRAMES tf, const int shift)
{
   double pl = TDI_PriceLine(sym, tf, shift);
   return (pl <= InpTDI_LowLevel + InpTDI_LevelTol);
}

bool TDI_AtHighExtreme(const string sym, const ENUM_TIMEFRAMES tf, const int shift)
{
   double pl = TDI_PriceLine(sym, tf, shift);
   return (pl >= InpTDI_HighLevel - InpTDI_LevelTol);
}

//+------------------------------------------------------------------+
//| CISD — close breaks open of last opposing candle                 |
//+------------------------------------------------------------------+
bool CISD_BullishBreak(const string sym, const ENUM_TIMEFRAMES tf, const int lookback, const int signalShift)
{
   double cisdLevel = 0.0;
   bool found = false;
   for(int i = signalShift + 1; i < lookback + signalShift; i++)
   {
      double o = iOpen(sym, tf, i);
      double c = iClose(sym, tf, i);
      if(c < o)
      {
         cisdLevel = o;
         found = true;
         break;
      }
   }
   if(!found) return false;
   double cSig = iClose(sym, tf, signalShift);
   double cPrev = iClose(sym, tf, signalShift + 1);
   return (cSig > cisdLevel && cPrev <= cisdLevel);
}

bool CISD_BearishBreak(const string sym, const ENUM_TIMEFRAMES tf, const int lookback, const int signalShift)
{
   double cisdLevel = 0.0;
   bool found = false;
   for(int i = signalShift + 1; i < lookback + signalShift; i++)
   {
      double o = iOpen(sym, tf, i);
      double c = iClose(sym, tf, i);
      if(c > o)
      {
         cisdLevel = o;
         found = true;
         break;
      }
   }
   if(!found) return false;
   double cSig = iClose(sym, tf, signalShift);
   double cPrev = iClose(sym, tf, signalShift + 1);
   return (cSig < cisdLevel && cPrev >= cisdLevel);
}

//+------------------------------------------------------------------+
//| Order block — opposing candle before impulse                     |
//+------------------------------------------------------------------+
bool BullishOrderBlock(const string sym, const ENUM_TIMEFRAMES tf, const int lookback)
{
   double atr = PA_ATR(sym, tf, 14, 1);
   if(atr <= 0.0) return false;
   for(int i = 2; i < lookback; i++)
   {
      double o2 = iOpen(sym, tf, i), c2 = iClose(sym, tf, i);
      double o1 = iOpen(sym, tf, i - 1), c1 = iClose(sym, tf, i - 1);
      if(c2 >= o2) continue;
      if(c1 <= o1) continue;
      double body1 = c1 - o1;
      double body2 = o2 - c2;
      if(body1 >= atr * InpOB_ATR_Mult && body2 < body1 * 0.6)
      {
         double obTop = o2;
         double obBot = c2;
         double px = iClose(sym, tf, 1);
         if(px >= obBot && px <= obTop + atr * 0.5) return true;
         if(i <= 6) return true;
      }
   }
   return false;
}

bool BearishOrderBlock(const string sym, const ENUM_TIMEFRAMES tf, const int lookback)
{
   double atr = PA_ATR(sym, tf, 14, 1);
   if(atr <= 0.0) return false;
   for(int i = 2; i < lookback; i++)
   {
      double o2 = iOpen(sym, tf, i), c2 = iClose(sym, tf, i);
      double o1 = iOpen(sym, tf, i - 1), c1 = iClose(sym, tf, i - 1);
      if(c2 <= o2) continue;
      if(c1 >= o1) continue;
      double body1 = o1 - c1;
      double body2 = c2 - o2;
      if(body1 >= atr * InpOB_ATR_Mult && body2 < body1 * 0.6)
      {
         double obTop = c2;
         double obBot = o2;
         double px = iClose(sym, tf, 1);
         if(px <= obTop && px >= obBot - atr * 0.5) return true;
         if(i <= 6) return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| H1 daily separation — prior day H/L market structure             |
//+------------------------------------------------------------------+
bool GetPriorDayHL(const string sym, const ENUM_TIMEFRAMES tf, double &prevHigh, double &prevLow)
{
   prevHigh = 0.0;
   prevLow = 0.0;
   MqlDateTime dt;
   TimeToStruct(iTime(sym, tf, 1), dt);
   int dayKey = dt.year * 10000 + dt.mon * 100 + dt.day;

   double dHigh = 0.0, dLow = 1e100;
   bool inDay = false;
   int bars = MathMin(iBars(sym, tf), 500);
   for(int i = 1; i < bars; i++)
   {
      MqlDateTime bdt;
      TimeToStruct(iTime(sym, tf, i), bdt);
      int bk = bdt.year * 10000 + bdt.mon * 100 + bdt.day;
      if(bk == dayKey)
      {
         inDay = true;
         dHigh = MathMax(dHigh, iHigh(sym, tf, i));
         dLow = MathMin(dLow, iLow(sym, tf, i));
      }
      else if(inDay)
         break;
   }
   if(!inDay || dLow >= dHigh) return false;

   double pHigh = 0.0, pLow = 1e100;
   bool gotPrev = false;
   int prevKey = -1;
   for(int i = 1; i < bars; i++)
   {
      MqlDateTime bdt;
      TimeToStruct(iTime(sym, tf, i), bdt);
      int bk = bdt.year * 10000 + bdt.mon * 100 + bdt.day;
      if(bk == dayKey) continue;
      if(prevKey < 0) prevKey = bk;
      if(bk != prevKey) break;
      gotPrev = true;
      pHigh = MathMax(pHigh, iHigh(sym, tf, i));
      pLow = MathMin(pLow, iLow(sym, tf, i));
   }
   if(!gotPrev || pLow >= pHigh) return false;
   prevHigh = pHigh;
   prevLow = pLow;
   return true;
}

ENUM_BTMM_DIR H1_DailyStructure(const string sym, const ENUM_TIMEFRAMES tf)
{
   double prevH = 0.0, prevL = 0.0;
   if(!GetPriorDayHL(sym, tf, prevH, prevL)) return BTMM_NONE;

   double curH = 0.0, curL = 1e100;
   MqlDateTime dt;
   TimeToStruct(iTime(sym, tf, 1), dt);
   int dayKey = dt.year * 10000 + dt.mon * 100 + dt.day;
   int bars = MathMin(iBars(sym, tf), 200);
   for(int i = 1; i < bars; i++)
   {
      MqlDateTime bdt;
      TimeToStruct(iTime(sym, tf, i), bdt);
      int bk = bdt.year * 10000 + bdt.mon * 100 + bdt.day;
      if(bk != dayKey) break;
      curH = MathMax(curH, iHigh(sym, tf, i));
      curL = MathMin(curL, iLow(sym, tf, i));
   }
   if(curL >= curH) return BTMM_NONE;

   double c1 = iClose(sym, tf, 1);
   if(curH > prevH && curL > prevL && c1 > prevH) return BTMM_BULL;
   if(curH < prevH && curL < prevL && c1 < prevL) return BTMM_BEAR;
   if(c1 > prevH) return BTMM_BULL;
   if(c1 < prevL) return BTMM_BEAR;
   return BTMM_NONE;
}

//+------------------------------------------------------------------+
//| ZigZag-style swing points (depth = period parameter)             |
//+------------------------------------------------------------------+
bool IsSwingHigh(const string sym, const ENUM_TIMEFRAMES tf, const int shift, const int halfW)
{
   if(shift < halfW) return false;
   double h = iHigh(sym, tf, shift);
   for(int i = 1; i <= halfW; i++)
   {
      if(iHigh(sym, tf, shift - i) >= h) return false;
      if(iHigh(sym, tf, shift + i) >= h) return false;
   }
   return true;
}

bool IsSwingLow(const string sym, const ENUM_TIMEFRAMES tf, const int shift, const int halfW)
{
   if(shift < halfW) return false;
   double l = iLow(sym, tf, shift);
   for(int i = 1; i <= halfW; i++)
   {
      if(iLow(sym, tf, shift - i) <= l) return false;
      if(iLow(sym, tf, shift + i) <= l) return false;
   }
   return true;
}

int FractalHalfWidth(const int period)
{
   int hw = period / 12;
   if(hw < 2) hw = 2;
   if(hw > 8) hw = 8;
   return hw;
}

bool FindSwingHigh(const string sym, const ENUM_TIMEFRAMES tf, const int period,
                   const int startShift, const int maxBars, SSwingPt &out)
{
   out.valid = false;
   int hw = FractalHalfWidth(period);
   int end = MathMin(startShift + maxBars, iBars(sym, tf) - hw - 1);
   for(int i = startShift; i < end; i++)
   {
      if(!IsSwingHigh(sym, tf, i, hw)) continue;
      out.valid = true;
      out.barShift = i;
      out.time = iTime(sym, tf, i);
      out.price = iHigh(sym, tf, i);
      return true;
   }
   return false;
}

bool FindSwingLow(const string sym, const ENUM_TIMEFRAMES tf, const int period,
                  const int startShift, const int maxBars, SSwingPt &out)
{
   out.valid = false;
   int hw = FractalHalfWidth(period);
   int end = MathMin(startShift + maxBars, iBars(sym, tf) - hw - 1);
   for(int i = startShift; i < end; i++)
   {
      if(!IsSwingLow(sym, tf, i, hw)) continue;
      out.valid = true;
      out.barShift = i;
      out.time = iTime(sym, tf, i);
      out.price = iLow(sym, tf, i);
      return true;
   }
   return false;
}

double TrendLinePriceAt(const STrendLine &tl, const datetime t)
{
   if(!tl.valid || tl.anchorTime <= 0) return 0.0;
   double dt = (double)(t - tl.anchorTime);
   return tl.anchorPrice + tl.slope * dt;
}

bool BuildBearishTrendLine(const string sym, const ENUM_TIMEFRAMES tf, STrendLine &tl)
{
   tl.valid = false;
   SSwingPt slow, fast;
   if(!FindSwingHigh(sym, tf, InpZZ_SlowPeriod, 3, InpSwingLookback, slow)) return false;
   if(!FindSwingHigh(sym, tf, InpZZ_FastPeriod, 3, slow.barShift + 2, fast)) return false;
   if(fast.time <= slow.time) return false;

   double dt = (double)(fast.time - slow.time);
   if(dt <= 0.0) return false;

   tl.ptSlow = slow;
   tl.ptFast = fast;
   tl.anchorTime = slow.time;
   tl.anchorPrice = slow.price;
   tl.slope = (fast.price - slow.price) / dt;
   tl.valid = true;
   return true;
}

bool BuildBullishTrendLine(const string sym, const ENUM_TIMEFRAMES tf, STrendLine &tl)
{
   tl.valid = false;
   SSwingPt slow, fast;
   if(!FindSwingLow(sym, tf, InpZZ_SlowPeriod, 3, InpSwingLookback, slow)) return false;
   if(!FindSwingLow(sym, tf, InpZZ_FastPeriod, 3, slow.barShift + 2, fast)) return false;
   if(fast.time <= slow.time) return false;

   double dt = (double)(fast.time - slow.time);
   if(dt <= 0.0) return false;

   tl.ptSlow = slow;
   tl.ptFast = fast;
   tl.anchorTime = slow.time;
   tl.anchorPrice = slow.price;
   tl.slope = (fast.price - slow.price) / dt;
   tl.valid = true;
   return true;
}

bool TrendlineBreakBull(const string sym, const ENUM_TIMEFRAMES tf, const STrendLine &tl, const int sh)
{
   if(!tl.valid) return false;
   datetime bt = iTime(sym, tf, sh);
   double linePx = TrendLinePriceAt(tl, bt);
   double c = iClose(sym, tf, sh);
   double cPrev = iClose(sym, tf, sh + 1);
   datetime btPrev = iTime(sym, tf, sh + 1);
   double linePrev = TrendLinePriceAt(tl, btPrev);
   return (c > linePx && cPrev <= linePrev);
}

bool TrendlineBreakBear(const string sym, const ENUM_TIMEFRAMES tf, const STrendLine &tl, const int sh)
{
   if(!tl.valid) return false;
   datetime bt = iTime(sym, tf, sh);
   double linePx = TrendLinePriceAt(tl, bt);
   double c = iClose(sym, tf, sh);
   double cPrev = iClose(sym, tf, sh + 1);
   datetime btPrev = iTime(sym, tf, sh + 1);
   double linePrev = TrendLinePriceAt(tl, btPrev);
   return (c < linePx && cPrev >= linePrev);
}

//+------------------------------------------------------------------+
//| iCB1 — internal correction block retest after impulse            |
//+------------------------------------------------------------------+
bool iCB1_BullReady(const string sym, const ENUM_TIMEFRAMES tf, const int lookback)
{
   double impulseHigh = 0.0;
   int impulseBar = -1;
   for(int i = 2; i < lookback; i++)
   {
      double o = iOpen(sym, tf, i), c = iClose(sym, tf, i);
      double body = c - o;
      double atr = PA_ATR(sym, tf, 14, i);
      if(atr <= 0.0) continue;
      if(body > atr * 0.5)
      {
         impulseHigh = iHigh(sym, tf, i);
         impulseBar = i;
         break;
      }
   }
   if(impulseBar < 0) return false;

   double cbTop = 0.0, cbBot = 1e100;
   bool gotCB = false;
   for(int j = impulseBar - 1; j >= 1; j--)
   {
      double o = iOpen(sym, tf, j), c = iClose(sym, tf, j);
      if(c < o)
      {
         cbTop = o;
         cbBot = c;
         gotCB = true;
         break;
      }
   }
   if(!gotCB) return false;

   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double tol = PipToPrice(3.0);
   return (bid >= cbBot - tol && bid <= cbTop + tol);
}

bool iCB1_BearReady(const string sym, const ENUM_TIMEFRAMES tf, const int lookback)
{
   double impulseLow = 1e100;
   int impulseBar = -1;
   for(int i = 2; i < lookback; i++)
   {
      double o = iOpen(sym, tf, i), c = iClose(sym, tf, i);
      double body = o - c;
      double atr = PA_ATR(sym, tf, 14, i);
      if(atr <= 0.0) continue;
      if(body > atr * 0.5)
      {
         impulseLow = iLow(sym, tf, i);
         impulseBar = i;
         break;
      }
   }
   if(impulseBar < 0) return false;

   double cbTop = 0.0, cbBot = 1e100;
   bool gotCB = false;
   for(int j = impulseBar - 1; j >= 1; j--)
   {
      double o = iOpen(sym, tf, j), c = iClose(sym, tf, j);
      if(c > o)
      {
         cbTop = c;
         cbBot = o;
         gotCB = true;
         break;
      }
   }
   if(!gotCB) return false;

   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double tol = PipToPrice(3.0);
   return (ask <= cbTop + tol && ask >= cbBot - tol);
}

//+------------------------------------------------------------------+
//| H4 direction lock                                                |
//+------------------------------------------------------------------+
ENUM_BTMM_DIR H4_Direction()
{
   double e21 = 0.0, e50 = 0.0;
   if(!Buf1(g_hEma21_H4, 1, e21) || !Buf1(g_hEma50_H4, 1, e50)) return BTMM_NONE;
   if(e21 > e50) return BTMM_BULL;
   if(e21 < e50) return BTMM_BEAR;
   return BTMM_NONE;
}

bool MACD_HistogramOK(const ENUM_BTMM_DIR dir, const int shift)
{
   double main[], sig[], hist[];
   ArraySetAsSeries(main, true);
   ArraySetAsSeries(sig, true);
   ArraySetAsSeries(hist, true);
   if(CopyBuffer(g_hMacd_H1, 0, shift, 2, main) < 2) return false;
   if(CopyBuffer(g_hMacd_H1, 1, shift, 2, sig) < 2) return false;
   if(CopyBuffer(g_hMacd_H1, 2, shift, 2, hist) < 2) return false;

   g_state.macdHist = hist[0];
   if(InpMACD_RequireCross)
   {
      if(dir == BTMM_BULL) return (hist[0] > 0.0 && hist[1] <= 0.0);
      if(dir == BTMM_BEAR) return (hist[0] < 0.0 && hist[1] >= 0.0);
      return false;
   }
   if(dir == BTMM_BULL) return (hist[0] > 0.0);
   if(dir == BTMM_BEAR) return (hist[0] < 0.0);
   return false;
}

//+------------------------------------------------------------------+
//| Evaluate full setup                                              |
//+------------------------------------------------------------------+
void RefreshState()
{
   g_state.h4Dir = H4_Direction();
   g_state.h1Struct = H1_DailyStructure(_Symbol, InpTF_Confirm);
   g_state.tdiPrice = TDI_PriceLine(_Symbol, InpTF_Confirm, 1);

   g_state.h4OB = false;
   g_state.h4CISD = false;
   g_state.h4Engulf = false;
   g_state.h1CISD = false;
   g_state.h1MacdOK = false;
   g_state.tlBreak = false;
   g_state.iCB1Ready = false;
   g_state.status = "Scanning";
   g_state.blockReason = "";

   if(g_state.h4Dir == BTMM_NONE)
   {
      g_state.status = "No H4 direction";
      return;
   }

   const bool bull = (g_state.h4Dir == BTMM_BULL);
   if(bull)
   {
      if(!TDI_AtLowExtreme(_Symbol, InpTF_Confirm, 1))
      {
         g_state.status = "Wait TDI 32 zone";
         g_state.blockReason = StringFormat("TDI=%.1f (need <=%.1f)", g_state.tdiPrice, InpTDI_LowLevel + InpTDI_LevelTol);
         return;
      }
   }
   else
   {
      if(!TDI_AtHighExtreme(_Symbol, InpTF_Confirm, 1))
      {
         g_state.status = "Wait TDI 68 zone";
         g_state.blockReason = StringFormat("TDI=%.1f (need >=%.1f)", g_state.tdiPrice, InpTDI_HighLevel - InpTDI_LevelTol);
         return;
      }
   }

   if(InpRequireOrderBlock)
   {
      g_state.h4OB = bull ? BullishOrderBlock(_Symbol, InpTF_Direction, InpOB_Lookback)
                          : BearishOrderBlock(_Symbol, InpTF_Direction, InpOB_Lookback);
      if(!g_state.h4OB)
      {
         g_state.status = "No H4 order block";
         return;
      }
   }
   else g_state.h4OB = true;

   if(InpRequireH4_CISD)
   {
      g_state.h4CISD = bull ? CISD_BullishBreak(_Symbol, InpTF_Direction, 30, 1)
                            : CISD_BearishBreak(_Symbol, InpTF_Direction, 30, 1);
      if(!g_state.h4CISD)
      {
         g_state.status = "No H4 CB1/CISD";
         return;
      }
   }
   else g_state.h4CISD = true;

   if(InpRequireH1_Structure)
   {
      if(bull && g_state.h1Struct != BTMM_BULL)
      {
         g_state.status = "H1 structure not bull";
         return;
      }
      if(!bull && g_state.h1Struct != BTMM_BEAR)
      {
         g_state.status = "H1 structure not bear";
         return;
      }
   }

   STrendLine tl;
   bool tlOk = bull ? BuildBearishTrendLine(_Symbol, InpTF_Entry, tl)
                    : BuildBullishTrendLine(_Symbol, InpTF_Entry, tl);
   if(tlOk) g_activeTL = tl;
   else if(InpUseAltEntryTF)
   {
      STrendLine tl2;
      if(bull ? BuildBearishTrendLine(_Symbol, InpTF_EntryAlt, tl2)
              : BuildBullishTrendLine(_Symbol, InpTF_EntryAlt, tl2))
         g_activeTL = tl2;
      else
         g_activeTL.valid = false;
   }
   else
      g_activeTL.valid = false;

   if(InpRequireTrendlineBreak)
   {
      g_state.tlBreak = tlOk && (bull ? TrendlineBreakBull(_Symbol, InpTF_Entry, tl, 1)
                                      : TrendlineBreakBear(_Symbol, InpTF_Entry, tl, 1));
      if(!g_state.tlBreak && InpUseAltEntryTF)
      {
         STrendLine tl2;
         bool tl2Ok = bull ? BuildBearishTrendLine(_Symbol, InpTF_EntryAlt, tl2)
                           : BuildBullishTrendLine(_Symbol, InpTF_EntryAlt, tl2);
         g_state.tlBreak = tl2Ok && (bull ? TrendlineBreakBull(_Symbol, InpTF_EntryAlt, tl2, 1)
                                            : TrendlineBreakBear(_Symbol, InpTF_EntryAlt, tl2, 1));
      }
      if(!g_state.tlBreak)
      {
         g_state.status = "No M15 trendline break";
         return;
      }
   }
   else g_state.tlBreak = true;

   if(InpRequireH1_MACD)
   {
      g_state.h1MacdOK = MACD_HistogramOK(g_state.h4Dir, 1);
      if(!g_state.h1MacdOK)
      {
         g_state.status = "H1 MACD not confirmed";
         return;
      }
   }
   else g_state.h1MacdOK = true;

   if(InpRequireH1_CISD)
   {
      g_state.h1CISD = bull ? CISD_BullishBreak(_Symbol, InpTF_Confirm, 25, 1)
                            : CISD_BearishBreak(_Symbol, InpTF_Confirm, 25, 1);
      if(!g_state.h1CISD)
      {
         g_state.status = "No H1 CISD";
         return;
      }
   }
   else g_state.h1CISD = true;

   if(InpRequireH4_Engulf)
   {
      g_state.h4Engulf = bull ? PA_BullishEngulfing(_Symbol, InpTF_Direction, 1)
                              : PA_BearishEngulfing(_Symbol, InpTF_Direction, 1);
      if(!g_state.h4Engulf)
      {
         g_state.status = "No H4 engulfing";
         return;
      }
   }
   else g_state.h4Engulf = true;

   if(InpRequire_iCB1)
   {
      g_state.iCB1Ready = bull ? iCB1_BullReady(_Symbol, InpTF_Entry, 40) : iCB1_BearReady(_Symbol, InpTF_Entry, 40);
      if(!g_state.iCB1Ready && InpUseAltEntryTF)
         g_state.iCB1Ready = bull ? iCB1_BullReady(_Symbol, InpTF_EntryAlt, 40) : iCB1_BearReady(_Symbol, InpTF_EntryAlt, 40);
      if(!g_state.iCB1Ready)
      {
         g_state.status = "Wait iCB1 retest";
         return;
      }
   }
   else g_state.iCB1Ready = true;

   g_state.status = bull ? "BUY setup ready" : "SELL setup ready";
}

//+------------------------------------------------------------------+
//| Trade management                                                 |
//+------------------------------------------------------------------+
void ResetDailyCount()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day != g_lastDay)
   {
      g_lastDay = dt.day;
      g_entriesToday = 0;
   }
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

bool CooldownOK()
{
   if(InpCooldownSec <= 0 || g_lastEntryTime <= 0) return true;
   return (TimeCurrent() - g_lastEntryTime >= InpCooldownSec);
}

double GetAccountTodayNetPL()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime from = StructToTime(dt);
   if(!HistorySelect(from, TimeCurrent())) return 0.0;
   double net = 0.0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      net += HistoryDealGetDouble(d, DEAL_PROFIT);
      net += HistoryDealGetDouble(d, DEAL_SWAP);
      net += HistoryDealGetDouble(d, DEAL_COMMISSION);
   }
   return net;
}

bool DailyPLAllowsEntry(string &reason)
{
   reason = "";
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal <= 0.0) return true;
   double pl = GetAccountTodayNetPL();
   if(InpMaxDailyLossPct > 0.0 && pl <= -bal * InpMaxDailyLossPct / 100.0)
   {
      reason = "Daily loss limit";
      return false;
   }
   if(InpMaxDailyProfitPct > 0.0 && pl >= bal * InpMaxDailyProfitPct / 100.0)
   {
      reason = "Daily profit target";
      return false;
   }
   return true;
}

double NormalizeLots(double lotSize)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0.0) return 0.0;
   if(InpMaxLots > 0.0) maxLot = MathMin(maxLot, InpMaxLots);
   lotSize = MathFloor(lotSize / stepLot) * stepLot;
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   return NormalizeDouble(lotSize, 2);
}

double CalcLotSize(const double riskDist)
{
   if(riskDist <= 0.0 || InpRiskPercent <= 0.0) return 0.0;
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0) return 0.0;
   double ticks = riskDist / tickSize;
   if(ticks <= 0.0) return 0.0;
   double riskAmt = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   return NormalizeLots(riskAmt / (ticks * tickValue));
}

bool StopsOK(const bool buy, const double sl, const double tp)
{
   int stopLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopLevel * Pt();
   double entry = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(sl > 0.0 && MathAbs(entry - sl) < minDist) return false;
   if(tp > 0.0 && MathAbs(entry - tp) < minDist) return false;
   return true;
}

bool BuildStops(const bool buy, const ENUM_TIMEFRAMES tf, double &sl, double &tp)
{
   const double buf = PipToPrice(InpSL_BufferPips);
   const double barLow = iLow(_Symbol, tf, 1);
   const double barHigh = iHigh(_Symbol, tf, 1);
   double entry = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(buy)
   {
      sl = Np(barLow - buf);
      double risk = entry - sl;
      if(risk < PipToPrice(InpMinSLPips)) return false;
      tp = Np(entry + risk * InpRewardRisk);
   }
   else
   {
      sl = Np(barHigh + buf);
      double risk = sl - entry;
      if(risk < PipToPrice(InpMinSLPips)) return false;
      tp = Np(entry - risk * InpRewardRisk);
   }
   return true;
}

bool OpenTrade(const bool buy)
{
   double sl = 0.0, tp = 0.0;
   if(!BuildStops(buy, InpTF_Entry, sl, tp))
   {
      if(!BuildStops(buy, InpTF_EntryAlt, sl, tp))
      {
         SetLog("Stops failed", true);
         return false;
      }
   }
   if(!StopsOK(buy, sl, tp))
   {
      SetLog("Broker stop level too close", true);
      return false;
   }
   double entry = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double risk = buy ? (entry - sl) : (sl - entry);
   double lots = CalcLotSize(risk);
   if(lots <= 0.0)
   {
      SetLog("Lot calc failed", true);
      return false;
   }

   bool ok = buy ? g_trade.Buy(lots, _Symbol, entry, sl, tp, InpComment)
                 : g_trade.Sell(lots, _Symbol, entry, sl, tp, InpComment);
   if(!ok)
   {
      SetLog(StringFormat("Order failed: %s", g_trade.ResultRetcodeDescription()), true);
      return false;
   }
   g_lastEntryTime = TimeCurrent();
   g_entriesToday++;
   SetLogOk(buy ? "BUY opened" : "SELL opened");
   Dbg(g_state.status);
   return true;
}

bool NewEntryBar(const ENUM_TIMEFRAMES tf)
{
   datetime t = iTime(_Symbol, tf, 0);
   if(t <= 0 || t == g_lastEntryBar) return false;
   g_lastEntryBar = t;
   return true;
}

void TryEntry()
{
   if(!NewEntryBar(InpTF_Entry)) return;
   if(CountOurPositions() > 0) return;
   if(InpMaxTradesPerDay > 0 && g_entriesToday >= InpMaxTradesPerDay) return;
   if(!CooldownOK()) return;
   if(!SpreadOK()) return;

   string plReason = "";
   if(!DailyPLAllowsEntry(plReason))
   {
      SetLog(plReason, false);
      return;
   }

   RefreshState();

   if(g_state.status == "BUY setup ready")
      OpenTrade(true);
   else if(g_state.status == "SELL setup ready")
      OpenTrade(false);
}

//+------------------------------------------------------------------+
//| Trade metrics                                                    |
//+------------------------------------------------------------------+
void RefreshTradeMetrics()
{
   g_totalTrades = 0;
   g_wins = 0;
   g_losses = 0;
   g_netPL = 0.0;

   if(!HistorySelect(0, TimeCurrent())) return;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      double profit = HistoryDealGetDouble(deal, DEAL_PROFIT)
                    + HistoryDealGetDouble(deal, DEAL_SWAP)
                    + HistoryDealGetDouble(deal, DEAL_COMMISSION);
      g_netPL += profit;
      g_totalTrades++;
      if(profit >= 0.0) g_wins++;
      else g_losses++;
   }
}

double WinRatePct()
{
   if(g_totalTrades <= 0) return 0.0;
   return 100.0 * (double)g_wins / (double)g_totalTrades;
}

//+------------------------------------------------------------------+
//| Desktop dashboard & chart trendline                              |
//+------------------------------------------------------------------+
string DirTxt(const ENUM_BTMM_DIR d)
{
   if(d == BTMM_BULL) return "BULL";
   if(d == BTMM_BEAR) return "BEAR";
   return "—";
}

string YN(const bool v) { return v ? "Y" : "N"; }

void DeleteTrendline()
{
   long chartId = ChartID();
   ObjectDelete(chartId, g_tlPrefix + "0");
}

void DrawTrendlineOnChart()
{
   if(!InpDrawTrendline || !g_activeTL.valid) return;
   if(Period() != InpTF_Entry && Period() != InpTF_EntryAlt) return;

   long chartId = ChartID();
   string name = g_tlPrefix + "0";
   datetime t2 = iTime(_Symbol, PERIOD_CURRENT, 0);
   double p2 = TrendLinePriceAt(g_activeTL, t2);
   color tlClr = (g_state.h4Dir == BTMM_BULL) ? clrDodgerBlue : clrOrangeRed;

   if(ObjectFind(chartId, name) < 0)
   {
      ObjectCreate(chartId, name, OBJ_TREND, 0,
                   g_activeTL.ptSlow.time, g_activeTL.ptSlow.price,
                   g_activeTL.ptFast.time, g_activeTL.ptFast.price);
      ObjectSetInteger(chartId, name, OBJPROP_RAY_RIGHT, true);
      ObjectSetInteger(chartId, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(chartId, name, OBJPROP_BACK, false);
   }
   else
   {
      ObjectMove(chartId, name, 0, g_activeTL.ptSlow.time, g_activeTL.ptSlow.price);
      ObjectMove(chartId, name, 1, g_activeTL.ptFast.time, g_activeTL.ptFast.price);
   }
   ObjectSetInteger(chartId, name, OBJPROP_COLOR, tlClr);
   ObjectSetInteger(chartId, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(chartId, name, OBJPROP_STYLE, STYLE_SOLID);
   ChartRedraw(chartId);
}

void DeleteDashboard()
{
   long chartId = ChartID();
   int total = ObjectsTotal(chartId, 0, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(chartId, i, 0, -1);
      if(StringFind(name, g_dashPrefix) == 0)
         ObjectDelete(chartId, name);
   }
}

void UpdateDashboard()
{
   if(!InpShowDashboard) return;

   RefreshState();
   RefreshTradeMetrics();
   DrawTrendlineOnChart();

   double e21 = 0.0, e50 = 0.0;
   Buf1(g_hEma21_H4, 1, e21);
   Buf1(g_hEma50_H4, 1, e50);

   string lines[];
   ArrayResize(lines, 18);
   lines[0]  = StringFormat("BTMM EA v1.01 | %s | chart %s", _Symbol, EnumToString((ENUM_TIMEFRAMES)Period()));
   lines[1]  = StringFormat("H4 %s: dir=%s | EMA21=%.5f EMA50=%.5f",
      EnumToString(InpTF_Direction), DirTxt(g_state.h4Dir), e21, e50);
   lines[2]  = StringFormat("H4 lock: OB=%s CISD=%s Engulf=%s",
      YN(g_state.h4OB), YN(g_state.h4CISD), YN(g_state.h4Engulf));
   lines[3]  = StringFormat("H1 %s: TDI=%.1f (32/68) | MACD hist=%.5f",
      EnumToString(InpTF_Confirm), g_state.tdiPrice, g_state.macdHist);
   lines[4]  = StringFormat("H1 struct=%s | CISD=%s",
      DirTxt(g_state.h1Struct), YN(g_state.h1CISD));
   lines[5]  = StringFormat("Entry %s: TL break=%s | iCB1=%s",
      EnumToString(InpTF_Entry), YN(g_state.tlBreak), YN(g_state.iCB1Ready));
   lines[6]  = StringFormat("Status: %s", g_state.status);
   lines[7]  = g_state.blockReason;
   lines[8]  = StringFormat("Open pos: %d | Entries today: %d/%d",
      CountOurPositions(), g_entriesToday, InpMaxTradesPerDay);
   lines[9]  = StringFormat("Trades: %d | W/L %d/%d | WR %.1f%% | Net %.2f",
      g_totalTrades, g_wins, g_losses, WinRatePct(), g_netPL);
   lines[10] = StringFormat("Day P/L: %.2f | Risk %.2f%% | RR 1:%.1f",
      GetAccountTodayNetPL(), InpRiskPercent, InpRewardRisk);
   lines[11] = StringFormat("TF stack: H4 bias / H1 confirm / %s entry",
      EnumToString(InpTF_Entry));
   lines[12] = (g_logIsError ? "ERROR: " : "Log: ") + g_logMsg;

   long chartId = ChartID();
   const int lineH = InpDashFontSize + 4;
   const int padSide = 10;
   const int padTop  = 6;
   const int padBot  = 6;
   int boxW = 520;
   int boxH = padTop + ArraySize(lines) * lineH + padBot;

   string bg = g_dashPrefix + "BG";
   if(ObjectFind(chartId, bg) < 0)
   {
      ObjectCreate(chartId, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(chartId, bg, OBJPROP_CORNER, InpDashCorner);
      ObjectSetInteger(chartId, bg, OBJPROP_BGCOLOR, C'18,22,28');
      ObjectSetInteger(chartId, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(chartId, bg, OBJPROP_COLOR, clrDimGray);
      ObjectSetInteger(chartId, bg, OBJPROP_BACK, false);
      ObjectSetInteger(chartId, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(chartId, bg, OBJPROP_ZORDER, 100);
   }
   ObjectSetInteger(chartId, bg, OBJPROP_XDISTANCE, InpDashX);
   ObjectSetInteger(chartId, bg, OBJPROP_YDISTANCE, InpDashY);
   ObjectSetInteger(chartId, bg, OBJPROP_XSIZE, boxW);
   ObjectSetInteger(chartId, bg, OBJPROP_YSIZE, boxH);

   const int labelX = InpDashX + padSide;
   const int labelY0 = InpDashY + padTop;

   for(int i = 0; i < ArraySize(lines); i++)
   {
      string name = g_dashPrefix + "L" + IntegerToString(i);
      if(ObjectFind(chartId, name) < 0)
      {
         ObjectCreate(chartId, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(chartId, name, OBJPROP_CORNER, InpDashCorner);
         ObjectSetInteger(chartId, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
         ObjectSetString(chartId, name, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(chartId, name, OBJPROP_BACK, false);
         ObjectSetInteger(chartId, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(chartId, name, OBJPROP_ZORDER, 101);
      }
      ObjectSetInteger(chartId, name, OBJPROP_XDISTANCE, labelX);
      ObjectSetInteger(chartId, name, OBJPROP_YDISTANCE, labelY0 + i * lineH);
      ObjectSetString(chartId, name, OBJPROP_TEXT, lines[i]);
      ObjectSetInteger(chartId, name, OBJPROP_FONTSIZE, InpDashFontSize);

      color rowClr = clrWhite;
      if(i == 0) rowClr = clrYellow;
      else if(i == 2) rowClr = clrGold;
      else if(i == 6) rowClr = (StringFind(g_state.status, "ready") >= 0) ? clrLime : clrOrange;
      else if(i == 9 || i == 10) rowClr = clrSilver;
      else if(i == 12) rowClr = g_logIsError ? clrTomato : clrLime;
      ObjectSetInteger(chartId, name, OBJPROP_COLOR, rowClr);
   }
   ChartRedraw(chartId);
}

void AttachBTMM_EMAs()
{
   if(!InpShowBTMM_EMAs) return;
   ChartIndicatorAdd(ChartID(), 0, g_hEma21_Disp);
   ChartIndicatorAdd(ChartID(), 0, g_hEma50_Disp);
   ChartIndicatorAdd(ChartID(), 0, g_hEma200_Disp);
   ChartIndicatorAdd(ChartID(), 0, g_hEma800_Disp);
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_pipSize = GetPipSize();

   const ENUM_TIMEFRAMES disp = InpEMA_DisplayTF;
   g_hEma21_Disp  = iMA(_Symbol, disp, InpEMA_21,  0, MODE_EMA, PRICE_CLOSE);
   g_hEma50_Disp  = iMA(_Symbol, disp, InpEMA_50,  0, MODE_EMA, PRICE_CLOSE);
   g_hEma200_Disp = iMA(_Symbol, disp, InpEMA_200, 0, MODE_EMA, PRICE_CLOSE);
   g_hEma800_Disp = iMA(_Symbol, disp, InpEMA_800, 0, MODE_EMA, PRICE_CLOSE);

   g_hEma21_H4 = iMA(_Symbol, InpTF_Direction, InpEMA_21, 0, MODE_EMA, PRICE_CLOSE);
   g_hEma50_H4 = iMA(_Symbol, InpTF_Direction, InpEMA_50, 0, MODE_EMA, PRICE_CLOSE);

   g_hMacd_H1 = iMACD(_Symbol, InpTF_Confirm, InpMACD_Fast, InpMACD_Slow, InpMACD_Signal, PRICE_CLOSE);
   if(g_hEma21_H4 == INVALID_HANDLE || g_hEma50_H4 == INVALID_HANDLE || g_hMacd_H1 == INVALID_HANDLE)
   {
      Print("BTMM: indicator init failed");
      return INIT_FAILED;
   }

   if(Period() != InpTF_Entry && Period() != InpTF_EntryAlt)
      Print("BTMM: recommended chart TF is ", EnumToString(InpTF_Entry),
            " or ", EnumToString(InpTF_EntryAlt),
            " (current: ", EnumToString((ENUM_TIMEFRAMES)Period()), ")");

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints((uint)InpSlippage);
   SetFilling();

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_lastDay = dt.day;
   g_activeTL.valid = false;

   AttachBTMM_EMAs();

   Print("BTMM v1.01 | ", _Symbol,
         " | H4=", EnumToString(InpTF_Direction),
         " H1=", EnumToString(InpTF_Confirm),
         " Entry=", EnumToString(InpTF_Entry),
         " | Chart=", EnumToString((ENUM_TIMEFRAMES)Period()));

   SetLogOk("EA initialized");
   UpdateDashboard();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_hEma21_Disp  != INVALID_HANDLE) IndicatorRelease(g_hEma21_Disp);
   if(g_hEma50_Disp  != INVALID_HANDLE) IndicatorRelease(g_hEma50_Disp);
   if(g_hEma200_Disp != INVALID_HANDLE) IndicatorRelease(g_hEma200_Disp);
   if(g_hEma800_Disp != INVALID_HANDLE) IndicatorRelease(g_hEma800_Disp);
   if(g_hEma21_H4    != INVALID_HANDLE) IndicatorRelease(g_hEma21_H4);
   if(g_hEma50_H4    != INVALID_HANDLE) IndicatorRelease(g_hEma50_H4);
   if(g_hMacd_H1     != INVALID_HANDLE) IndicatorRelease(g_hMacd_H1);
   DeleteDashboard();
   DeleteTrendline();
}

void OnTick()
{
   ResetDailyCount();
   UpdateDashboard();
   TryEntry();
}
//+------------------------------------------------------------------+

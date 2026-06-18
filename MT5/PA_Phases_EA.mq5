//+------------------------------------------------------------------+
//| PA_Phases_EA.mq5                                                 |
//| Developer: Zeke Trading                                          |
//| Gold, indices, forex, CFD & futures. Session phases + FVG agent. |
//+------------------------------------------------------------------+
#property copyright "Zeke Trading"
#property version   "3.40"
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
input string   InpGeneral       = "=== General ===";
input ulong    InpMagic         = 20260523;
input string   InpComment       = "PA_Phases";
input int      InpSlippage      = 30;
input int      InpMaxSpread     = 0;
input bool     InpUseSymbolWhitelist = false;  // false = trade any chart symbol (auto-detect asset type)
input string   InpAllowedSymbols = "XAUUSD,XAUEUR,US100,USTEC,NAS100"; // only used if whitelist enabled

//--- Sessions (CST / UTC-6, converted to broker time)
input string   InpSessionHdr    = "=== Session times (CST) ===";
input int      InpBrokerGMTOffset = 2;
input string   InpAsiaOpenCST     = "18:00";
input string   InpLondonOpenCST   = "03:00";
input string   InpNYOpenCST       = "08:30";

//--- Phase / scan
input string   InpPhaseHdr      = "=== Phase detection ===";
input ENUM_TIMEFRAMES InpSessionTF = PERIOD_M15;
input ENUM_TIMEFRAMES InpSignalTF  = PERIOD_M5;
input double   InpMinSessionPips  = 10.0;
input double   InpConsolRangeRatio = 0.45;   // current range vs prev session range
input double   InpRetrMinPct        = 0.30;
input double   InpRetrMaxPct        = 0.70;
input double   InpExpansionPips     = 5.0;   // min break beyond prev H/L
input bool     InpRequirePhaseAlign = true;  // entries only on expansion/reversal, aligned to direction
input bool     InpTradePhaseEntries = false;

//--- FVG agent (H4 + M15)
input string   InpFVGHdr        = "=== FVG agent ===";
input bool     InpUseFVGAgent       = true;
enum ENUM_FVG_ENTRY_TF
{
   FVG_ENTRY_H4 = 0,         // H4 FVG only
   FVG_ENTRY_M15 = 1,        // M15 FVG only
   FVG_ENTRY_H4_OR_M15 = 2   // entry on H4 or M15 (whichever signals first)
};
input ENUM_FVG_ENTRY_TF InpFVG_EntryTF = FVG_ENTRY_H4_OR_M15;
input int      InpFVG_H4_Lookback   = 60;
input int      InpFVG_M15_Lookback  = 100;
input double   InpFVG_MinPips       = 3.0;
input double   InpFVG_ProxPips      = 8.0;
input bool     InpFVG_TradeBounce   = true;
input bool     InpFVG_TradeBreak    = true;
input bool     InpFVG_UsePin        = true;
input bool     InpFVG_UseEngulf     = true;
input bool     InpFVG_RequireAtZone = true;      // signal bar must touch the FVG zone
input bool     InpFVG_FreshReactionOnly = true; // only first signal bar of a reaction
input bool     InpFVG_OneTradePerZone = true;    // one entry per FVG zone + reaction type
input bool     InpFVG_StrictPA      = true;      // pin/engulf only (no generic body candle)
input double   InpFVG_MinBodyPips   = 5.0;       // min candle body if strict PA is off

input group "=== H1 / H4 S&R entry (optional) ==="
input bool     InpUseSR_H1            = true;    // swing S/R on H1 as entry source
input bool     InpUseSR_H4            = true;    // swing S/R on H4 as entry source
input int      InpSR_H1_Lookback      = 80;
input int      InpSR_H4_Lookback      = 40;
input int      InpSR_SwingBars        = 2;       // pivot bars each side (fractal width)
input double   InpSR_ProxPips         = 10.0;    // proximity to level on signal TF
input bool     InpSR_TradeBounce      = true;
input bool     InpSR_TradeBreak       = true;
input bool     InpSR_RequireAtLevel   = true;   // signal bar must touch the level
input bool     InpSR_OneTradePerLevel = true;  // one entry per level + reaction type

input group "=== Volume-confirmed breakout (CFD) ==="
input bool     InpUseVolumeFilter      = true;
input int      InpVolAvgPeriod         = 20;
input double   InpVolMinRelMult        = 1.5;
input bool     InpVolRequireRising     = true;
input bool     InpVolUseCandleStrength = true;
input double   InpVolMinCloseFrac      = 0.70;
input bool     InpVolBreakOnly         = true;   // skip filter on FVG bounce / non-break entries

//--- Trade toggles (expansion/reversal only; retracement/consolidation = context)
input string   InpTradeHdr      = "=== Trade phases ===";
input bool     InpTradeExpansion     = true;
input bool     InpTradeReversal      = true;

//--- Risk
input string   InpRiskHdr       = "=== Risk ===";
input double   InpRiskPercent   = 0.25;        // % of balance risked per trade
input ENUM_TIMEFRAMES InpLevelTF = PERIOD_M15; // SL/TP from highs/lows on this TF
input int      InpLevelLookback = 80;
input double   InpSL_BufferPips = 30.0;        // pips beyond nearest M15 H/L (scaled per asset type)
input int      InpMinRiskPoints = 50;
input double   InpMinRR         = 2.0;         // TP distance = SL distance × this (2.0 = 2:1 RR)
input int      InpMaxTradesPerDay = 8;
input int      InpCooldownSec   = 300;
input double   InpMaxDailyLossPct   = 2.0;     // stop entries after daily loss >= this % of balance (0=off)
input double   InpMaxDailyProfitPct = 4.0;     // stop entries after daily profit >= this % of balance (0=off)
input bool     InpAccountPLWholeAccount = true; // P/L limits use whole account (false = this EA magic only)
input double   InpMaxLots         = 10.0;       // cap lot size per trade (0 = broker max only)

//--- Dashboard
input string   InpDashHdr       = "=== Dashboard ===";
input bool     InpShowDashboard = true;
input int      InpDashCorner    = 0;
input int      InpDashX         = 10;
input int      InpDashY         = 20;
input int      InpDashFontSize  = 9;
input bool     InpDebugLog      = true;      // print status/errors to Experts journal
input bool     InpRequireValidSession = true; // block entries when session OHLC unavailable

enum ENUM_PA_SESSION
{
   SESS_NONE   = 0,
   SESS_ASIA   = 1,
   SESS_LONDON = 2,
   SESS_NY     = 3
};

enum ENUM_PA_TREND
{
   PA_TREND_NONE = 0,
   PA_TREND_BULL = 1,
   PA_TREND_BEAR = -1
};

enum ENUM_PA_PHASE
{
   PA_UNKNOWN = 0,
   PA_EXPANSION = 1,
   PA_RETRACEMENT = 2,
   PA_CONSOLIDATION = 3,
   PA_REVERSAL = 4
};

enum ENUM_SYMBOL_ASSET
{
   ASSET_FOREX  = 0,
   ASSET_GOLD   = 1,
   ASSET_SILVER = 2,
   ASSET_INDEX  = 3,
   ASSET_CRYPTO = 4,
   ASSET_FUTURES = 5,
   ASSET_OTHER  = 6
};

struct SSessionSnap
{
   ENUM_PA_SESSION sess;
   datetime        tStart;
   datetime        tEnd;
   double          open;
   double          high;
   double          low;
   double          close;
   double          range;
   ENUM_PA_TREND   trend;
   bool            valid;
};

struct SPA_State
{
   ENUM_PA_SESSION curSess;
   ENUM_PA_SESSION prevSess;
   SSessionSnap    prev;
   SSessionSnap    cur;
   ENUM_PA_PHASE   phase;
   string          phaseLabel;
};

CTrade         g_trade;
SPA_State      g_pa;
datetime       g_cooldown_until = 0;
datetime       g_entries_day = 0;
int            g_entries_today = 0;
int            g_lastDay = -1;
string         g_dashPrefix = "PA_Sess_";
string         g_logMsg = "Initializing";
bool           g_logIsError = false;
string         g_logLastPrint = "";
ENUM_SYMBOL_ASSET g_symbolAsset = ASSET_OTHER;
double         g_pipSize = 0.0;
string         g_instrumentKind = "Unknown";

int g_asiaH, g_asiaM, g_londonH, g_londonM, g_nyH, g_nyM;

#define FVG_MAX_ZONES 24
#define SR_MAX_LEVELS 32

enum ENUM_FVG_REACT
{
   FVG_REACT_NONE = 0,
   FVG_REACT_BOUNCE = 1,
   FVG_REACT_BREAK  = 2
};

struct SFVGZone
{
   int               dir;
   double            top;
   double            bottom;
   datetime          barTime;
   ENUM_TIMEFRAMES   tf;
   bool              valid;
};

struct SFVGAgent
{
   SFVGZone          h4;
   SFVGZone          m15;
   ENUM_FVG_REACT    h4React;
   ENUM_FVG_REACT    m15React;
   bool              h4AtZone;
   bool              m15AtZone;
   string            status;
};

struct SFVGTradeLock
{
   datetime          zoneBarTime;
   ENUM_TIMEFRAMES   tf;
   int               dir;
   ENUM_FVG_REACT    react;
   datetime          lockUntil;
};

struct SSRLevel
{
   double            price;
   int               dir;       // +1 support (swing low), -1 resistance (swing high)
   datetime          barTime;
   ENUM_TIMEFRAMES   tf;
   bool              valid;
};

struct SSRAgent
{
   SSRLevel          h1;
   SSRLevel          h4;
   ENUM_FVG_REACT    h1React;
   ENUM_FVG_REACT    h4React;
   bool              h1AtLevel;
   bool              h4AtLevel;
   string            status;
};

struct SSRTradeLock
{
   double            price;
   ENUM_TIMEFRAMES   tf;
   int               dir;
   ENUM_FVG_REACT    react;
   datetime          lockUntil;
};

SFVGZone   g_fvgH4[FVG_MAX_ZONES];
SFVGZone   g_fvgM15[FVG_MAX_ZONES];
int        g_fvgH4Count = 0;
int        g_fvgM15Count = 0;
SFVGAgent  g_fvgAgent;
datetime   g_fvgLastH4 = 0;
datetime   g_fvgLastM15 = 0;
SFVGTradeLock g_fvgLock;
SSRLevel   g_srH1[SR_MAX_LEVELS];
SSRLevel   g_srH4[SR_MAX_LEVELS];
int        g_srH1Count = 0;
int        g_srH4Count = 0;
SSRAgent   g_srAgent;
datetime   g_srLastH1 = 0;
datetime   g_srLastH4 = 0;
SSRTradeLock g_srLock;
datetime   g_lastEntrySignalBar = 0;

//+------------------------------------------------------------------+
//| FVG agent — scan H4/M15, wait for touch, bounce/break + PA       |
//+------------------------------------------------------------------+
bool FVG_BullAt(const string sym, const ENUM_TIMEFRAMES tf, const int shift,
                double &top, double &bottom)
{
   if(shift < 1) return false;
   double h3 = iHigh(sym, tf, shift + 2);
   double l1 = iLow(sym, tf, shift);
   if(h3 <= 0.0 || l1 <= 0.0 || l1 <= h3) return false;
   bottom = h3;
   top = l1;
   return true;
}

bool FVG_BearAt(const string sym, const ENUM_TIMEFRAMES tf, const int shift,
                double &top, double &bottom)
{
   if(shift < 1) return false;
   double l3 = iLow(sym, tf, shift + 2);
   double h1 = iHigh(sym, tf, shift);
   if(l3 <= 0.0 || h1 <= 0.0 || h1 >= l3) return false;
   bottom = h1;
   top = l3;
   return true;
}

bool FVG_IsMitigated(const SFVGZone &z)
{
   if(!z.valid) return true;
   double c1 = iClose(_Symbol, z.tf, 1);
   if(z.dir > 0 && c1 < z.bottom) return true;
   if(z.dir < 0 && c1 > z.top) return true;
   return false;
}

bool FVG_PriceTouchesZone(const SFVGZone &z, const double price, const double prox)
{
   if(!z.valid) return false;
   return (price <= z.top + prox && price >= z.bottom - prox);
}

bool FVG_BarTouchesZone(const SFVGZone &z, const ENUM_TIMEFRAMES tf, const int shift, const double prox)
{
   if(!z.valid) return false;
   double hi = iHigh(_Symbol, tf, shift);
   double lo = iLow(_Symbol, tf, shift);
   return (lo <= z.top + prox && hi >= z.bottom - prox);
}

void FVG_ScanTF(const ENUM_TIMEFRAMES tf, const int lookback, SFVGZone &zones[], int &count)
{
   count = 0;
   double minGap = PipsToPrice(InpFVG_MinPips);
   int bars = iBars(_Symbol, tf);
   if(bars < 5) return;
   int maxShift = MathMin(lookback, bars - 3);

   for(int s = 2; s <= maxShift && count < FVG_MAX_ZONES; s++)
   {
      SFVGZone z;
      z.valid = false;
      z.tf = tf;
      z.barTime = iTime(_Symbol, tf, s);
      z.dir = 0;
      z.top = z.bottom = 0.0;

      if(FVG_BullAt(_Symbol, tf, s, z.top, z.bottom))
         z.dir = 1;
      else if(FVG_BearAt(_Symbol, tf, s, z.top, z.bottom))
         z.dir = -1;
      else
         continue;

      if((z.top - z.bottom) < minGap) continue;
      z.valid = true;
      if(FVG_IsMitigated(z)) continue;

      zones[count++] = z;
   }
}

int FVG_NearestIndex(const SFVGZone &zones[], const int count, const double price)
{
   if(count <= 0) return -1;
   int best = -1;
   double bestDist = 1e100;
   for(int i = 0; i < count; i++)
   {
      if(!zones[i].valid) continue;
      double mid = (zones[i].top + zones[i].bottom) * 0.5;
      double dist = MathAbs(price - mid);
      if(dist < bestDist)
      {
         bestDist = dist;
         best = i;
      }
   }
   return best;
}

ENUM_FVG_REACT FVG_DetectReactionAtBar(const SFVGZone &z, const ENUM_TIMEFRAMES tf,
                                         const int shift, bool &atZone)
{
   atZone = false;
   if(!z.valid) return FVG_REACT_NONE;

   double prox = PipsToPrice(InpFVG_ProxPips);
   double c1 = iClose(_Symbol, tf, shift);
   double c2 = iClose(_Symbol, tf, shift + 1);
   if(c1 <= 0.0) return FVG_REACT_NONE;

   atZone = FVG_BarTouchesZone(z, tf, shift, prox) || FVG_PriceTouchesZone(z, c1, prox);

   if(z.dir > 0)
   {
      if(c1 < z.bottom && FVG_BarTouchesZone(z, tf, shift, prox))
         return FVG_REACT_BREAK;
      if(atZone && c1 > z.top && c1 > c2)
         return FVG_REACT_BOUNCE;
   }
   else if(z.dir < 0)
   {
      if(c1 > z.top && FVG_BarTouchesZone(z, tf, shift, prox))
         return FVG_REACT_BREAK;
      if(atZone && c1 < z.bottom && c1 < c2)
         return FVG_REACT_BOUNCE;
   }
   return FVG_REACT_NONE;
}

ENUM_FVG_REACT FVG_DetectReaction(const SFVGZone &z, const ENUM_TIMEFRAMES tf, bool &atZone)
{
   return FVG_DetectReactionAtBar(z, tf, 1, atZone);
}

bool FVG_ReactionIsFresh(const SFVGZone &zone, const ENUM_FVG_REACT react)
{
   if(!InpFVG_FreshReactionOnly || react == FVG_REACT_NONE) return true;
   bool at1 = false, at2 = false;
   ENUM_FVG_REACT r1 = FVG_DetectReactionAtBar(zone, InpSignalTF, 1, at1);
   ENUM_FVG_REACT r2 = FVG_DetectReactionAtBar(zone, InpSignalTF, 2, at2);
   return (r1 == react && r1 != r2);
}

bool FVG_ZoneKeysMatch(const SFVGZone &a, const SFVGZone &b)
{
   return (a.valid && b.valid && a.barTime == b.barTime && a.tf == b.tf && a.dir == b.dir);
}

bool FVG_IsLocked(const SFVGZone &zone, const ENUM_FVG_REACT react)
{
   if(!InpFVG_OneTradePerZone || g_fvgLock.lockUntil == 0) return false;
   if(TimeCurrent() >= g_fvgLock.lockUntil) return false;
   return (g_fvgLock.zoneBarTime == zone.barTime &&
           g_fvgLock.tf == zone.tf &&
           g_fvgLock.dir == zone.dir &&
           g_fvgLock.react == react);
}

void FVG_LockZone(const SFVGZone &zone, const ENUM_FVG_REACT react)
{
   g_fvgLock.zoneBarTime = zone.barTime;
   g_fvgLock.tf = zone.tf;
   g_fvgLock.dir = zone.dir;
   g_fvgLock.react = react;
   int lockSec = MathMax(InpCooldownSec, 60);
   g_fvgLock.lockUntil = TimeCurrent() + lockSec;
}

void FVG_ClearLockIfMitigated(const SFVGZone &zone)
{
   if(g_fvgLock.lockUntil == 0) return;
   SFVGZone locked;
   locked.valid = true;
   locked.barTime = g_fvgLock.zoneBarTime;
   locked.tf = g_fvgLock.tf;
   locked.dir = g_fvgLock.dir;
   locked.top = zone.top;
   locked.bottom = zone.bottom;
   if(FVG_ZoneKeysMatch(zone, locked) && FVG_IsMitigated(zone))
      g_fvgLock.lockUntil = 0;
}

//+------------------------------------------------------------------+
//| H1 / H4 swing S&R levels (optional entry alongside FVG)          |
//+------------------------------------------------------------------+
string FVG_ReactName(const ENUM_FVG_REACT r)
{
   if(r == FVG_REACT_BOUNCE) return "Bounce";
   if(r == FVG_REACT_BREAK) return "Break";
   return "—";
}

double SR_ProxPrice() { return PipsToPrice(InpSR_ProxPips); }

string SR_TFShort(const ENUM_TIMEFRAMES tf)
{
   if(tf == PERIOD_H4) return "H4";
   if(tf == PERIOD_H1) return "H1";
   return EnumToString(tf);
}

string SR_LevelName(const SSRLevel &lv)
{
   if(!lv.valid) return "—";
   return StringFormat("%s %s %.2f", SR_TFShort(lv.tf),
      (lv.dir > 0 ? "Sup" : "Res"), lv.price);
}

bool SR_IsSwingHigh(const ENUM_TIMEFRAMES tf, const int shift, const int wing)
{
   if(wing < 1) return false;
   int bars = iBars(_Symbol, tf);
   if(shift + wing >= bars || shift - wing < 0) return false;
   double h = iHigh(_Symbol, tf, shift);
   if(h <= 0.0) return false;
   for(int i = 1; i <= wing; i++)
   {
      if(iHigh(_Symbol, tf, shift - i) >= h) return false;
      if(iHigh(_Symbol, tf, shift + i) >= h) return false;
   }
   return true;
}

bool SR_IsSwingLow(const ENUM_TIMEFRAMES tf, const int shift, const int wing)
{
   if(wing < 1) return false;
   int bars = iBars(_Symbol, tf);
   if(shift + wing >= bars || shift - wing < 0) return false;
   double l = iLow(_Symbol, tf, shift);
   if(l <= 0.0) return false;
   for(int i = 1; i <= wing; i++)
   {
      if(iLow(_Symbol, tf, shift - i) <= l) return false;
      if(iLow(_Symbol, tf, shift + i) <= l) return false;
   }
   return true;
}

void SR_ScanTF(const ENUM_TIMEFRAMES tf, const int lookback, SSRLevel &levels[], int &count)
{
   count = 0;
   int wing = MathMax(1, InpSR_SwingBars);
   int maxShift = MathMin(lookback, iBars(_Symbol, tf) - wing - 1);
   for(int s = wing; s <= maxShift && count < SR_MAX_LEVELS; s++)
   {
      SSRLevel lv;
      lv.valid = false;
      lv.tf = tf;
      lv.barTime = iTime(_Symbol, tf, s);
      if(lv.barTime <= 0) continue;

      if(SR_IsSwingHigh(tf, s, wing))
      {
         lv.price = iHigh(_Symbol, tf, s);
         lv.dir = -1;
         lv.valid = true;
      }
      else if(SR_IsSwingLow(tf, s, wing))
      {
         lv.price = iLow(_Symbol, tf, s);
         lv.dir = 1;
         lv.valid = true;
      }
      else continue;

      levels[count++] = lv;
   }
}

int SR_NearestIndex(const SSRLevel &levels[], const int count, const double price)
{
   if(count <= 0) return -1;
   int best = -1;
   double bestDist = 1e100;
   for(int i = 0; i < count; i++)
   {
      if(!levels[i].valid) continue;
      double dist = MathAbs(price - levels[i].price);
      if(dist < bestDist)
      {
         bestDist = dist;
         best = i;
      }
   }
   return best;
}

bool SR_PriceNearLevel(const SSRLevel &lv, const double price, const double prox)
{
   if(!lv.valid) return false;
   return (MathAbs(price - lv.price) <= prox + 1e-9);
}

bool SR_BarTouchesLevel(const SSRLevel &lv, const ENUM_TIMEFRAMES tf, const int shift, const double prox)
{
   if(!lv.valid) return false;
   double hi = iHigh(_Symbol, tf, shift);
   double lo = iLow(_Symbol, tf, shift);
   if(hi <= 0.0 || lo <= 0.0) return false;
   return (lo <= lv.price + prox && hi >= lv.price - prox);
}

ENUM_FVG_REACT SR_DetectReactionAtBar(const SSRLevel &lv, const ENUM_TIMEFRAMES tf,
                                      const int shift, bool &atLevel)
{
   atLevel = false;
   if(!lv.valid) return FVG_REACT_NONE;

   double prox = SR_ProxPrice();
   double c1 = iClose(_Symbol, tf, shift);
   double c2 = iClose(_Symbol, tf, shift + 1);
   if(c1 <= 0.0) return FVG_REACT_NONE;

   atLevel = SR_BarTouchesLevel(lv, tf, shift, prox) || SR_PriceNearLevel(lv, c1, prox);

   if(lv.dir > 0)  // support
   {
      if(c1 < lv.price - prox && SR_BarTouchesLevel(lv, tf, shift, prox))
         return FVG_REACT_BREAK;
      if(atLevel && c1 > lv.price + prox && c1 > c2)
         return FVG_REACT_BOUNCE;
   }
   else if(lv.dir < 0)  // resistance
   {
      if(c1 > lv.price + prox && SR_BarTouchesLevel(lv, tf, shift, prox))
         return FVG_REACT_BREAK;
      if(atLevel && c1 < lv.price - prox && c1 < c2)
         return FVG_REACT_BOUNCE;
   }
   return FVG_REACT_NONE;
}

ENUM_FVG_REACT SR_DetectReaction(const SSRLevel &lv, const ENUM_TIMEFRAMES tf, bool &atLevel)
{
   return SR_DetectReactionAtBar(lv, tf, 1, atLevel);
}

bool SR_ReactionIsFresh(const SSRLevel &lv, const ENUM_FVG_REACT react)
{
   if(!InpFVG_FreshReactionOnly || react == FVG_REACT_NONE) return true;
   bool at1 = false, at2 = false;
   ENUM_FVG_REACT r1 = SR_DetectReactionAtBar(lv, InpSignalTF, 1, at1);
   ENUM_FVG_REACT r2 = SR_DetectReactionAtBar(lv, InpSignalTF, 2, at2);
   return (r1 == react && r2 != react);
}

bool SR_LevelKeysMatch(const SSRLevel &a, const SSRLevel &b)
{
   return (a.valid && b.valid && a.tf == b.tf && a.dir == b.dir &&
           MathAbs(a.price - b.price) < Pt() * 2.0);
}

bool SR_IsLocked(const SSRLevel &lv, const ENUM_FVG_REACT react)
{
   if(!InpSR_OneTradePerLevel || g_srLock.lockUntil == 0) return false;
   if(TimeCurrent() >= g_srLock.lockUntil) return false;
   return (MathAbs(g_srLock.price - lv.price) < Pt() * 2.0 &&
           g_srLock.tf == lv.tf &&
           g_srLock.dir == lv.dir &&
           g_srLock.react == react);
}

void SR_LockLevel(const SSRLevel &lv, const ENUM_FVG_REACT react)
{
   g_srLock.price = lv.price;
   g_srLock.tf = lv.tf;
   g_srLock.dir = lv.dir;
   g_srLock.react = react;
   int lockSec = MathMax(InpCooldownSec, 60);
   g_srLock.lockUntil = TimeCurrent() + lockSec;
}

bool SR_TryReactionFromLevel(const SSRLevel &lv, const ENUM_FVG_REACT react,
                             ENUM_FVG_REACT &reactOut, SSRLevel &lvOut, string &reasonOut)
{
   if(!lv.valid || react == FVG_REACT_NONE) return false;
   reactOut = react;
   lvOut = lv;
   reasonOut = StringFormat("%s %s %s", SR_TFShort(lv.tf),
      (lv.dir > 0 ? "Support" : "Resistance"), FVG_ReactName(react));
   return true;
}

void SR_AgentUpdate()
{
   g_srAgent.status = "Off";
   g_srAgent.h1.valid = false;
   g_srAgent.h4.valid = false;
   g_srAgent.h1React = FVG_REACT_NONE;
   g_srAgent.h4React = FVG_REACT_NONE;
   g_srAgent.h1AtLevel = false;
   g_srAgent.h4AtLevel = false;

   if(!InpUseSR_H1 && !InpUseSR_H4) return;

   datetime tH1 = iTime(_Symbol, PERIOD_H1, 0);
   datetime tH4 = iTime(_Symbol, PERIOD_H4, 0);
   if(InpUseSR_H1 && tH1 != g_srLastH1)
   {
      SR_ScanTF(PERIOD_H1, InpSR_H1_Lookback, g_srH1, g_srH1Count);
      g_srLastH1 = tH1;
   }
   if(InpUseSR_H4 && tH4 != g_srLastH4)
   {
      SR_ScanTF(PERIOD_H4, InpSR_H4_Lookback, g_srH4, g_srH4Count);
      g_srLastH4 = tH4;
   }

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price <= 0.0) price = iClose(_Symbol, InpSignalTF, 1);

   if(InpUseSR_H1)
   {
      int iH1 = SR_NearestIndex(g_srH1, g_srH1Count, price);
      if(iH1 >= 0) g_srAgent.h1 = g_srH1[iH1];
      if(g_srAgent.h1.valid)
         g_srAgent.h1React = SR_DetectReaction(g_srAgent.h1, InpSignalTF, g_srAgent.h1AtLevel);
   }
   if(InpUseSR_H4)
   {
      int iH4 = SR_NearestIndex(g_srH4, g_srH4Count, price);
      if(iH4 >= 0) g_srAgent.h4 = g_srH4[iH4];
      if(g_srAgent.h4.valid)
         g_srAgent.h4React = SR_DetectReaction(g_srAgent.h4, InpSignalTF, g_srAgent.h4AtLevel);
   }

   if(InpUseSR_H4 && g_srAgent.h4.valid)
      g_srAgent.status = StringFormat("H4 %s %.2f %s",
         (g_srAgent.h4.dir > 0 ? "Sup" : "Res"), g_srAgent.h4.price,
         FVG_ReactName(g_srAgent.h4React));
   else if(InpUseSR_H1 && g_srAgent.h1.valid)
      g_srAgent.status = StringFormat("H1 %s %.2f %s",
         (g_srAgent.h1.dir > 0 ? "Sup" : "Res"), g_srAgent.h1.price,
         FVG_ReactName(g_srAgent.h1React));
   else
      g_srAgent.status = "No S/R level near price";
}

bool SR_ReactionReady(ENUM_FVG_REACT &reactOut, SSRLevel &lvOut, string &reasonOut)
{
   reactOut = FVG_REACT_NONE;
   lvOut.valid = false;
   reasonOut = "";

   if(!InpUseSR_H1 && !InpUseSR_H4) return false;

   // Prefer H4 S/R over H1 when both signal
   if(InpUseSR_H4)
   {
      if(SR_TryReactionFromLevel(g_srAgent.h4, g_srAgent.h4React, reactOut, lvOut, reasonOut))
         return true;
   }
   if(InpUseSR_H1)
   {
      if(SR_TryReactionFromLevel(g_srAgent.h1, g_srAgent.h1React, reactOut, lvOut, reasonOut))
         return true;
   }

   reasonOut = "No H1/H4 S/R reaction";
   return false;
}

double PA_Body(const double o, const double c) { return MathAbs(c - o); }

bool PA_BullPin(const ENUM_TIMEFRAMES tf, const int sh)
{
   double o = iOpen(_Symbol, tf, sh), c = iClose(_Symbol, tf, sh);
   double h = iHigh(_Symbol, tf, sh), l = iLow(_Symbol, tf, sh);
   double range = h - l;
   if(range <= 0.0 || c < o) return false;
   double body = c - o;
   double lowerWick = MathMin(o, c) - l;
   return (lowerWick >= body * 2.0 && body <= range * 0.35);
}

bool PA_BearPin(const ENUM_TIMEFRAMES tf, const int sh)
{
   double o = iOpen(_Symbol, tf, sh), c = iClose(_Symbol, tf, sh);
   double h = iHigh(_Symbol, tf, sh), l = iLow(_Symbol, tf, sh);
   double range = h - l;
   if(range <= 0.0 || c > o) return false;
   double body = o - c;
   double upperWick = h - MathMax(o, c);
   return (upperWick >= body * 2.0 && body <= range * 0.35);
}

bool PA_BullEngulf(const ENUM_TIMEFRAMES tf, const int sh)
{
   double o1 = iOpen(_Symbol, tf, sh), c1 = iClose(_Symbol, tf, sh);
   double o2 = iOpen(_Symbol, tf, sh + 1), c2 = iClose(_Symbol, tf, sh + 1);
   if(c2 >= o2 || c1 <= o1) return false;
   return (c1 >= o2 && o1 <= c2 && (c1 - o1) > (o2 - c2));
}

bool PA_BearEngulf(const ENUM_TIMEFRAMES tf, const int sh)
{
   double o1 = iOpen(_Symbol, tf, sh), c1 = iClose(_Symbol, tf, sh);
   double o2 = iOpen(_Symbol, tf, sh + 1), c2 = iClose(_Symbol, tf, sh + 1);
   if(c2 <= o2 || c1 >= o1) return false;
   return (o1 >= c2 && c1 <= o2 && (o1 - c1) > (c2 - o2));
}

bool PA_BullConfirm(const ENUM_TIMEFRAMES tf)
{
   double c1 = iClose(_Symbol, tf, 1);
   double o1 = iOpen(_Symbol, tf, 1);
   if(c1 <= o1) return false;
   if(InpFVG_UsePin && PA_BullPin(tf, 1)) return true;
   if(InpFVG_UseEngulf && PA_BullEngulf(tf, 1)) return true;
   if(InpFVG_StrictPA) return false;
   return (c1 > o1 && PA_Body(o1, c1) > PipsToPrice(InpFVG_MinBodyPips));
}

bool PA_BearConfirm(const ENUM_TIMEFRAMES tf)
{
   double c1 = iClose(_Symbol, tf, 1);
   double o1 = iOpen(_Symbol, tf, 1);
   if(c1 >= o1) return false;
   if(InpFVG_UsePin && PA_BearPin(tf, 1)) return true;
   if(InpFVG_UseEngulf && PA_BearEngulf(tf, 1)) return true;
   if(InpFVG_StrictPA) return false;
   return (c1 < o1 && PA_Body(o1, c1) > PipsToPrice(InpFVG_MinBodyPips));
}

bool SessionStateOK()
{
   if(!InpRequireValidSession) return true;
   return (g_pa.prev.valid && g_pa.cur.valid && g_pa.phase != PA_UNKNOWN);
}

void RecordEntrySuccess()
{
   datetime bar = iTime(_Symbol, InpSignalTF, 1);
   if(bar > 0 && bar == g_lastEntrySignalBar)
      return;
   ResetDailyTradeCount();
   g_entries_today++;
   if(InpCooldownSec > 0)
      g_cooldown_until = TimeCurrent() + InpCooldownSec;
   if(bar > 0)
      g_lastEntrySignalBar = bar;
}

bool Phase_IsTradable()
{
   return (g_pa.phase == PA_EXPANSION || g_pa.phase == PA_REVERSAL);
}

// Entries: expansion/reversal always; retracement/consolidation allowed on FVG path only.
bool Phase_AllowsTrade(const bool wantBuy, const bool fvgEntry = false)
{
   if(!InpRequirePhaseAlign) return true;
   if(!g_pa.prev.valid || g_pa.prev.trend == PA_TREND_NONE) return false;

   if(g_pa.phase == PA_EXPANSION)
   {
      if(wantBuy)  return (g_pa.prev.trend == PA_TREND_BULL);
      return (g_pa.prev.trend == PA_TREND_BEAR);
   }

   if(g_pa.phase == PA_REVERSAL)
   {
      if(wantBuy)  return (g_pa.prev.trend == PA_TREND_BEAR);
      return (g_pa.prev.trend == PA_TREND_BULL);
   }

   if(fvgEntry && (g_pa.phase == PA_RETRACEMENT || g_pa.phase == PA_CONSOLIDATION))
   {
      if(wantBuy)  return (g_pa.prev.trend == PA_TREND_BULL);
      return (g_pa.prev.trend == PA_TREND_BEAR);
   }

   return false;
}

string Phase_EntryHint()
{
   if(g_pa.phase == PA_RETRACEMENT)
      return (InpUseFVGAgent || InpUseSR_H1 || InpUseSR_H4) ?
         "Entry OK (retracement, with trend)" : "Context: retracement (no entry)";
   if(g_pa.phase == PA_CONSOLIDATION)
      return (InpUseFVGAgent || InpUseSR_H1 || InpUseSR_H4) ?
         "Entry OK (consolidation, with trend)" : "Context: consolidation (no entry)";
   if(g_pa.phase == PA_EXPANSION)      return "Tradable: expansion";
   if(g_pa.phase == PA_REVERSAL)       return "Tradable: reversal";
   return "Phase unknown";
}

string FVG_TFShort(const ENUM_TIMEFRAMES tf)
{
   if(tf == PERIOD_H4) return "H4";
   if(tf == PERIOD_M15) return "M15";
   return EnumToString(tf);
}

bool FVG_TryReactionFromZone(const SFVGZone &zone, const ENUM_FVG_REACT react,
                             ENUM_FVG_REACT &reactOut, SFVGZone &zoneOut, string &reasonOut)
{
   if(!zone.valid || react == FVG_REACT_NONE) return false;
   reactOut = react;
   zoneOut = zone;
   reasonOut = StringFormat("%s FVG %s", FVG_TFShort(zone.tf), FVG_ReactName(react));
   return true;
}

void FVG_AgentUpdate()
{
   g_fvgAgent.status = "Scanning";
   g_fvgAgent.h4.valid = false;
   g_fvgAgent.m15.valid = false;
   g_fvgAgent.h4React = FVG_REACT_NONE;
   g_fvgAgent.m15React = FVG_REACT_NONE;
   g_fvgAgent.h4AtZone = false;
   g_fvgAgent.m15AtZone = false;

   datetime tH4 = iTime(_Symbol, PERIOD_H4, 0);
   datetime tM15 = iTime(_Symbol, PERIOD_M15, 0);
   if(tH4 != g_fvgLastH4)
   {
      FVG_ScanTF(PERIOD_H4, InpFVG_H4_Lookback, g_fvgH4, g_fvgH4Count);
      g_fvgLastH4 = tH4;
   }
   if(tM15 != g_fvgLastM15)
   {
      FVG_ScanTF(PERIOD_M15, InpFVG_M15_Lookback, g_fvgM15, g_fvgM15Count);
      g_fvgLastM15 = tM15;
   }

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int iH4 = FVG_NearestIndex(g_fvgH4, g_fvgH4Count, price);
   int iM15 = FVG_NearestIndex(g_fvgM15, g_fvgM15Count, price);

   if(iH4 >= 0) g_fvgAgent.h4 = g_fvgH4[iH4];
   if(iM15 >= 0) g_fvgAgent.m15 = g_fvgM15[iM15];

   if(g_fvgAgent.h4.valid)
      g_fvgAgent.h4React = FVG_DetectReaction(g_fvgAgent.h4, InpSignalTF, g_fvgAgent.h4AtZone);
   if(g_fvgAgent.m15.valid)
      g_fvgAgent.m15React = FVG_DetectReaction(g_fvgAgent.m15, InpSignalTF, g_fvgAgent.m15AtZone);

   if(g_fvgAgent.h4.valid && g_fvgAgent.m15.valid)
   {
      g_fvgAgent.status = StringFormat("H4 %s %.2f-%.2f %s | M15 %s %.2f-%.2f %s",
         (g_fvgAgent.h4.dir > 0 ? "Bull" : "Bear"),
         g_fvgAgent.h4.bottom, g_fvgAgent.h4.top, FVG_ReactName(g_fvgAgent.h4React),
         (g_fvgAgent.m15.dir > 0 ? "Bull" : "Bear"),
         g_fvgAgent.m15.bottom, g_fvgAgent.m15.top, FVG_ReactName(g_fvgAgent.m15React));
   }
   else if(g_fvgAgent.h4.valid)
   {
      g_fvgAgent.status = StringFormat("H4 %s %.2f-%.2f %s",
         (g_fvgAgent.h4.dir > 0 ? "Bull" : "Bear"),
         g_fvgAgent.h4.bottom, g_fvgAgent.h4.top,
         FVG_ReactName(g_fvgAgent.h4React));
   }
   else if(g_fvgAgent.m15.valid)
   {
      g_fvgAgent.status = StringFormat("M15 %s %.2f-%.2f %s",
         (g_fvgAgent.m15.dir > 0 ? "Bull" : "Bear"),
         g_fvgAgent.m15.bottom, g_fvgAgent.m15.top,
         FVG_ReactName(g_fvgAgent.m15React));
   }
   else
      g_fvgAgent.status = "No active FVG near price";
}

bool FVG_ReactionReady(ENUM_FVG_REACT &reactOut, SFVGZone &zoneOut, string &reasonOut)
{
   reactOut = FVG_REACT_NONE;
   zoneOut.valid = false;
   reasonOut = "";

   if(InpFVG_EntryTF == FVG_ENTRY_H4)
   {
      if(FVG_TryReactionFromZone(g_fvgAgent.h4, g_fvgAgent.h4React, reactOut, zoneOut, reasonOut))
         return true;
      reasonOut = "No H4 FVG reaction";
      return false;
   }

   if(InpFVG_EntryTF == FVG_ENTRY_M15)
   {
      if(FVG_TryReactionFromZone(g_fvgAgent.m15, g_fvgAgent.m15React, reactOut, zoneOut, reasonOut))
         return true;
      reasonOut = "No M15 FVG reaction";
      return false;
   }

   // H4 or M15 — prefer H4 when both signal (higher TF)
   if(FVG_TryReactionFromZone(g_fvgAgent.h4, g_fvgAgent.h4React, reactOut, zoneOut, reasonOut))
      return true;
   if(FVG_TryReactionFromZone(g_fvgAgent.m15, g_fvgAgent.m15React, reactOut, zoneOut, reasonOut))
      return true;

   reasonOut = "No H4 or M15 FVG reaction";
   return false;
}

bool ExecuteTrade(const bool buy, const string tag, const bool fvgEntry = false, const bool breakoutVolume = true);

void SetLog(const string msg, const bool isError = false)
{
   g_logMsg = msg;
   g_logIsError = isError;
   if(!InpDebugLog || msg == g_logLastPrint) return;
   g_logLastPrint = msg;
   Print(isError ? "PA Phases ERROR: " : "PA Phases: ", msg);
}

void SetLogOk(const string msg)
{
   SetLog(msg, false);
}

bool PassesBreakoutVolume(const bool buy, const datetime barTime, const bool isBreakoutEntry)
{
   if(!InpUseVolumeFilter) return true;
   if(InpVolBreakOnly && !isBreakoutEntry) return true;
   return VBF_PassesBreakoutVolume(_Symbol, InpSignalTF, barTime, buy,
      true, InpVolAvgPeriod, InpVolMinRelMult, InpVolRequireRising,
      InpVolUseCandleStrength, InpVolMinCloseFrac);
}

bool AgentPlaceEntry(const bool wantBuy, const bool wantSell,
                     const string tag, const bool volBreak, const string agentLabel)
{
   if(wantBuy && !PA_BullConfirm(InpSignalTF))
   {
      SetLogOk(InpFVG_StrictPA ? StringFormat("%s buy waiting for pin/engulf", agentLabel) :
                                StringFormat("%s buy waiting for PA candle", agentLabel));
      return false;
   }
   if(wantSell && !PA_BearConfirm(InpSignalTF))
   {
      SetLogOk(InpFVG_StrictPA ? StringFormat("%s sell waiting for pin/engulf", agentLabel) :
                                StringFormat("%s sell waiting for PA candle", agentLabel));
      return false;
   }
   if(!wantBuy && !wantSell)
   {
      SetLog(StringFormat("%s reaction has no direction", agentLabel), true);
      return false;
   }
   if(!Phase_AllowsTrade(wantBuy, true))
   {
      SetLogOk(StringFormat("%s %s skipped — %s (phase filter)",
         agentLabel, wantBuy ? "buy" : "sell", Phase_Name(g_pa.phase)));
      return false;
   }

   datetime signalBar = iTime(_Symbol, InpSignalTF, 1);
   if(signalBar > 0 && signalBar == g_lastEntrySignalBar)
   {
      SetLogOk(StringFormat("%s skipped — already entered on this signal bar", agentLabel));
      return false;
   }

   if(wantBuy)  return ExecuteTrade(true, tag, true, volBreak);
   if(wantSell) return ExecuteTrade(false, tag, true, volBreak);
   return false;
}

bool TryFVGTrade()
{
   if(!InpUseFVGAgent) return false;
   if(!SessionStateOK())
   {
      SetLogOk("FVG skipped — session state invalid");
      return false;
   }

   ENUM_FVG_REACT react;
   SFVGZone zone;
   string reason;
   if(!FVG_ReactionReady(react, zone, reason))
   {
      SetLogOk(reason);
      return false;
   }

   if(react == FVG_REACT_BOUNCE && !InpFVG_TradeBounce)
   {
      SetLogOk("FVG bounce signal ignored (disabled)");
      return false;
   }
   if(react == FVG_REACT_BREAK && !InpFVG_TradeBreak)
   {
      SetLogOk("FVG break signal ignored (disabled)");
      return false;
   }
   if(FVG_IsLocked(zone, react))
   {
      SetLogOk("FVG skipped — zone already traded");
      return false;
   }
   if(!FVG_ReactionIsFresh(zone, react))
   {
      SetLogOk("FVG skipped — reaction not fresh on this bar");
      return false;
   }

   bool atZone = false;
   FVG_DetectReactionAtBar(zone, InpSignalTF, 1, atZone);
   if(InpFVG_RequireAtZone && !atZone)
   {
      SetLogOk("FVG skipped — price not at zone on signal bar");
      return false;
   }

   FVG_ClearLockIfMitigated(zone);

   bool wantBuy = false;
   bool wantSell = false;

   if(react == FVG_REACT_BOUNCE)
   {
      if(zone.dir > 0) wantBuy = true;
      else wantSell = true;
   }
   else if(react == FVG_REACT_BREAK)
   {
      if(zone.dir > 0) wantSell = true;
      else wantBuy = true;
   }

   string tag = StringFormat("%s_%s",
      (react == FVG_REACT_BOUNCE ? "FVG_BNC" : "FVG_BRK"),
      FVG_TFShort(zone.tf));
   bool placed = AgentPlaceEntry(wantBuy, wantSell, tag, react == FVG_REACT_BREAK, "FVG");
   if(placed)
      FVG_LockZone(zone, react);
   return placed;
}

bool TrySRTrade()
{
   if(!InpUseSR_H1 && !InpUseSR_H4) return false;
   if(!SessionStateOK())
   {
      SetLogOk("S/R skipped — session state invalid");
      return false;
   }

   ENUM_FVG_REACT react;
   SSRLevel level;
   string reason;
   if(!SR_ReactionReady(react, level, reason))
   {
      SetLogOk(reason);
      return false;
   }

   if(react == FVG_REACT_BOUNCE && !InpSR_TradeBounce)
   {
      SetLogOk("S/R bounce signal ignored (disabled)");
      return false;
   }
   if(react == FVG_REACT_BREAK && !InpSR_TradeBreak)
   {
      SetLogOk("S/R break signal ignored (disabled)");
      return false;
   }
   if(SR_IsLocked(level, react))
   {
      SetLogOk("S/R skipped — level already traded");
      return false;
   }
   if(!SR_ReactionIsFresh(level, react))
   {
      SetLogOk("S/R skipped — reaction not fresh on this bar");
      return false;
   }

   bool atLevel = false;
   SR_DetectReactionAtBar(level, InpSignalTF, 1, atLevel);
   if(InpSR_RequireAtLevel && !atLevel)
   {
      SetLogOk("S/R skipped — price not at level on signal bar");
      return false;
   }

   bool wantBuy = false;
   bool wantSell = false;
   if(react == FVG_REACT_BOUNCE)
   {
      if(level.dir > 0) wantBuy = true;
      else wantSell = true;
   }
   else if(react == FVG_REACT_BREAK)
   {
      if(level.dir > 0) wantSell = true;
      else wantBuy = true;
   }

   string tag = StringFormat("%s_%s_%s",
      (react == FVG_REACT_BOUNCE ? "SR_BNC" : "SR_BRK"),
      SR_TFShort(level.tf),
      (level.dir > 0 ? "SUP" : "RES"));
   bool placed = AgentPlaceEntry(wantBuy, wantSell, tag, react == FVG_REACT_BREAK, "S/R");
   if(placed)
      SR_LockLevel(level, react);
   return placed;
}

//+------------------------------------------------------------------+
//| Session helpers (inlined)                                        |
//+------------------------------------------------------------------+
void Sess_CSTToBroker(const string cstTime, const int brokerGMTOffset, int &brokerH, int &brokerM)
{
   int cstH = (int)StringSubstr(cstTime, 0, 2);
   int cstM = (int)StringSubstr(cstTime, 3, 2);
   int cstGMT = -6;
   int totalMins = cstH * 60 + cstM + (brokerGMTOffset - cstGMT) * 60;
   if(totalMins < 0)     totalMins += 1440;
   if(totalMins >= 1440) totalMins -= 1440;
   brokerH = totalMins / 60;
   brokerM = totalMins % 60;
}

double Sess_HourFrac(const int h, const int m) { return h + m / 60.0; }

bool Sym_HasKey(const string symUpper, const string key)
{
   return (StringFind(symUpper, key) >= 0);
}

string Sym_Normalize(const string sym)
{
   string s = sym;
   StringReplace(s, "#", "");
   StringToUpper(s);
   return s;
}

bool SymbolAllowed()
{
   if(!InpUseSymbolWhitelist) return true;
   if(StringLen(InpAllowedSymbols) == 0) return true;

   string sym = Sym_Normalize(_Symbol);
   string parts[];
   int n = StringSplit(InpAllowedSymbols, ',', parts);
   for(int i = 0; i < n; i++)
   {
      string key = parts[i];
      StringTrimLeft(key);
      StringTrimRight(key);
      StringToUpper(key);
      if(key == "") continue;
      if(StringFind(sym, key) >= 0) return true;
   }
   return false;
}

bool Sym_MatchRoot(const string symUpper, const string root)
{
   int pos = StringFind(symUpper, root);
   if(pos < 0) return false;
   int after = pos + (int)StringLen(root);
   if(after >= StringLen(symUpper)) return true;
   ushort ch = StringGetCharacter(symUpper, after);
   return (ch >= '0' && ch <= '9') || ch == '.' || ch == '_' || ch == '-';
}

bool Sym_HasRoot(const string symUpper, const string root)
{
   return Sym_MatchRoot(symUpper, root);
}

bool Sym_HasAnyRoot(const string symUpper, const string &roots[])
{
   for(int i = 0; i < ArraySize(roots); i++)
      if(Sym_HasRoot(symUpper, roots[i])) return true;
   return false;
}

bool Sym_IsGoldName(const string symUpper)
{
   return Sym_HasKey(symUpper, "XAU") || Sym_HasKey(symUpper, "GOLD");
}

bool Sym_IsSilverName(const string symUpper)
{
   return Sym_HasKey(symUpper, "XAG") || Sym_HasKey(symUpper, "SILVER");
}

bool Sym_IsFutureIndexName(const string symUpper)
{
   static const string keys[] =
   {
      "MES", "MNQ", "MYM", "M2K",
      "ES", "NQ", "YM", "RTY", "EMD", "NKD",
      "FDAX", "FESX", "FSMI"
   };
   return Sym_HasAnyRoot(symUpper, keys);
}

bool Sym_IsFutureGoldName(const string symUpper)
{
   static const string keys[] = { "MGC", "GC", "QO" };
   return Sym_HasAnyRoot(symUpper, keys) || Sym_IsGoldName(symUpper);
}

bool Sym_IsFutureSilverName(const string symUpper)
{
   static const string keys[] = { "SIL", "SI" };
   return Sym_HasAnyRoot(symUpper, keys) || Sym_IsSilverName(symUpper);
}

bool Sym_IsFutureEnergyName(const string symUpper)
{
   static const string keys[] = { "MCL", "CL", "NG", "QG", "RB", "HO" };
   return Sym_HasAnyRoot(symUpper, keys);
}

bool Sym_IsFutureName(const string symUpper)
{
   return Sym_IsFutureIndexName(symUpper) || Sym_IsFutureGoldName(symUpper) ||
          Sym_IsFutureSilverName(symUpper) || Sym_IsFutureEnergyName(symUpper);
}

bool Sym_IsIndexName(const string symUpper)
{
   static const string keys[] =
   {
      "US30", "US500", "US100", "US2000", "USTEC", "USTECH", "USATECH", "TECH100",
      "NAS100", "NASDAQ", "NDX", "NDX100", "NQ100", "USNAS", "USA100",
      "DOW", "DJI", "DJ30", "WS30",
      "UK100", "FTSE100", "FTSE",
      "GER40", "DE40", "DAX40", "DAX",
      "EU50", "STOXX50", "FRA40", "CAC40",
      "JP225", "NI225", "NIKKEI",
      "AUS200", "HK50", "HSI", "CN50", "IT40", "ES35",
      "SWI20", "NOR25", "SPA35"
   };
   for(int i = 0; i < ArraySize(keys); i++)
      if(StringFind(symUpper, keys[i]) >= 0) return true;
   return false;
}

bool Sym_IsCryptoName(const string symUpper)
{
   return Sym_HasKey(symUpper, "BTC") || Sym_HasKey(symUpper, "ETH") ||
          Sym_HasKey(symUpper, "LTC") || Sym_HasKey(symUpper, "XRP");
}

bool Sym_HeuristicIsIndex(const double bid, const int digits,
                          const double point, const double tickSize)
{
   if(digits > 2 || bid < 100.0) return false;
   if(tickSize >= 1.0) return true;
   if(bid >= 100.0 && point <= 0.01) return true;
   return false;
}

string SymbolCalcModeName(const long calcMode)
{
   switch((ENUM_SYMBOL_CALC_MODE)calcMode)
   {
      case SYMBOL_CALC_MODE_FOREX:         return "Forex";
      case SYMBOL_CALC_MODE_FUTURES:       return "Futures";
      case SYMBOL_CALC_MODE_CFD:           return "CFD";
      case SYMBOL_CALC_MODE_CFDINDEX:      return "CFD Index";
      case SYMBOL_CALC_MODE_CFDLEVERAGE:   return "CFD Leverage";
      case SYMBOL_CALC_MODE_EXCH_STOCKS:   return "Stocks";
      case SYMBOL_CALC_MODE_EXCH_FUTURES:  return "Exchange Futures";
      case SYMBOL_CALC_MODE_SERV_COLLATERAL: return "Collateral";
      default:                             return "Other";
   }
}

string SymbolAsset_Name(const ENUM_SYMBOL_ASSET asset)
{
   switch(asset)
   {
      case ASSET_GOLD:    return "Gold";
      case ASSET_SILVER:  return "Silver";
      case ASSET_INDEX:   return "Index";
      case ASSET_FOREX:   return "Forex";
      case ASSET_CRYPTO:  return "Crypto";
      case ASSET_FUTURES: return "Futures";
      default:            return "Other";
   }
}

string SymbolAsset_Label()
{
   return StringFormat("%s/%s", SymbolAsset_Name(g_symbolAsset), g_instrumentKind);
}

double IndexPipSizeUnit()  { return 1.0; }    // US30, USTEC, DE40: 1 pip = 1 index point

double GoldPipSizeUnit()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tick  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0) tick = point;
   if(tick >= 0.1) return tick;
   if(tick >= 0.01) return 0.1;   // XAUUSD/XAUEUR: 1 pip = $0.10 (10 × 0.01 point)
   return MathMax(0.1, point * 10.0);
}

double SilverPipSizeUnit()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tick  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0) tick = point;
   if(tick >= 0.01) return 0.01;
   return MathMax(0.01, point * 10.0);
}

double SymbolAsset_PipSizeFor(const ENUM_SYMBOL_ASSET asset)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   switch(asset)
   {
      case ASSET_GOLD:    return GoldPipSizeUnit();
      case ASSET_SILVER:  return SilverPipSizeUnit();
      case ASSET_INDEX:   return IndexPipSizeUnit();
      case ASSET_CRYPTO:
         if(bid >= 1000.0) return 1.0;
         if(digits == 3 || digits == 5) return point * 10.0;
         return point;
      case ASSET_FUTURES:
         if(tickSize > 0.0) return MathMax(tickSize, point);
         if(digits == 3 || digits == 5) return point * 10.0;
         return point;
      case ASSET_FOREX:
         if(digits == 3 || digits == 5) return point * 10.0;
         return point;
      default:
         if(digits == 3 || digits == 5) return point * 10.0;
         return point;
   }
}

ENUM_SYMBOL_ASSET SymbolAsset_DetectFrom(const string symUpper, const long calcMode)
{
   if(Sym_IsGoldName(symUpper) || Sym_IsFutureGoldName(symUpper)) return ASSET_GOLD;
   if(Sym_IsSilverName(symUpper) || Sym_IsFutureSilverName(symUpper)) return ASSET_SILVER;

   if(calcMode == SYMBOL_CALC_MODE_FUTURES || calcMode == SYMBOL_CALC_MODE_EXCH_FUTURES)
   {
      if(Sym_IsFutureIndexName(symUpper) || Sym_IsIndexName(symUpper)) return ASSET_INDEX;
      if(Sym_IsFutureEnergyName(symUpper)) return ASSET_FUTURES;
      if(Sym_IsFutureName(symUpper)) return ASSET_FUTURES;
      return ASSET_FUTURES;
   }

   if(calcMode == SYMBOL_CALC_MODE_CFDINDEX) return ASSET_INDEX;

   if(Sym_IsIndexName(symUpper)) return ASSET_INDEX;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(!Sym_IsGoldName(symUpper) && !Sym_IsSilverName(symUpper) &&
      Sym_HeuristicIsIndex(bid, digits, point, tickSize))
      return ASSET_INDEX;

   if(Sym_IsCryptoName(symUpper)) return ASSET_CRYPTO;
   if(calcMode == SYMBOL_CALC_MODE_FOREX) return ASSET_FOREX;
   if((calcMode == SYMBOL_CALC_MODE_CFD || calcMode == SYMBOL_CALC_MODE_CFDLEVERAGE) &&
      bid >= 100.0 && digits <= 2 && !Sym_IsCryptoName(symUpper) &&
      !Sym_IsGoldName(symUpper) && !Sym_IsSilverName(symUpper))
      return ASSET_INDEX;

   return ASSET_OTHER;
}

ENUM_SYMBOL_ASSET SymbolAsset_Detect()
{
   long calcMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_CALC_MODE);
   return SymbolAsset_DetectFrom(Sym_Normalize(_Symbol), calcMode);
}

void SymbolAsset_Init()
{
   long calcMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_CALC_MODE);
   g_instrumentKind = SymbolCalcModeName(calcMode);
   g_symbolAsset = SymbolAsset_DetectFrom(Sym_Normalize(_Symbol), calcMode);
   g_pipSize = SymbolAsset_PipSizeFor(g_symbolAsset);
   if(g_pipSize <= 0.0)
      g_pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
}

ENUM_SYMBOL_ASSET GetSymbolAsset()
{
   if(g_pipSize <= 0.0) SymbolAsset_Init();
   return g_symbolAsset;
}

double GetPipSize()
{
   if(g_pipSize <= 0.0) SymbolAsset_Init();
   string sym = Sym_Normalize(_Symbol);
   if(Sym_IsGoldName(sym))   return GoldPipSizeUnit();
   if(Sym_IsSilverName(sym)) return SilverPipSizeUnit();
   ENUM_SYMBOL_ASSET asset = g_symbolAsset;
   if(asset == ASSET_INDEX)  return IndexPipSizeUnit();
   if(asset == ASSET_GOLD)   return GoldPipSizeUnit();
   if(asset == ASSET_SILVER) return SilverPipSizeUnit();
   return g_pipSize;
}

double SLBufferPrice()
{
   string sym = Sym_Normalize(_Symbol);
   if(Sym_IsGoldName(sym))   return InpSL_BufferPips * GoldPipSizeUnit();
   if(Sym_IsSilverName(sym)) return InpSL_BufferPips * SilverPipSizeUnit();
   ENUM_SYMBOL_ASSET asset = GetSymbolAsset();
   switch(asset)
   {
      case ASSET_INDEX:  return InpSL_BufferPips * IndexPipSizeUnit();
      case ASSET_GOLD:   return InpSL_BufferPips * GoldPipSizeUnit();
      case ASSET_SILVER: return InpSL_BufferPips * SilverPipSizeUnit();
      default:           return InpSL_BufferPips * GetPipSize();
   }
}

double MinSLDistancePrice() { return SLBufferPrice(); }

double PriceToPips(const double priceDist)
{
   double pip = GetPipSize();
   if(pip <= 0.0) return 0.0;
   return priceDist / pip;
}

void SR_EnforceMinSLDistance(const bool buy, const double entry, double &sl)
{
   double minDist = MinSLDistancePrice();
   if(minDist <= 0.0) return;
   double dist = buy ? (entry - sl) : (sl - entry);
   if(dist >= minDist - 1e-9) return;
   sl = buy ? Np(entry - minDist) : Np(entry + minDist);
   if(InpDebugLog)
      Print(StringFormat("SL widened to min buffer: entry=%.2f SL=%.2f dist=%.1f pips (%s)",
         entry, sl, PriceToPips(buy ? (entry - sl) : (sl - entry)), SymbolAsset_Label()));
}

bool SR_EntrySLMeetsBuffer(const bool buy, const double entry, const double sl)
{
   double distPips = PriceToPips(buy ? (entry - sl) : (sl - entry));
   return (distPips >= InpSL_BufferPips - 0.5);
}

double PipsToPrice(const double pips) { return pips * GetPipSize(); }

bool Sess_ScanOHLC(const string sym, const ENUM_TIMEFRAMES tf,
                   const datetime t1, const datetime t2,
                   double &o, double &h, double &l, double &c)
{
   o = 0; h = 0; l = 0; c = 0;
   if(t2 <= t1) return false;

   int total = iBars(sym, tf);
   if(total < 1) return false;

   bool found = false;
   for(int i = 0; i < total; i++)
   {
      datetime bt = iTime(sym, tf, i);
      if(bt <= 0) continue;
      if(bt >= t2) continue;
      if(bt < t1) break;

      double bh = iHigh(sym, tf, i);
      double bl = iLow(sym, tf, i);
      double bo = iOpen(sym, tf, i);
      double bc = iClose(sym, tf, i);
      if(bh <= 0.0 || bl <= 0.0) continue;

      if(!found)
      {
         o = bo;
         h = bh;
         l = bl;
         c = bc;
         found = true;
      }
      else
      {
         if(bh > h) h = bh;
         if(bl < l) l = bl;
         o = bo;
      }
   }
   return found;
}

datetime Sess_DayAnchor(const datetime refTime, const int hour, const int minute)
{
   MqlDateTime dt;
   TimeToStruct(refTime, dt);
   return StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d", dt.year, dt.mon, dt.day, hour, minute));
}

datetime Sess_AnchorOnOrBefore(const datetime refTime, const int hour, const int minute)
{
   datetime anchor = Sess_DayAnchor(refTime, hour, minute);
   if(anchor > refTime)
      anchor -= 86400;
   return anchor;
}

ENUM_PA_SESSION Sess_Current(const double brokerHour)
{
   double asiaH   = Sess_HourFrac(g_asiaH, g_asiaM);
   double londonH = Sess_HourFrac(g_londonH, g_londonM);
   double nyH     = Sess_HourFrac(g_nyH, g_nyM);

   if(asiaH < londonH)
   {
      if(brokerHour >= asiaH && brokerHour < londonH) return SESS_ASIA;
   }
   else
   {
      if(brokerHour >= asiaH || brokerHour < londonH) return SESS_ASIA;
   }

   if(londonH < nyH)
   {
      if(brokerHour >= londonH && brokerHour < nyH) return SESS_LONDON;
   }
   else
   {
      if(brokerHour >= londonH || brokerHour < nyH) return SESS_LONDON;
   }

   return SESS_NY;
}

datetime Sess_DayMidnight(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return StringToTime(StringFormat("%04d.%02d.%02d 00:00:00", dt.year, dt.mon, dt.day));
}

datetime Sess_SessionStart(const datetime cycleAsiaStart, const ENUM_PA_SESSION sess)
{
   if(sess == SESS_ASIA) return cycleAsiaStart;

   datetime day0 = Sess_DayMidnight(cycleAsiaStart);
   int asiaMins = g_asiaH * 60 + g_asiaM;
   int targetMins = 0;

   if(sess == SESS_LONDON) targetMins = g_londonH * 60 + g_londonM;
   else if(sess == SESS_NY) targetMins = g_nyH * 60 + g_nyM;
   else return 0;

   datetime t = day0 + (datetime)targetMins * 60;
   if(targetMins <= asiaMins)
      t += 86400;

   if(sess == SESS_NY)
   {
      datetime london = Sess_SessionStart(cycleAsiaStart, SESS_LONDON);
      if(t <= london)
         t += 86400;
   }

   return t;
}

bool Sess_GetCycleAnchors(const datetime now,
                          datetime &asiaStart, datetime &londonStart,
                          datetime &nyStart, datetime &nextAsiaStart)
{
   asiaStart = Sess_AnchorOnOrBefore(now, g_asiaH, g_asiaM);
   londonStart = Sess_SessionStart(asiaStart, SESS_LONDON);
   nyStart = Sess_SessionStart(asiaStart, SESS_NY);
   nextAsiaStart = asiaStart + 86400;
   return (nextAsiaStart > asiaStart && nyStart > londonStart && londonStart > asiaStart);
}

bool Sess_GetWindow(const ENUM_PA_SESSION sess, const datetime now,
                    datetime &tStart, datetime &tEnd, const bool completedOnly)
{
   datetime asiaStart, londonStart, nyStart, nextAsiaStart;
   if(!Sess_GetCycleAnchors(now, asiaStart, londonStart, nyStart, nextAsiaStart))
      return false;

   if(sess == SESS_ASIA)
   {
      tStart = asiaStart;
      tEnd = londonStart;
   }
   else if(sess == SESS_LONDON)
   {
      tStart = londonStart;
      tEnd = nyStart;
   }
   else if(sess == SESS_NY)
   {
      tStart = nyStart;
      tEnd = nextAsiaStart;
   }
   else
      return false;

   if(completedOnly && now < tEnd) return false;
   if(!completedOnly && now < tEnd) tEnd = now;
   return (tEnd > tStart);
}

bool Sess_GetCompletedSessionWindow(const ENUM_PA_SESSION sess, const datetime now,
                                    datetime &tStart, datetime &tEnd)
{
   datetime asiaStart, londonStart, nyStart, nextAsiaStart;
   if(!Sess_GetCycleAnchors(now, asiaStart, londonStart, nyStart, nextAsiaStart))
      return false;

   datetime prevAsia = asiaStart - 86400;

   if(sess == SESS_ASIA)
   {
      tStart = asiaStart;
      tEnd = londonStart;
   }
   else if(sess == SESS_LONDON)
   {
      tStart = londonStart;
      tEnd = nyStart;
   }
   else if(sess == SESS_NY)
   {
      tStart = Sess_SessionStart(prevAsia, SESS_NY);
      tEnd = asiaStart;
   }
   else
      return false;

   return (tEnd > tStart && now >= tEnd);
}

ENUM_PA_SESSION Sess_Previous(const ENUM_PA_SESSION cur)
{
   if(cur == SESS_LONDON) return SESS_ASIA;
   if(cur == SESS_NY)     return SESS_LONDON;
   if(cur == SESS_ASIA)   return SESS_NY;
   return SESS_NONE;
}

ENUM_PA_TREND Sess_DeriveTrend(const SSessionSnap &snap)
{
   if(!snap.valid || snap.range <= 0.0) return PA_TREND_NONE;
   double upper = snap.low + snap.range * 0.75;
   double lower = snap.low + snap.range * 0.25;
   if(snap.close >= upper && snap.close >= snap.open) return PA_TREND_BULL;
   if(snap.close <= lower && snap.close <= snap.open) return PA_TREND_BEAR;
   if(snap.close > snap.open + snap.range * 0.10) return PA_TREND_BULL;
   if(snap.close < snap.open - snap.range * 0.10) return PA_TREND_BEAR;
   double mid = (snap.high + snap.low) * 0.5;
   if(snap.close > mid) return PA_TREND_BULL;
   if(snap.close < mid) return PA_TREND_BEAR;
   if(snap.close > snap.open) return PA_TREND_BULL;
   if(snap.close < snap.open) return PA_TREND_BEAR;
   return PA_TREND_NONE;
}

bool Sess_BuildSnap(const ENUM_PA_SESSION sess, const datetime now, const bool completedOnly, SSessionSnap &snap)
{
   snap.sess = sess;
   snap.valid = false;
   snap.trend = PA_TREND_NONE;
   snap.open = snap.high = snap.low = snap.close = snap.range = 0.0;

   datetime t1, t2;
   bool ok = false;
   if(completedOnly)
      ok = Sess_GetCompletedSessionWindow(sess, now, t1, t2);
   else
      ok = Sess_GetWindow(sess, now, t1, t2, false);

   if(!ok) return false;
   snap.tStart = t1;
   snap.tEnd = t2;

   double o, h, l, c;
   if(!Sess_ScanOHLC(_Symbol, InpSessionTF, t1, t2, o, h, l, c)) return false;

   snap.open = o;
   snap.high = h;
   snap.low = l;
   snap.close = c;
   snap.range = h - l;
   snap.valid = (snap.range >= PipsToPrice(InpMinSessionPips));
   if(snap.valid)
      snap.trend = Sess_DeriveTrend(snap);
   return true;
}

string Sess_Name(const ENUM_PA_SESSION s)
{
   if(s == SESS_ASIA) return "Asia";
   if(s == SESS_LONDON) return "London";
   if(s == SESS_NY) return "NY";
   return "—";
}

string Phase_Name(const ENUM_PA_PHASE p)
{
   switch(p)
   {
      case PA_EXPANSION:     return "Expansion";
      case PA_RETRACEMENT:   return "Retracement";
      case PA_CONSOLIDATION: return "Consolidation";
      case PA_REVERSAL:      return "Reversal";
      default:               return "Unknown";
   }
}

string Trend_Name(const ENUM_PA_TREND t)
{
   if(t == PA_TREND_BULL) return "Bull";
   if(t == PA_TREND_BEAR) return "Bear";
   return "Neutral";
}

//+------------------------------------------------------------------+
//| Phase = f(previous session trend, current price vs prev range)   |
//+------------------------------------------------------------------+
ENUM_PA_PHASE Sess_ClassifyPhase(const SSessionSnap &prev, const SSessionSnap &cur, const double price)
{
   if(!prev.valid || !cur.valid || prev.trend == PA_TREND_NONE)
      return PA_UNKNOWN;

   const double breakDist = PipsToPrice(InpExpansionPips);
   const double prevMid = (prev.high + prev.low) * 0.5;

   bool abovePrev = (price > prev.high + breakDist);
   bool belowPrev = (price < prev.low - breakDist);
   bool insidePrev = (price <= prev.high && price >= prev.low);

   if(prev.trend == PA_TREND_BULL && belowPrev)
      return PA_REVERSAL;
   if(prev.trend == PA_TREND_BEAR && abovePrev)
      return PA_REVERSAL;

   if(prev.trend == PA_TREND_BULL && abovePrev)
   {
      double leg = cur.high - prev.high;
      if(leg <= 0.0) return PA_EXPANSION;
      double retr = (cur.high - price) / leg;
      if(retr >= InpRetrMinPct && retr <= InpRetrMaxPct && price > prev.high)
         return PA_RETRACEMENT;
      return PA_EXPANSION;
   }

   if(prev.trend == PA_TREND_BEAR && belowPrev)
   {
      double leg = prev.low - cur.low;
      if(leg <= 0.0) return PA_EXPANSION;
      double retr = (price - cur.low) / leg;
      if(retr >= InpRetrMinPct && retr <= InpRetrMaxPct && price < prev.low)
         return PA_RETRACEMENT;
      return PA_EXPANSION;
   }

   if(insidePrev)
   {
      if(cur.range <= prev.range * InpConsolRangeRatio)
         return PA_CONSOLIDATION;
      if(prev.trend == PA_TREND_BULL && price < prevMid && price >= prev.low)
         return PA_RETRACEMENT;
      if(prev.trend == PA_TREND_BEAR && price > prevMid && price <= prev.high)
         return PA_RETRACEMENT;
      return PA_CONSOLIDATION;
   }

   if(prev.trend == PA_TREND_BULL && price >= prev.low && price <= prev.high)
   {
      double leg = prev.high - prev.low;
      double retr = (prev.high - price) / leg;
      if(retr >= InpRetrMinPct && retr <= InpRetrMaxPct)
         return PA_RETRACEMENT;
      return PA_CONSOLIDATION;
   }

   if(prev.trend == PA_TREND_BEAR && price >= prev.low && price <= prev.high)
   {
      double leg = prev.high - prev.low;
      double retr = (price - prev.low) / leg;
      if(retr >= InpRetrMinPct && retr <= InpRetrMaxPct)
         return PA_RETRACEMENT;
      return PA_CONSOLIDATION;
   }

   return PA_UNKNOWN;
}

bool PA_UpdateState()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   double brokerHour = dt.hour + dt.min / 60.0;

   g_pa.curSess = Sess_Current(brokerHour);
   g_pa.prevSess = Sess_Previous(g_pa.curSess);
   g_pa.phase = PA_UNKNOWN;
   g_pa.phaseLabel = "Unknown";

   if(g_pa.curSess == SESS_NONE || g_pa.prevSess == SESS_NONE)
   {
      SetLog("Session unknown — check InpBrokerGMTOffset", true);
      return false;
   }

   if(!Sess_BuildSnap(g_pa.prevSess, TimeCurrent(), true, g_pa.prev))
   {
      SetLog(StringFormat("Prev %s session window/OHLC unavailable", Sess_Name(g_pa.prevSess)), true);
      return false;
   }
   if(!g_pa.prev.valid)
   {
      SetLog(StringFormat("Prev %s range %.1f < min %.1f pips",
         Sess_Name(g_pa.prevSess), g_pa.prev.range / GetPipSize(), InpMinSessionPips), true);
      return false;
   }

   if(!Sess_BuildSnap(g_pa.curSess, TimeCurrent(), false, g_pa.cur))
   {
      SetLog(StringFormat("Current %s session OHLC unavailable", Sess_Name(g_pa.curSess)), true);
      return false;
   }

   double price = iClose(_Symbol, InpSignalTF, 1);
   if(price <= 0.0)
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   g_pa.phase = Sess_ClassifyPhase(g_pa.prev, g_pa.cur, price);
   g_pa.phaseLabel = StringFormat("%s (prev %s %s)",
      Phase_Name(g_pa.phase),
      Sess_Name(g_pa.prevSess),
      Trend_Name(g_pa.prev.trend));
   SetLogOk(StringFormat("Phase: %s | %s trend",
      Phase_Name(g_pa.phase), Trend_Name(g_pa.prev.trend)));
   return true;
}

//+------------------------------------------------------------------+
//| Trade / risk — 1% balance, closest M15 H/L for SL, next H/L for TP |
//+------------------------------------------------------------------+
double Pt() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
double Np(const double p) { return NormalizeDouble(p, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)); }

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

double GetPipValue()
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0) return 0.0;
   return tickValue / tickSize * GetPipSize();
}

double NormalizeLots(double lotSize)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0.0) return 0.0;
   if(InpMaxLots > 0.0)
      maxLot = MathMin(maxLot, InpMaxLots);
   lotSize = MathFloor(lotSize / stepLot) * stepLot;
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   int volDigits = 2;
   if(stepLot >= 1.0) volDigits = 0;
   else if(stepLot >= 0.1) volDigits = 1;
   return NormalizeDouble(lotSize, volDigits);
}

double CalcLotSizeByTicks(const double riskDistPrice)
{
   if(riskDistPrice <= 0.0 || InpRiskPercent <= 0.0) return 0.0;
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0) return 0.0;

   double ticks = riskDistPrice / tickSize;
   if(ticks <= 0.0) return 0.0;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * InpRiskPercent / 100.0;
   return NormalizeLots(riskAmount / (ticks * tickValue));
}

double CalcLotSize(const double riskDistPrice)
{
   if(riskDistPrice <= 0.0 || InpRiskPercent <= 0.0) return 0.0;

   double lots = CalcLotSizeByTicks(riskDistPrice);
   if(lots > 0.0) return lots;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * InpRiskPercent / 100.0;
   double pipVal = GetPipValue();
   if(pipVal <= 0.0) return 0.0;
   double slPips = riskDistPrice / GetPipSize();
   if(slPips <= 0.0) return 0.0;
   return NormalizeLots(riskAmount / (slPips * pipVal));
}

bool SymbolTradable()
{
   long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   return (mode == SYMBOL_TRADE_MODE_FULL || mode == SYMBOL_TRADE_MODE_LONGONLY ||
           mode == SYMBOL_TRADE_MODE_SHORTONLY);
}

double SLBuf() { return SLBufferPrice(); }

bool SR_ClosestLowBelow(const double entry, double &lowOut)
{
   lowOut = 0.0;
   double best = -1.0;
   int last = MathMin(InpLevelLookback, iBars(_Symbol, InpLevelTF) - 1);
   for(int i = 1; i <= last; i++)
   {
      double lv = iLow(_Symbol, InpLevelTF, i);
      if(lv >= entry) continue;
      if(lv > best) best = lv;
   }
   if(best < 0.0) return false;
   lowOut = best;
   return true;
}

bool SR_ClosestHighAbove(const double entry, double &highOut)
{
   highOut = 0.0;
   double best = 1e100;
   int last = MathMin(InpLevelLookback, iBars(_Symbol, InpLevelTF) - 1);
   for(int i = 1; i <= last; i++)
   {
      double hv = iHigh(_Symbol, InpLevelTF, i);
      if(hv <= entry) continue;
      if(hv < best) best = hv;
   }
   if(best >= 1e100) return false;
   highOut = best;
   return true;
}

bool SR_SetTPFromRR(const bool buy, const double entry, const double sl, double &tp)
{
   double risk = buy ? (entry - sl) : (sl - entry);
   if(risk <= 0.0) return false;
   double rr = (InpMinRR > 0.0) ? InpMinRR : 2.0;
   tp = buy ? Np(entry + risk * rr) : Np(entry - risk * rr);
   return buy ? (tp > entry) : (tp < entry);
}

bool SR_GetStops(const bool buy, const double entry, double &sl, double &tp)
{
   sl = 0.0;
   tp = 0.0;
   double buffer = SLBufferPrice();
   double nearLow = 0.0, nearHigh = 0.0;

   if(buy)
   {
      if(!SR_ClosestLowBelow(entry, nearLow)) return false;
      sl = Np(nearLow - buffer);
      SR_EnforceMinSLDistance(true, entry, sl);
      if(sl >= entry) return false;
      if(!SR_SetTPFromRR(true, entry, sl, tp)) return false;
   }
   else
   {
      if(!SR_ClosestHighAbove(entry, nearHigh)) return false;
      sl = Np(nearHigh + buffer);
      SR_EnforceMinSLDistance(false, entry, sl);
      if(sl <= entry) return false;
      if(!SR_SetTPFromRR(false, entry, sl, tp)) return false;
   }

   if(!SR_EntrySLMeetsBuffer(buy, entry, sl))
   {
      if(InpDebugLog)
         Print(StringFormat("SL rejected: %.1f pips < buffer %.0f pips (%s)",
            PriceToPips(buy ? (entry - sl) : (sl - entry)), InpSL_BufferPips, SymbolAsset_Label()));
      return false;
   }

   if(InpDebugLog)
   {
      double riskPips = PriceToPips(buy ? (entry - sl) : (sl - entry));
      Print(StringFormat("SL calc %s: level=%.2f buffer=%.2f entry=%.2f SL=%.2f TP=%.2f risk=%.1f pips (%s)",
         buy ? "buy" : "sell",
         buy ? nearLow : nearHigh, buffer, entry, sl, tp, riskPips, SymbolAsset_Label()));
   }
   return true;
}

datetime DayStart(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}

void ResetDailyTradeCount()
{
   datetime ds = DayStart(TimeCurrent());
   if(g_entries_day != ds) { g_entries_day = ds; g_entries_today = 0; }
}

double GetAccountTodayNetPL()
{
   datetime from = DayStart(TimeCurrent());
   if(!HistorySelect(from, TimeCurrent())) return 0.0;
   double net = 0.0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(!InpAccountPLWholeAccount &&
         HistoryDealGetInteger(d, DEAL_MAGIC) != (long)InpMagic)
         continue;
      net += HistoryDealGetDouble(d, DEAL_PROFIT);
      net += HistoryDealGetDouble(d, DEAL_SWAP);
      net += HistoryDealGetDouble(d, DEAL_COMMISSION);
   }
   return net;
}

double GetTodayNetPL()
{
   datetime from = DayStart(TimeCurrent());
   if(!HistorySelect(from, TimeCurrent())) return 0.0;
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
   return net;
}

double AccountDailyProfitTarget()
{
   if(InpMaxDailyProfitPct <= 0.0) return 0.0;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0) return 0.0;
   return balance * InpMaxDailyProfitPct / 100.0;
}

//+------------------------------------------------------------------+
double AccountDailyLossLimit()
{
   if(InpMaxDailyLossPct <= 0.0) return 0.0;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0) return 0.0;
   return balance * InpMaxDailyLossPct / 100.0;
}

//+------------------------------------------------------------------+
bool DailyLossLimitHit()
{
   double limit = AccountDailyLossLimit();
   if(limit <= 0.0) return false;
   return (GetAccountTodayNetPL() <= -limit);
}

//+------------------------------------------------------------------+
bool DailyProfitTargetHit()
{
   double target = AccountDailyProfitTarget();
   if(target <= 0.0) return false;
   return (GetAccountTodayNetPL() >= target);
}

bool SpreadOK()
{
   if(InpMaxSpread <= 0) return true;
   return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpread;
}

bool CooldownOK() { return TimeCurrent() >= g_cooldown_until; }

bool EntrySpacingOK()
{
   if(InpMaxTradesPerDay > 0 && g_entries_today >= InpMaxTradesPerDay) return false;
   return true;
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

bool NewSignalBar()
{
   static datetime last = 0;
   datetime t = iTime(_Symbol, InpSignalTF, 0);
   if(t == 0 || t == last) return false;
   last = t;
   return true;
}

bool StopsOK(const bool buy, const double sl, const double tp)
{
   long lv = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double d = (lv > 0) ? (double)lv * Pt() : MathMax(Pt() * 10.0, GetPipSize() * 0.5);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(buy)
   {
      if(sl > 0.0 && (ask - sl) < d) return false;
      if(tp > 0.0 && (tp - ask) < d) return false;
      if(tp > 0.0 && tp <= ask) return false;
   }
   else
   {
      if(sl > 0.0 && (sl - bid) < d) return false;
      if(tp > 0.0 && (bid - tp) < d) return false;
      if(tp > 0.0 && tp >= bid) return false;
   }
   return true;
}

bool EntryRiskOK(const bool buy, const double sl)
{
   double entry = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double distPrice = MathAbs(entry - sl);
   double minDist = MinSLDistancePrice();
   if(InpMinRiskPoints > 0)
   {
      double minByPoints = (double)InpMinRiskPoints * Pt();
      if(minByPoints > minDist) minDist = minByPoints;
   }
   if(minDist > 0.0 && distPrice + 1e-9 < minDist)
      return false;
   return true;
}

bool RewardRiskOK(const bool buy, const double entry, const double sl, const double tp)
{
   if(InpMinRR <= 0.0 || tp <= 0.0) return true;
   double risk = buy ? (entry - sl) : (sl - entry);
   double reward = buy ? (tp - entry) : (entry - tp);
   if(risk <= 0.0 || reward <= 0.0) return false;
   return (reward / risk >= InpMinRR - 1e-9);
}

bool OpenBuy(const double sl, const double tp, const string tag)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(!EntryRiskOK(true, sl))
   {
      SetLog(StringFormat("Buy blocked: SL %.1f pips from entry (min %.1f pips)",
         MathAbs(ask - sl) / GetPipSize(), InpSL_BufferPips), true);
      return false;
   }
   if(!RewardRiskOK(true, ask, sl, tp))
   {
      SetLogOk(StringFormat("Buy skipped: TP/SL RR below %.2f", InpMinRR));
      return false;
   }
   if(!StopsOK(true, sl, tp))
   {
      SetLog("Buy blocked: broker stop level too close", true);
      return false;
   }
   double lots = CalcLotSize(ask - sl);
   if(lots <= 0.0)
   {
      SetLog("Buy blocked: lot size calc failed (check risk %)", true);
      return false;
   }
   if(!g_trade.Buy(lots, _Symbol, ask, Np(sl), Np(tp), InpComment + "_" + tag))
   {
      SetLog(StringFormat("Buy order failed: %s", g_trade.ResultRetcodeDescription()), true);
      return false;
   }
   RecordEntrySuccess();
   SetLogOk(StringFormat("Buy placed (%s) lots=%.2f SL=%.2f TP=%.2f risk=%.1f pips",
      tag, lots, sl, tp, MathAbs(ask - sl) / GetPipSize()));
   return true;
}

bool OpenSell(const double sl, const double tp, const string tag)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(!EntryRiskOK(false, sl))
   {
      SetLog(StringFormat("Sell blocked: SL %.1f pips from entry (min %.1f pips)",
         MathAbs(sl - bid) / GetPipSize(), InpSL_BufferPips), true);
      return false;
   }
   if(!RewardRiskOK(false, bid, sl, tp))
   {
      SetLogOk(StringFormat("Sell skipped: TP/SL RR below %.2f", InpMinRR));
      return false;
   }
   if(!StopsOK(false, sl, tp))
   {
      SetLog("Sell blocked: broker stop level too close", true);
      return false;
   }
   double lots = CalcLotSize(sl - bid);
   if(lots <= 0.0)
   {
      SetLog("Sell blocked: lot size calc failed (check risk %)", true);
      return false;
   }
   if(!g_trade.Sell(lots, _Symbol, bid, Np(sl), Np(tp), InpComment + "_" + tag))
   {
      SetLog(StringFormat("Sell order failed: %s", g_trade.ResultRetcodeDescription()), true);
      return false;
   }
   RecordEntrySuccess();
   SetLogOk(StringFormat("Sell placed (%s) lots=%.2f SL=%.2f TP=%.2f risk=%.1f pips",
      tag, lots, sl, tp, MathAbs(sl - bid) / GetPipSize()));
   return true;
}

bool ExecuteTrade(const bool buy, const string tag, const bool fvgEntry, const bool breakoutVolume)
{
   if(!SymbolAllowed())
   {
      SetLog(StringFormat("Trade blocked: %s not in allowed symbol list", _Symbol), true);
      return false;
   }
   if(!SymbolTradable())
   {
      SetLog("Trade blocked: symbol not tradable (check market hours / contract)", true);
      return false;
   }
   if(!SessionStateOK())
   {
      SetLog("Trade blocked: session OHLC/phase unavailable", true);
      return false;
   }
   if(!g_pa.prev.valid || g_pa.prev.trend == PA_TREND_NONE)
   {
      SetLog("Trade blocked: invalid previous session trend", true);
      return false;
   }
   if(!Phase_AllowsTrade(buy, fvgEntry))
   {
      SetLogOk(StringFormat("%s skipped — phase filter", buy ? "Buy" : "Sell"));
      return false;
   }

   datetime sigBar = iTime(_Symbol, InpSignalTF, 1);
   if(!PassesBreakoutVolume(buy, sigBar, breakoutVolume))
   {
      SetLogOk(StringFormat("%s skipped — volume filter (breakout confirm)", buy ? "Buy" : "Sell"));
      return false;
   }

   double entry = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0.0, tp = 0.0;
   if(!SR_GetStops(buy, entry, sl, tp))
   {
      SetLogOk("Trade skipped: nearest M15 SL level not found");
      return false;
   }
   return buy ? OpenBuy(sl, tp, tag) : OpenSell(sl, tp, tag);
}

bool TryExpansionTrade()
{
   if(!InpTradeExpansion || g_pa.phase != PA_EXPANSION) return false;

   if(g_pa.prev.trend == PA_TREND_BULL)
   {
      if(!PA_BullConfirm(InpSignalTF)) return false;
      return ExecuteTrade(true, "EXP");
   }
   if(g_pa.prev.trend == PA_TREND_BEAR)
   {
      if(!PA_BearConfirm(InpSignalTF)) return false;
      return ExecuteTrade(false, "EXP");
   }
   return false;
}

bool TryReversalTrade()
{
   if(!InpTradeReversal || g_pa.phase != PA_REVERSAL) return false;
   SSessionSnap prev = g_pa.prev;
   double c1 = iClose(_Symbol, InpSignalTF, 1);

   if(prev.trend == PA_TREND_BULL && c1 < prev.low)
   {
      if(!PA_BearConfirm(InpSignalTF)) return false;
      return ExecuteTrade(false, "REV");
   }
   if(prev.trend == PA_TREND_BEAR && c1 > prev.high)
   {
      if(!PA_BullConfirm(InpSignalTF)) return false;
      return ExecuteTrade(true, "REV");
   }
   return false;
}

void LogEntryBlockers()
{
   if(!SymbolAllowed())
   {
      SetLog(StringFormat("Blocked: %s not in allowed symbol list", _Symbol), true);
      return;
   }
   if(!SessionStateOK())
   {
      SetLog("Blocked: session OHLC/phase unavailable", true);
      return;
   }
   if(!SymbolTradable())
   {
      SetLog("Blocked: symbol not tradable (futures contract may be closed or expired)", true);
      return;
   }
   if(!SpreadOK())
   {
      SetLog(StringFormat("Blocked: spread %d > max %d",
         (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), InpMaxSpread), true);
      return;
   }
   if(DailyLossLimitHit())
   {
      SetLog(StringFormat("Blocked: account daily loss limit (%.1f%%, P/L %.2f)",
         InpMaxDailyLossPct, GetAccountTodayNetPL()), true);
      return;
   }
   if(DailyProfitTargetHit())
   {
      SetLog(StringFormat("Blocked: account daily profit target (%.1f%%, P/L %.2f)",
         InpMaxDailyProfitPct, GetAccountTodayNetPL()), true);
      return;
   }
   if(!CooldownOK())
   {
      SetLog("Blocked: entry cooldown active", true);
      return;
   }
   if(!EntrySpacingOK())
   {
      SetLog(StringFormat("Blocked: max trades/day reached (%d)", InpMaxTradesPerDay), true);
      return;
   }
   if(CountOurPositions() > 0)
   {
      SetLogOk("Position open — waiting");
      return;
   }
   if(g_pa.prev.trend == PA_TREND_NONE)
   {
      SetLogOk("Prev session neutral — no trend bias");
      return;
   }
   SetLogOk("Ready — scanning entries");
}

void DeleteDashboard()
{
   long chartId = ChartID();
   ObjectsDeleteAll(chartId, g_dashPrefix);
}

void UpdateDashboard()
{
   long chartId = ChartID();

   if(!InpShowDashboard)
   {
      DeleteDashboard();
      return;
   }

   string lines[];
   ArrayResize(lines, 14);
   lines[0] = "PA Session Phases EA v3.40 | Zeke Trading";
   lines[1] = StringFormat("%s (%s) | Session: %s",
      _Symbol, SymbolAsset_Label(), Sess_Name(g_pa.curSess));
   lines[2] = StringFormat("Prev: %s  Trend: %s", Sess_Name(g_pa.prevSess), Trend_Name(g_pa.prev.trend));
   lines[3] = StringFormat("Phase: %s", Phase_Name(g_pa.phase));
   lines[4] = Phase_EntryHint();
   lines[5] = StringFormat("Prev H/L: %.2f / %.2f", g_pa.prev.high, g_pa.prev.low);
   lines[6] = StringFormat("Cur H/L: %.2f / %.2f", g_pa.cur.high, g_pa.cur.low);
   lines[7] = StringFormat("FVG: %s", g_fvgAgent.status);
   lines[8] = StringFormat("S/R: %s", g_srAgent.status);
   lines[9] = StringFormat("H4 react: %s  M15 react: %s",
      FVG_ReactName(g_fvgAgent.h4React), FVG_ReactName(g_fvgAgent.m15React));
   lines[10] = StringFormat("Risk: %.2f%% | pip=%.2f | SL buf=%.0f pips (%.2f pts)",
      InpRiskPercent, GetPipSize(), InpSL_BufferPips, SLBufferPrice());
   lines[11] = StringFormat("Acct P/L: %.2f | Target: +%.1f%% / -%.1f%% (%s)",
      GetAccountTodayNetPL(), InpMaxDailyProfitPct, InpMaxDailyLossPct,
      InpAccountPLWholeAccount ? "whole account" : "EA magic");
   lines[12] = StringFormat("Trades today: %d", g_entries_today);
   lines[13] = (g_logIsError ? "ERROR: " : "Status: ") + g_logMsg;

   const int lineH = InpDashFontSize + 6;
   const int padSide = 12;
   const int padTop  = 8;
   const int padBot  = 8;
   int boxW = 420;
   int boxH = padTop + ArraySize(lines) * lineH + padBot;

   string bg = g_dashPrefix + "BG";
   if(ObjectFind(chartId, bg) < 0)
   {
      ObjectCreate(chartId, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(chartId, bg, OBJPROP_CORNER, InpDashCorner);
      ObjectSetInteger(chartId, bg, OBJPROP_BGCOLOR, C'20,20,30');
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
      else if(i == 3) rowClr = clrGold;
      else if(i == 4) rowClr = clrSilver;
      else if(i == 13) rowClr = g_logIsError ? clrTomato : clrLime;
      ObjectSetInteger(chartId, name, OBJPROP_COLOR, rowClr);
   }

   for(int j = ArraySize(lines); j < 16; j++)
   {
      string unused = g_dashPrefix + "L" + IntegerToString(j);
      if(ObjectFind(chartId, unused) >= 0)
         ObjectSetString(chartId, unused, OBJPROP_TEXT, "");
   }

   ChartRedraw(chartId);
}

//+------------------------------------------------------------------+
int OnInit()
{
   Sess_CSTToBroker(InpAsiaOpenCST,   InpBrokerGMTOffset, g_asiaH,   g_asiaM);
   Sess_CSTToBroker(InpLondonOpenCST, InpBrokerGMTOffset, g_londonH, g_londonM);
   Sess_CSTToBroker(InpNYOpenCST,     InpBrokerGMTOffset, g_nyH,     g_nyM);

   SymbolAsset_Init();

   if(!SymbolAllowed())
      Print("PA Phases WARNING: ", _Symbol, " is not in InpAllowedSymbols — no trades will be placed.");

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints((uint)InpSlippage);
   SetFilling();

   Print("PA Session Phases EA v3.40 | Zeke Trading | ", _Symbol,
         " | ", SymbolAsset_Label(),
         " | Risk ", InpRiskPercent, "% | MaxLots ", InpMaxLots,
         " | FVG ", (InpUseFVGAgent ? "on" : "off"),
         " | SR H1=", (InpUseSR_H1 ? "on" : "off"),
         " H4=", (InpUseSR_H4 ? "on" : "off"),
         " | Whitelist ", (InpUseSymbolWhitelist ? "on" : "off"),
         " | pip=", DoubleToString(GetPipSize(), 4),
         " | SL buffer=", DoubleToString(SLBufferPrice(), _Digits),
         " (", DoubleToString(InpSL_BufferPips, 1), " pips)",
         " | VolFilter ", (InpUseVolumeFilter ? "on" : "off"),
         " | TP=", InpMinRR, "R");

   datetime asiaStart, londonStart, nyStart, nextAsiaStart;
   if(!Sess_GetCycleAnchors(TimeCurrent(), asiaStart, londonStart, nyStart, nextAsiaStart))
   {
      SetLog("Invalid session time configuration (check CST session inputs)", true);
      Print("PA Phases EA: invalid session time configuration.");
      return INIT_PARAMETERS_INCORRECT;
   }

   FVG_ScanTF(PERIOD_H4, InpFVG_H4_Lookback, g_fvgH4, g_fvgH4Count);
   FVG_ScanTF(PERIOD_M15, InpFVG_M15_Lookback, g_fvgM15, g_fvgM15Count);
   g_fvgLastH4 = iTime(_Symbol, PERIOD_H4, 0);
   g_fvgLastM15 = iTime(_Symbol, PERIOD_M15, 0);
   if(InpUseSR_H1)
   {
      SR_ScanTF(PERIOD_H1, InpSR_H1_Lookback, g_srH1, g_srH1Count);
      g_srLastH1 = iTime(_Symbol, PERIOD_H1, 0);
   }
   if(InpUseSR_H4)
   {
      SR_ScanTF(PERIOD_H4, InpSR_H4_Lookback, g_srH4, g_srH4Count);
      g_srLastH4 = iTime(_Symbol, PERIOD_H4, 0);
   }

   PA_UpdateState();
   FVG_AgentUpdate();
   SR_AgentUpdate();
   if(!g_logIsError) SetLogOk("EA initialized");
   UpdateDashboard();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { DeleteDashboard(); }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.symbol != _Symbol) return;
   ulong deal = trans.deal;
   if(deal == 0) return;
   if(HistoryDealGetInteger(deal, DEAL_MAGIC) != (long)InpMagic) return;
   if(HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
      RecordEntrySuccess();
}

void OnTick()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day != g_lastDay) g_lastDay = dt.day;

   PA_UpdateState();
   FVG_AgentUpdate();
   SR_AgentUpdate();
   UpdateDashboard();

   if(!SymbolAllowed())
   {
      SetLog(StringFormat("Blocked: %s not in allowed symbol list", _Symbol), true);
      UpdateDashboard();
      return;
   }

   if(g_logIsError) return;

   if(!NewSignalBar()) return;
   ResetDailyTradeCount();
   if(!SessionStateOK())
   {
      SetLog("Blocked: session OHLC/phase unavailable", true);
      return;
   }
   LogEntryBlockers();
   if(g_logIsError) return;
   if(CountOurPositions() > 0) return;

   if(InpUseFVGAgent && TryFVGTrade()) return;
   if((InpUseSR_H1 || InpUseSR_H4) && TrySRTrade()) return;

   if(!InpTradePhaseEntries)
   {
      if(!InpUseFVGAgent && !InpUseSR_H1 && !InpUseSR_H4)
         SetLogOk("No entry — FVG, S/R and phase entries disabled");
      return;
   }
   if(!Phase_IsTradable())
   {
      SetLogOk(StringFormat("Phase %s — no entry", Phase_Name(g_pa.phase)));
      return;
   }

   if(TryReversalTrade()) return;
   TryExpansionTrade();
}

//+------------------------------------------------------------------+

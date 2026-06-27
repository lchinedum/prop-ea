//+------------------------------------------------------------------+
//| Zeke_Trading_BSE.mq5                                             |
//| Zeke Trading — Bias → Sweep → Entry (BSE)                        |
//| Prev session H/L (M5) | SessionSweepLG confirm | optional M15 FVG | 3R
//+------------------------------------------------------------------+
#property copyright "Zeke Trading"
#property version   "1.07"
#property strict

#include <Trade\Trade.mqh>

//--- General
input group "=== General ==="
input ulong    InpMagic           = 20260527;
input string   InpComment         = "ZekeBSE";
input int      InpSlippage        = 30;
input int      InpMaxSpread       = 0;          // 0 = off

//--- Timeframes
input group "=== BSE timeframes ==="
input ENUM_TIMEFRAMES InpSweepTF   = PERIOD_M5;   // session H/L + sweep (matches SessionSweepLG chart TF)
input ENUM_TIMEFRAMES InpEntryTF   = PERIOD_M15; // optional FVG entry TF

//--- Sessions (broker server hours — same as SessionSweepLG v1.03)
input group "=== Sessions (broker server hours) ==="
input int      InpAsiaStartHour    = 2;
input int      InpAsiaEndHour      = 10;
input int      InpLondonStartHour  = 10;
input int      InpLondonEndHour    = 18;
input int      InpNewYorkStartHour = 15;
input int      InpNewYorkEndHour   = 22;

//--- SessionSweepLG sweep / confirm logic
input group "=== Sweep & confirm (SessionSweepLG) ==="
input int      InpConfirmCloses    = 2;         // consecutive closes to confirm (indicator default)
input bool     InpTradeReversal    = true;      // REV: high sweep + closes inside = sell; low sweep + inside = buy
input bool     InpTradeContinuation = true;     // CONT: high sweep + closes outside = buy; low + outside = sell
input int      InpSweepValidBars   = 12;        // setup expires after N entry-TF bars
input bool     InpOneSweepPerSession = true;

//--- FVG entry (optional filter after confirm)
input group "=== FVG entry ==="
input bool     InpRequireFVGEntry  = false;     // false = enter on confirm bar; true = wait M15 FVG
input double   InpFVG_MinPips      = 3.0;
input double   InpFVG_ProxPips     = 5.0;

//--- Risk
input group "=== Risk ==="
input double   InpRiskPercent      = 1.0;
input double   InpTargetRR         = 3.0;
input double   InpSL_BufferPipsGold  = 25.0;    // SL buffer beyond sweep (gold)
input double   InpSL_BufferPipsIndex = 20.0;    // SL buffer beyond sweep (indices)
input double   InpSL_BufferPipsOther = 15.0;    // SL buffer (forex/other)
input double   InpMinSLPipsGold      = 20.0;    // min entry→SL distance (gold)
input double   InpMinSLPipsIndex     = 15.0;    // min entry→SL (US100 etc = points)
input double   InpMinSLPipsOther     = 10.0;
input double   InpSpreadSLMult       = 3.0;     // min SL >= spread × this
input double   InpSmallSweepMaxPips  = 10.0;    // sweep wick depth below this = "small"
input double   InpSmallSweepBufferPips = 30.0;  // SL beyond extreme when small (pips/points)
input double   InpMaxSLPips          = 0.0;     // 0 = off
input double   InpMaxLots            = 5.0;
input int      InpMaxTradesPerDay    = 3;
input int      InpCooldownSec        = 300;

//--- Dashboard
input group "=== Dashboard ==="
input bool     InpShowDashboard    = true;
input int      InpDashCorner       = 0;
input int      InpDashX            = 10;
input int      InpDashY            = 20;
input int      InpDashFontSize     = 9;

enum ENUM_BSE_SESSION
{
   SESS_NONE   = 0,
   SESS_ASIA   = 1,
   SESS_LONDON = 2,
   SESS_NY     = 3
};

enum ENUM_BSE_BIAS
{
   BSE_NONE = 0,
   BSE_BULL = 1,
   BSE_BEAR = -1
};

enum ENUM_SYMBOL_ASSET
{
   ASSET_FOREX  = 0,
   ASSET_GOLD   = 1,
   ASSET_INDEX  = 2,
   ASSET_OTHER  = 3
};

enum ENUM_BSE_CONFIRM
{
   CONF_NONE = 0,
   CONF_REVERSAL = 1,
   CONF_CONTINUATION = 2
};

struct SSweepSetup
{
   bool              valid;
   ENUM_BSE_BIAS     dir;
   ENUM_BSE_CONFIRM  confirm;
   double            pivotLevel;
   double            extreme;
   datetime          sweepBarTime;
   datetime          expiresAt;
   string            sweptSide;
};

struct SFVGZone
{
   bool              valid;
   int               dir;
   double            top;
   double            bottom;
   datetime          barTime;
};

struct SBSEState
{
   ENUM_BSE_BIAS     bias;
   double            prevHigh;
   double            prevLow;
   SSweepSetup       sweep;
   SFVGZone          entryFVG;
   string            status;
};

CTrade         g_trade;
SBSEState      g_bse;
datetime       g_cooldown_until = 0;
int            g_entries_today = 0;
int            g_lastDay = -1;
datetime       g_lastSignalBar = 0;
string         g_dashPrefix = "ZekeBSE_";
string         g_logMsg = "Initializing";
bool           g_logIsError = false;
double         g_pipSize = 0.0;
ENUM_SYMBOL_ASSET g_symbolAsset = ASSET_OTHER;
datetime       g_sweepLockSessionStart = 0;

// SessionSweepLG state (matches SessionSweepLiquidityGrab.mq5)
int            g_sslgCurSession = 0;
int            g_sslgPrevSession = 0;
double         g_sslgBuildHigh = 0.0;
double         g_sslgBuildLow = 0.0;
bool           g_sslgBuildInit = false;
double         g_sslgPrevHigh = 0.0;
double         g_sslgPrevLow = 0.0;
bool           g_sslgPrevReady = false;
bool           g_sslgHighSwept = false;
bool           g_sslgLowSwept = false;
int            g_sslgHighInside = 0;
int            g_sslgHighOutside = 0;
int            g_sslgLowInside = 0;
int            g_sslgLowOutside = 0;
double         g_sslgHighExtreme = 0.0;
double         g_sslgLowExtreme = 0.0;
datetime       g_sslgLastBar = 0;
bool           g_sslgHistoryBuilt = false;
string         g_sslgConfirmStr = "waiting";

//+------------------------------------------------------------------+
double Pt() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }

bool Sym_HasKey(const string symUpper, const string key)
{
   return (StringFind(symUpper, key) >= 0);
}

bool Sym_IsGoldName(const string symUpper)
{
   return Sym_HasKey(symUpper, "XAU") || Sym_HasKey(symUpper, "GOLD");
}

bool Sym_IsIndexName(const string symUpper)
{
   static const string keys[] =
   {
      "US30", "US500", "US100", "US2000", "USTEC", "USTECH", "NAS100", "NASDAQ",
      "NDX", "NQ100", "UK100", "GER40", "DE40", "DAX", "JP225", "NI225", "NIKKEI",
      "AUS200", "HK50", "US100.CASH", "US100CASH"
   };
   for(int i = 0; i < ArraySize(keys); i++)
      if(StringFind(symUpper, keys[i]) >= 0) return true;
   return false;
}

ENUM_SYMBOL_ASSET DetectSymbolAsset()
{
   string sym = _Symbol;
   StringToUpper(sym);
   if(Sym_IsGoldName(sym)) return ASSET_GOLD;
   if(Sym_IsIndexName(sym)) return ASSET_INDEX;

   long calcMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_CALC_MODE);
   if(calcMode == SYMBOL_CALC_MODE_CFDINDEX) return ASSET_INDEX;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = Pt();
   if(bid >= 100.0 && digits <= 2 && !Sym_IsGoldName(sym)) return ASSET_INDEX;
   if(calcMode == SYMBOL_CALC_MODE_FOREX) return ASSET_FOREX;
   return ASSET_OTHER;
}

double GoldPipSizeUnit()
{
   double point = Pt();
   double tick  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0) tick = point;
   if(tick >= 0.1) return tick;
   if(tick >= 0.01) return 0.1;
   return MathMax(0.1, point * 10.0);
}

void SymbolAsset_Init()
{
   g_symbolAsset = DetectSymbolAsset();
   switch(g_symbolAsset)
   {
      case ASSET_GOLD:  g_pipSize = GoldPipSizeUnit(); break;
      case ASSET_INDEX: g_pipSize = 1.0; break;
      default:
      {
         int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
         double point = Pt();
         if(StringFind(_Symbol, "JPY") >= 0 || digits == 3 || digits == 5)
            g_pipSize = point * 10.0;
         else
            g_pipSize = point;
         break;
      }
   }
}

double GetPipSize()
{
   if(g_pipSize <= 0.0) SymbolAsset_Init();
   return g_pipSize;
}

string AssetLabel()
{
   switch(g_symbolAsset)
   {
      case ASSET_GOLD:  return "Gold";
      case ASSET_INDEX: return "Index";
      case ASSET_FOREX: return "Forex";
      default:          return "Other";
   }
}

double SLBufferPips()
{
   switch(g_symbolAsset)
   {
      case ASSET_GOLD:  return InpSL_BufferPipsGold;
      case ASSET_INDEX: return InpSL_BufferPipsIndex;
      default:          return InpSL_BufferPipsOther;
   }
}

double MinSLPips()
{
   switch(g_symbolAsset)
   {
      case ASSET_GOLD:  return InpMinSLPipsGold;
      case ASSET_INDEX: return InpMinSLPipsIndex;
      default:          return InpMinSLPipsOther;
   }
}

double PipsToPrice(const double pips) { return pips * GetPipSize(); }
double PriceToPips(const double dist) { return (GetPipSize() > 0.0) ? dist / GetPipSize() : 0.0; }

double SLBufferPrice() { return PipsToPrice(SLBufferPips()); }

double SweepWickDepthPips()
{
   if(!g_bse.sweep.valid) return 0.0;
   if(g_bse.sweep.dir == BSE_BULL)
      return PriceToPips(g_bse.sweep.pivotLevel - g_bse.sweep.extreme);
   return PriceToPips(g_bse.sweep.extreme - g_bse.sweep.pivotLevel);
}

double SLBufferForSweep()
{
   if(InpSmallSweepMaxPips > 0.0 && SweepWickDepthPips() < InpSmallSweepMaxPips)
      return PipsToPrice(InpSmallSweepBufferPips);
   return SLBufferPrice();
}

double MinSLDistancePrice()
{
   double minDist = PipsToPrice(MinSLPips());
   if(InpSpreadSLMult > 0.0)
   {
      double spreadMin = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * Pt() * InpSpreadSLMult;
      if(spreadMin > minDist) minDist = spreadMin;
   }
   return minDist;
}

double Np(const double p) { return NormalizeDouble(p, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)); }

void SetLog(const string msg, const bool isError = false)
{
   g_logMsg = msg;
   g_logIsError = isError;
}

void SetLogOk(const string msg) { SetLog(msg, false); }

datetime DayStart(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return StringToTime(StringFormat("%04d.%02d.%02d 00:00:00", dt.year, dt.mon, dt.day));
}

void ResetDailyTradeCount()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day != g_lastDay)
   {
      g_lastDay = dt.day;
      g_entries_today = 0;
   }
}

void RecordEntrySuccess()
{
   g_entries_today++;
   g_cooldown_until = TimeCurrent() + InpCooldownSec;
   ENUM_TIMEFRAMES sigTf = InpRequireFVGEntry ? InpEntryTF : InpSweepTF;
   g_lastSignalBar = iTime(_Symbol, sigTf, 1);
}

bool SpreadOK()
{
   if(InpMaxSpread <= 0) return true;
   return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpread;
}

bool CooldownOK() { return TimeCurrent() >= g_cooldown_until; }

bool EntrySpacingOK()
{
   if(InpMaxTradesPerDay <= 0) return true;
   return g_entries_today < InpMaxTradesPerDay;
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

bool NewBarOnTF(const ENUM_TIMEFRAMES tf)
{
   datetime t = iTime(_Symbol, tf, 1);
   if(t <= 0) return false;
   static datetime lastSweep = 0;
   static datetime lastEntry = 0;
   if(tf == InpSweepTF)
   {
      if(t == lastSweep) return false;
      lastSweep = t;
      return true;
   }
   if(t == lastEntry) return false;
   lastEntry = t;
   return true;
}

bool NewSignalBar()
{
   if(InpRequireFVGEntry) return NewBarOnTF(InpEntryTF);
   return NewBarOnTF(InpSweepTF);
}

//+------------------------------------------------------------------+
//| SessionSweepLG engine (matches SessionSweepLiquidityGrab.mq5)     |
//+------------------------------------------------------------------+
string SSLG_SessionName(const int id)
{
   if(id == SESS_ASIA)   return "Asia";
   if(id == SESS_LONDON) return "London";
   if(id == SESS_NY)     return "NewYork";
   return "Off";
}

int SSLG_SessionIdFromHour(const int h)
{
   if(h >= InpAsiaStartHour && h < InpAsiaEndHour) return SESS_ASIA;
   if(h >= InpNewYorkStartHour && h < InpNewYorkEndHour) return SESS_NY;
   if(h >= InpLondonStartHour && h < InpLondonEndHour) return SESS_LONDON;
   return 0;
}

void SSLG_ResetConfirmState()
{
   g_sslgHighSwept = false;
   g_sslgLowSwept = false;
   g_sslgHighInside = 0;
   g_sslgHighOutside = 0;
   g_sslgLowInside = 0;
   g_sslgLowOutside = 0;
   g_sslgHighExtreme = 0.0;
   g_sslgLowExtreme = 0.0;
   g_sslgConfirmStr = "waiting";
}

void BSE_LockSweepForSession()
{
   if(!InpOneSweepPerSession || g_sslgCurSession <= 0) return;
   g_sweepLockSessionStart = (datetime)g_sslgCurSession;
}

bool BSE_SessionSweepLocked()
{
   if(!InpOneSweepPerSession || g_sslgCurSession <= 0) return false;
   return (g_sweepLockSessionStart > 0 && g_sweepLockSessionStart == (datetime)g_sslgCurSession);
}

string BSE_ConfirmLabel(const ENUM_BSE_CONFIRM c)
{
   if(c == CONF_REVERSAL) return "REV";
   if(c == CONF_CONTINUATION) return "CONT";
   return "-";
}

void SSLG_ResetAllState()
{
   g_sslgLastBar = 0;
   g_sslgHistoryBuilt = false;
   g_sslgCurSession = 0;
   g_sslgPrevSession = 0;
   g_sslgBuildHigh = 0.0;
   g_sslgBuildLow = 0.0;
   g_sslgBuildInit = false;
   g_sslgPrevHigh = 0.0;
   g_sslgPrevLow = 0.0;
   g_sslgPrevReady = false;
   SSLG_ResetConfirmState();
}

void SSLG_HandleNewSession(const int newSessionId, const double barHigh, const double barLow)
{
   g_sslgPrevSession = g_sslgCurSession;
   if(g_sslgBuildInit)
   {
      g_sslgPrevHigh = g_sslgBuildHigh;
      g_sslgPrevLow = g_sslgBuildLow;
      g_sslgPrevReady = (g_sslgPrevHigh > 0.0 && g_sslgPrevLow > 0.0 && g_sslgPrevHigh >= g_sslgPrevLow);
   }
   g_sslgCurSession = newSessionId;
   g_sslgBuildHigh = barHigh;
   g_sslgBuildLow = barLow;
   g_sslgBuildInit = true;
   SSLG_ResetConfirmState();
   g_sweepLockSessionStart = 0;
}

void BSE_ArmSetup(const ENUM_BSE_BIAS dir, const ENUM_BSE_CONFIRM confirm,
                  const double level, const double extreme, const datetime barTime,
                  const string side, const string tag)
{
   g_bse.sweep.valid = true;
   g_bse.sweep.dir = dir;
   g_bse.sweep.confirm = confirm;
   g_bse.sweep.pivotLevel = level;
   g_bse.sweep.extreme = extreme;
   g_bse.sweep.sweepBarTime = barTime;
   g_bse.sweep.sweptSide = side;
   g_bse.bias = dir;
   g_bse.entryFVG.valid = false;
   int entrySec = PeriodSeconds(InpRequireFVGEntry ? InpEntryTF : InpSweepTF);
   g_bse.sweep.expiresAt = barTime + entrySec * InpSweepValidBars;
   g_bse.prevHigh = g_sslgPrevHigh;
   g_bse.prevLow = g_sslgPrevLow;
   BSE_LockSweepForSession();
   g_bse.status = StringFormat("%s %s @ %.2f — %s",
      tag, side, level, InpRequireFVGEntry ? "wait FVG" : "ready entry");
}

void SSLG_ProcessClosedBar(const datetime t, const double h, const double l, const double c)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   int sid = SSLG_SessionIdFromHour(dt.hour);
   if(sid == 0) return;

   if(g_sslgCurSession == 0 || sid != g_sslgCurSession)
      SSLG_HandleNewSession(sid, h, l);
   else
   {
      g_sslgBuildHigh = MathMax(g_sslgBuildHigh, h);
      g_sslgBuildLow = MathMin(g_sslgBuildLow, l);
   }

   g_bse.prevHigh = g_sslgPrevHigh;
   g_bse.prevLow = g_sslgPrevLow;

   if(!g_sslgPrevReady || g_sslgCurSession == g_sslgPrevSession)
   {
      g_bse.status = StringFormat("%s | Prev %s not ready",
         SSLG_SessionName(g_sslgCurSession), SSLG_SessionName(g_sslgPrevSession));
      return;
   }

   if(BSE_SessionSweepLocked() && !g_bse.sweep.valid)
   {
      g_bse.status = "Sweep used this session — wait next session";
      return;
   }

   bool highSweepBar = false;
   bool lowSweepBar = false;

   if(!g_sslgHighSwept && h > g_sslgPrevHigh)
   {
      g_sslgHighSwept = true;
      g_sslgHighExtreme = h;
      highSweepBar = true;
   }
   else if(g_sslgHighSwept && h > g_sslgHighExtreme)
      g_sslgHighExtreme = h;

   if(!g_sslgLowSwept && l < g_sslgPrevLow)
   {
      g_sslgLowSwept = true;
      g_sslgLowExtreme = l;
      lowSweepBar = true;
   }
   else if(g_sslgLowSwept && l < g_sslgLowExtreme)
      g_sslgLowExtreme = l;

   bool highRev = false, highCont = false, lowRev = false, lowCont = false;

   if(g_sslgHighSwept)
   {
      if(c < g_sslgPrevHigh)
      {
         g_sslgHighInside++;
         g_sslgHighOutside = 0;
      }
      else if(c > g_sslgPrevHigh)
      {
         g_sslgHighOutside++;
         g_sslgHighInside = 0;
      }
      else
      {
         g_sslgHighInside = 0;
         g_sslgHighOutside = 0;
      }
      if(InpTradeReversal && g_sslgHighInside >= InpConfirmCloses)
         highRev = true;
      if(InpTradeContinuation && g_sslgHighOutside >= InpConfirmCloses)
         highCont = true;
   }

   if(g_sslgLowSwept)
   {
      if(c > g_sslgPrevLow)
      {
         g_sslgLowInside++;
         g_sslgLowOutside = 0;
      }
      else if(c < g_sslgPrevLow)
      {
         g_sslgLowOutside++;
         g_sslgLowInside = 0;
      }
      else
      {
         g_sslgLowInside = 0;
         g_sslgLowOutside = 0;
      }
      if(InpTradeReversal && g_sslgLowInside >= InpConfirmCloses)
         lowRev = true;
      if(InpTradeContinuation && g_sslgLowOutside >= InpConfirmCloses)
         lowCont = true;
   }

   if(highSweepBar || lowSweepBar)
      g_sslgConfirmStr = StringFormat("HS=%s LS=%s", g_sslgHighSwept ? "Y" : "N", g_sslgLowSwept ? "Y" : "N");
   else if(g_sslgHighSwept || g_sslgLowSwept)
      g_sslgConfirmStr = StringFormat("HiIn=%d HiOut=%d LoIn=%d LoOut=%d",
         g_sslgHighInside, g_sslgHighOutside, g_sslgLowInside, g_sslgLowOutside);

   if(highRev && !BSE_SessionSweepLocked())
      BSE_ArmSetup(BSE_BEAR, CONF_REVERSAL, g_sslgPrevHigh, g_sslgHighExtreme, t, "HIGH", "REV S");
   else if(lowRev && !BSE_SessionSweepLocked())
      BSE_ArmSetup(BSE_BULL, CONF_REVERSAL, g_sslgPrevLow, g_sslgLowExtreme, t, "LOW", "REV L");
   else if(highCont && !BSE_SessionSweepLocked())
      BSE_ArmSetup(BSE_BULL, CONF_CONTINUATION, g_sslgPrevHigh, g_sslgHighExtreme, t, "HIGH", "CONT L");
   else if(lowCont && !BSE_SessionSweepLocked())
      BSE_ArmSetup(BSE_BEAR, CONF_CONTINUATION, g_sslgPrevLow, g_sslgLowExtreme, t, "LOW", "CONT S");
   else if(!g_bse.sweep.valid)
      g_bse.status = StringFormat("%s | Prev %s H=%.2f L=%.2f | %s",
         SSLG_SessionName(g_sslgCurSession), SSLG_SessionName(g_sslgPrevSession),
         g_sslgPrevHigh, g_sslgPrevLow, g_sslgConfirmStr);
}

void SSLG_BuildHistory()
{
   SSLG_ResetAllState();
   int bars = iBars(_Symbol, InpSweepTF);
   if(bars < 3) return;
   for(int shift = bars - 1; shift >= 1; shift--)
   {
      SSLG_ProcessClosedBar(iTime(_Symbol, InpSweepTF, shift),
                            iHigh(_Symbol, InpSweepTF, shift),
                            iLow(_Symbol, InpSweepTF, shift),
                            iClose(_Symbol, InpSweepTF, shift));
   }
   g_sslgLastBar = iTime(_Symbol, InpSweepTF, 1);
   g_sslgHistoryBuilt = true;
}

bool SSLG_OnNewBar()
{
   if(g_bse.sweep.valid && TimeCurrent() > g_bse.sweep.expiresAt)
   {
      g_bse.sweep.valid = false;
      g_bse.entryFVG.valid = false;
      g_bse.bias = BSE_NONE;
   }

   if(!g_sslgHistoryBuilt)
      SSLG_BuildHistory();

   datetime barTime = iTime(_Symbol, InpSweepTF, 1);
   if(barTime <= 0) return false;
   if(barTime == g_sslgLastBar) return false;

   g_sslgLastBar = barTime;
   SSLG_ProcessClosedBar(barTime,
                         iHigh(_Symbol, InpSweepTF, 1),
                         iLow(_Symbol, InpSweepTF, 1),
                         iClose(_Symbol, InpSweepTF, 1));
   return true;
}

//+------------------------------------------------------------------+
//| FVG detection                                                     |
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
   double c1 = iClose(_Symbol, InpEntryTF, 1);
   if(z.dir > 0 && c1 < z.bottom) return true;
   if(z.dir < 0 && c1 > z.top) return true;
   return false;
}

bool FVG_PriceInZone(const SFVGZone &z, const double price, const double prox)
{
   if(!z.valid) return false;
   return (price <= z.top + prox && price >= z.bottom - prox);
}

bool FindFirstPostSweepFVG(const ENUM_BSE_BIAS bias, const datetime afterTime, SFVGZone &out)
{
   out.valid = false;
   double minGap = PipsToPrice(InpFVG_MinPips);
   int bars = iBars(_Symbol, InpEntryTF);
   if(bars < 5) return false;

   int maxShift = MathMin(bars - 3, 120);
   for(int s = maxShift; s >= 2; s--)
   {
      datetime bt = iTime(_Symbol, InpEntryTF, s);
      if(bt <= afterTime) continue;

      SFVGZone z;
      z.valid = false;
      z.barTime = bt;
      z.dir = 0;
      z.top = z.bottom = 0.0;

      if(bias == BSE_BULL && FVG_BullAt(_Symbol, InpEntryTF, s, z.top, z.bottom))
         z.dir = 1;
      else if(bias == BSE_BEAR && FVG_BearAt(_Symbol, InpEntryTF, s, z.top, z.bottom))
         z.dir = -1;
      else
         continue;

      if((z.top - z.bottom) < minGap) continue;
      z.valid = true;
      if(FVG_IsMitigated(z)) continue;
      out = z;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Entry after SessionSweepLG confirm                                |
//+------------------------------------------------------------------+
void BSE_UpdateEntryFVG()
{
   if(!g_bse.sweep.valid || !InpRequireFVGEntry) return;
   if(g_bse.entryFVG.valid && !FVG_IsMitigated(g_bse.entryFVG)) return;

   SFVGZone z;
   if(!FindFirstPostSweepFVG(g_bse.sweep.dir, g_bse.sweep.sweepBarTime, z))
   {
      g_bse.status = StringFormat("%s — waiting for %s FVG",
         g_bse.status, EnumToString(InpEntryTF));
      return;
   }

   g_bse.entryFVG = z;
   g_bse.status = StringFormat("FVG ready %s [%.2f - %.2f] — wait retrace",
      z.dir > 0 ? "BULL" : "BEAR", z.bottom, z.top);
}

bool BSE_EntrySignal(bool &buy, bool &sell)
{
   buy = sell = false;
   if(!g_bse.sweep.valid) return false;

   if(!InpRequireFVGEntry)
   {
      buy = (g_bse.sweep.dir == BSE_BULL);
      sell = (g_bse.sweep.dir == BSE_BEAR);
      return (buy || sell);
   }

   if(!g_bse.entryFVG.valid || FVG_IsMitigated(g_bse.entryFVG)) return false;

   double prox = PipsToPrice(InpFVG_ProxPips);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid = (bid + ask) * 0.5;

   double hi1 = iHigh(_Symbol, InpEntryTF, 1);
   double lo1 = iLow(_Symbol, InpEntryTF, 1);
   bool barTouch = (lo1 <= g_bse.entryFVG.top + prox && hi1 >= g_bse.entryFVG.bottom - prox);
   if(!barTouch) return false;

   if(g_bse.sweep.dir == BSE_BULL && g_bse.entryFVG.dir > 0)
   {
      double cl = iClose(_Symbol, InpEntryTF, 1);
      if(cl >= g_bse.entryFVG.bottom && FVG_PriceInZone(g_bse.entryFVG, mid, prox))
         buy = true;
   }
   else if(g_bse.sweep.dir == BSE_BEAR && g_bse.entryFVG.dir < 0)
   {
      double cl = iClose(_Symbol, InpEntryTF, 1);
      if(cl <= g_bse.entryFVG.top && FVG_PriceInZone(g_bse.entryFVG, mid, prox))
         sell = true;
   }
   return (buy || sell);
}

//+------------------------------------------------------------------+
//| Risk / execution                                                  |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;
   lots = MathFloor(lots / step + 1e-9) * step;
   if(lots < minLot) lots = minLot;
   if(InpMaxLots > 0.0 && lots > InpMaxLots) lots = InpMaxLots;
   if(lots > maxLot) lots = maxLot;
   return lots;
}

double CalcLotSize(const double riskDistPrice)
{
   if(riskDistPrice <= 0.0 || InpRiskPercent <= 0.0) return 0.0;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * InpRiskPercent / 100.0;
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0) return 0.0;
   double ticks = riskDistPrice / tickSize;
   if(ticks <= 0.0) return 0.0;
   return NormalizeLots(riskAmount / (ticks * tickValue));
}

bool StopsOK(const bool buy, const double sl, const double tp)
{
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double d = stopLevel * Pt();
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(buy)
   {
      if(sl > 0.0 && (ask - sl) < d) return false;
      if(tp > 0.0 && (tp - ask) < d) return false;
   }
   else
   {
      if(sl > 0.0 && (sl - bid) < d) return false;
      if(tp > 0.0 && (bid - tp) < d) return false;
   }
   return true;
}

bool BuildStops(const bool buy, const double entry, double &sl, double &tp)
{
   if(!g_bse.sweep.valid) return false;
   double buffer = SLBufferForSweep();
   double minDist = MinSLDistancePrice();
   bool smallSweep = (InpSmallSweepMaxPips > 0.0 && SweepWickDepthPips() < InpSmallSweepMaxPips);

   if(buy)
   {
      double slSweep = g_bse.sweep.extreme - buffer;
      sl = smallSweep ? Np(slSweep) : Np(MathMin(slSweep, entry - minDist));
      double risk = entry - sl;
      if(risk <= 0.0) return false;
      tp = Np(entry + risk * InpTargetRR);
   }
   else
   {
      double slSweep = g_bse.sweep.extreme + buffer;
      sl = smallSweep ? Np(slSweep) : Np(MathMax(slSweep, entry + minDist));
      double risk = sl - entry;
      if(risk <= 0.0) return false;
      tp = Np(entry - risk * InpTargetRR);
   }

   double riskPips = PriceToPips(MathAbs(entry - sl));
   if(InpMaxSLPips > 0.0 && riskPips > InpMaxSLPips)
   {
      SetLogOk(StringFormat("Skipped: SL %.1f pips > max %.1f", riskPips, InpMaxSLPips));
      return false;
   }
   return StopsOK(buy, sl, tp);
}

bool OpenBuy(const double sl, const double tp)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double lots = CalcLotSize(ask - sl);
   if(lots <= 0.0) { SetLog("Buy blocked: lot calc failed", true); return false; }
   if(!g_trade.Buy(lots, _Symbol, ask, Np(sl), Np(tp), InpComment))
   {
      SetLog(StringFormat("Buy failed: %s", g_trade.ResultRetcodeDescription()), true);
      return false;
   }
   RecordEntrySuccess();
   g_bse.sweep.valid = false;
   g_bse.entryFVG.valid = false;
   g_bse.bias = BSE_NONE;
   SetLogOk(StringFormat("BUY | lots=%.2f SL=%.2f TP=%.2f (%.1f pips, %.0fR)",
      lots, sl, tp, PriceToPips(ask - sl), InpTargetRR));
   return true;
}

bool OpenSell(const double sl, const double tp)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lots = CalcLotSize(sl - bid);
   if(lots <= 0.0) { SetLog("Sell blocked: lot calc failed", true); return false; }
   if(!g_trade.Sell(lots, _Symbol, bid, Np(sl), Np(tp), InpComment))
   {
      SetLog(StringFormat("Sell failed: %s", g_trade.ResultRetcodeDescription()), true);
      return false;
   }
   RecordEntrySuccess();
   g_bse.sweep.valid = false;
   g_bse.entryFVG.valid = false;
   g_bse.bias = BSE_NONE;
   SetLogOk(StringFormat("SELL | lots=%.2f SL=%.2f TP=%.2f (%.1f pips, %.0fR)",
      lots, sl, tp, PriceToPips(sl - bid), InpTargetRR));
   return true;
}

bool TryBSETrade()
{
   bool buy = false, sell = false;
   if(!BSE_EntrySignal(buy, sell)) return false;

   ENUM_TIMEFRAMES sigTf = InpRequireFVGEntry ? InpEntryTF : InpSweepTF;
   datetime sigBar = iTime(_Symbol, sigTf, 1);
   if(sigBar == g_lastSignalBar && g_entries_today > 0) return false;

   if(buy)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl = 0.0, tp = 0.0;
      if(!BuildStops(true, ask, sl, tp))
      {
         SetLogOk("Buy skipped — SL/TP invalid");
         return false;
      }
      return OpenBuy(sl, tp);
   }
   if(sell)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = 0.0, tp = 0.0;
      if(!BuildStops(false, bid, sl, tp))
      {
         SetLogOk("Sell skipped — SL/TP invalid");
         return false;
      }
      return OpenSell(sl, tp);
   }
   return false;
}

//+------------------------------------------------------------------+
//| Dashboard                                                         |
//+------------------------------------------------------------------+
void DeleteDashboard()
{
   ObjectsDeleteAll(ChartID(), g_dashPrefix);
}

void UpdateDashboard()
{
   long chartId = ChartID();

   if(!InpShowDashboard)
   {
      DeleteDashboard();
      return;
   }

   string biasStr = "NONE";
   if(g_bse.bias == BSE_BULL) biasStr = "BULL";
   else if(g_bse.bias == BSE_BEAR) biasStr = "BEAR";

   string sweepStr = g_bse.sweep.valid
      ? StringFormat("%s %s @ %.2f", BSE_ConfirmLabel(g_bse.sweep.confirm),
         g_bse.sweep.sweptSide, g_bse.sweep.pivotLevel)
      : g_sslgConfirmStr;

   string fvgStr = g_bse.entryFVG.valid
      ? StringFormat("%.2f - %.2f", g_bse.entryFVG.bottom, g_bse.entryFVG.top)
      : (InpRequireFVGEntry ? "waiting" : "off");

   string lines[];
   ArrayResize(lines, 8);
   lines[0] = "Zeke Trading BSE v1.07 | SessionSweepLG BSE";
   lines[1] = StringFormat("%s (%s) | Cur: %s | pip=%.2f",
      _Symbol, AssetLabel(), SSLG_SessionName(g_sslgCurSession), GetPipSize());
   lines[2] = StringFormat("Prev %s H=%.2f L=%.2f | %s",
      SSLG_SessionName(g_sslgPrevSession), g_bse.prevHigh, g_bse.prevLow,
      g_sslgPrevReady ? "ready" : "building");
   lines[3] = StringFormat("Setup: %s | Bias: %s", sweepStr, biasStr);
   lines[4] = StringFormat("Entry FVG: %s", fvgStr);
   lines[5] = StringFormat("RR: %.1f | Risk: %.1f%% | buf: %.0f | small buf: %.0f",
      InpTargetRR, InpRiskPercent, SLBufferPips(), InpSmallSweepBufferPips);
   lines[6] = StringFormat("Trades: %d/%d | Sweep lock: %s | Cooldown: %s",
      g_entries_today, InpMaxTradesPerDay,
      BSE_SessionSweepLocked() ? "used" : "open", CooldownOK() ? "ready" : "active");
   lines[7] = (g_logIsError ? "ERROR: " : "Status: ") + g_logMsg;

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
      else if(i == 3) rowClr = clrAqua;
      else if(i == 7) rowClr = g_logIsError ? clrTomato : clrLime;
      ObjectSetInteger(chartId, name, OBJPROP_COLOR, rowClr);
   }

   for(int j = ArraySize(lines); j < 12; j++)
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
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   SymbolAsset_Init();
   g_bse.bias = BSE_NONE;
   g_bse.sweep.valid = false;
   g_bse.entryFVG.valid = false;
   g_bse.status = "Ready";
   SSLG_ResetAllState();
   SSLG_BuildHistory();

   Print("Zeke Trading BSE v1.07 | ", _Symbol, " (", AssetLabel(), ")",
         " | pip=", DoubleToString(GetPipSize(), 4),
         " | minSL=", MinSLPips(), " | SLbuf=", SLBufferPips(),
         " | smallSweep<", InpSmallSweepMaxPips, " buf=", InpSmallSweepBufferPips,
         " | REV=", InpTradeReversal, " CONT=", InpTradeContinuation,
         " | FVG=", InpRequireFVGEntry,
         " | Risk ", InpRiskPercent, "% | RR=", InpTargetRR);
   UpdateDashboard();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { DeleteDashboard(); }

void OnTick()
{
   UpdateDashboard();

   if(!SpreadOK())
   {
      SetLog("Blocked: spread too wide", true);
      return;
   }
   if(!CooldownOK())
   {
      SetLogOk("Cooldown active");
      return;
   }
   if(!EntrySpacingOK())
   {
      SetLog("Max trades/day reached", true);
      return;
   }
   if(CountOurPositions() > 0) return;

   SSLG_OnNewBar();

   if(g_bse.sweep.valid && InpRequireFVGEntry)
      BSE_UpdateEntryFVG();

   if(!NewSignalBar()) return;
   ResetDailyTradeCount();

   if(!g_bse.sweep.valid)
   {
      SetLogOk(g_bse.status);
      return;
   }

   TryBSETrade();
}

//+------------------------------------------------------------------+

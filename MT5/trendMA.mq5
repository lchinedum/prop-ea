//+------------------------------------------------------------------+
//| trendMA.mq5                                                      |
//| Zeke Trading by Lucky Ekechi                                     |
//| EMA 50/200 gap entry + breakout through EMA50. 1:3 RR.             |
//+------------------------------------------------------------------+
#property copyright "Zeke Trading by Lucky Ekechi"
#property version   "1.04"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Volume filter (same logic as PA_Phases_EA)                       |
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
   return ((long)iTickVolume(sym, tf, shSig) > (long)iTickVolume(sym, tf, shPrev));
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

bool VBF_PassesVolume(const string sym, const ENUM_TIMEFRAMES tf, const datetime signalBarTime,
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
input group "=== General ==="
input ulong    InpMagic         = 20260524;
input string   InpComment       = "trendMA";
input int      InpSlippage      = 30;
input int      InpMaxSpread     = 0;

input group "=== Moving averages (M5 only) ==="
input int      InpEMA_Fast      = 50;
input int      InpEMA_Slow      = 200;
input int      InpEMA_Shift     = 0;
input int      InpGapProxPoints = 20;        // tolerance when bar touches EMA gap zone

input group "=== Volume filter (optional) ==="
input bool     InpUseVolumeFilter      = false;
input int      InpVolAvgPeriod         = 20;
input double   InpVolMinRelMult        = 1.5;
input bool     InpVolRequireRising     = true;
input bool     InpVolUseCandleStrength = true;
input double   InpVolMinCloseFrac      = 0.70;

input group "=== Risk ==="
input double   InpRiskPercent   = 0.25;
input double   InpRewardRisk    = 3.0;         // TP = SL distance × this (1:3 default)
input int      InpSL_BufferPoints = 120;       // added beyond signal-bar low (buy) / high (sell)
input int      InpMinRiskPoints = 50;
input int      InpMaxTradesPerDay = 8;
input int      InpCooldownSec   = 0;         // 0 = new trade as soon as flat + signal
input double   InpMaxLots       = 10.0;
input double   InpMaxDailyLossPct   = 2.0;     // stop entries after daily loss >= this % of balance (0=off)
input double   InpMaxDailyProfitPct = 4.0;     // stop entries after daily profit >= this % of balance (0=off)
input bool     InpAccountPLWholeAccount = true; // daily limits use whole account (false = this EA magic only)

input group "=== Dashboard ==="
input bool     InpShowDashboard = true;
input int      InpDashCorner    = 0;
input int      InpDashX         = 10;
input int      InpDashY         = 20;
input int      InpDashFontSize  = 9;
input bool     InpDebugLog      = true;      // print skip reasons to Experts journal

CTrade         g_trade;
int            g_hEmaFast = INVALID_HANDLE;
int            g_hEmaSlow = INVALID_HANDLE;

string         g_dashPrefix = "TMA_Dash_";
string         g_logMsg = "Initializing";
bool           g_logIsError = false;

datetime       g_lastSignalBar = 0;
datetime       g_lastEntryTime = 0;
int            g_entriesToday = 0;
int            g_lastDay = -1;

// Trade metrics (EA magic, all history)
int            g_totalTrades = 0;
int            g_wins = 0;
int            g_losses = 0;
double         g_netPL = 0.0;
double         g_todayPL = 0.0;

ENUM_TIMEFRAMES SignalTF() { return PERIOD_M5; }

double Pt() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }

double GetPipSize()
{
   double pt = Pt();
   if(pt <= 0.0) return 0.0;
   int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digs == 3 || digs == 5) return pt * 10.0;
   return pt;
}

double GapProxPrice() { return (double)InpGapProxPoints * Pt(); }

void EMAGapBounds(const double emaF, const double emaS, double &gapLo, double &gapHi)
{
   gapLo = MathMin(emaF, emaS);
   gapHi = MathMax(emaF, emaS);
}

// Bar range intersects the zone between EMA50 and EMA200.
bool BarTouchesEMAGap(const int sh, const double emaF, const double emaS)
{
   if(MathAbs(emaF - emaS) < Pt()) return false;
   double gapLo = 0.0, gapHi = 0.0;
   EMAGapBounds(emaF, emaS, gapLo, gapHi);
   const double prox = GapProxPrice();
   ENUM_TIMEFRAMES tf = SignalTF();
   double hi = iHigh(_Symbol, tf, sh);
   double lo = iLow(_Symbol, tf, sh);
   return (lo <= gapHi + prox && hi >= gapLo - prox);
}

bool PriceWasInGapRecently(const int sh, const double emaF, const double emaS)
{
   if(BarTouchesEMAGap(sh, emaF, emaS)) return true;
   double emaF2 = 0.0, emaS2 = 0.0;
   if(!GetEMA(g_hEmaFast, sh + 1, emaF2) || !GetEMA(g_hEmaSlow, sh + 1, emaS2)) return false;
   return BarTouchesEMAGap(sh + 1, emaF2, emaS2);
}

void Dbg(const string msg)
{
   if(InpDebugLog) Print("trendMA: ", msg);
}

double Np(const double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

void SetLog(const string msg, const bool isError)
{
   g_logMsg = msg;
   g_logIsError = isError;
   if(isError) Print("trendMA: ", msg);
}

void SetLogOk(const string msg) { SetLog(msg, false); }

bool GetEMA(const int handle, const int shift, double &val)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) != 1) return false;
   val = buf[0];
   return true;
}

bool NewSignalBar()
{
   datetime t = iTime(_Symbol, SignalTF(), 0);
   if(t <= 0 || t == g_lastSignalBar) return false;
   g_lastSignalBar = t;
   return true;
}

void ResetDailyCount()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day != g_lastDay)
   {
      g_lastDay = dt.day;
      g_entriesToday = 0;
      g_todayPL = 0.0;
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

bool DailyLimitOK()
{
   if(InpMaxTradesPerDay <= 0) return true;
   return (g_entriesToday < InpMaxTradesPerDay);
}

datetime DayStart(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
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

double AccountDailyProfitTarget()
{
   if(InpMaxDailyProfitPct <= 0.0) return 0.0;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0) return 0.0;
   return balance * InpMaxDailyProfitPct / 100.0;
}

double AccountDailyLossLimit()
{
   if(InpMaxDailyLossPct <= 0.0) return 0.0;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0) return 0.0;
   return balance * InpMaxDailyLossPct / 100.0;
}

bool DailyLossLimitHit()
{
   double limit = AccountDailyLossLimit();
   if(limit <= 0.0) return false;
   return (GetAccountTodayNetPL() <= -limit);
}

bool DailyProfitTargetHit()
{
   double target = AccountDailyProfitTarget();
   if(target <= 0.0) return false;
   return (GetAccountTodayNetPL() >= target);
}

bool DailyPLAllowsEntry(string &blockReason)
{
   blockReason = "";
   if(DailyLossLimitHit())
   {
      blockReason = StringFormat("Daily loss limit (%.1f%%, P/L %.2f)",
         InpMaxDailyLossPct, GetAccountTodayNetPL());
      return false;
   }
   if(DailyProfitTargetHit())
   {
      blockReason = StringFormat("Daily profit target (%.1f%%, P/L %.2f)",
         InpMaxDailyProfitPct, GetAccountTodayNetPL());
      return false;
   }
   return true;
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

double CalcLotSize(const double riskDistPrice)
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

bool StopsOK(const bool buy, const double sl, const double tp)
{
   int stopLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopLevel * Pt();
   double entry = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(sl > 0.0 && MathAbs(entry - sl) < minDist) return false;
   if(tp > 0.0 && MathAbs(entry - tp) < minDist) return false;
   return true;
}

void RefreshTradeMetrics()
{
   g_totalTrades = 0;
   g_wins = 0;
   g_losses = 0;
   g_netPL = 0.0;
   g_todayPL = 0.0;

   datetime dayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(!HistorySelect(0, TimeCurrent())) return;

   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
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

      datetime dealTime = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
      if(dealTime >= dayStart)
         g_todayPL += profit;
   }
}

double WinRatePct()
{
   if(g_totalTrades <= 0) return 0.0;
   return 100.0 * (double)g_wins / (double)g_totalTrades;
}

string TrendLabel(const double emaFast, const double emaSlow)
{
   if(emaFast > emaSlow) return "Bull (50>200)";
   if(emaFast < emaSlow) return "Bear (50<200)";
   return "Flat";
}

// Buy: bull trend, price into EMA gap, then breakout above EMA50 on signal bar.
bool SignalBuyGapBreakout(const int sh, string &detail)
{
   detail = "";
   double emaF = 0.0, emaS = 0.0;
   double emaF2 = 0.0;
   if(!GetEMA(g_hEmaFast, sh, emaF) || !GetEMA(g_hEmaSlow, sh, emaS)) return false;
   if(!GetEMA(g_hEmaFast, sh + 1, emaF2)) return false;
   if(emaF <= emaS) return false;

   ENUM_TIMEFRAMES tf = SignalTF();
   double o1 = iOpen(_Symbol, tf, sh);
   double c1 = iClose(_Symbol, tf, sh);
   double c2 = iClose(_Symbol, tf, sh + 1);

   if(!PriceWasInGapRecently(sh, emaF, emaS)) return false;

   bool brokeEMA50 = (c1 > emaF) && (o1 <= emaF || c2 <= emaF2);
   if(brokeEMA50)
   {
      detail = StringFormat("Buy gap breakout above EMA50 %.2f", emaF);
      return true;
   }
   return false;
}

// Sell: bear trend, price into EMA gap, then breakout below EMA50 on signal bar.
bool SignalSellGapBreakout(const int sh, string &detail)
{
   detail = "";
   double emaF = 0.0, emaS = 0.0;
   double emaF2 = 0.0;
   if(!GetEMA(g_hEmaFast, sh, emaF) || !GetEMA(g_hEmaSlow, sh, emaS)) return false;
   if(!GetEMA(g_hEmaFast, sh + 1, emaF2)) return false;
   if(emaF >= emaS) return false;

   ENUM_TIMEFRAMES tf = SignalTF();
   double o1 = iOpen(_Symbol, tf, sh);
   double c1 = iClose(_Symbol, tf, sh);
   double c2 = iClose(_Symbol, tf, sh + 1);

   if(!PriceWasInGapRecently(sh, emaF, emaS)) return false;

   bool brokeEMA50 = (c1 < emaF) && (o1 >= emaF || c2 >= emaF2);
   if(brokeEMA50)
   {
      detail = StringFormat("Sell gap breakout below EMA50 %.2f", emaF);
      return true;
   }
   return false;
}

string DiagnoseLastBar()
{
   const int sh = 1;
   double emaF = 0.0, emaS = 0.0;
   double emaF2 = 0.0;
   if(!GetEMA(g_hEmaFast, sh, emaF) || !GetEMA(g_hEmaSlow, sh, emaS))
      return "EMA data loading";
   GetEMA(g_hEmaFast, sh + 1, emaF2);

   ENUM_TIMEFRAMES tf = SignalTF();
   double o1 = iOpen(_Symbol, tf, sh);
   double c1 = iClose(_Symbol, tf, sh);
   double c2 = iClose(_Symbol, tf, sh + 1);
   bool inGap = PriceWasInGapRecently(sh, emaF, emaS);

   if(emaF > emaS)
   {
      bool brk = (c1 > emaF) && (o1 <= emaF || c2 <= emaF2);
      return StringFormat("Bull | inGap=%s brk>EMA50=%s", inGap ? "Y" : "N", brk ? "Y" : "N");
   }
   if(emaF < emaS)
   {
      bool brk = (c1 < emaF) && (o1 >= emaF || c2 >= emaF2);
      return StringFormat("Bear | inGap=%s brk<EMA50=%s", inGap ? "Y" : "N", brk ? "Y" : "N");
   }
   return "EMA50=EMA200 (no trend)";
}

bool BuildStops(const bool buy, const int sh, double &sl, double &tp)
{
   const ENUM_TIMEFRAMES tf = PERIOD_M5;
   const double buffer = (double)InpSL_BufferPoints * Pt();
   const double barLow  = iLow(_Symbol, tf, sh);
   const double barHigh = iHigh(_Symbol, tf, sh);
   double entry = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(buy)
   {
      sl = Np(barLow - buffer);
      double risk = entry - sl;
      if(risk <= 0.0) return false;
      tp = Np(entry + risk * InpRewardRisk);
   }
   else
   {
      sl = Np(barHigh + buffer);
      double risk = sl - entry;
      if(risk <= 0.0) return false;
      tp = Np(entry - risk * InpRewardRisk);
   }

   if(InpMinRiskPoints > 0)
   {
      double minDist = (double)InpMinRiskPoints * Pt();
      double dist = buy ? (entry - sl) : (sl - entry);
      if(dist + 1e-9 < minDist) return false;
   }
   return true;
}

bool OpenBuy(const double sl, const double tp)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(!StopsOK(true, sl, tp))
   {
      SetLog("Buy blocked: broker stop level too close", true);
      return false;
   }
   double lots = CalcLotSize(ask - sl);
   if(lots <= 0.0)
   {
      SetLog("Buy blocked: lot size calc failed", true);
      return false;
   }
   if(!g_trade.Buy(lots, _Symbol, ask, Np(sl), Np(tp), InpComment))
   {
      SetLog(StringFormat("Buy failed: %s", g_trade.ResultRetcodeDescription()), true);
      return false;
   }
   g_lastEntryTime = TimeCurrent();
   g_entriesToday++;
   SetLogOk(StringFormat("Buy %.2f lots SL=%.2f TP=%.2f (1:%.0f)",
      lots, sl, tp, InpRewardRisk));
   Print("trendMA: Buy ", lots, " lots SL=", sl, " TP=", tp);
   return true;
}

bool OpenSell(const double sl, const double tp)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(!StopsOK(false, sl, tp))
   {
      SetLog("Sell blocked: broker stop level too close", true);
      return false;
   }
   double lots = CalcLotSize(sl - bid);
   if(lots <= 0.0)
   {
      SetLog("Sell blocked: lot size calc failed", true);
      return false;
   }
   if(!g_trade.Sell(lots, _Symbol, bid, Np(sl), Np(tp), InpComment))
   {
      SetLog(StringFormat("Sell failed: %s", g_trade.ResultRetcodeDescription()), true);
      return false;
   }
   g_lastEntryTime = TimeCurrent();
   g_entriesToday++;
   SetLogOk(StringFormat("Sell %.2f lots SL=%.2f TP=%.2f (1:%.0f)",
      lots, sl, tp, InpRewardRisk));
   Print("trendMA: Sell ", lots, " lots SL=", sl, " TP=", tp);
   return true;
}

bool TryEntry()
{
   if(CountOurPositions() > 0)
   {
      SetLogOk("Position open — waiting for close");
      return false;
   }

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      SetLog("Blocked: AutoTrading disabled in terminal", true);
      return false;
   }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      SetLog("Blocked: EA trading not allowed (check AutoTrading button)", true);
      return false;
   }

   string plBlock = "";
   if(!DailyPLAllowsEntry(plBlock))
   {
      SetLog(StringFormat("Blocked: %s", plBlock), true);
      return false;
   }

   if(!DailyLimitOK())
   {
      SetLogOk("Daily trade limit reached");
      return false;
   }
   if(!CooldownOK())
   {
      SetLogOk("Cooldown active");
      return false;
   }
   if(!VBF_SpreadOK(InpMaxSpread))
   {
      SetLog("Spread too wide", true);
      return false;
   }

   const int sh = 1;
   datetime barTime = iTime(_Symbol, SignalTF(), sh);
   string detail = "";
   double emaF = 0.0, emaS = 0.0;
   GetEMA(g_hEmaFast, 1, emaF);
   GetEMA(g_hEmaSlow, 1, emaS);

   if(SignalBuyGapBreakout(sh, detail))
   {
      Dbg(detail);
      if(!VBF_PassesVolume(_Symbol, SignalTF(), barTime, true,
         InpUseVolumeFilter, InpVolAvgPeriod, InpVolMinRelMult,
         InpVolRequireRising, InpVolUseCandleStrength, InpVolMinCloseFrac))
      {
         SetLogOk("Buy gap breakout — volume filter failed");
         Dbg("Buy blocked by volume filter");
         return false;
      }
      double sl = 0.0, tp = 0.0;
      if(!BuildStops(true, sh, sl, tp))
      {
         SetLogOk("Buy gap breakout — invalid SL/TP");
         Dbg("Buy blocked: SL/TP build failed");
         return false;
      }
      return OpenBuy(sl, tp);
   }

   if(SignalSellGapBreakout(sh, detail))
   {
      Dbg(detail);
      if(!VBF_PassesVolume(_Symbol, SignalTF(), barTime, false,
         InpUseVolumeFilter, InpVolAvgPeriod, InpVolMinRelMult,
         InpVolRequireRising, InpVolUseCandleStrength, InpVolMinCloseFrac))
      {
         SetLogOk("Sell gap breakout — volume filter failed");
         Dbg("Sell blocked by volume filter");
         return false;
      }
      double sl = 0.0, tp = 0.0;
      if(!BuildStops(false, sh, sl, tp))
      {
         SetLogOk("Sell gap breakout — invalid SL/TP");
         Dbg("Sell blocked: SL/TP build failed");
         return false;
      }
      return OpenSell(sl, tp);
   }

   string diag = DiagnoseLastBar();
   SetLogOk(StringFormat("Scanning — %s | %s", TrendLabel(emaF, emaS), diag));
   Dbg(StringFormat("No entry on last bar: %s", diag));
   return false;
}

void DeleteDashboard()
{
   ObjectsDeleteAll(ChartID(), g_dashPrefix);
}

void UpdateDashboard()
{
   if(!InpShowDashboard)
   {
      DeleteDashboard();
      return;
   }

   RefreshTradeMetrics();

   double emaF = 0.0, emaS = 0.0;
   GetEMA(g_hEmaFast, 1, emaF);
   GetEMA(g_hEmaSlow, 1, emaS);

   int posCount = CountOurPositions();
   string posStr = "Flat";
   if(posCount > 0)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         long type = PositionGetInteger(POSITION_TYPE);
         double pl = PositionGetDouble(POSITION_PROFIT);
         posStr = StringFormat("%s %.2f lots P/L %.2f",
            (type == POSITION_TYPE_BUY ? "Long" : "Short"),
            PositionGetDouble(POSITION_VOLUME), pl);
         break;
      }
   }

   string lines[];
   ArrayResize(lines, 14);
   lines[0] = "trendMA v1.04 | Zeke Trading by Lucky Ekechi";
   lines[1] = StringFormat("%s | TF: M5 (fixed)", _Symbol);
   lines[2] = StringFormat("EMA %d / %d | Trend: %s", InpEMA_Fast, InpEMA_Slow, TrendLabel(emaF, emaS));
   lines[3] = StringFormat("EMA50=%.2f  EMA200=%.2f", emaF, emaS);
   lines[4] = StringFormat("Position: %s", posStr);
   lines[5] = StringFormat("RR 1:%.1f | Risk %.2f%%", InpRewardRisk, InpRiskPercent);
   lines[6] = StringFormat("Trades: %d (W %d / L %d) | Win %.1f%%",
      g_totalTrades, g_wins, g_losses, WinRatePct());
   lines[7] = StringFormat("Net P/L: %.2f | EA today: %.2f", g_netPL, g_todayPL);
   lines[8] = StringFormat("Acct today: %.2f | Limit +%.1f%% / -%.1f%% (%s)",
      GetAccountTodayNetPL(), InpMaxDailyProfitPct, InpMaxDailyLossPct,
      InpAccountPLWholeAccount ? "whole account" : "EA magic");
   lines[9] = StringFormat("Entries today: %d / %d", g_entriesToday, InpMaxTradesPerDay);
   lines[10] = StringFormat("Vol filter: %s", InpUseVolumeFilter ? "on" : "off");
   lines[11] = DiagnoseLastBar();
   lines[12] = "Entry: EMA gap then break EMA50";
   lines[13] = (g_logIsError ? "ERROR: " : "Status: ") + g_logMsg;

   long chartId = ChartID();
   const int lineH = InpDashFontSize + 6;
   const int padSide = 12;
   const int padTop  = 8;
   const int padBot  = 8;
   int boxW = 440;
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
      else if(i == 2) rowClr = clrGold;
      else if(i == 6 || i == 7 || i == 8) rowClr = clrSilver;
      else if(i == 13) rowClr = g_logIsError ? clrTomato : clrLime;
      ObjectSetInteger(chartId, name, OBJPROP_COLOR, rowClr);
   }
   ChartRedraw(chartId);
}

int OnInit()
{
   if(_Period != PERIOD_M5)
   {
      Print("trendMA: attach this EA to an M5 chart only (current: ", EnumToString((ENUM_TIMEFRAMES)_Period), ")");
      return INIT_PARAMETERS_INCORRECT;
   }

   const ENUM_TIMEFRAMES tf = PERIOD_M5;
   g_hEmaFast = iMA(_Symbol, tf, InpEMA_Fast, InpEMA_Shift, MODE_EMA, PRICE_CLOSE);
   g_hEmaSlow = iMA(_Symbol, tf, InpEMA_Slow, InpEMA_Shift, MODE_EMA, PRICE_CLOSE);
   if(g_hEmaFast == INVALID_HANDLE || g_hEmaSlow == INVALID_HANDLE)
   {
      Print("trendMA: failed to create EMA indicators");
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints((uint)InpSlippage);
   SetFilling();

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_lastDay = dt.day;

   Print("trendMA v1.04 | Zeke Trading by Lucky Ekechi | ", _Symbol,
         " | TF M5",
         " | EMA ", InpEMA_Fast, "/", InpEMA_Slow,
         " | RR 1:", InpRewardRisk,
         " | Risk ", InpRiskPercent, "%",
         " | Daily +", InpMaxDailyProfitPct, "% / -", InpMaxDailyLossPct, "%",
         " | VolFilter ", (InpUseVolumeFilter ? "on" : "off"));

   SetLogOk("EA initialized");
   UpdateDashboard();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_hEmaFast != INVALID_HANDLE) IndicatorRelease(g_hEmaFast);
   if(g_hEmaSlow != INVALID_HANDLE) IndicatorRelease(g_hEmaSlow);
   DeleteDashboard();
}

void OnTick()
{
   ResetDailyCount();
   UpdateDashboard();

   if(!NewSignalBar()) return;
   TryEntry();
}

//+------------------------------------------------------------------+

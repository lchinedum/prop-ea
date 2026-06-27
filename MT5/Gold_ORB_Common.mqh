//+------------------------------------------------------------------+
//| Gold_ORB_Common.mqh                                              |
//| Shared ORB time/range helpers for GOLD_ORB_Indicator / EAs.     |
//| ORB_ScanRange(sym, tf, ...): pass PERIOD_M15 for box H/L vs M5 chart.|
//| No inputs, globals, or version strings — include only helpers.   |
//+------------------------------------------------------------------+
#ifndef GOLD_ORB_COMMON_MQH
#define GOLD_ORB_COMMON_MQH

void ORB_CSTToBroker(const string cstTime, const int brokerGMTOffset, int &brokerH, int &brokerM)
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

void ORB_OrbEndHM(const int startH, const int startM, const int durationMins, int &endH, int &endM)
{
   int totalMins = startH * 60 + startM + durationMins;
   if(totalMins >= 1440) totalMins -= 1440;
   if(totalMins < 0)     totalMins += 1440;
   endH = totalMins / 60;
   endM = totalMins % 60;
}

double ORB_OrbEndFrac(const int startH, const int startM, const int durationMins)
{
   int totalMins = startH * 60 + startM + durationMins;
   if(totalMins >= 1440) totalMins -= 1440;
   if(totalMins < 0)     totalMins += 1440;
   return totalMins / 60.0;
}

bool ORB_ScanRange(const string sym, const ENUM_TIMEFRAMES tf, const datetime t1, const datetime t2, double &hi, double &lo)
{
   int bs = iBarShift(sym, tf, t1, false);
   int be = iBarShift(sym, tf, t2, false);
   if(bs < 0 || be < 0) return false;
   int cnt = MathAbs(bs - be) + 1;
   if(cnt <= 0 || cnt > 200) return false;
   double h[], l[];
   int first = MathMin(bs, be);
   if(CopyHigh(sym, tf, first, cnt, h) != cnt) return false;
   if(CopyLow (sym, tf, first, cnt, l) != cnt) return false;
   hi = h[0]; lo = l[0];
   for(int i = 1; i < cnt; i++)
   {
      if(h[i] > hi) hi = h[i];
      if(l[i] < lo) lo = l[i];
   }
   return true;
}

#endif // GOLD_ORB_COMMON_MQH

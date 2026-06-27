//+------------------------------------------------------------------+
//| Gold_ORB_SMC.mqh                                               |
//| SMC / price-action confluence (OB-style, FVG, liquidity, etc.)    |
//| for GOLD_ORB_Indicator / GOLD_ORB_Master_EA. Place in Include.  |
//| Series index: 1 = last closed bar (same as ORB OnCalculate).    |
//+------------------------------------------------------------------+
#ifndef GOLD_ORB_SMC_MQH
#define GOLD_ORB_SMC_MQH

struct SMCScoreResult
{
   int    score;
   int    maxScore;
   string tag;
};

//+------------------------------------------------------------------+
double SMC_Body(const double o, const double c) { return MathAbs(c - o); }

double SMC_RangeSym(const string sym, const double h, const double l)
{
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   return MathMax(h - l, pt * 5.0);
}

//+------------------------------------------------------------------+
// ATR value at shift (MQL5: iATR returns handle; value via CopyBuffer).
//+------------------------------------------------------------------+
double SMC_AtrValue(const string sym, const ENUM_TIMEFRAMES tf, const int period, const int shift)
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
// Bullish FVG: gap between wick high of bar[shift+2] and wick low of bar[shift].
//+------------------------------------------------------------------+
bool SMC_BullishFVGAt(const string sym, const ENUM_TIMEFRAMES tf, const int shift)
{
   if(shift < 1) return false;
   double h3 = iHigh(sym, tf, shift + 2);
   double l1 = iLow(sym, tf, shift);
   if(h3 <= 0 || l1 <= 0) return false;
   return (l1 > h3);
}

bool SMC_BearishFVGAt(const string sym, const ENUM_TIMEFRAMES tf, const int shift)
{
   if(shift < 1) return false;
   double l3 = iLow(sym, tf, shift + 2);
   double h1 = iHigh(sym, tf, shift);
   if(l3 <= 0 || h1 <= 0) return false;
   return (h1 < l3);
}

//+------------------------------------------------------------------+
bool SMC_BullishPinBar(const string sym, const ENUM_TIMEFRAMES tf, const int sh)
{
   double o = iOpen(sym, tf, sh), c = iClose(sym, tf, sh);
   double h = iHigh(sym, tf, sh), l = iLow(sym, tf, sh);
   double body = SMC_Body(o, c);
   double range = SMC_RangeSym(sym, h, l);
   if(range <= 0 || c < o) return false;
   double lowerWick = MathMin(o, c) - l;
   return (lowerWick >= body * 2.0 && body <= range * 0.35);
}

bool SMC_BearishPinBar(const string sym, const ENUM_TIMEFRAMES tf, const int sh)
{
   double o = iOpen(sym, tf, sh), c = iClose(sym, tf, sh);
   double h = iHigh(sym, tf, sh), l = iLow(sym, tf, sh);
   double body = SMC_Body(o, c);
   double range = SMC_RangeSym(sym, h, l);
   if(range <= 0 || c > o) return false;
   double upperWick = h - MathMax(o, c);
   return (upperWick >= body * 2.0 && body <= range * 0.35);
}

//+------------------------------------------------------------------+
bool SMC_DojiAt(const string sym, const ENUM_TIMEFRAMES tf, const int sh, const double maxBodyPct)
{
   double o = iOpen(sym, tf, sh), c = iClose(sym, tf, sh);
   double h = iHigh(sym, tf, sh), l = iLow(sym, tf, sh);
   double range = SMC_RangeSym(sym, h, l);
   return (SMC_Body(o, c) <= range * maxBodyPct);
}

//+------------------------------------------------------------------+
bool SMC_BullishEngulfing(const string sym, const ENUM_TIMEFRAMES tf, const int sh)
{
   double o1 = iOpen(sym, tf, sh), c1 = iClose(sym, tf, sh);
   double o2 = iOpen(sym, tf, sh + 1), c2 = iClose(sym, tf, sh + 1);
   if(c2 >= o2) return false;
   if(c1 <= o1) return false;
   return (c1 >= o2 && o1 <= c2 && (c1 - o1) > (o2 - c2));
}

bool SMC_BearishEngulfing(const string sym, const ENUM_TIMEFRAMES tf, const int sh)
{
   double o1 = iOpen(sym, tf, sh), c1 = iClose(sym, tf, sh);
   double o2 = iOpen(sym, tf, sh + 1), c2 = iClose(sym, tf, sh + 1);
   if(c2 <= o2) return false;
   if(c1 >= o1) return false;
   return (o1 >= c2 && c1 <= o2 && (o1 - c1) > (c2 - o2));
}

//+------------------------------------------------------------------+
bool SMC_TweezerBottom(const string sym, const ENUM_TIMEFRAMES tf, const int sh, const double tolPrice)
{
   double l1 = iLow(sym, tf, sh);
   double l2 = iLow(sym, tf, sh + 1);
   return (MathAbs(l1 - l2) <= tolPrice);
}

bool SMC_TweezerTop(const string sym, const ENUM_TIMEFRAMES tf, const int sh, const double tolPrice)
{
   double h1 = iHigh(sym, tf, sh);
   double h2 = iHigh(sym, tf, sh + 1);
   return (MathAbs(h1 - h2) <= tolPrice);
}

//+------------------------------------------------------------------+
// Sweep: wick pierces recent swing extreme then closes back inside.
//+------------------------------------------------------------------+
bool SMC_BullishLiquidityGrab(const string sym, const ENUM_TIMEFRAMES tf, const int lookback, const int tolBars)
{
   int from = 3;
   int to = MathMax(from + 1, lookback);
   double swingLow = iLow(sym, tf, from);
   for(int i = from; i <= to; i++)
   {
      double v = iLow(sym, tf, i);
      if(v < swingLow) swingLow = v;
   }
   double l1 = iLow(sym, tf, 1), c1 = iClose(sym, tf, 1);
   if(swingLow <= 0) return false;
   return (l1 < swingLow && c1 > swingLow);
}

bool SMC_BearishLiquidityGrab(const string sym, const ENUM_TIMEFRAMES tf, const int lookback, const int tolBars)
{
   int from = 3;
   int to = MathMax(from + 1, lookback);
   double swingHigh = iHigh(sym, tf, from);
   for(int i = from; i <= to; i++)
   {
      double v = iHigh(sym, tf, i);
      if(v > swingHigh) swingHigh = v;
   }
   double h1 = iHigh(sym, tf, 1), c1 = iClose(sym, tf, 1);
   if(swingHigh <= 0) return false;
   return (h1 > swingHigh && c1 < swingHigh);
}

//+------------------------------------------------------------------+
// "Normal OB": small bearish bar then strong bullish impulse (bar 1).
//+------------------------------------------------------------------+
bool SMC_NormalBullOB(const string sym, const ENUM_TIMEFRAMES tf, const double atrMult)
{
   double o2 = iOpen(sym, tf, 2), c2 = iClose(sym, tf, 2);
   double o1 = iOpen(sym, tf, 1), c1 = iClose(sym, tf, 1);
   if(c2 >= o2) return false;
   if(c1 <= o1) return false;
   double atr = SMC_AtrValue(sym, tf, 14, 1);
   if(atr <= 0) return false;
   double body1 = c1 - o1;
   double body2 = o2 - c2;
   return (body1 >= atr * atrMult && body2 < body1 * 0.55);
}

bool SMC_NormalBearOB(const string sym, const ENUM_TIMEFRAMES tf, const double atrMult)
{
   double o2 = iOpen(sym, tf, 2), c2 = iClose(sym, tf, 2);
   double o1 = iOpen(sym, tf, 1), c1 = iClose(sym, tf, 1);
   if(c2 <= o2) return false;
   if(c1 >= o1) return false;
   double atr = SMC_AtrValue(sym, tf, 14, 1);
   if(atr <= 0) return false;
   double body1 = o1 - c1;
   double body2 = c2 - o2;
   return (body1 >= atr * atrMult && body2 < body1 * 0.55);
}

//+------------------------------------------------------------------+
// Manipulation: tiny body green, sweeps prior lows, then closes up.
//+------------------------------------------------------------------+
bool SMC_ManipBullish(const string sym, const ENUM_TIMEFRAMES tf)
{
   double o1 = iOpen(sym, tf, 1), c1 = iClose(sym, tf, 1);
   double h1 = iHigh(sym, tf, 1), l1 = iLow(sym, tf, 1);
   if(c1 <= o1) return false;
   double range = SMC_RangeSym(sym, h1, l1);
   double body = c1 - o1;
   if(body > range * 0.45) return false;
   double l2 = iLow(sym, tf, 2), l3 = iLow(sym, tf, 3);
   return (l1 < l2 && l1 < l3 && c1 > iClose(sym, tf, 2));
}

bool SMC_ManipBearish(const string sym, const ENUM_TIMEFRAMES tf)
{
   double o1 = iOpen(sym, tf, 1), c1 = iClose(sym, tf, 1);
   double h1 = iHigh(sym, tf, 1), l1 = iLow(sym, tf, 1);
   if(c1 >= o1) return false;
   double range = SMC_RangeSym(sym, h1, l1);
   double body = o1 - c1;
   if(body > range * 0.45) return false;
   double h2 = iHigh(sym, tf, 2), h3 = iHigh(sym, tf, 3);
   return (h1 > h2 && h1 > h3 && c1 < iClose(sym, tf, 2));
}

//+------------------------------------------------------------------+
// MSS (simplified): last closed broke above recent swing high (bullish).
//+------------------------------------------------------------------+
bool SMC_BullishMSSSimple(const string sym, const ENUM_TIMEFRAMES tf, const int lookback)
{
   double c1 = iClose(sym, tf, 1);
   int to = lookback;
   double sh = iHigh(sym, tf, 2);
   for(int i = 3; i <= to; i++)
   {
      double v = iHigh(sym, tf, i);
      if(v > sh) sh = v;
   }
   return (c1 > sh);
}

bool SMC_BearishMSSSimple(const string sym, const ENUM_TIMEFRAMES tf, const int lookback)
{
   double c1 = iClose(sym, tf, 1);
   int to = lookback;
   double sl = iLow(sym, tf, 2);
   for(int i = 3; i <= to; i++)
   {
      double v = iLow(sym, tf, i);
      if(v < sl) sl = v;
   }
   return (c1 < sl);
}

//+------------------------------------------------------------------+
// OTE: close in 62–79% retrace of swing high/low over lookback (discount for longs).
//+------------------------------------------------------------------+
bool SMC_LongInOTE(const string sym, const ENUM_TIMEFRAMES tf, const int lookback,
                   const double fibLo, const double fibHi)
{
   int a = 1, b = lookback;
   double hi = iHigh(sym, tf, a), lo = iLow(sym, tf, a);
   for(int i = a; i <= b; i++)
   {
      double h = iHigh(sym, tf, i), l = iLow(sym, tf, i);
      if(h > hi) hi = h;
      if(l < lo) lo = l;
   }
   double range = hi - lo;
   if(range <= 0) return false;
   double c1 = iClose(sym, tf, 1);
   // Discount OTE: retrace fibLo..fibHi from swing high toward low (e.g. 0.62–0.79)
   double zoneHi = hi - fibLo * range;
   double zoneLo = hi - fibHi * range;
   if(zoneLo > zoneHi) { double t = zoneLo; zoneLo = zoneHi; zoneHi = t; }
   return (c1 >= zoneLo && c1 <= zoneHi);
}

bool SMC_ShortInOTE(const string sym, const ENUM_TIMEFRAMES tf, const int lookback,
                    const double fibLo, const double fibHi)
{
   int a = 1, b = lookback;
   double hi = iHigh(sym, tf, a), lo = iLow(sym, tf, a);
   for(int i = a; i <= b; i++)
   {
      double h = iHigh(sym, tf, i), l = iLow(sym, tf, i);
      if(h > hi) hi = h;
      if(l < lo) lo = l;
   }
   double range = hi - lo;
   if(range <= 0) return false;
   double c1 = iClose(sym, tf, 1);
   double zoneLo = lo + fibLo * range;
   double zoneHi = lo + fibHi * range;
   if(zoneLo > zoneHi) { double t = zoneLo; zoneLo = zoneHi; zoneHi = t; }
   return (c1 >= zoneLo && c1 <= zoneHi);
}

//+------------------------------------------------------------------+
void SMC_ScoreLong(const string sym, const ENUM_TIMEFRAMES tf,
                   const int lookback, const double atrMultImpulse,
                   const double tweezerTolPoints, const double dojiBodyPct,
                   const bool useFvg, const bool usePin, const bool useDoji, const bool useEng,
                   const bool useTweezer, const bool useLq, const bool useNormalOb,
                   const bool useManip, const bool useMss, const bool useOte,
                   SMCScoreResult &out)
{
   out.score = 0;
   out.maxScore = 0;
   out.tag = "";

   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   double tol = tweezerTolPoints * pt;
   if(StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0)
      tol = MathMax(tol, pt * 10.0);

   string bits = "";

   bool anyFvg = false;
   if(useFvg)
   {
      out.maxScore++;
      for(int s = 1; s <= 8 && !anyFvg; s++)
      {
         if(SMC_BullishFVGAt(sym, tf, s))
            anyFvg = true;
      }
      if(anyFvg) { out.score++; bits += "FVG"; }
   }

   bool pin = false;
   if(usePin)
   {
      out.maxScore++;
      for(int s = 2; s <= 12 && !pin; s++)
      {
         if(SMC_BullishPinBar(sym, tf, s))
            pin = true;
      }
      if(pin) { out.score++; bits += (bits == "" ? "" : "+") + "Pin"; }
   }

   bool doji = false;
   if(useDoji)
   {
      out.maxScore++;
      for(int s = 2; s <= 10 && !doji; s++)
      {
         if(SMC_DojiAt(sym, tf, s, dojiBodyPct))
            doji = true;
      }
      if(doji) { out.score++; bits += (bits == "" ? "" : "+") + "Doji"; }
   }

   if(useEng)
   {
      out.maxScore++;
      bool eng = SMC_BullishEngulfing(sym, tf, 1) || SMC_BullishEngulfing(sym, tf, 2);
      if(eng) { out.score++; bits += (bits == "" ? "" : "+") + "Eng"; }
   }

   if(useTweezer)
   {
      out.maxScore++;
      bool tw = SMC_TweezerBottom(sym, tf, 1, tol) || SMC_TweezerBottom(sym, tf, 2, tol);
      if(tw) { out.score++; bits += (bits == "" ? "" : "+") + "Twz"; }
   }

   if(useLq)
   {
      out.maxScore++;
      bool lq = SMC_BullishLiquidityGrab(sym, tf, lookback, 3);
      if(lq) { out.score++; bits += (bits == "" ? "" : "+") + "LQ"; }
   }

   if(useNormalOb)
   {
      out.maxScore++;
      bool nrm = SMC_NormalBullOB(sym, tf, atrMultImpulse);
      if(nrm) { out.score++; bits += (bits == "" ? "" : "+") + "OB"; }
   }

   if(useManip)
   {
      out.maxScore++;
      bool man = SMC_ManipBullish(sym, tf);
      if(man) { out.score++; bits += (bits == "" ? "" : "+") + "Manip"; }
   }

   if(useMss)
   {
      out.maxScore++;
      bool mss = SMC_BullishMSSSimple(sym, tf, lookback);
      if(mss) { out.score++; bits += (bits == "" ? "" : "+") + "MSS"; }
   }

   if(useOte)
   {
      out.maxScore++;
      bool ote = SMC_LongInOTE(sym, tf, lookback, 0.62, 0.79);
      if(ote) { out.score++; bits += (bits == "" ? "" : "+") + "OTE"; }
   }

   out.tag = bits;
}

//+------------------------------------------------------------------+
void SMC_ScoreShort(const string sym, const ENUM_TIMEFRAMES tf,
                    const int lookback, const double atrMultImpulse,
                    const double tweezerTolPoints, const double dojiBodyPct,
                    const bool useFvg, const bool usePin, const bool useDoji, const bool useEng,
                    const bool useTweezer, const bool useLq, const bool useNormalOb,
                    const bool useManip, const bool useMss, const bool useOte,
                    SMCScoreResult &out)
{
   out.score = 0;
   out.maxScore = 0;
   out.tag = "";

   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   double tol = tweezerTolPoints * pt;
   if(StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0)
      tol = MathMax(tol, pt * 10.0);

   string bits = "";

   bool anyFvg = false;
   if(useFvg)
   {
      out.maxScore++;
      for(int s = 1; s <= 8 && !anyFvg; s++)
      {
         if(SMC_BearishFVGAt(sym, tf, s))
            anyFvg = true;
      }
      if(anyFvg) { out.score++; bits += "FVG"; }
   }

   bool pin = false;
   if(usePin)
   {
      out.maxScore++;
      for(int s = 2; s <= 12 && !pin; s++)
      {
         if(SMC_BearishPinBar(sym, tf, s))
            pin = true;
      }
      if(pin) { out.score++; bits += (bits == "" ? "" : "+") + "Pin"; }
   }

   bool doji = false;
   if(useDoji)
   {
      out.maxScore++;
      for(int s = 2; s <= 10 && !doji; s++)
      {
         if(SMC_DojiAt(sym, tf, s, dojiBodyPct))
            doji = true;
      }
      if(doji) { out.score++; bits += (bits == "" ? "" : "+") + "Doji"; }
   }

   if(useEng)
   {
      out.maxScore++;
      bool eng = SMC_BearishEngulfing(sym, tf, 1) || SMC_BearishEngulfing(sym, tf, 2);
      if(eng) { out.score++; bits += (bits == "" ? "" : "+") + "Eng"; }
   }

   if(useTweezer)
   {
      out.maxScore++;
      bool tw = SMC_TweezerTop(sym, tf, 1, tol) || SMC_TweezerTop(sym, tf, 2, tol);
      if(tw) { out.score++; bits += (bits == "" ? "" : "+") + "Twz"; }
   }

   if(useLq)
   {
      out.maxScore++;
      bool lq = SMC_BearishLiquidityGrab(sym, tf, lookback, 3);
      if(lq) { out.score++; bits += (bits == "" ? "" : "+") + "LQ"; }
   }

   if(useNormalOb)
   {
      out.maxScore++;
      bool nrm = SMC_NormalBearOB(sym, tf, atrMultImpulse);
      if(nrm) { out.score++; bits += (bits == "" ? "" : "+") + "OB"; }
   }

   if(useManip)
   {
      out.maxScore++;
      bool man = SMC_ManipBearish(sym, tf);
      if(man) { out.score++; bits += (bits == "" ? "" : "+") + "Manip"; }
   }

   if(useMss)
   {
      out.maxScore++;
      bool mss = SMC_BearishMSSSimple(sym, tf, lookback);
      if(mss) { out.score++; bits += (bits == "" ? "" : "+") + "MSS"; }
   }

   if(useOte)
   {
      out.maxScore++;
      bool ote = SMC_ShortInOTE(sym, tf, lookback, 0.62, 0.79);
      if(ote) { out.score++; bits += (bits == "" ? "" : "+") + "OTE"; }
   }

   out.tag = bits;
}

//+------------------------------------------------------------------+
bool SMC_PassesLongFilter(const string sym, const ENUM_TIMEFRAMES tf,
                          const int lookback, const int minScore,
                          const double atrMultImpulse, const double tweezerTolPoints,
                          const double dojiBodyPct,
                          const bool useFvg, const bool usePin, const bool useDoji, const bool useEng,
                          const bool useTweezer, const bool useLq, const bool useNormalOb,
                          const bool useManip, const bool useMss, const bool useOte,
                          SMCScoreResult &detail)
{
   SMC_ScoreLong(sym, tf, lookback, atrMultImpulse, tweezerTolPoints, dojiBodyPct,
                 useFvg, usePin, useDoji, useEng, useTweezer, useLq, useNormalOb,
                 useManip, useMss, useOte, detail);
   if(detail.maxScore <= 0) return true;
   return (detail.score >= minScore);
}

bool SMC_PassesShortFilter(const string sym, const ENUM_TIMEFRAMES tf,
                           const int lookback, const int minScore,
                           const double atrMultImpulse, const double tweezerTolPoints,
                           const double dojiBodyPct,
                           const bool useFvg, const bool usePin, const bool useDoji, const bool useEng,
                           const bool useTweezer, const bool useLq, const bool useNormalOb,
                           const bool useManip, const bool useMss, const bool useOte,
                           SMCScoreResult &detail)
{
   SMC_ScoreShort(sym, tf, lookback, atrMultImpulse, tweezerTolPoints, dojiBodyPct,
                  useFvg, usePin, useDoji, useEng, useTweezer, useLq, useNormalOb,
                  useManip, useMss, useOte, detail);
   if(detail.maxScore <= 0) return true;
   return (detail.score >= minScore);
}

#endif // GOLD_ORB_SMC_MQH

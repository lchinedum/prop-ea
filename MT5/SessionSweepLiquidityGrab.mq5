//+------------------------------------------------------------------+
//|                                     SessionSweepLiquidityGrab.mq5 |
//| Cross-session liquidity sweep detector with two-close confirmation|
//+------------------------------------------------------------------+
#property copyright "SessionSweepLiquidityGrab"
#property version   "1.03"
#property description "Session H/L lines via indicator buffers + sweep alerts"
#property indicator_chart_window
#property indicator_buffers 4
#property indicator_plots   4

#property indicator_label1  "Prev Session High"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrRed
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

#property indicator_label2  "Prev Session Low"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrDeepSkyBlue
#property indicator_style2  STYLE_SOLID
#property indicator_width2  2

#property indicator_label3  "Current Session High"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrOrangeRed
#property indicator_style3  STYLE_DOT
#property indicator_width3  1

#property indicator_label4  "Current Session Low"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrDodgerBlue
#property indicator_style4  STYLE_DOT
#property indicator_width4  1

input group "=== Session Time (Broker Server) ==="
input int InpAsiaStartHour = 2;
input int InpAsiaEndHour = 10;
input int InpNewYorkStartHour = 15;
input int InpNewYorkEndHour = 22;
input int InpLondonStartHour = 10;
input int InpLondonEndHour = 18;

input group "=== Visuals ==="
input bool InpShowCurrentSessionLines = true;

input group "=== Notifications ==="
input bool InpNotifyOnSweep = true;
input bool InpNotifyOnReversalConfirm = true;
input bool InpNotifyOnContinuationConfirm = true;
input bool InpNotifyPopup = true;
input bool InpNotifyPush = false;
input bool InpNotifySound = false;
input bool InpAllowRepeatAlerts = false;
input bool InpDebugPrint = false;

double gBufPrevHigh[];
double gBufPrevLow[];
double gBufCurrHigh[];
double gBufCurrLow[];

long gChartId = 0;
string gPrefix = "SSLG_";
datetime gLastBarTime = 0;
bool gHistoryBuilt = false;

int gCurrentSessionId = 0;
int gPrevSessionId = 0;
double gBuildHigh = 0.0;
double gBuildLow = 0.0;
bool gBuildInit = false;

double gPrevSessionHigh = 0.0;
double gPrevSessionLow = 0.0;
bool gPrevLevelsReady = false;

bool gHighSwept = false;
bool gLowSwept = false;
int gHighInsideCloses = 0;
int gHighOutsideCloses = 0;
int gLowInsideCloses = 0;
int gLowOutsideCloses = 0;
bool gHighReversalSent = false;
bool gHighContinuationSent = false;
bool gLowReversalSent = false;
bool gLowContinuationSent = false;
int gLastSweepAlertSession = -1;
int gLastReversalAlertSession = -1;
int gLastContinuationAlertSession = -1;

void Dbg(const string msg)
{
   if(InpDebugPrint)
      Print("SSLG: ", msg);
}

void SslgSendAlert(const string msg)
{
   if(InpNotifyPopup)
      Alert(msg);
   if(InpNotifyPush)
      SendNotification(msg);
   if(InpNotifySound)
      PlaySound("alert.wav");
}

bool CanSendAlertForSession(const int kind, const int sessionId)
{
   if(InpAllowRepeatAlerts)
      return true;

   if(kind == 1)
      return (gLastSweepAlertSession != sessionId);
   if(kind == 2)
      return (gLastReversalAlertSession != sessionId);
   if(kind == 3)
      return (gLastContinuationAlertSession != sessionId);
   return true;
}

void MarkAlertSentForSession(const int kind, const int sessionId)
{
   if(kind == 1)
      gLastSweepAlertSession = sessionId;
   else if(kind == 2)
      gLastReversalAlertSession = sessionId;
   else if(kind == 3)
      gLastContinuationAlertSession = sessionId;
}

void ResetConfirmState()
{
   gHighSwept = false;
   gLowSwept = false;
   gHighInsideCloses = 0;
   gHighOutsideCloses = 0;
   gLowInsideCloses = 0;
   gLowOutsideCloses = 0;
   gHighReversalSent = false;
   gHighContinuationSent = false;
   gLowReversalSent = false;
   gLowContinuationSent = false;
}

void ResetAllState()
{
   gLastBarTime = 0;
   gHistoryBuilt = false;
   gCurrentSessionId = 0;
   gPrevSessionId = 0;
   gBuildHigh = 0.0;
   gBuildLow = 0.0;
   gBuildInit = false;
   gPrevSessionHigh = 0.0;
   gPrevSessionLow = 0.0;
   gPrevLevelsReady = false;
   gLastSweepAlertSession = -1;
   gLastReversalAlertSession = -1;
   gLastContinuationAlertSession = -1;
   ResetConfirmState();
}

// Priority: Asia -> New York -> London (NY wins overlap with London).
int SessionIdFromHour(const int h)
{
   if(h >= InpAsiaStartHour && h < InpAsiaEndHour)
      return 1;
   if(h >= InpNewYorkStartHour && h < InpNewYorkEndHour)
      return 3;
   if(h >= InpLondonStartHour && h < InpLondonEndHour)
      return 2;
   return 0;
}

string SessionName(const int id)
{
   if(id == 1)
      return "Asia";
   if(id == 2)
      return "London";
   if(id == 3)
      return "NewYork";
   return "Off";
}

string BarObjectTag(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return StringFormat("%04d%02d%02d%02d%02d", dt.year, dt.mon, dt.day, dt.hour, dt.min);
}

void DrawMarker(const string name, const datetime t, const double p, const color clr, const int arrowCode, const string text)
{
   if(ObjectFind(gChartId, name) >= 0)
      return;
   if(!ObjectCreate(gChartId, name, OBJ_ARROW, 0, t, p))
      return;
   ObjectSetInteger(gChartId, name, OBJPROP_ARROWCODE, arrowCode);
   ObjectSetInteger(gChartId, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(gChartId, name, OBJPROP_WIDTH, 2);
   ObjectSetString(gChartId, name, OBJPROP_TEXT, text);
   ObjectSetInteger(gChartId, name, OBJPROP_SELECTABLE, false);
}

void DrawLineLabel(const string name, const datetime t, const double p, const color clr, const string text)
{
   if(p <= 0.0)
      return;
   if(ObjectFind(gChartId, name) < 0)
      ObjectCreate(gChartId, name, OBJ_TEXT, 0, t, p);
   ObjectSetInteger(gChartId, name, OBJPROP_TIME, t);
   ObjectSetDouble(gChartId, name, OBJPROP_PRICE, p);
   ObjectSetString(gChartId, name, OBJPROP_TEXT, text);
   ObjectSetInteger(gChartId, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(gChartId, name, OBJPROP_FONTSIZE, 8);
   ObjectSetString(gChartId, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(gChartId, name, OBJPROP_ANCHOR, ANCHOR_LEFT);
   ObjectSetInteger(gChartId, name, OBJPROP_SELECTABLE, false);
}

void UpdateLineLabels()
{
   datetime rightEdge = iTime(_Symbol, _Period, 0);

   if(gPrevLevelsReady)
   {
      DrawLineLabel(gPrefix + "LblPrevHigh",
                    rightEdge,
                    gPrevSessionHigh,
                    clrRed,
                    "Prev High " + DoubleToString(gPrevSessionHigh, _Digits));
      DrawLineLabel(gPrefix + "LblPrevLow",
                    rightEdge,
                    gPrevSessionLow,
                    clrDeepSkyBlue,
                    "Prev Low " + DoubleToString(gPrevSessionLow, _Digits));
   }
   else
   {
      ObjectDelete(gChartId, gPrefix + "LblPrevHigh");
      ObjectDelete(gChartId, gPrefix + "LblPrevLow");
   }

   if(InpShowCurrentSessionLines && gBuildInit && gCurrentSessionId > 0)
   {
      DrawLineLabel(gPrefix + "LblCurrHigh",
                    rightEdge,
                    gBuildHigh,
                    clrOrangeRed,
                    "Curr High " + DoubleToString(gBuildHigh, _Digits));
      DrawLineLabel(gPrefix + "LblCurrLow",
                    rightEdge,
                    gBuildLow,
                    clrDodgerBlue,
                    "Curr Low " + DoubleToString(gBuildLow, _Digits));
   }
   else
   {
      ObjectDelete(gChartId, gPrefix + "LblCurrHigh");
      ObjectDelete(gChartId, gPrefix + "LblCurrLow");
   }
}

void UpdateStatusLabel()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);

   string panel = gPrefix + "Panel";
   if(ObjectFind(gChartId, panel) < 0)
      ObjectCreate(gChartId, panel, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(gChartId, panel, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(gChartId, panel, OBJPROP_XDISTANCE, 8);
   ObjectSetInteger(gChartId, panel, OBJPROP_YDISTANCE, 24);
   ObjectSetInteger(gChartId, panel, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(gChartId, panel, OBJPROP_FONTSIZE, 9);
   ObjectSetString(gChartId, panel, OBJPROP_FONT, "Consolas");
   ObjectSetString(gChartId, panel, OBJPROP_TEXT,
                   StringFormat("SessionSweepLG v1.03 | Server %02d:%02d | Curr:%s | Prev:%s | H/L:%s",
                                now.hour,
                                now.min,
                                SessionName(gCurrentSessionId),
                                SessionName(gPrevSessionId),
                                gPrevLevelsReady
                                   ? DoubleToString(gPrevSessionHigh, _Digits) + " / " + DoubleToString(gPrevSessionLow, _Digits)
                                   : "waiting"));
   ObjectSetInteger(gChartId, panel, OBJPROP_SELECTABLE, false);
}

void FillPlotBuffers(const int rates_total)
{
   double ph = gPrevLevelsReady ? gPrevSessionHigh : EMPTY_VALUE;
   double pl = gPrevLevelsReady ? gPrevSessionLow : EMPTY_VALUE;
   double ch = EMPTY_VALUE;
   double cl = EMPTY_VALUE;

   if(InpShowCurrentSessionLines && gBuildInit && gCurrentSessionId > 0)
   {
      ch = gBuildHigh;
      cl = gBuildLow;
   }

   for(int i = 0; i < rates_total; i++)
   {
      gBufPrevHigh[i] = ph;
      gBufPrevLow[i] = pl;
      gBufCurrHigh[i] = ch;
      gBufCurrLow[i] = cl;
   }
}

void HandleNewSession(const int newSessionId, const double barHigh, const double barLow)
{
   gPrevSessionId = gCurrentSessionId;
   if(gBuildInit)
   {
      gPrevSessionHigh = gBuildHigh;
      gPrevSessionLow = gBuildLow;
      gPrevLevelsReady = (gPrevSessionHigh > 0.0 && gPrevSessionLow > 0.0 && gPrevSessionHigh >= gPrevSessionLow);
   }

   gCurrentSessionId = newSessionId;
   gBuildHigh = barHigh;
   gBuildLow = barLow;
   gBuildInit = true;
   ResetConfirmState();
}

void ProcessClosedBar(const datetime t, const double h, const double l, const double c, const bool drawMarkers)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   int sid = SessionIdFromHour(dt.hour);
   if(sid == 0)
      return;

   if(gCurrentSessionId == 0 || sid != gCurrentSessionId)
      HandleNewSession(sid, h, l);
   else
   {
      gBuildHigh = MathMax(gBuildHigh, h);
      gBuildLow = MathMin(gBuildLow, l);
   }

   if(!gPrevLevelsReady || gCurrentSessionId == gPrevSessionId)
      return;

   bool highSweepThisBar = false;
   bool lowSweepThisBar = false;
   bool highReversalThisBar = false;
   bool highContinuationThisBar = false;
   bool lowReversalThisBar = false;
   bool lowContinuationThisBar = false;

   if(!gHighSwept && h > gPrevSessionHigh)
   {
      gHighSwept = true;
      highSweepThisBar = true;
   }
   if(!gLowSwept && l < gPrevSessionLow)
   {
      gLowSwept = true;
      lowSweepThisBar = true;
   }

   if(gHighSwept)
   {
      if(c < gPrevSessionHigh)
      {
         gHighInsideCloses++;
         gHighOutsideCloses = 0;
      }
      else if(c > gPrevSessionHigh)
      {
         gHighOutsideCloses++;
         gHighInsideCloses = 0;
      }
      else
      {
         gHighInsideCloses = 0;
         gHighOutsideCloses = 0;
      }

      if(gHighInsideCloses >= 2 && (InpAllowRepeatAlerts || !gHighReversalSent))
      {
         gHighReversalSent = true;
         highReversalThisBar = true;
      }
      if(gHighOutsideCloses >= 2 && (InpAllowRepeatAlerts || !gHighContinuationSent))
      {
         gHighContinuationSent = true;
         highContinuationThisBar = true;
      }
   }

   if(gLowSwept)
   {
      if(c > gPrevSessionLow)
      {
         gLowInsideCloses++;
         gLowOutsideCloses = 0;
      }
      else if(c < gPrevSessionLow)
      {
         gLowOutsideCloses++;
         gLowInsideCloses = 0;
      }
      else
      {
         gLowInsideCloses = 0;
         gLowOutsideCloses = 0;
      }

      if(gLowInsideCloses >= 2 && (InpAllowRepeatAlerts || !gLowReversalSent))
      {
         gLowReversalSent = true;
         lowReversalThisBar = true;
      }
      if(gLowOutsideCloses >= 2 && (InpAllowRepeatAlerts || !gLowContinuationSent))
      {
         gLowContinuationSent = true;
         lowContinuationThisBar = true;
      }
   }

   if(!drawMarkers)
      return;

   string barTag = BarObjectTag(t);
   if(highSweepThisBar)
      DrawMarker(gPrefix + "HS_" + barTag, t, h, clrOrange, 234, "HS");
   if(lowSweepThisBar)
      DrawMarker(gPrefix + "LS_" + barTag, t, l, clrMagenta, 233, "LS");
   if(highReversalThisBar)
      DrawMarker(gPrefix + "HR_" + barTag, t, h, clrRed, 234, "REV S");
   if(highContinuationThisBar)
      DrawMarker(gPrefix + "HC_" + barTag, t, h, clrLimeGreen, 233, "CONT L");
   if(lowReversalThisBar)
      DrawMarker(gPrefix + "LR_" + barTag, t, l, clrLime, 233, "REV L");
   if(lowContinuationThisBar)
      DrawMarker(gPrefix + "LC_" + barTag, t, l, clrMaroon, 234, "CONT S");

   if(InpNotifyOnSweep && (highSweepThisBar || lowSweepThisBar) && CanSendAlertForSession(1, gCurrentSessionId))
   {
      SslgSendAlert(StringFormat("Session sweep on %s %s | Prev %s H=%.5f L=%.5f",
                                 _Symbol,
                                 EnumToString(_Period),
                                 SessionName(gPrevSessionId),
                                 gPrevSessionHigh,
                                 gPrevSessionLow));
      MarkAlertSentForSession(1, gCurrentSessionId);
   }
   if(InpNotifyOnReversalConfirm && (highReversalThisBar || lowReversalThisBar) && CanSendAlertForSession(2, gCurrentSessionId))
   {
      SslgSendAlert(StringFormat("Reversal confirmed on %s %s", _Symbol, EnumToString(_Period)));
      MarkAlertSentForSession(2, gCurrentSessionId);
   }
   if(InpNotifyOnContinuationConfirm && (highContinuationThisBar || lowContinuationThisBar) && CanSendAlertForSession(3, gCurrentSessionId))
   {
      SslgSendAlert(StringFormat("Continuation confirmed on %s %s", _Symbol, EnumToString(_Period)));
      MarkAlertSentForSession(3, gCurrentSessionId);
   }
}

void BuildHistory()
{
   ResetAllState();
   ENUM_TIMEFRAMES tf = _Period;
   int bars = Bars(_Symbol, tf);
   if(bars < 3)
   {
      Dbg("BuildHistory skipped: not enough bars");
      return;
   }

   for(int shift = bars - 1; shift >= 1; shift--)
   {
      ProcessClosedBar(iTime(_Symbol, tf, shift),
                       iHigh(_Symbol, tf, shift),
                       iLow(_Symbol, tf, shift),
                       iClose(_Symbol, tf, shift),
                       false);
   }

   gLastBarTime = iTime(_Symbol, tf, 1);
   gHistoryBuilt = true;

   Dbg(StringFormat("History built | Curr=%s Prev=%s Ready=%s H=%.5f L=%.5f",
                    SessionName(gCurrentSessionId),
                    SessionName(gPrevSessionId),
                    gPrevLevelsReady ? "Y" : "N",
                    gPrevSessionHigh,
                    gPrevSessionLow));
}

int OnInit()
{
   gChartId = ChartID();

   SetIndexBuffer(0, gBufPrevHigh, INDICATOR_DATA);
   SetIndexBuffer(1, gBufPrevLow, INDICATOR_DATA);
   SetIndexBuffer(2, gBufCurrHigh, INDICATOR_DATA);
   SetIndexBuffer(3, gBufCurrLow, INDICATOR_DATA);

   ArraySetAsSeries(gBufPrevHigh, true);
   ArraySetAsSeries(gBufPrevLow, true);
   ArraySetAsSeries(gBufCurrHigh, true);
   ArraySetAsSeries(gBufCurrLow, true);

   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(3, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   IndicatorSetString(INDICATOR_SHORTNAME, "SessionSweepLG");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   ObjectsDeleteAll(gChartId, gPrefix);
   ResetAllState();

   Dbg("OnInit OK chart=" + IntegerToString(gChartId));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   ObjectsDeleteAll(gChartId, gPrefix);
}

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   if(rates_total < 3)
      return 0;

   if(prev_calculated == 0 || !gHistoryBuilt)
      BuildHistory();

   ENUM_TIMEFRAMES tf = _Period;
   datetime barTime = iTime(_Symbol, tf, 1);
   if(barTime != gLastBarTime)
   {
      gLastBarTime = barTime;
      ProcessClosedBar(barTime,
                       iHigh(_Symbol, tf, 1),
                       iLow(_Symbol, tf, 1),
                       iClose(_Symbol, tf, 1),
                       true);
   }

   FillPlotBuffers(rates_total);
   UpdateLineLabels();
   UpdateStatusLabel();
   return rates_total;
}

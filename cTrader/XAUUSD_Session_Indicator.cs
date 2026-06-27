// ---------------------------------------------------------------------------
// XAUUSD_Session_Indicator.cs
// Gold Asian + NY Session Strategy — Visual Indicator for cTrader
// ---------------------------------------------------------------------------

using System;
using cAlgo.API;
using cAlgo.API.Indicators;
using cAlgo.API.Internals;

namespace cAlgo.Indicators
{
    [Indicator(IsOverlay = true, TimeZone = TimeZones.UTC, AccessRights = AccessRights.None)]
    public class XAUUSD_Session_Indicator : Indicator
    {
        [Parameter("Asia range start (hour)", DefaultValue = 19)]
        public int AsiaRangeStart { get; set; }

        [Parameter("Asia range end (hour)", DefaultValue = 23)]
        public int AsiaRangeEnd { get; set; }

        [Parameter("Asia trade window end (hour)", DefaultValue = 2)]
        public int AsiaTradeWindowEnd { get; set; }

        [Parameter("London start (hour)", DefaultValue = 2)]
        public int LondonStart { get; set; }

        [Parameter("London end (hour)", DefaultValue = 6)]
        public int LondonEnd { get; set; }

        [Parameter("NY start (hour)", DefaultValue = 7)]
        public int NYStartHour { get; set; }

        [Parameter("NY start (minute)", DefaultValue = 30)]
        public int NYStartMinute { get; set; }

        [Parameter("NY end (hour)", DefaultValue = 11)]
        public int NYEnd { get; set; }

        [Parameter("Show info panel", DefaultValue = true)]
        public bool ShowInfoPanel { get; set; }

        [Parameter("Alert on signal", DefaultValue = false)]
        public bool AlertOnSignal { get; set; }

        private double _asiaHigh, _asiaLow, _asiaMid;
        private bool _asiaValid;
        private double _londonHigh, _londonLow;
        private bool _londonValid;
        private double _prevDayHigh, _prevDayLow;
        private int _lastBarDay = -1;
        private string _signalText = "";
        private int _signalDir = 0;

        private double PipSize => Symbol.PipSize;

        protected override void Initialize() { }

        public override void Calculate(int index)
        {
            if (index < 50 || Bars.Count < 50) return;

            var serverTime = Bars.OpenTimes[index];
            int hour = serverTime.Hour;
            int day = serverTime.Day;

            if (day != _lastBarDay)
            {
                _lastBarDay = day;
                _londonValid = false;
                var yesterday = serverTime.Date.AddDays(-1);
                _prevDayHigh = 0;
                _prevDayLow = double.MaxValue;
                for (int i = 1; i < Bars.Count; i++)
                {
                    var t = Bars.OpenTimes[i];
                    if (t.Date < yesterday) break;
                    if (t.Date == yesterday)
                    {
                        _prevDayHigh = Math.Max(_prevDayHigh, Bars.HighPrices[i]);
                        _prevDayLow = Math.Min(_prevDayLow, Bars.LowPrices[i]);
                    }
                }
                if (_prevDayLow > 1e10) _prevDayLow = 0;
            }

            if (hour >= AsiaTradeWindowEnd && hour < AsiaRangeStart)
                _asiaValid = false;

            UpdateRanges(index, serverTime);
            DetectSignals(index, serverTime);
            DrawLevels(index);
            if (ShowInfoPanel) DrawInfoPanel(serverTime);
        }

        private void UpdateRanges(int index, DateTime serverTime)
        {
            var rangeStart = new DateTime(serverTime.Year, serverTime.Month, serverTime.Day, AsiaRangeStart, 0, 0);
            var rangeEnd = new DateTime(serverTime.Year, serverTime.Month, serverTime.Day, AsiaRangeEnd, 0, 0);
            if (rangeEnd <= rangeStart) rangeEnd = rangeEnd.AddDays(1);

            double ah = 0, al = double.MaxValue;
            for (int i = index; i >= 0 && i < Bars.Count; i--)
            {
                var t = Bars.OpenTimes[i];
                if (t < rangeStart) continue;
                if (t >= rangeEnd) break;
                ah = Math.Max(ah, Bars.HighPrices[i]);
                al = Math.Min(al, Bars.LowPrices[i]);
            }
            if (al < double.MaxValue)
            {
                _asiaHigh = ah;
                _asiaLow = al;
                _asiaMid = (ah + al) / 2.0;
                _asiaValid = true;
            }

            var londonStart = new DateTime(serverTime.Year, serverTime.Month, serverTime.Day, LondonStart, 0, 0);
            var londonEnd = new DateTime(serverTime.Year, serverTime.Month, serverTime.Day, LondonEnd, 0, 0);
            if (londonEnd <= londonStart) londonEnd = londonEnd.AddDays(1);

            double lh = 0, ll = double.MaxValue;
            for (int i = index; i >= 0 && i < Bars.Count; i--)
            {
                var t = Bars.OpenTimes[i];
                if (t < londonStart) continue;
                if (t >= londonEnd) break;
                lh = Math.Max(lh, Bars.HighPrices[i]);
                ll = Math.Min(ll, Bars.LowPrices[i]);
            }
            if (ll < double.MaxValue) { _londonHigh = lh; _londonLow = ll; _londonValid = true; }
        }

        private void DetectSignals(int index, DateTime serverTime)
        {
            _signalText = "";
            _signalDir = 0;

            int hour = serverTime.Hour;
            int min = serverTime.Minute;
            bool inAsiaTrade = (hour >= AsiaRangeEnd && hour < AsiaTradeWindowEnd) || (AsiaRangeEnd > AsiaTradeWindowEnd && (hour >= AsiaRangeEnd || hour < AsiaTradeWindowEnd));
            bool inNY = hour > NYStartHour || (hour == NYStartHour && min >= NYStartMinute);
            if (hour >= NYEnd) inNY = false;

            if (inAsiaTrade && _asiaValid && index >= 2)
            {
                double h1 = Bars.HighPrices[index - 1], l1 = Bars.LowPrices[index - 1], c1 = Bars.ClosePrices[index - 1];
                double h2 = Bars.HighPrices[index - 2], l2 = Bars.LowPrices[index - 2];

                if ((h1 > _asiaHigh && c1 < _asiaHigh) || (h2 > _asiaHigh && c1 < _asiaHigh))
                {
                    double sweepLow = GetSweepLowBullish(index);
                    if (sweepLow > 0)
                    {
                        _signalText = $"ASIA BUY | SL:{sweepLow - 5 * PipSize:F2} TP1:{_asiaMid:F2} TP2:{_asiaHigh:F2}";
                        _signalDir = 1;
                        if (AlertOnSignal) Alert("XAUUSD Asia BUY");
                    }
                }
                else if ((l1 < _asiaLow && c1 > _asiaLow) || (l2 < _asiaLow && c1 > _asiaLow))
                {
                    double sweepHigh = GetSweepHighBearish(index);
                    if (sweepHigh > 0)
                    {
                        _signalText = $"ASIA SELL | SL:{sweepHigh + 5 * PipSize:F2} TP1:{_asiaMid:F2} TP2:{_asiaLow:F2}";
                        _signalDir = -1;
                        if (AlertOnSignal) Alert("XAUUSD Asia SELL");
                    }
                }
            }

            if (inNY && _asiaValid && _signalDir == 0 && index >= 2)
            {
                double o1 = Bars.OpenPrices[index - 1], h1 = Bars.HighPrices[index - 1], l1 = Bars.LowPrices[index - 1], c1 = Bars.ClosePrices[index - 1];
                double body = Math.Abs(c1 - o1);
                double range = h1 - l1;
                if (range > 0)
                {
                    bool sweepLow = l1 < _asiaLow || (_londonValid && l1 < _londonLow) || l1 < _prevDayLow;
                    bool strongBull = c1 > o1 && (body / range >= 0.5) && body >= 10 * PipSize;
                    if (sweepLow && strongBull) { _signalText = "NY BUY | Sweep+Displacement"; _signalDir = 1; if (AlertOnSignal) Alert("XAUUSD NY BUY"); }
                    else
                    {
                        bool sweepHigh = h1 > _asiaHigh || (_londonValid && h1 > _londonHigh) || h1 > _prevDayHigh;
                        bool strongBear = c1 < o1 && (body / range >= 0.5) && body >= 10 * PipSize;
                        if (sweepHigh && strongBear) { _signalText = "NY SELL | Sweep+Displacement"; _signalDir = -1; if (AlertOnSignal) Alert("XAUUSD NY SELL"); }
                    }
                }
            }
        }

        private double GetSweepLowBullish(int index)
        {
            double sweepLow = double.MaxValue;
            for (int i = index - 1; i >= index - 50 && i >= 0; i--)
            {
                double h = Bars.HighPrices[i], l = Bars.LowPrices[i], c = Bars.ClosePrices[i];
                if (h > _asiaHigh) { sweepLow = Math.Min(sweepLow, l); if (c < _asiaHigh) return sweepLow; }
            }
            return sweepLow < double.MaxValue ? sweepLow : 0;
        }

        private double GetSweepHighBearish(int index)
        {
            double sweepHigh = 0;
            for (int i = index - 1; i >= index - 50 && i >= 0; i--)
            {
                double h = Bars.HighPrices[i], l = Bars.LowPrices[i], c = Bars.ClosePrices[i];
                if (l < _asiaLow) { sweepHigh = Math.Max(sweepHigh, h); if (c > _asiaLow) return sweepHigh; }
            }
            return sweepHigh;
        }

        private void DrawLevels(int index)
        {
            var t = Bars.OpenTimes[index];
            double price = Bars.ClosePrices[Math.Min(index, Bars.Count - 1)];

            if (_asiaValid)
            {
                Chart.DrawTrendLine("AsiaH", t, _asiaHigh, t.AddHours(24), _asiaHigh, Color.DodgerBlue, 2);
                Chart.DrawTrendLine("AsiaL", t, _asiaLow, t.AddHours(24), _asiaLow, Color.Crimson, 2);
                Chart.DrawTrendLine("AsiaMid", t, _asiaMid, t.AddHours(24), _asiaMid, Color.Gold, 2);
            }
            if (_londonValid)
            {
                Chart.DrawTrendLine("LondonH", t, _londonHigh, t.AddHours(24), _londonHigh, Color.Gray, 1);
                Chart.DrawTrendLine("LondonL", t, _londonLow, t.AddHours(24), _londonLow, Color.Gray, 1);
            }
            Chart.DrawTrendLine("PrevH", t, _prevDayHigh, t.AddHours(24), _prevDayHigh, Color.DarkGray, 1);
            Chart.DrawTrendLine("PrevL", t, _prevDayLow, t.AddHours(24), _prevDayLow, Color.DarkGray, 1);

            if (_signalDir == 1)
                Chart.DrawIcon("Signal", ChartIconType.UpArrow, t, price, Color.LimeGreen);
            else if (_signalDir == -1)
                Chart.DrawIcon("Signal", ChartIconType.DownArrow, t, price, Color.Red);
        }

        private void DrawInfoPanel(DateTime serverTime)
        {
            string txt = "=== XAUUSD Session Strategy ===\n";
            txt += $"Time: {serverTime.Hour}:{serverTime.Minute}\n\n";
            txt += _asiaValid ? $"Asia: {_asiaHigh:F2} / {_asiaMid:F2} / {_asiaLow:F2}\n" : "Asia: Building...\n";
            txt += _londonValid ? $"London: {_londonHigh:F2} - {_londonLow:F2}\n" : "";
            txt += $"Prev Day: {_prevDayHigh:F2} / {_prevDayLow:F2}\n\n";
            txt += _signalText != "" ? $">>> {_signalText} <<<\n" : "No signal — wait for sweep + close back\n";

            Chart.DrawStaticText("Panel", txt, VerticalAlignment.Top, HorizontalAlignment.Left, Color.White);
        }
    }
}

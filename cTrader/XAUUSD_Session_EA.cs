// ---------------------------------------------------------------------------
// XAUUSD_Session_EA.cs
// XAUUSD Asia/NY Session-Based cBot
// Based on EA-LOGIC-SPECIFICATION.md
// REQUIRED: Attach to XAUUSD M5 chart
// ---------------------------------------------------------------------------

using System;
using System.Collections.Generic;
using System.Linq;
using cAlgo.API;
using cAlgo.API.Indicators;
using cAlgo.API.Internals;

namespace cAlgo.Robots
{
    [Robot(TimeZone = TimeZones.UTC, AccessRights = AccessRights.None)]
    public class XAUUSD_Session_EA : Robot
    {
        // --- Risk ---
        [Parameter("Risk per trade (%)", Group = "Risk", DefaultValue = 0.5)]
        public double RiskPercent { get; set; }

        [Parameter("Daily loss limit (%)", Group = "Risk", DefaultValue = 3.0)]
        public double DailyLossLimitPercent { get; set; }

        [Parameter("Drawdown limit (%)", Group = "Risk", DefaultValue = 10.0)]
        public double DrawdownLimitPercent { get; set; }

        // --- Asia Session ---
        [Parameter("Asia range start (hour)", Group = "Asia", DefaultValue = 19)]
        public int AsiaRangeStart { get; set; }

        [Parameter("Asia range end (hour)", Group = "Asia", DefaultValue = 23)]
        public int AsiaRangeEnd { get; set; }

        [Parameter("Asia trade window end (hour)", Group = "Asia", DefaultValue = 2)]
        public int AsiaTradeWindowEnd { get; set; }

        // --- London Session ---
        [Parameter("London start (hour)", Group = "London", DefaultValue = 2)]
        public int LondonStart { get; set; }

        [Parameter("London end (hour)", Group = "London", DefaultValue = 6)]
        public int LondonEnd { get; set; }

        // --- NY Session ---
        [Parameter("NY start (hour)", Group = "NY", DefaultValue = 7)]
        public int NYStartHour { get; set; }

        [Parameter("NY start (minute)", Group = "NY", DefaultValue = 30)]
        public int NYStartMinute { get; set; }

        [Parameter("NY end (hour)", Group = "NY", DefaultValue = 11)]
        public int NYEnd { get; set; }

        // --- Trade Settings ---
        [Parameter("Sweep buffer (pips)", Group = "Trade", DefaultValue = 5)]
        public int SweepBufferPips { get; set; }

        [Parameter("NY displacement min (pips)", Group = "Trade", DefaultValue = 10)]
        public int DisplacementMinPips { get; set; }

        [Parameter("NY strong candle body (%)", Group = "Trade", DefaultValue = 50)]
        public int StrongCandleBodyPct { get; set; }

        [Parameter("NY TP risk:reward", Group = "Trade", DefaultValue = 2.0)]
        public double NY_TP_RR { get; set; }

        [Parameter("Use TP2 runner (Asia)", Group = "Trade", DefaultValue = true)]
        public bool UseTP2_Asia { get; set; }

        [Parameter("Partial close % at TP1 (Asia)", Group = "Trade", DefaultValue = 50)]
        public int PartialClosePct_Asia { get; set; }

        [Parameter("Move SL to BE at midline (Asia)", Group = "Trade", DefaultValue = true)]
        public bool MoveSLtoBE_Asia { get; set; }

        [Parameter("Move SL to BE at 1R profit (NY)", Group = "Trade", DefaultValue = true)]
        public bool MoveSLtoBE_NY { get; set; }

        [Parameter("Magic number", Group = "Trade", DefaultValue = 202503)]
        public int MagicNumber { get; set; }

        // --- State ---
        private DateTime _lastBarTime = DateTime.MinValue;
        private int _lastBarDay = -1;

        private double _asiaHigh, _asiaLow, _asiaMid;
        private bool _asiaRangeValid;
        private int _asiaTradesToday;

        private double _londonHigh, _londonLow;
        private bool _londonRangeValid;

        private double _prevDayHigh, _prevDayLow;
        private int _nyTradesToday;

        private const string Label = "XAUUSD_Session";

        protected override void OnStart()
        {
            Print("XAUUSD Session EA started");
        }

        protected override void OnBar()
        {
            var serverTime = Server.Time;
            int hour = serverTime.Hour;
            int day = serverTime.Day;

            // New day reset
            if (day != _lastBarDay)
            {
                OnNewDay();
                _lastBarDay = day;
            }

            // Guardrails
            if (IsDailyLossBreached() || IsDrawdownBreached())
                return;

            // Build Asia range
            if (IsInAsiaRangeWindow(hour))
                UpdateAsiaRange();

            // Build London range
            if (IsInLondonRangeWindow(hour))
                UpdateLondonRange();

            // Asia trade logic
            if (IsInAsiaTradeWindow(hour) && _asiaRangeValid && _asiaTradesToday < 1)
                ProcessAsiaLogic();

            // NY trade logic
            if (IsInNYWindow(serverTime) && _nyTradesToday < 1)
                ProcessNYLogic();

            // Manage positions
            ManagePositions();
        }

        protected override void OnStop()
        {
            Print("XAUUSD Session EA stopped");
        }

        private double PipSize => Symbol.PipSize;

        private double PipsToPrice(double pips) => pips * PipSize;

        private void OnNewDay()
        {
            _asiaTradesToday = 0;
            _nyTradesToday = 0;
            _asiaRangeValid = false;
            _londonRangeValid = false;

            var yesterday = Server.Time.Date.AddDays(-1);
            double high = 0, low = double.MaxValue;
            for (int i = 1; i < Bars.Count; i++)
            {
                var t = Bars.OpenTimes[i];
                if (t.Date > yesterday) continue;
                if (t.Date < yesterday) break;
                high = Math.Max(high, Bars.HighPrices[i]);
                low = Math.Min(low, Bars.LowPrices[i]);
            }
            if (low < double.MaxValue)
            {
                _prevDayHigh = high;
                _prevDayLow = low;
            }
        }

        private bool IsInAsiaRangeWindow(int hour)
        {
            if (AsiaRangeStart <= AsiaRangeEnd)
                return hour >= AsiaRangeStart && hour < AsiaRangeEnd;
            return hour >= AsiaRangeStart || hour < AsiaRangeEnd;
        }

        private bool IsInAsiaTradeWindow(int hour)
        {
            if (AsiaRangeEnd <= AsiaTradeWindowEnd)
                return hour >= AsiaRangeEnd && hour < AsiaTradeWindowEnd;
            return hour >= AsiaRangeEnd || hour < AsiaTradeWindowEnd;
        }

        private bool IsInLondonRangeWindow(int hour)
        {
            if (LondonStart <= LondonEnd)
                return hour >= LondonStart && hour < LondonEnd;
            return hour >= LondonStart || hour < LondonEnd;
        }

        private bool IsInNYWindow(DateTime serverTime)
        {
            int hour = serverTime.Hour;
            int min = serverTime.Minute;
            if (hour < NYStartHour) return false;
            if (hour == NYStartHour && min < NYStartMinute) return false;
            return hour < NYEnd;
        }

        private void UpdateAsiaRange()
        {
            var serverTime = Server.Time;
            var rangeStart = new DateTime(serverTime.Year, serverTime.Month, serverTime.Day, AsiaRangeStart, 0, 0);
            var rangeEnd = new DateTime(serverTime.Year, serverTime.Month, serverTime.Day, AsiaRangeEnd, 0, 0);
            if (rangeEnd <= rangeStart) rangeEnd = rangeEnd.AddDays(1);

            double high = 0, low = double.MaxValue;
            for (int i = Bars.Count - 1; i >= 0; i--)
            {
                var t = Bars.OpenTimes[i];
                if (t < rangeStart) continue;
                if (t >= rangeEnd) break;

                double h = Bars.HighPrices[i];
                double l = Bars.LowPrices[i];
                if (h > high) high = h;
                if (l < low) low = l;
            }
            if (low < double.MaxValue)
            {
                _asiaHigh = high;
                _asiaLow = low;
                _asiaMid = (high + low) / 2.0;
                _asiaRangeValid = true;
            }
        }

        private void UpdateLondonRange()
        {
            var serverTime = Server.Time;
            var rangeStart = new DateTime(serverTime.Year, serverTime.Month, serverTime.Day, LondonStart, 0, 0);
            var rangeEnd = new DateTime(serverTime.Year, serverTime.Month, serverTime.Day, LondonEnd, 0, 0);
            if (rangeEnd <= rangeStart) rangeEnd = rangeEnd.AddDays(1);

            double high = 0, low = double.MaxValue;
            for (int i = Bars.Count - 1; i >= 0; i--)
            {
                var t = Bars.OpenTimes[i];
                if (t < rangeStart) continue;
                if (t >= rangeEnd) break;

                double h = Bars.HighPrices[i];
                double l = Bars.LowPrices[i];
                if (h > high) high = h;
                if (l < low) low = l;
            }
            if (low < double.MaxValue)
            {
                _londonHigh = high;
                _londonLow = low;
                _londonRangeValid = true;
            }
        }

        private void ProcessAsiaLogic()
        {
            if (Bars.Count < 3) return;

            int i = 1;
            double open1 = Bars.OpenPrices[i];
            double high1 = Bars.HighPrices[i];
            double low1 = Bars.LowPrices[i];
            double close1 = Bars.ClosePrices[i];

            // Bullish sweep → BUY (target up to midline/top)
            if (high1 > _asiaHigh && close1 < _asiaHigh)
            {
                double sweepLow = GetSweepLowBullish();
                if (sweepLow > 0)
                {
                    double sl = sweepLow - PipsToPrice(SweepBufferPips);
                    double tp1 = _asiaMid;
                    double tp2 = UseTP2_Asia ? _asiaHigh : 0;  // BUY targets UP
                    OpenAsiaTrade(TradeType.Buy, sl, tp1, tp2);
                }
                return;
            }

            // Bearish sweep → SELL (target down to midline/bottom)
            if (low1 < _asiaLow && close1 > _asiaLow)
            {
                double sweepHigh = GetSweepHighBearish();
                if (sweepHigh > 0)
                {
                    double sl = sweepHigh + PipsToPrice(SweepBufferPips);
                    double tp1 = _asiaMid;
                    double tp2 = UseTP2_Asia ? _asiaLow : 0;   // SELL targets DOWN
                    OpenAsiaTrade(TradeType.Sell, sl, tp1, tp2);
                }
                return;
            }
        }

        private double GetSweepLowBullish()
        {
            double sweepLow = double.MaxValue;
            for (int i = 1; i < Math.Min(50, Bars.Count); i++)
            {
                double h = Bars.HighPrices[i];
                double l = Bars.LowPrices[i];
                double c = Bars.ClosePrices[i];
                if (h > _asiaHigh)
                {
                    if (l < sweepLow) sweepLow = l;
                    if (c < _asiaHigh) return sweepLow;
                }
            }
            return sweepLow < double.MaxValue ? sweepLow : 0;
        }

        private double GetSweepHighBearish()
        {
            double sweepHigh = 0;
            for (int i = 1; i < Math.Min(50, Bars.Count); i++)
            {
                double h = Bars.HighPrices[i];
                double l = Bars.LowPrices[i];
                double c = Bars.ClosePrices[i];
                if (l < _asiaLow)
                {
                    if (h > sweepHigh) sweepHigh = h;
                    if (c > _asiaLow) return sweepHigh;
                }
            }
            return sweepHigh;
        }

        private void OpenAsiaTrade(TradeType type, double slPrice, double tp1Price, double tp2Price)
        {
            double price = type == TradeType.Buy ? Symbol.Ask : Symbol.Bid;
            double slDist = Math.Abs(price - slPrice);
            double volume = CalcVolumeInUnits(slDist);
            if (volume <= 0) return;

            volume = Symbol.NormalizeVolumeInUnits(volume);
            double tpPrice = (tp2Price > 0 && PartialClosePct_Asia > 0) ? tp1Price : (tp2Price > 0 ? tp2Price : tp1Price);
            string label = "Asia_" + (type == TradeType.Buy ? "L" : "S");

            // cTrader expects SL/TP in pips (distance from entry)
            double? slPips = type == TradeType.Buy ? (price - slPrice) / PipSize : (slPrice - price) / PipSize;
            double? tpPips = type == TradeType.Buy ? (tpPrice - price) / PipSize : (price - tpPrice) / PipSize;
            // Skip if invalid (wrong direction - would cause "Invalid stops")
            if (slPips <= 0 || (tpPips.HasValue && tpPips.Value < 0)) return;

            var result = ExecuteMarketOrder(type, SymbolName, volume, label, slPips, tpPips);
            if (result.IsSuccessful)
            {
                _asiaTradesToday++;
                Print("Asia trade opened: ", label);
            }
            else
                Print("Asia trade failed: ", result.Error);
        }

        private void ProcessNYLogic()
        {
            if (!_asiaRangeValid || Bars.Count < 3) return;

            int i = 1;
            double open1 = Bars.OpenPrices[i];
            double high1 = Bars.HighPrices[i];
            double low1 = Bars.LowPrices[i];
            double close1 = Bars.ClosePrices[i];
            double body = Math.Abs(close1 - open1);
            double range = high1 - low1;
            if (range <= 0) return;

            // Bullish
            bool sweepLow = low1 < _asiaLow || (_londonRangeValid && low1 < _londonLow) || low1 < _prevDayLow;
            bool strongBull = close1 > open1 && (body / range >= StrongCandleBodyPct / 100.0);
            if (sweepLow && strongBull && body >= PipsToPrice(DisplacementMinPips))
            {
                double entry = open1 + (close1 - open1) * 0.5;
                double sl = low1 - PipsToPrice(SweepBufferPips);
                double slDist = Math.Abs(entry - sl);
                double tpDist = slDist * NY_TP_RR;
                double tp = entry + tpDist;
                OpenNYTrade(TradeType.Buy, sl, tp);
                return;
            }

            // Bearish
            bool sweepHigh = high1 > _asiaHigh || (_londonRangeValid && high1 > _londonHigh) || high1 > _prevDayHigh;
            bool strongBear = close1 < open1 && (body / range >= StrongCandleBodyPct / 100.0);
            if (sweepHigh && strongBear && body >= PipsToPrice(DisplacementMinPips))
            {
                double entry = close1 + (open1 - close1) * 0.5;
                double sl = high1 + PipsToPrice(SweepBufferPips);
                double slDist = Math.Abs(entry - sl);
                double tpDist = slDist * NY_TP_RR;
                double tp = entry - tpDist;
                OpenNYTrade(TradeType.Sell, sl, tp);
            }
        }

        private void OpenNYTrade(TradeType type, double slPrice, double tpPrice)
        {
            double price = type == TradeType.Buy ? Symbol.Ask : Symbol.Bid;
            double slDist = Math.Abs(price - slPrice);
            double volume = CalcVolumeInUnits(slDist);
            if (volume <= 0) return;

            volume = Symbol.NormalizeVolumeInUnits(volume);
            string label = "NY_" + (type == TradeType.Buy ? "L" : "S");

            double? slPips = type == TradeType.Buy ? (price - slPrice) / PipSize : (slPrice - price) / PipSize;
            double? tpPips = type == TradeType.Buy ? (tpPrice - price) / PipSize : (price - tpPrice) / PipSize;
            if (slPips < 0) slPips = null;
            if (tpPips < 0) tpPips = null;

            var result = ExecuteMarketOrder(type, SymbolName, volume, label, slPips, tpPips);
            if (result.IsSuccessful)
            {
                _nyTradesToday++;
                Print("NY trade opened: ", label);
            }
            else
                Print("NY trade failed: ", result.Error);
        }

        private double CalcVolumeInUnits(double slDistancePrice)
        {
            double balance = Account.Balance;
            double riskAmount = balance * RiskPercent / 100.0;
            double slPips = slDistancePrice / PipSize;
            if (slPips <= 0) return 0;

            double pipValue = Symbol.PipValue;
            if (pipValue <= 0) return 0;

            double volumeInUnits = riskAmount / (slPips * pipValue);
            return Symbol.NormalizeVolumeInUnits(volumeInUnits);
        }

        private bool IsDailyLossBreached()
        {
            double balance = Account.Balance;
            double equity = Account.Equity;
            double dailyPnL = equity - balance;
            double limit = balance * DailyLossLimitPercent / 100.0;
            return dailyPnL <= -limit;
        }

        private bool IsDrawdownBreached()
        {
            double balance = Account.Balance;
            double equity = Account.Equity;
            if (balance <= 0) return true;
            double dd = (balance - equity) / balance * 100.0;
            return dd >= DrawdownLimitPercent;
        }

        private void ManagePositions()
        {
            var positions = Positions.Where(p => p.SymbolName == SymbolName &&
                (p.Label.StartsWith("Asia") || p.Label.StartsWith("NY")));
            foreach (var pos in positions)
            {
                double price = pos.TradeType == TradeType.Buy ? Symbol.Bid : Symbol.Ask;
                double buffer = PipsToPrice(2);

                // Asia: move SL to BE at midline
                if (pos.Label.StartsWith("Asia") && MoveSLtoBE_Asia && _asiaRangeValid)
                {
                    if (pos.TradeType == TradeType.Buy && price >= _asiaMid - buffer && (pos.StopLoss == null || pos.StopLoss < pos.EntryPrice - buffer))
                        ModifyPosition(pos, pos.EntryPrice, pos.TakeProfit, ProtectionType.Absolute);
                    else if (pos.TradeType == TradeType.Sell && price <= _asiaMid + buffer && (pos.StopLoss == null || pos.StopLoss > pos.EntryPrice + buffer))
                        ModifyPosition(pos, pos.EntryPrice, pos.TakeProfit, ProtectionType.Absolute);
                }

                // NY: move SL to BE when 1R in profit
                if (pos.Label.StartsWith("NY") && MoveSLtoBE_NY && pos.StopLoss != null)
                {
                    double oneR = pos.TradeType == TradeType.Buy
                        ? (pos.EntryPrice - pos.StopLoss.Value)
                        : (pos.StopLoss.Value - pos.EntryPrice);
                    bool triggerBE = pos.TradeType == TradeType.Buy
                        ? price >= pos.EntryPrice + oneR - buffer
                        : price <= pos.EntryPrice - oneR + buffer;
                    bool notYetBE = pos.TradeType == TradeType.Buy
                        ? pos.StopLoss < pos.EntryPrice - buffer
                        : pos.StopLoss > pos.EntryPrice + buffer;
                    if (triggerBE && notYetBE)
                        ModifyPosition(pos, pos.EntryPrice, pos.TakeProfit, ProtectionType.Absolute);
                }
            }
        }
    }
}

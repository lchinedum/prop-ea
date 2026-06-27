using System;
using cAlgo.API;
using cAlgo.API.Internals;

namespace cAlgo.Indicators
{
    [Indicator(IsOverlay = true, TimeZone = TimeZones.UTC, AccessRights = AccessRights.None)]
    public class SessionSweepLiquidityGrabIndicator : Indicator
    {
        [Parameter("Asia Start Hour", DefaultValue = 0)]
        public int AsiaStartHour { get; set; }

        [Parameter("Asia End Hour", DefaultValue = 8)]
        public int AsiaEndHour { get; set; }

        [Parameter("London Start Hour", DefaultValue = 8)]
        public int LondonStartHour { get; set; }

        [Parameter("London End Hour", DefaultValue = 16)]
        public int LondonEndHour { get; set; }

        [Parameter("New York Start Hour", DefaultValue = 13)]
        public int NewYorkStartHour { get; set; }

        [Parameter("New York End Hour", DefaultValue = 21)]
        public int NewYorkEndHour { get; set; }

        [Parameter("Prev Session High Color", DefaultValue = "Red")]
        public Color PrevSessionHighColor { get; set; }

        [Parameter("Prev Session Low Color", DefaultValue = "DeepSkyBlue")]
        public Color PrevSessionLowColor { get; set; }

        [Parameter("Notify On Sweep", DefaultValue = true)]
        public bool NotifyOnSweep { get; set; }

        [Parameter("Notify On Reversal Confirm", DefaultValue = true)]
        public bool NotifyOnReversalConfirm { get; set; }

        [Parameter("Notify On Continuation Confirm", DefaultValue = true)]
        public bool NotifyOnContinuationConfirm { get; set; }

        [Parameter("Allow Repeat Alerts", DefaultValue = false)]
        public bool AllowRepeatAlerts { get; set; }

        private int _currentSessionId;
        private int _prevSessionId;
        private bool _buildInit;
        private double _buildHigh;
        private double _buildLow;
        private bool _prevLevelsReady;
        private double _prevSessionHigh;
        private double _prevSessionLow;

        private bool _highSwept;
        private bool _lowSwept;
        private int _highInsideCloses;
        private int _highOutsideCloses;
        private int _lowInsideCloses;
        private int _lowOutsideCloses;
        private bool _highReversalSent;
        private bool _highContinuationSent;
        private bool _lowReversalSent;
        private bool _lowContinuationSent;

        protected override void Initialize()
        {
            ResetConfirmState();
        }

        public override void Calculate(int index)
        {
            if (index < 2)
                return;

            int closed = index - 1;
            DateTime t = Bars.OpenTimes[closed];
            int sessionId = SessionIdFromHour(t.Hour);
            if (sessionId == 0)
                return;

            double h = Bars.HighPrices[closed];
            double l = Bars.LowPrices[closed];
            double c = Bars.ClosePrices[closed];

            if (_currentSessionId == 0 || sessionId != _currentSessionId)
            {
                HandleNewSession(sessionId, h, l, closed);
            }
            else
            {
                _buildHigh = Math.Max(_buildHigh, h);
                _buildLow = Math.Min(_buildLow, l);
            }

            if (!_prevLevelsReady || _currentSessionId == _prevSessionId)
                return;

            bool highSweepThisBar = false;
            bool lowSweepThisBar = false;
            bool highReversalThisBar = false;
            bool highContinuationThisBar = false;
            bool lowReversalThisBar = false;
            bool lowContinuationThisBar = false;

            if (!_highSwept && h > _prevSessionHigh)
            {
                _highSwept = true;
                highSweepThisBar = true;
            }

            if (!_lowSwept && l < _prevSessionLow)
            {
                _lowSwept = true;
                lowSweepThisBar = true;
            }

            if (_highSwept)
            {
                if (c < _prevSessionHigh)
                {
                    _highInsideCloses++;
                    _highOutsideCloses = 0;
                }
                else if (c > _prevSessionHigh)
                {
                    _highOutsideCloses++;
                    _highInsideCloses = 0;
                }
                else
                {
                    _highInsideCloses = 0;
                    _highOutsideCloses = 0;
                }

                if (_highInsideCloses >= 2 && (AllowRepeatAlerts || !_highReversalSent))
                {
                    _highReversalSent = true;
                    highReversalThisBar = true;
                }
                if (_highOutsideCloses >= 2 && (AllowRepeatAlerts || !_highContinuationSent))
                {
                    _highContinuationSent = true;
                    highContinuationThisBar = true;
                }
            }

            if (_lowSwept)
            {
                if (c > _prevSessionLow)
                {
                    _lowInsideCloses++;
                    _lowOutsideCloses = 0;
                }
                else if (c < _prevSessionLow)
                {
                    _lowOutsideCloses++;
                    _lowInsideCloses = 0;
                }
                else
                {
                    _lowInsideCloses = 0;
                    _lowOutsideCloses = 0;
                }

                if (_lowInsideCloses >= 2 && (AllowRepeatAlerts || !_lowReversalSent))
                {
                    _lowReversalSent = true;
                    lowReversalThisBar = true;
                }
                if (_lowOutsideCloses >= 2 && (AllowRepeatAlerts || !_lowContinuationSent))
                {
                    _lowContinuationSent = true;
                    lowContinuationThisBar = true;
                }
            }

            string tag = t.ToString("yyyyMMddHHmm");
            if (highSweepThisBar)
                Chart.DrawIcon($"SSLG_HS_{tag}", ChartIconType.DownArrow, t, h, Color.Orange);
            if (lowSweepThisBar)
                Chart.DrawIcon($"SSLG_LS_{tag}", ChartIconType.UpArrow, t, l, Color.Magenta);
            if (highReversalThisBar)
                Chart.DrawText($"SSLG_HR_{tag}", "REV S", t, h, Color.Red);
            if (highContinuationThisBar)
                Chart.DrawText($"SSLG_HC_{tag}", "CONT L", t, h, Color.LimeGreen);
            if (lowReversalThisBar)
                Chart.DrawText($"SSLG_LR_{tag}", "REV L", t, l, Color.Lime);
            if (lowContinuationThisBar)
                Chart.DrawText($"SSLG_LC_{tag}", "CONT S", t, l, Color.Maroon);

            if (NotifyOnSweep && (highSweepThisBar || lowSweepThisBar))
                Print($"SSLG Sweep: {SymbolName} TF={TimeFrame} Prev={SessionName(_prevSessionId)} H={_prevSessionHigh:F5} L={_prevSessionLow:F5}");
            if (NotifyOnReversalConfirm && (highReversalThisBar || lowReversalThisBar))
                Print($"SSLG Reversal Confirmed: {SymbolName} TF={TimeFrame}");
            if (NotifyOnContinuationConfirm && (highContinuationThisBar || lowContinuationThisBar))
                Print($"SSLG Continuation Confirmed: {SymbolName} TF={TimeFrame}");

            DrawPanel();
        }

        private void HandleNewSession(int sessionId, double firstHigh, double firstLow, int index)
        {
            _prevSessionId = _currentSessionId;
            if (_buildInit)
            {
                _prevSessionHigh = _buildHigh;
                _prevSessionLow = _buildLow;
                _prevLevelsReady = true;
                DrawPrevLevels(index);
            }

            _currentSessionId = sessionId;
            _buildHigh = firstHigh;
            _buildLow = firstLow;
            _buildInit = true;
            ResetConfirmState();
        }

        private void DrawPrevLevels(int index)
        {
            DateTime start = Bars.OpenTimes[Math.Max(0, index - 1)];
            DateTime end = start.AddHours(24);

            Chart.DrawTrendLine("SSLG_PrevHigh", start, _prevSessionHigh, end, _prevSessionHigh, PrevSessionHighColor, 2, LineStyle.DotsVeryRare);
            Chart.DrawTrendLine("SSLG_PrevLow", start, _prevSessionLow, end, _prevSessionLow, PrevSessionLowColor, 2, LineStyle.DotsVeryRare);
        }

        private void DrawPanel()
        {
            string text = "Session Sweep Liquidity Grab\n";
            text += $"Current Session: {SessionName(_currentSessionId)}\n";
            text += $"Prev Session: {SessionName(_prevSessionId)}\n";
            text += _prevLevelsReady
                ? $"Prev H/L: {_prevSessionHigh:F5} / {_prevSessionLow:F5}\n"
                : "Prev H/L: waiting...\n";
            text += $"HighSwept={_highSwept} LowSwept={_lowSwept}";

            Chart.DrawStaticText("SSLG_PANEL", text, VerticalAlignment.Top, HorizontalAlignment.Right, Color.White);
        }

        private void ResetConfirmState()
        {
            _highSwept = false;
            _lowSwept = false;
            _highInsideCloses = 0;
            _highOutsideCloses = 0;
            _lowInsideCloses = 0;
            _lowOutsideCloses = 0;
            _highReversalSent = false;
            _highContinuationSent = false;
            _lowReversalSent = false;
            _lowContinuationSent = false;
        }

        private int SessionIdFromHour(int h)
        {
            if (h >= AsiaStartHour && h < AsiaEndHour) return 1;
            if (h >= LondonStartHour && h < LondonEndHour) return 2;
            if (h >= NewYorkStartHour && h < NewYorkEndHour) return 3;
            return 0;
        }

        private string SessionName(int id)
        {
            if (id == 1) return "Asia";
            if (id == 2) return "London";
            if (id == 3) return "NewYork";
            return "None";
        }
    }
}

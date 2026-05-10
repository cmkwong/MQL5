#property indicator_chart_window
#property indicator_plots 1
#property indicator_buffers 1

#property indicator_label1 "VolumeSupportLine"
#property indicator_type1 DRAW_LINE
#property indicator_color1 clrLime
#property indicator_style1 STYLE_SOLID
#property indicator_width1 2

enum ENUM_SR_LINE_MODE {
   SR_LINE_AUTO = 0,
   SR_LINE_SUPPORT,
   SR_LINE_RESISTANCE
};

input int               LookbackBars     = 300;            // Maximum bars to scan back
input bool              UseDayLookback   = true;           // Use day-based lookback window
input int               LookbackDays     = 90;             // Number of days to include when day lookback is enabled
input ENUM_SR_LINE_MODE SelectedLineMode = SR_LINE_AUTO;   // Auto, Support, or Resistance
input int               PivotWindow      = 3;              // Bars on each side to confirm a pivot
input int               VolumeMAPeriod   = 20;             // Volume moving-average period
input double            VolumeMultiplier = 1.5;            // Volume expansion multiplier
input bool              UseTickVolume    = true;           // true = Tick Volume, false = Real Volume (if available)

double SupportBuffer[];

int OnInit() {
   SetIndexBuffer(0, SupportBuffer, INDICATOR_DATA);
   ArraySetAsSeries(SupportBuffer, true);
   IndicatorSetString(INDICATOR_SHORTNAME, "Volume Support Line (MT5)");
   return (INIT_SUCCEEDED);
}

// Check whether a bar is a local pivot low
bool IsLocalPivotLow(const int     shift,
                     const int     total,
                     const int     window,
                     const double &low[]) {
   if(shift < window || shift + window >= total)
      return (false);

   double pivotLowPrice = low[shift];

   for(int offset = 1; offset <= window; offset++) {
      if(pivotLowPrice >= low[shift - offset])
         return (false);
      if(pivotLowPrice > low[shift + offset])
         return (false);
   }

   return (true);
}

// Check whether a bar is a local pivot high
bool IsLocalPivotHigh(const int     shift,
                      const int     total,
                      const int     window,
                      const double &high[]) {
   if(shift < window || shift + window >= total)
      return (false);

   double pivotHighPrice = high[shift];

   for(int offset = 1; offset <= window; offset++) {
      if(pivotHighPrice <= high[shift - offset])
         return (false);
      if(pivotHighPrice < high[shift + offset])
         return (false);
   }

   return (true);
}

// Get average volume from the specified bar forward in series indexing
double GetVolumeMA(const int   shift,
                   const int   total,
                   const int   period,
                   const long &tick_volume[],
                   const long &volume[],
                   const bool  useTickVolume) {
   if(shift + period >= total)
      return (0.0);

   double volumeSum = 0.0;
   for(int i = 0; i < period; i++) {
      int barIndex  = shift + i;
      volumeSum    += (useTickVolume ? (double)tick_volume[barIndex] : (double)volume[barIndex]);
   }

   return (volumeSum / period);
}

// Convert a day-based lookback window into bars on the current chart
int GetDayLookbackBars(const datetime &time[], const int rates_total, const int lookbackDays) {
   if(lookbackDays <= 0)
      return (rates_total - 1);

   datetime cutoffTime = time[0] - (datetime)(lookbackDays * 86400);
   int      barsInDays = 0;

   for(int i = 0; i < rates_total; i++) {
      if(time[i] < cutoffTime)
         break;
      barsInDays = i;
   }

   return (barsInDays);
}

// Find latest two volume-qualified pivots (low or high)
bool FindQualifiedPivots(const bool    findLows,
                         const int     rates_total,
                         const int     maxScanBars,
                         const int     pivotWindow,
                         const int     volumeMAPeriod,
                         const double  volumeMultiplier,
                         const bool    useTickVolume,
                         const double &low[],
                         const double &high[],
                         const long   &tick_volume[],
                         const long   &volume[],
                         int          &latestPivotShift,
                         int          &previousPivotShift) {
   latestPivotShift   = -1;
   previousPivotShift = -1;

   for(int i = pivotWindow + 1; i < maxScanBars; i++) {
      bool isPivot = (findLows ?
                          IsLocalPivotLow(i, rates_total, pivotWindow, low) :
                          IsLocalPivotHigh(i, rates_total, pivotWindow, high));
      if(!isPivot)
         continue;

      double averageVolume = GetVolumeMA(i, rates_total, volumeMAPeriod, tick_volume, volume, useTickVolume);
      if(averageVolume <= 0.0)
         continue;

      double currentVolume = (useTickVolume ? (double)tick_volume[i] : (double)volume[i]);

      if(currentVolume >= averageVolume * volumeMultiplier) {
         if(latestPivotShift == -1)
            latestPivotShift = i;
         else {
            previousPivotShift = i;
            break;
         }
      }
   }

   return (latestPivotShift != -1 && previousPivotShift != -1);
}

// Build a line from two pivots and return slope + anchor point
bool BuildLineFromPivots(const int     latestPivotShift,
                         const int     previousPivotShift,
                         const double &priceSeries[],
                         double       &slope,
                         double       &anchorX,
                         double       &anchorY) {
   anchorX = (double)previousPivotShift;
   anchorY = priceSeries[previousPivotShift];

   double newerX = (double)latestPivotShift;
   double newerY = priceSeries[latestPivotShift];

   if(anchorX == newerX)
      return (false);

   slope = (newerY - anchorY) / (newerX - anchorX);
   return (true);
}

double GetLinePriceAtShift(const double slope, const double anchorX, const double anchorY, const int shift) {
   return (anchorY + slope * ((double)shift - anchorX));
}

int OnCalculate(const int       rates_total,
                const int       prev_calculated,
                const datetime &time[],
                const double   &open[],
                const double   &high[],
                const double   &low[],
                const double   &close[],
                const long     &tick_volume[],
                const long     &volume[],
                const int      &spread[]) {
   if(rates_total < PivotWindow + VolumeMAPeriod + 10)
      return (0);

   ArraySetAsSeries(time, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(tick_volume, true);
   ArraySetAsSeries(volume, true);

   for(int i = 0; i < rates_total; i++)
      SupportBuffer[i] = EMPTY_VALUE;

   int selectedLookbackBars = LookbackBars;
   if(UseDayLookback)
      selectedLookbackBars = MathMin(selectedLookbackBars, GetDayLookbackBars(time, rates_total, LookbackDays));

   int maxScanBars = MathMin(selectedLookbackBars, rates_total - PivotWindow - VolumeMAPeriod - 2);
   if(maxScanBars <= PivotWindow + 1)
      return (rates_total);

   int  latestSupportPivotShift      = -1;
   int  previousSupportPivotShift    = -1;
   int  latestResistancePivotShift   = -1;
   int  previousResistancePivotShift = -1;
   bool hasSupportPivots             = FindQualifiedPivots(true,
                                                           rates_total,
                                                           maxScanBars,
                                                           PivotWindow,
                                                           VolumeMAPeriod,
                                                           VolumeMultiplier,
                                                           UseTickVolume,
                                                           low,
                                                           high,
                                                           tick_volume,
                                                           volume,
                                                           latestSupportPivotShift,
                                                           previousSupportPivotShift);
   bool hasResistancePivots          = FindQualifiedPivots(false,
                                                           rates_total,
                                                           maxScanBars,
                                                           PivotWindow,
                                                           VolumeMAPeriod,
                                                           VolumeMultiplier,
                                                           UseTickVolume,
                                                           low,
                                                           high,
                                                           tick_volume,
                                                           volume,
                                                           latestResistancePivotShift,
                                                           previousResistancePivotShift);

   double supportSlope      = 0.0;
   double supportAnchorX    = 0.0;
   double supportAnchorY    = 0.0;
   double resistanceSlope   = 0.0;
   double resistanceAnchorX = 0.0;
   double resistanceAnchorY = 0.0;

   bool hasSupportLine    = (hasSupportPivots &&
                             BuildLineFromPivots(latestSupportPivotShift,
                                                 previousSupportPivotShift,
                                                 low,
                                                 supportSlope,
                                                 supportAnchorX,
                                                 supportAnchorY));
   bool hasResistanceLine = (hasResistancePivots &&
                             BuildLineFromPivots(latestResistancePivotShift,
                                                 previousResistancePivotShift,
                                                 high,
                                                 resistanceSlope,
                                                 resistanceAnchorX,
                                                 resistanceAnchorY));

   if(!hasSupportLine && !hasResistanceLine)
      return (rates_total);

   bool drawSupport = true;
   if(SelectedLineMode == SR_LINE_SUPPORT) {
      drawSupport = true;
   } else if(SelectedLineMode == SR_LINE_RESISTANCE) {
      drawSupport = false;
   } else {
      if(hasSupportLine && hasResistanceLine) {
         double supportNow           = GetLinePriceAtShift(supportSlope, supportAnchorX, supportAnchorY, 0);
         double resistanceNow        = GetLinePriceAtShift(resistanceSlope, resistanceAnchorX, resistanceAnchorY, 0);
         double distanceToSupport    = MathAbs(close[0] - supportNow);
         double distanceToResistance = MathAbs(close[0] - resistanceNow);
         drawSupport                 = (distanceToSupport <= distanceToResistance);
      } else {
         drawSupport = hasSupportLine;
      }
   }

   if(drawSupport && !hasSupportLine)
      return (rates_total);
   if(!drawSupport && !hasResistanceLine)
      return (rates_total);

   double selectedSlope   = (drawSupport ? supportSlope : resistanceSlope);
   double selectedAnchorX = (drawSupport ? supportAnchorX : resistanceAnchorX);
   double selectedAnchorY = (drawSupport ? supportAnchorY : resistanceAnchorY);

   // Extend selected support/resistance line across the scan range
   for(int i = 0; i < maxScanBars; i++) {
      double projectedPrice = GetLinePriceAtShift(selectedSlope, selectedAnchorX, selectedAnchorY, i);
      SupportBuffer[i]      = projectedPrice;
   }

   string roleText  = (drawSupport ? "Support" : "Resistance");
   string scopeText = (UseDayLookback ? IntegerToString(LookbackDays) + "D" : IntegerToString(LookbackBars) + "B");
   IndicatorSetString(INDICATOR_SHORTNAME, "Volume " + roleText + " Line (" + scopeText + ")");
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, (drawSupport ? clrLime : clrTomato));

   return (rates_total);
}

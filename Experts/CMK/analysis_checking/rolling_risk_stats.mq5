#property script_show_inputs
#property strict

input string          InpSymbols                        = "EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD,USDCHF,NZDUSD,EURGBP,EURJPY,GBPJPY";   // Comma-separated symbols
input ENUM_TIMEFRAMES InpTimeframe                      = PERIOD_H1;                                                                 // Analysis timeframe
input int             InpBarsToAnalyze                  = 1500;                                                                      // Number of return bars to analyze
input int             InpAnalysisEndShiftBars           = 0;                                                                         // End-bar shift (0=current bar, 1=previous bar) when not using date range
input bool            InpUseDateRange                   = false;                                                                     // true=analyze by date range, false=analyze by bar window
input string          InpAnalysisStartText              = "2025.01.01 00:00";                                                        // Start datetime string for date-range mode
input string          InpAnalysisEndText                = "0";                                                                      // End datetime string for date-range mode ("0"=now)
input bool            InpUseLogReturns                  = true;                                                                      // true=log returns, false=simple returns
input bool            InpReturnAsPercent                = true;                                                                      // true=return units in percent
input int             InpRollingWindow                  = 50;                                                                        // Window for rolling volatility and rolling Sharpe
input int             InpRegimeLookback                 = 300;                                                                       // Lookback windows used to classify volatility regime
input double          InpLowVolPercentile               = 20.0;                                                                      // Low-vol regime percentile
input double          InpHighVolPercentile              = 80.0;                                                                      // High-vol regime percentile
input double          InpRiskFreeRateAnnual             = 0.0;                                                                       // Annual risk-free rate for Sharpe (e.g., 0.02 = 2%)
input double          InpSuitabilityStopDrawdownPct     = 8.0;                                                                       // STOP threshold for current drawdown (%)
input int             InpSuitabilityStopDrawdownBars    = 300;                                                                       // STOP threshold for current drawdown duration (bars)
input double          InpSuitabilityStopSharpe          = -0.50;                                                                     // STOP threshold for rolling Sharpe
input double          InpSuitabilityCautionDrawdownPct  = 4.0;                                                                       // CAUTION threshold for current drawdown (%)
input int             InpSuitabilityCautionDrawdownBars = 120;                                                                       // CAUTION threshold for current drawdown duration (bars)
input double          InpSuitabilityCautionSharpe       = 0.0;                                                                       // CAUTION threshold for rolling Sharpe
input double          InpSuitabilityNearHighVolRatio    = 0.90;                                                                      // CAUTION when current vol is near high threshold
input string          InpOutputCsvPath                  = "analysis_checking/rolling_risk_stats.csv";                                // Output CSV path
input bool            InpUseCommonFiles                 = true;                                                                      // true=Common Files, false=terminal Files

string TrimCopy(const string value) {
   string out = value;
   StringTrimLeft(out);
   StringTrimRight(out);
   return out;
}

string ToUpperCopy(const string value) {
   string out = value;
   StringToUpper(out);
   return out;
}

string ResolveSymbolName(const string requested) {
   string req = TrimCopy(requested);
   if(StringLen(req) == 0)
      return "";

   string reqUp = ToUpperCopy(req);

   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++) {
      string symbol = SymbolName(i, false);
      if(ToUpperCopy(symbol) == reqUp)
         return symbol;
   }

   string best    = "";
   int    bestLen = 100000;
   for(int i = 0; i < total; i++) {
      string symbol = SymbolName(i, false);
      string up     = ToUpperCopy(symbol);
      if(StringFind(up, reqUp) != 0)
         continue;

      int len = StringLen(symbol);
      if(len < bestLen) {
         best    = symbol;
         bestLen = len;
      }
   }

   return best;
}

int FindLastSlashIndex(const string path) {
   int last = -1;
   int len  = StringLen(path);

   for(int i = 0; i < len; i++) {
      ushort ch = (ushort)StringGetCharacter(path, i);
      if(ch == '/' || ch == '\\')
         last = i;
   }

   return last;
}

int FindLastDotIndex(const string text) {
   int last = -1;
   int len  = StringLen(text);

   for(int i = 0; i < len; i++) {
      ushort ch = (ushort)StringGetCharacter(text, i);
      if(ch == '.')
         last = i;
   }

   return last;
}

string BuildRunTimestamp(const datetime t) {
   MqlDateTime tm = {};
   TimeToStruct(t, tm);
   return StringFormat("%04d%02d%02d_%02d%02d%02d", tm.year, tm.mon, tm.day, tm.hour, tm.min, tm.sec);
}

string BuildRunOutputPath(const string basePath, const datetime runTime) {
   string stamp     = BuildRunTimestamp(runTime);
   int    lastSlash = FindLastSlashIndex(basePath);
   int    lastDot   = FindLastDotIndex(basePath);

   if(lastDot > lastSlash) {
      string left = StringSubstr(basePath, 0, lastDot);
      string ext  = StringSubstr(basePath, lastDot);
      return left + "_" + stamp + ext;
   }

   return basePath + "_" + stamp + ".csv";
}

void EnsureParentFolders(const string outputPath, const bool useCommonFiles) {
   string normalized = outputPath;
   StringReplace(normalized, "\\", "/");

   int lastSlash = FindLastSlashIndex(normalized);
   if(lastSlash < 0)
      return;

   string folderPath = StringSubstr(normalized, 0, lastSlash);
   if(StringLen(folderPath) == 0)
      return;

   string parts[];
   int    partCount = StringSplit(folderPath, '/', parts);
   if(partCount <= 0)
      return;

   string current = "";
   for(int i = 0; i < partCount; i++) {
      if(StringLen(parts[i]) == 0)
         continue;

      if(StringLen(current) == 0)
         current = parts[i];
      else
         current = current + "/" + parts[i];

      FolderCreate(current, useCommonFiles ? FILE_COMMON : 0);
   }
}

string BuildCsvRow(const string &values[]) {
   string row = "";
   int    n   = ArraySize(values);

   for(int i = 0; i < n; i++) {
      if(i > 0)
         row += ",";
      row += values[i];
   }

   return row;
}

string DateTimeToText(const datetime t) {
   if(t <= 0)
      return "";
   return TimeToString(t, TIME_DATE | TIME_SECONDS);
}

bool ParseDateTimeInput(const string rawText, const bool allowZeroAsNow, datetime &out) {
   string text = TrimCopy(rawText);
   if(StringLen(text) == 0)
      return false;

   if(allowZeroAsNow && text == "0") {
      out = 0;
      return true;
   }

   datetime t = StringToTime(text);
   if(t <= 0)
      return false;

   out = t;
   return true;
}

bool ParseSymbols(string &symbols[]) {
   string parts[];
   int    count = StringSplit(InpSymbols, ',', parts);
   if(count <= 0)
      return false;

   ArrayResize(symbols, 0);

   for(int i = 0; i < count; i++) {
      string resolved = ResolveSymbolName(parts[i]);
      if(StringLen(resolved) == 0)
         continue;

      bool duplicated = false;
      for(int j = 0; j < ArraySize(symbols); j++) {
         if(symbols[j] == resolved) {
            duplicated = true;
            break;
         }
      }
      if(duplicated)
         continue;

      if(!SymbolSelect(resolved, true))
         continue;

      int n = ArraySize(symbols);
      ArrayResize(symbols, n + 1);
      symbols[n] = resolved;
   }

   return (ArraySize(symbols) >= 1);
}

bool BuildPriceAndReturns(const string          symbol,
                          const ENUM_TIMEFRAMES timeframe,
                          const int             barsToAnalyze,
                          const int             analysisEndShiftBars,
                          const bool            useDateRange,
                          const datetime        analysisStart,
                          const datetime        analysisEnd,
                          const bool            useLogReturns,
                          const bool            returnAsPercent,
                          datetime             &usedStart,
                          datetime             &usedEnd,
                          double               &closesChrono[],
                          double               &returnsChrono[]) {
   usedStart = 0;
   usedEnd   = 0;

   int nClose = 0;

   if(useDateRange) {
      datetime endTime = analysisEnd;
      if(endTime <= 0)
         endTime = TimeCurrent();

      if(analysisStart <= 0 || analysisStart >= endTime)
         return false;

      MqlRates rates[];
      ArraySetAsSeries(rates, false);
      int copied = CopyRates(symbol, timeframe, analysisStart, endTime, rates);
      if(copied < 3)
         return false;

      nClose = copied;
      ArrayResize(closesChrono, nClose);
      for(int i = 0; i < nClose; i++)
         closesChrono[i] = rates[i].close;

      usedStart = rates[0].time;
      usedEnd   = rates[nClose - 1].time;
   } else {
      double closeSeries[];
      ArraySetAsSeries(closeSeries, true);

      int requestedCloses = barsToAnalyze + 1;
      int copied          = CopyClose(symbol, timeframe, analysisEndShiftBars, requestedCloses, closeSeries);
      if(copied < 30)
         return false;

      nClose = MathMin(copied, requestedCloses);
      ArrayResize(closesChrono, nClose);
      for(int k = 0; k < nClose; k++)
         closesChrono[k] = closeSeries[nClose - 1 - k];

      datetime timeSeries[];
      ArraySetAsSeries(timeSeries, true);
      int copiedTime = CopyTime(symbol, timeframe, analysisEndShiftBars, nClose, timeSeries);
      if(copiedTime == nClose) {
         usedStart = timeSeries[nClose - 1];
         usedEnd   = timeSeries[0];
      }
   }

   if(nClose < 3)
      return false;

   int nRet = nClose - 1;
   ArrayResize(returnsChrono, nRet);

   for(int i = 1; i < nClose; i++) {
      double p0 = closesChrono[i - 1];
      double p1 = closesChrono[i];
      if(p0 <= 0.0 || p1 <= 0.0)
         return false;

      double r = 0.0;
      if(useLogReturns)
         r = MathLog(p1 / p0);
      else
         r = (p1 - p0) / p0;

      if(returnAsPercent)
         r *= 100.0;

      returnsChrono[i - 1] = r;
   }

   return true;
}

string EvaluateMartingaleSuitability(const string regime,
                                     const bool   sharpeOk,
                                     const double rollingSharpe,
                                     const double currentDDPct,
                                     const int    currentDDBars,
                                     const double currentVol,
                                     const double highTh) {
   if(regime == "HIGH" || currentDDPct >= InpSuitabilityStopDrawdownPct || currentDDBars >= InpSuitabilityStopDrawdownBars || (sharpeOk && rollingSharpe <= InpSuitabilityStopSharpe))
      return "STOP";

   bool nearHighVol = (highTh > 0.0 && currentVol >= highTh * InpSuitabilityNearHighVolRatio);
   if(nearHighVol || currentDDPct >= InpSuitabilityCautionDrawdownPct || currentDDBars >= InpSuitabilityCautionDrawdownBars || (sharpeOk && rollingSharpe < InpSuitabilityCautionSharpe))
      return "CAUTION";

   if(regime == "LOW")
      return "GO";

   return "CAUTION";
}

bool MeanStdRange(const double &values[], const int start, const int len, double &mean, double &stdDev) {
   if(len < 2)
      return false;

   double sum = 0.0;
   for(int i = start; i < start + len; i++)
      sum += values[i];

   mean = sum / (double)len;

   double varAcc = 0.0;
   for(int i = start; i < start + len; i++) {
      double d  = values[i] - mean;
      varAcc   += d * d;
   }

   stdDev = MathSqrt(varAcc / (double)(len - 1));
   return true;
}

bool ComputeRollingVolSeries(const double &returnsChrono[],
                             const int     retCount,
                             const int     window,
                             double       &rollingVols[]) {
   if(retCount < window || window < 2)
      return false;

   int count = retCount - window + 1;
   ArrayResize(rollingVols, count);

   for(int i = 0; i < count; i++) {
      double mean   = 0.0;
      double stdDev = 0.0;
      if(!MeanStdRange(returnsChrono, i, window, mean, stdDev))
         return false;
      rollingVols[i] = stdDev;
   }

   return true;
}

double Quantile(const double &values[], const int n, const double percentile) {
   if(n <= 0)
      return 0.0;

   double p = MathMax(0.0, MathMin(100.0, percentile));

   double tmp[];
   ArrayResize(tmp, n);
   for(int i = 0; i < n; i++)
      tmp[i] = values[i];

   ArraySort(tmp);

   if(n == 1)
      return tmp[0];

   double pos = (p / 100.0) * (double)(n - 1);
   int    lo  = (int)MathFloor(pos);
   int    hi  = (int)MathCeil(pos);
   double w   = pos - (double)lo;

   return tmp[lo] * (1.0 - w) + tmp[hi] * w;
}

bool ComputeCurrentRollingSharpe(const double &returnsChrono[],
                                 const int     retCount,
                                 const int     window,
                                 const double  riskFreeAnnual,
                                 const int     periodSeconds,
                                 const bool    useLogReturns,
                                 double       &rollingSharpe) {
   if(retCount < window || window < 2 || periodSeconds <= 0)
      return false;

   int start = retCount - window;

   const double yearSeconds = 31557600.0;
   double       rfBarSimple = MathPow(1.0 + riskFreeAnnual, (double)periodSeconds / yearSeconds) - 1.0;
   double       rfBar       = (useLogReturns ? MathLog(1.0 + rfBarSimple) : rfBarSimple);

   double sumExcess = 0.0;
   for(int i = start; i < retCount; i++)
      sumExcess += (returnsChrono[i] - rfBar);

   double meanExcess = sumExcess / (double)window;

   double varAcc = 0.0;
   for(int i = start; i < retCount; i++) {
      double d  = (returnsChrono[i] - rfBar) - meanExcess;
      varAcc   += d * d;
   }

   double stdExcess = MathSqrt(varAcc / (double)(window - 1));
   if(stdExcess <= 0.0)
      return false;

   double barsPerYear = yearSeconds / (double)periodSeconds;
   rollingSharpe      = (meanExcess / stdExcess) * MathSqrt(barsPerYear);
   return true;
}

void ComputeDrawdownMetrics(const double &closesChrono[],
                            const int     n,
                            double       &currentDDPct,
                            double       &maxDDPct,
                            int          &currentDDBars,
                            int          &maxDDBars) {
   currentDDPct  = 0.0;
   maxDDPct      = 0.0;
   currentDDBars = 0;
   maxDDBars     = 0;

   if(n < 2)
      return;

   double peak   = closesChrono[0];
   int    curDur = 0;

   for(int i = 0; i < n; i++) {
      double price = closesChrono[i];
      double ddPct = 0.0;

      if(price >= peak) {
         peak   = price;
         curDur = 0;
      } else {
         ddPct = (peak - price) / peak * 100.0;
         curDur++;

         if(ddPct > maxDDPct)
            maxDDPct = ddPct;
         if(curDur > maxDDBars)
            maxDDBars = curDur;
      }

      if(i == n - 1) {
         currentDDPct  = ddPct;
         currentDDBars = curDur;
      }
   }
}

int OnStart() {
   datetime parsedAnalysisStart = 0;
   datetime parsedAnalysisEnd = 0;

   if(!ParseDateTimeInput(InpAnalysisStartText, false, parsedAnalysisStart)) {
      Print("[ERROR] Invalid InpAnalysisStartText. Use format: YYYY.MM.DD HH:MI (e.g., 2025.01.01 00:00)");
      return 0;
   }

   if(!ParseDateTimeInput(InpAnalysisEndText, true, parsedAnalysisEnd)) {
      Print("[ERROR] Invalid InpAnalysisEndText. Use format: YYYY.MM.DD HH:MI or 0 for now.");
      return 0;
   }

   if(InpRollingWindow < 2 || InpRegimeLookback < 5) {
      Print("[ERROR] Invalid inputs: bars/rolling window/regime lookback are too small.");
      return 0;
   }

   if(!InpUseDateRange && InpBarsToAnalyze < 30) {
      Print("[ERROR] InpBarsToAnalyze must be at least 30 when not using date range mode.");
      return 0;
   }

   if(InpAnalysisEndShiftBars < 0) {
      Print("[ERROR] InpAnalysisEndShiftBars must be >= 0.");
      return 0;
   }

   if(InpUseDateRange) {
      datetime endTime = parsedAnalysisEnd;
      if(endTime <= 0)
         endTime = TimeCurrent();

      if(parsedAnalysisStart <= 0 || parsedAnalysisStart >= endTime) {
         Print("[ERROR] Invalid date range. Require AnalysisStart < AnalysisEnd (or AnalysisEnd=0 for now).");
         return 0;
      }
   }

   if(InpLowVolPercentile < 0.0 || InpLowVolPercentile >= InpHighVolPercentile || InpHighVolPercentile > 100.0) {
      Print("[ERROR] Invalid volatility percentiles. Require 0 <= low < high <= 100.");
      return 0;
   }

   string symbols[];
   if(!ParseSymbols(symbols)) {
      Print("[ERROR] No valid symbols parsed from InpSymbols.");
      return 0;
   }

   string runOutputPath = BuildRunOutputPath(InpOutputCsvPath, TimeLocal());

   EnsureParentFolders(runOutputPath, InpUseCommonFiles);

   int flags = FILE_WRITE | FILE_TXT | FILE_ANSI;
   if(InpUseCommonFiles)
      flags |= FILE_COMMON;

   int h = FileOpen(runOutputPath, flags);
   if(h == INVALID_HANDLE) {
      PrintFormat("[ERROR] Cannot open CSV output: %s (err=%d)", runOutputPath, GetLastError());
      return 0;
   }

   string unit       = (InpReturnAsPercent ? "pct" : "decimal");
   string returnType = (InpUseLogReturns ? "log" : "simple");

   string header[];
   ArrayResize(header, 24);
   header[0]  = "symbol";
   header[1]  = "timeframe";
   header[2]  = "analysis_start";
   header[3]  = "analysis_end";
   header[4]  = "bars_used";
   header[5]  = "return_type";
   header[6]  = "return_unit";
   header[7]  = "rolling_window";
   header[8]  = "regime_lookback";
   header[9]  = "low_vol_percentile";
   header[10] = "high_vol_percentile";
   header[11] = "current_vol";
   header[12] = "vol_threshold_low";
   header[13] = "vol_threshold_high";
   header[14] = "vol_regime";
   header[15] = "rolling_sharpe_annual";
   header[16] = "current_drawdown_pct";
   header[17] = "max_drawdown_pct";
   header[18] = "current_drawdown_duration_bars";
   header[19] = "max_drawdown_duration_bars";
   header[20] = "current_drawdown_duration_minutes";
   header[21] = "max_drawdown_duration_minutes";
   header[22] = "martingale_suitability_score";
   header[23] = "status";

   FileWriteString(h, BuildCsvRow(header) + "\r\n");

   int periodSec = PeriodSeconds(InpTimeframe);
   if(periodSec <= 0)
      periodSec = 60;

   for(int s = 0; s < ArraySize(symbols); s++) {
      string symbol = symbols[s];

      double   closes[];
      double   returns[];
      datetime usedStart = 0;
      datetime usedEnd   = 0;

      string row[];
      ArrayResize(row, 24);
      row[0]  = symbol;
      row[1]  = EnumToString(InpTimeframe);
      row[5]  = returnType;
      row[6]  = unit;
      row[7]  = IntegerToString(InpRollingWindow);
      row[8]  = IntegerToString(InpRegimeLookback);
      row[9]  = DoubleToString(InpLowVolPercentile, 2);
      row[10] = DoubleToString(InpHighVolPercentile, 2);

      bool ok = BuildPriceAndReturns(symbol,
                                     InpTimeframe,
                                     InpBarsToAnalyze,
                                     InpAnalysisEndShiftBars,
                                     InpUseDateRange,
                                     parsedAnalysisStart,
                                     parsedAnalysisEnd,
                                     InpUseLogReturns,
                                     InpReturnAsPercent,
                                     usedStart,
                                     usedEnd,
                                     closes,
                                     returns);
      if(!ok) {
         row[2]  = DateTimeToText(usedStart);
         row[3]  = DateTimeToText(usedEnd);
         row[4]  = "0";
         row[11] = "";
         row[12] = "";
         row[13] = "";
         row[14] = "";
         row[15] = "";
         row[16] = "";
         row[17] = "";
         row[18] = "";
         row[19] = "";
         row[20] = "";
         row[21] = "";
         row[22] = "";
         row[23] = "ERROR: insufficient or invalid price data";
         FileWriteString(h, BuildCsvRow(row) + "\r\n");
         continue;
      }

      int barsUsed = ArraySize(returns);
      row[2]       = DateTimeToText(usedStart);
      row[3]       = DateTimeToText(usedEnd);
      row[4]       = IntegerToString(barsUsed);

      double rollingVols[];
      if(!ComputeRollingVolSeries(returns, barsUsed, InpRollingWindow, rollingVols)) {
         row[11] = "";
         row[11] = "";
         row[12] = "";
         row[13] = "";
         row[14] = "";
         row[15] = "";
         row[16] = "";
         row[17] = "";
         row[18] = "";
         row[19] = "";
         row[20] = "";
         row[21] = "";
         row[22] = "";
         row[23] = "ERROR: not enough bars for rolling window";
         FileWriteString(h, BuildCsvRow(row) + "\r\n");
         continue;
      }

      int rollingCount = ArraySize(rollingVols);
      int lb           = MathMin(InpRegimeLookback, rollingCount);
      int lbStart      = rollingCount - lb;

      double sample[];
      ArrayResize(sample, lb);
      for(int i = 0; i < lb; i++)
         sample[i] = rollingVols[lbStart + i];

      double lowTh      = Quantile(sample, lb, InpLowVolPercentile);
      double highTh     = Quantile(sample, lb, InpHighVolPercentile);
      double currentVol = rollingVols[rollingCount - 1];

      string regime = "NORMAL";
      if(currentVol < lowTh)
         regime = "LOW";
      else if(currentVol > highTh)
         regime = "HIGH";

      double rollingSharpe = 0.0;
      bool   sharpeOk      = ComputeCurrentRollingSharpe(returns,
                                                         barsUsed,
                                                         InpRollingWindow,
                                                         InpRiskFreeRateAnnual,
                                                         periodSec,
                                                         InpUseLogReturns,
                                                         rollingSharpe);

      double currentDD     = 0.0;
      double maxDD         = 0.0;
      int    currentDDBars = 0;
      int    maxDDBars     = 0;
      ComputeDrawdownMetrics(closes, ArraySize(closes), currentDD, maxDD, currentDDBars, maxDDBars);

      string suitability = EvaluateMartingaleSuitability(regime,
                                                         sharpeOk,
                                                         rollingSharpe,
                                                         currentDD,
                                                         currentDDBars,
                                                         currentVol,
                                                         highTh);

      row[11] = DoubleToString(currentVol, 8);
      row[12] = DoubleToString(lowTh, 8);
      row[13] = DoubleToString(highTh, 8);
      row[14] = regime;
      row[15] = (sharpeOk ? DoubleToString(rollingSharpe, 6) : "");
      row[16] = DoubleToString(currentDD, 4);
      row[17] = DoubleToString(maxDD, 4);
      row[18] = IntegerToString(currentDDBars);
      row[19] = IntegerToString(maxDDBars);
      row[20] = DoubleToString((double)currentDDBars * (double)periodSec / 60.0, 2);
      row[21] = DoubleToString((double)maxDDBars * (double)periodSec / 60.0, 2);
      row[22] = suitability;
      row[23] = "OK";

      FileWriteString(h, BuildCsvRow(row) + "\r\n");
   }

   FileClose(h);

   PrintFormat("[DONE] Rolling risk stats CSV written: %s%s",
               (InpUseCommonFiles ? "[COMMON] " : "[LOCAL] "),
               runOutputPath);

   return 0;
}

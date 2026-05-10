#property script_show_inputs
#property strict

struct FxSymbolInfo {
   string symbol;
   string base;
   string quote;
   int    bars;
};

struct CointegrationResult {
   string ySymbol;
   string x1Symbol;
   string x2Symbol;
   string viaCurrency;
   int    barsUsed;
   double p1;
   double p2;
   double c;
   double r2;
   double adfT;
};

input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_H1;                                  // Timeframe used for analysis
input int             InpBarsToAnalyze    = 3000;                                       // Number of bars used in each regression
input bool            InpScanSelectedOnly = false;                                      // true=Market Watch only, false=all symbols
input double          InpMinR2            = 0.80;                                       // Minimum R2 to report
input double          InpAdfTThreshold    = -3.00;                                      // ADF t-stat threshold (more negative is stronger)
input bool            InpOnlyCointegrated = true;                                       // true=output only matching equations
input string          InpOutputPath       = "cointegration/cointegration_report.txt";   // Base output path. Script appends key parameters to filename.
input bool            InpUseCommonFiles   = true;                                       // true=write to Common Files, false=terminal Files

bool IsThreeLetterCurrency(const string currency) {
   if(StringLen(currency) != 3)
      return false;

   for(int i = 0; i < 3; i++) {
      ushort ch = (ushort)StringGetCharacter(currency, i);
      if(ch < 'A' || ch > 'Z')
         return false;
   }

   return true;
}

void AddUniqueCurrency(const string currency, string &currencies[]) {
   int total = ArraySize(currencies);
   for(int i = 0; i < total; i++) {
      if(currencies[i] == currency)
         return;
   }

   ArrayResize(currencies, total + 1);
   currencies[total] = currency;
}

string FindBestSymbolForPair(const FxSymbolInfo &fxSymbols[], const string base, const string quote) {
   string bestSymbol = "";
   int    bestBars   = -1;

   int total = ArraySize(fxSymbols);
   for(int i = 0; i < total; i++) {
      if(fxSymbols[i].base != base || fxSymbols[i].quote != quote)
         continue;

      if(fxSymbols[i].bars > bestBars) {
         bestBars   = fxSymbols[i].bars;
         bestSymbol = fxSymbols[i].symbol;
      }
   }

   return bestSymbol;
}

bool Solve3x3(const double a00,
              const double a01,
              const double a02,
              const double a10,
              const double a11,
              const double a12,
              const double a20,
              const double a21,
              const double a22,
              const double b0,
              const double b1,
              const double b2,
              double      &x0,
              double      &x1,
              double      &x2) {
   double detA = a00 * (a11 * a22 - a12 * a21) - a01 * (a10 * a22 - a12 * a20) + a02 * (a10 * a21 - a11 * a20);

   if(MathAbs(detA) < 1e-12)
      return false;

   double detX0 = b0 * (a11 * a22 - a12 * a21) - a01 * (b1 * a22 - a12 * b2) + a02 * (b1 * a21 - a11 * b2);

   double detX1 = a00 * (b1 * a22 - a12 * b2) - b0 * (a10 * a22 - a12 * a20) + a02 * (a10 * b2 - b1 * a20);

   double detX2 = a00 * (a11 * b2 - b1 * a21) - a01 * (a10 * b2 - b1 * a20) + b0 * (a10 * a21 - a11 * a20);

   x0 = detX0 / detA;
   x1 = detX1 / detA;
   x2 = detX2 / detA;
   return true;
}

bool FitRegressionAndResiduals(const double &y[],
                               const double &x1[],
                               const double &x2[],
                               const int     n,
                               double       &p1,
                               double       &p2,
                               double       &c,
                               double       &r2,
                               double       &residuals[]) {
   if(n < 30)
      return false;

   double sumY    = 0.0;
   double sumX1   = 0.0;
   double sumX2   = 0.0;
   double sumX1X1 = 0.0;
   double sumX2X2 = 0.0;
   double sumX1X2 = 0.0;
   double sumX1Y  = 0.0;
   double sumX2Y  = 0.0;

   for(int i = 0; i < n; i++) {
      double yi  = y[i];
      double x1i = x1[i];
      double x2i = x2[i];

      sumY    += yi;
      sumX1   += x1i;
      sumX2   += x2i;
      sumX1X1 += x1i * x1i;
      sumX2X2 += x2i * x2i;
      sumX1X2 += x1i * x2i;
      sumX1Y  += x1i * yi;
      sumX2Y  += x2i * yi;
   }

   double intercept = 0.0;
   double beta1     = 0.0;
   double beta2     = 0.0;

   bool solved = Solve3x3((double)n,
                          sumX1,
                          sumX2,
                          sumX1,
                          sumX1X1,
                          sumX1X2,
                          sumX2,
                          sumX1X2,
                          sumX2X2,
                          sumY,
                          sumX1Y,
                          sumX2Y,
                          intercept,
                          beta1,
                          beta2);

   if(!solved)
      return false;

   ArrayResize(residuals, n);

   double meanY = sumY / (double)n;
   double ssRes = 0.0;
   double ssTot = 0.0;

   for(int i = 0; i < n; i++) {
      double fitted   = intercept + beta1 * x1[i] + beta2 * x2[i];
      double residual = y[i] - fitted;
      residuals[i]    = residual;

      ssRes += residual * residual;

      double dY  = y[i] - meanY;
      ssTot     += dY * dY;
   }

   p1 = beta1;
   p2 = beta2;
   c  = intercept;
   r2 = (ssTot > 0.0) ? (1.0 - ssRes / ssTot) : 0.0;

   return true;
}

bool ComputeAdfTStat(const double &residuals[], const int n, double &adfT) {
   if(n < 40)
      return false;

   int m = n - 1;

   double sumX  = 0.0;
   double sumY  = 0.0;
   double sumXX = 0.0;
   double sumXY = 0.0;

   for(int i = n - 1; i >= 1; i--) {
      double prevResidual = residuals[i];
      double delta        = residuals[i - 1] - residuals[i];

      sumX  += prevResidual;
      sumY  += delta;
      sumXX += prevResidual * prevResidual;
      sumXY += prevResidual * delta;
   }

   double denom = (double)m * sumXX - sumX * sumX;
   if(MathAbs(denom) < 1e-12)
      return false;

   double gamma = ((double)m * sumXY - sumX * sumY) / denom;
   double alpha = (sumY - gamma * sumX) / (double)m;

   double sse         = 0.0;
   double meanX       = sumX / (double)m;
   double centeredSxx = 0.0;

   for(int i = n - 1; i >= 1; i--) {
      double prevResidual  = residuals[i];
      double delta         = residuals[i - 1] - residuals[i];
      double fitted        = alpha + gamma * prevResidual;
      double err           = delta - fitted;
      sse                 += err * err;

      double xCentered  = prevResidual - meanX;
      centeredSxx      += xCentered * xCentered;
   }

   if(m <= 2 || centeredSxx <= 0.0)
      return false;

   double sigma2  = sse / (double)(m - 2);
   double seGamma = MathSqrt(sigma2 / centeredSxx);
   if(seGamma <= 0.0)
      return false;

   adfT = gamma / seGamma;
   return true;
}

bool GetAlignedCloses(const string          symbol,
                      const ENUM_TIMEFRAMES timeframe,
                      const int             barsToAnalyze,
                      double               &closes[]) {
   ArraySetAsSeries(closes, true);
   int copied = CopyClose(symbol, timeframe, 0, barsToAnalyze, closes);
   return (copied >= barsToAnalyze);
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

string GetTimeStampTag() {
   MqlDateTime dt;
   TimeToStruct(TimeLocal(), dt);
   uint ms = GetTickCount() % 1000;
   return StringFormat("%04d%02d%02d_%02d%02d%02d_%03u", dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec, ms);
}

string ToPathSafeNumberTag(const double value, const int digits) {
   string tag = DoubleToString(value, digits);
   StringReplace(tag, "-", "m");
   StringReplace(tag, ".", "p");
   return tag;
}

void SplitOutputPath(const string outputPath, string &directory, string &baseName, string &extension) {
   string normalized = outputPath;
   StringReplace(normalized, "\\", "/");

   int    lastSlash = FindLastSlashIndex(normalized);
   string fileName  = normalized;
   directory        = "";

   if(lastSlash >= 0) {
      directory = StringSubstr(normalized, 0, lastSlash);
      fileName  = StringSubstr(normalized, lastSlash + 1);
   }

   if(StringLen(fileName) == 0)
      fileName = "cointegration_report.txt";

   int lastDot = -1;
   int len     = StringLen(fileName);
   for(int i = 0; i < len; i++) {
      if((ushort)StringGetCharacter(fileName, i) == '.')
         lastDot = i;
   }

   if(lastDot > 0) {
      baseName  = StringSubstr(fileName, 0, lastDot);
      extension = StringSubstr(fileName, lastDot);
   } else {
      baseName  = fileName;
      extension = ".txt";
   }
}

string BuildParameterizedOutputPath(const string          outputPath,
                                    const ENUM_TIMEFRAMES timeframe,
                                    const int             bars,
                                    const double          minR2,
                                    const double          adfThreshold,
                                    const bool            onlyCointegrated,
                                    const bool            selectedOnly) {
   string directory = "";
   string baseName  = "";
   string extension = "";
   SplitOutputPath(outputPath, directory, baseName, extension);

   string tfTag = EnumToString(timeframe);
   StringReplace(tfTag, "PERIOD_", "");

   string modeTag = (onlyCointegrated ? "co" : "all");
   string scanTag = (selectedOnly ? "sel" : "allsym");
   string r2Tag   = ToPathSafeNumberTag(minR2, 4);
   string adfTag  = ToPathSafeNumberTag(adfThreshold, 4);
   string tsTag   = GetTimeStampTag();

   string fileName = StringFormat("%s_tf%s_b%d_r2%s_adf%s_%s_%s_%s%s",
                                  baseName,
                                  tfTag,
                                  bars,
                                  r2Tag,
                                  adfTag,
                                  modeTag,
                                  scanTag,
                                  tsTag,
                                  extension);

   if(StringLen(directory) > 0)
      return directory + "/" + fileName;

   return fileName;
}

string EnsureUniqueOutputPath(const string outputPath, const bool useCommonFiles) {
   int commonFlag = (useCommonFiles ? FILE_COMMON : 0);

   int testHandle = FileOpen(outputPath, FILE_READ | FILE_TXT | commonFlag);
   if(testHandle == INVALID_HANDLE)
      return outputPath;
   FileClose(testHandle);

   int    lastSlash = FindLastSlashIndex(outputPath);
   string directory = "";
   string fileName  = outputPath;

   if(lastSlash >= 0) {
      directory = StringSubstr(outputPath, 0, lastSlash);
      fileName  = StringSubstr(outputPath, lastSlash + 1);
   }

   int lastDot = -1;
   int len     = StringLen(fileName);
   for(int i = 0; i < len; i++) {
      if((ushort)StringGetCharacter(fileName, i) == '.')
         lastDot = i;
   }

   string baseName  = fileName;
   string extension = "";
   if(lastDot > 0) {
      baseName  = StringSubstr(fileName, 0, lastDot);
      extension = StringSubstr(fileName, lastDot);
   }

   for(int i = 1; i <= 999; i++) {
      string numberedName = StringFormat("%s_%03d%s", baseName, i, extension);
      string candidate    = (StringLen(directory) > 0 ? directory + "/" + numberedName : numberedName);

      int candidateHandle = FileOpen(candidate, FILE_READ | FILE_TXT | commonFlag);
      if(candidateHandle == INVALID_HANDLE)
         return candidate;
      FileClose(candidateHandle);
   }

   return outputPath;
}

void SortByAdfAscending(CointegrationResult &results[]) {
   int total = ArraySize(results);
   for(int i = 0; i < total - 1; i++) {
      for(int j = i + 1; j < total; j++) {
         if(results[j].adfT < results[i].adfT) {
            CointegrationResult tmp = results[i];
            results[i]              = results[j];
            results[j]              = tmp;
         }
      }
   }
}

void OnStart() {
   if(InpBarsToAnalyze < 100) {
      Print("[ERROR] InpBarsToAnalyze should be at least 100.");
      return;
   }

   ENUM_TIMEFRAMES timeframe = (InpTimeframe == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : InpTimeframe);

   FxSymbolInfo fxSymbols[];
   string       currencies[];

   int totalSymbols = SymbolsTotal(InpScanSelectedOnly);

   for(int i = 0; i < totalSymbols; i++) {
      string symbol = SymbolName(i, InpScanSelectedOnly);
      if(StringLen(symbol) == 0)
         continue;

      if(!SymbolSelect(symbol, true))
         continue;

      string base  = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE);
      string quote = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);

      if(!IsThreeLetterCurrency(base) || !IsThreeLetterCurrency(quote) || base == quote)
         continue;

      int bars = Bars(symbol, timeframe);
      if(bars < InpBarsToAnalyze)
         continue;

      int idx = ArraySize(fxSymbols);
      ArrayResize(fxSymbols, idx + 1);
      fxSymbols[idx].symbol = symbol;
      fxSymbols[idx].base   = base;
      fxSymbols[idx].quote  = quote;
      fxSymbols[idx].bars   = bars;

      AddUniqueCurrency(base, currencies);
      AddUniqueCurrency(quote, currencies);
   }

   int fxCount = ArraySize(fxSymbols);
   if(fxCount == 0) {
      Print("[ERROR] No FX symbols found with enough bars for analysis.");
      return;
   }

   CointegrationResult results[];

   int tested = 0;
   for(int yIdx = 0; yIdx < fxCount; yIdx++) {
      string ySymbol = fxSymbols[yIdx].symbol;
      string baseA   = fxSymbols[yIdx].base;
      string quoteB  = fxSymbols[yIdx].quote;

      for(int cIdx = 0; cIdx < ArraySize(currencies); cIdx++) {
         string midCurrency = currencies[cIdx];
         if(midCurrency == baseA || midCurrency == quoteB)
            continue;

         string x1Symbol = FindBestSymbolForPair(fxSymbols, baseA, midCurrency);
         string x2Symbol = FindBestSymbolForPair(fxSymbols, midCurrency, quoteB);

         if(StringLen(x1Symbol) == 0 || StringLen(x2Symbol) == 0)
            continue;

         double yClose[];
         double x1Close[];
         double x2Close[];

         if(!GetAlignedCloses(ySymbol, timeframe, InpBarsToAnalyze, yClose))
            continue;
         if(!GetAlignedCloses(x1Symbol, timeframe, InpBarsToAnalyze, x1Close))
            continue;
         if(!GetAlignedCloses(x2Symbol, timeframe, InpBarsToAnalyze, x2Close))
            continue;

         double p1 = 0.0;
         double p2 = 0.0;
         double c  = 0.0;
         double r2 = 0.0;
         double residuals[];

         if(!FitRegressionAndResiduals(yClose,
                                       x1Close,
                                       x2Close,
                                       InpBarsToAnalyze,
                                       p1,
                                       p2,
                                       c,
                                       r2,
                                       residuals))
            continue;

         double adfT = 0.0;
         if(!ComputeAdfTStat(residuals, InpBarsToAnalyze, adfT))
            continue;

         tested++;

         bool isCointegrated = (r2 >= InpMinR2 && adfT <= InpAdfTThreshold);
         if(InpOnlyCointegrated && !isCointegrated)
            continue;

         int outIdx = ArraySize(results);
         ArrayResize(results, outIdx + 1);
         results[outIdx].ySymbol     = ySymbol;
         results[outIdx].x1Symbol    = x1Symbol;
         results[outIdx].x2Symbol    = x2Symbol;
         results[outIdx].viaCurrency = midCurrency;
         results[outIdx].barsUsed    = InpBarsToAnalyze;
         results[outIdx].p1          = p1;
         results[outIdx].p2          = p2;
         results[outIdx].c           = c;
         results[outIdx].r2          = r2;
         results[outIdx].adfT        = adfT;
      }
   }

   SortByAdfAscending(results);

   string resolvedOutputPath = BuildParameterizedOutputPath(InpOutputPath,
                                                            timeframe,
                                                            InpBarsToAnalyze,
                                                            InpMinR2,
                                                            InpAdfTThreshold,
                                                            InpOnlyCointegrated,
                                                            InpScanSelectedOnly);
   resolvedOutputPath        = EnsureUniqueOutputPath(resolvedOutputPath, InpUseCommonFiles);

   EnsureParentFolders(resolvedOutputPath, InpUseCommonFiles);

   int fileFlags = FILE_WRITE | FILE_TXT | FILE_ANSI;
   if(InpUseCommonFiles)
      fileFlags |= FILE_COMMON;

   int fileHandle = FileOpen(resolvedOutputPath, fileFlags);
   if(fileHandle == INVALID_HANDLE) {
      PrintFormat("[ERROR] Failed to open output file: %s (err=%d)", resolvedOutputPath, GetLastError());
      return;
   }

   FileWrite(fileHandle, "Cointegration Matching Report");
   FileWrite(fileHandle, StringFormat("Generated: %s", TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS)));
   FileWrite(fileHandle, StringFormat("Timeframe: %s", EnumToString(timeframe)));
   FileWrite(fileHandle, StringFormat("Bars analyzed: %d", InpBarsToAnalyze));
   FileWrite(fileHandle, StringFormat("FX symbols scanned: %d", fxCount));
   FileWrite(fileHandle, StringFormat("Equation candidates tested: %d", tested));
   FileWrite(fileHandle, StringFormat("Filter: R2 >= %.4f and ADF_t <= %.4f", InpMinR2, InpAdfTThreshold));
   FileWrite(fileHandle, "");

   int resultCount = ArraySize(results);
   FileWrite(fileHandle, StringFormat("Matched equations: %d", resultCount));
   FileWrite(fileHandle, "");

   for(int i = 0; i < resultCount; i++) {
      string equation = StringFormat("%s = (%.8f)*%s + (%.8f)*%s + %.8f",
                                     results[i].ySymbol,
                                     results[i].p1,
                                     results[i].x1Symbol,
                                     results[i].p2,
                                     results[i].x2Symbol,
                                     results[i].c);

      string metrics = StringFormat("via=%s | bars=%d | R2=%.6f | ADF_t=%.6f",
                                    results[i].viaCurrency,
                                    results[i].barsUsed,
                                    results[i].r2,
                                    results[i].adfT);

      FileWrite(fileHandle, equation);
      FileWrite(fileHandle, metrics);
      FileWrite(fileHandle, "");
   }

   FileClose(fileHandle);

   PrintFormat("[DONE] cointegration_matching finished. Tested=%d, Matched=%d, Output=%s%s",
               tested,
               resultCount,
               (InpUseCommonFiles ? "[COMMON] " : "[LOCAL] "),
               resolvedOutputPath);
}

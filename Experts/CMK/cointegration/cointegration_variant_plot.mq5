#property strict
#property indicator_separate_window
#property indicator_plots 3
#property indicator_buffers 3

#property indicator_label1 "Eq1 Variant"
#property indicator_type1 DRAW_LINE
#property indicator_color1 clrDeepSkyBlue
#property indicator_style1 STYLE_SOLID
#property indicator_width1 2

#property indicator_label2 "Eq2 Variant"
#property indicator_type2 DRAW_LINE
#property indicator_color2 clrOrange
#property indicator_style2 STYLE_SOLID
#property indicator_width2 2

#property indicator_label3 "Eq3 Variant"
#property indicator_type3 DRAW_LINE
#property indicator_color3 clrLimeGreen
#property indicator_style3 STYLE_SOLID
#property indicator_width3 2

input ENUM_TIMEFRAMES InpTimeframe  = PERIOD_CURRENT;   // Timeframe used to sample prices
input int             InpBarsToPlot = 3000;             // How many most-recent bars to plot

input bool   InpEnableEq1 = true;
input string InpY1        = "EURUSD";
input string InpX11       = "EURGBP";
input string InpX21       = "GBPUSD";
input double InpP11       = 1.34285999;
input double InpP21       = 0.86878936;
input double InpC1        = -1.16663185;
input color  InpColorEq1  = clrDeepSkyBlue;

input bool   InpEnableEq2 = true;
input string InpY2        = "EURCAD";
input string InpX12       = "EURUSD";
input string InpX22       = "USDCAD";
input double InpP12       = 1.36405515;
input double InpP22       = 1.15617267;
input double InpC2        = -1.57716130;
input color  InpColorEq2  = clrOrange;

input bool   InpEnableEq3 = true;
input string InpY3        = "EURUSD";
input string InpX13       = "EURAUD";
input string InpX23       = "AUDUSD";
input double InpP13       = 0.71015315;
input double InpP23       = 1.65775592;
input double InpC3        = -1.17731121;
input color  InpColorEq3  = clrLimeGreen;

double g_bufferEq1[];
double g_bufferEq2[];
double g_bufferEq3[];

string g_y1  = "";
string g_x11 = "";
string g_x21 = "";
string g_y2  = "";
string g_x12 = "";
string g_x22 = "";
string g_y3  = "";
string g_x13 = "";
string g_x23 = "";

string ToUpperCopy(const string value) {
   string out = value;
   StringToUpper(out);
   return out;
}

string ResolveSymbolName(const string requested) {
   if(StringLen(requested) == 0)
      return "";

   string reqUp = ToUpperCopy(requested);

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

bool PrepareSymbol(const string requested, string &resolved) {
   resolved = ResolveSymbolName(requested);
   if(StringLen(resolved) == 0) {
      PrintFormat("[WARN] Symbol not found: %s", requested);
      return false;
   }

   if(!SymbolSelect(resolved, true)) {
      PrintFormat("[WARN] Symbol cannot be selected: %s", resolved);
      return false;
   }

   return true;
}

bool GetVariantAtTime(const string          symbolY,
                      const string          symbolX1,
                      const string          symbolX2,
                      const double          p1,
                      const double          p2,
                      const double          c,
                      const ENUM_TIMEFRAMES timeframe,
                      const datetime        t,
                      double               &variantValue) {
   int shiftY  = iBarShift(symbolY, timeframe, t, false);
   int shiftX1 = iBarShift(symbolX1, timeframe, t, false);
   int shiftX2 = iBarShift(symbolX2, timeframe, t, false);

   if(shiftY < 0 || shiftX1 < 0 || shiftX2 < 0)
      return false;

   double y  = iClose(symbolY, timeframe, shiftY);
   double x1 = iClose(symbolX1, timeframe, shiftX1);
   double x2 = iClose(symbolX2, timeframe, shiftX2);

   if(y <= 0.0 || x1 <= 0.0 || x2 <= 0.0)
      return false;

   variantValue = y - (p1 * x1 + p2 * x2 + c);
   return true;
}

int OnInit() {
   SetIndexBuffer(0, g_bufferEq1, INDICATOR_DATA);
   SetIndexBuffer(1, g_bufferEq2, INDICATOR_DATA);
   SetIndexBuffer(2, g_bufferEq3, INDICATOR_DATA);

   ArraySetAsSeries(g_bufferEq1, true);
   ArraySetAsSeries(g_bufferEq2, true);
   ArraySetAsSeries(g_bufferEq3, true);

   PlotIndexSetInteger(0, PLOT_LINE_COLOR, InpColorEq1);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, InpColorEq2);
   PlotIndexSetInteger(2, PLOT_LINE_COLOR, InpColorEq3);

   PrepareSymbol(InpY1, g_y1);
   PrepareSymbol(InpX11, g_x11);
   PrepareSymbol(InpX21, g_x21);
   PrepareSymbol(InpY2, g_y2);
   PrepareSymbol(InpX12, g_x12);
   PrepareSymbol(InpX22, g_x22);
   PrepareSymbol(InpY3, g_y3);
   PrepareSymbol(InpX13, g_x13);
   PrepareSymbol(InpX23, g_x23);

   string tfText = EnumToString((InpTimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTimeframe);
   IndicatorSetString(INDICATOR_SHORTNAME, "Cointegration Variant Plot (" + tfText + ")");

   PlotIndexSetString(0, PLOT_LABEL, "Eq1: " + InpY1 + " vs " + InpX11 + "+" + InpX21);
   PlotIndexSetString(1, PLOT_LABEL, "Eq2: " + InpY2 + " vs " + InpX12 + "+" + InpX22);
   PlotIndexSetString(2, PLOT_LABEL, "Eq3: " + InpY3 + " vs " + InpX13 + "+" + InpX23);

   return INIT_SUCCEEDED;
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
   if(rates_total < 10)
      return 0;

   ENUM_TIMEFRAMES tf = (InpTimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTimeframe;

   int plotBars = MathMin(InpBarsToPlot, rates_total);

   for(int i = 0; i < rates_total; i++) {
      g_bufferEq1[i] = EMPTY_VALUE;
      g_bufferEq2[i] = EMPTY_VALUE;
      g_bufferEq3[i] = EMPTY_VALUE;
   }

   for(int i = 0; i < plotBars; i++) {
      datetime t     = time[i];
      double   value = 0.0;

      if(InpEnableEq1 && StringLen(g_y1) > 0 && StringLen(g_x11) > 0 && StringLen(g_x21) > 0) {
         if(GetVariantAtTime(g_y1, g_x11, g_x21, InpP11, InpP21, InpC1, tf, t, value))
            g_bufferEq1[i] = value;
      }

      if(InpEnableEq2 && StringLen(g_y2) > 0 && StringLen(g_x12) > 0 && StringLen(g_x22) > 0) {
         if(GetVariantAtTime(g_y2, g_x12, g_x22, InpP12, InpP22, InpC2, tf, t, value))
            g_bufferEq2[i] = value;
      }

      if(InpEnableEq3 && StringLen(g_y3) > 0 && StringLen(g_x13) > 0 && StringLen(g_x23) > 0) {
         if(GetVariantAtTime(g_y3, g_x13, g_x23, InpP13, InpP23, InpC3, tf, t, value))
            g_bufferEq3[i] = value;
      }
   }

   return rates_total;
}

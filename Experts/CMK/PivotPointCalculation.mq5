#property copyright "Copyright 2024, MetaQuotes Ltd."
#property link "https://www.mql5.com"
#property version "1.00"

input ENUM_TIMEFRAMES    MaTimeframe = PERIOD_H1;
input int                MaPeriods   = 200;
input ENUM_MA_METHOD     maMethod    = MODE_SMA;
input ENUM_APPLIED_PRICE MaAppPrice  = PRICE_CLOSE;

int      handleMa;
MqlRates bars[];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   // MA handler
   handleMa = iMA(_Symbol, MaTimeframe, MaPeriods, 0, maMethod, MaAppPrice);

   // array set as series
   ArraySetAsSeries(bars, true);

   return (INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   ObjectsDeleteAll(0, "DGT");
}
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   int maTrend = getMaTrend();

   // calculate the pivot points
   double highD1  = iHigh(_Symbol, PERIOD_D1, 1);
   double lowD1   = iLow(_Symbol, PERIOD_D1, 1);
   double closeD1 = iClose(_Symbol, PERIOD_D1, 1);
   // pivot point = pp
   double pp = (highD1 + lowD1 + closeD1) / 3;
   double s1 = 2 * pp - highD1;
   double s2 = pp - (highD1 - lowD1);
   double s3 = lowD1 - (2 * (highD1 - pp));
   double r1 = 2 * pp - lowD1;
   double r2 = pp + (highD1 - lowD1);
   double r3 = 2 * (pp - lowD1) + highD1;

   addLevel("pp", pp, clrBlack);
   addLevel("s1", s1, clrGreen);
   addLevel("s2", s2, clrDarkOliveGreen);
   addLevel("s3", s3, clrMediumSeaGreen);
   addLevel("r1", r1, clrBrown);
   addLevel("r2", r2, clrCrimson);
   addLevel("r3", r3, clrOrangeRed);
}
//+------------------------------------------------------------------+

int getMaTrend() {
   double ma[];
   CopyBuffer(handleMa, MAIN_LINE, 0, 1, ma);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(bid > ma[0]) {
      return 1;
   } else if(bid < ma[0]) {
      return -1;
   }
   return 0;
}

void addLevel(string name, double price, color clr) {
   datetime time1 = iTime(_Symbol, PERIOD_D1, 0);
   datetime time2 = time1 + PeriodSeconds(PERIOD_D1);

   string objName;
   StringConcatenate(objName, "DGT ", name, " ", time1, " ", price);
   ObjectCreate(0, objName, OBJ_TREND, 0, time1, price, time2, price);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
}
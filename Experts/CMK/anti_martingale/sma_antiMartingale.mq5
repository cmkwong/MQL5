#property strict
#property version "1.00"

#include <Trade/Trade.mqh>

input string          InpTradeSymbol     = "";               // Symbol to trade (empty = current chart symbol)
input ENUM_TIMEFRAMES InpSignalTimeframe = PERIOD_CURRENT;   // Timeframe for SMA/ATR signals

input int                InpFastMAPeriod  = 20;            // Small SMA period
input int                InpSlowMAPeriod  = 50;            // Large SMA period
input ENUM_MA_METHOD     InpMAMethod      = MODE_SMA;      // MA method
input ENUM_APPLIED_PRICE InpAppliedPrice  = PRICE_CLOSE;   // Applied price
input bool               InpTradeOnNewBar = true;          // Trade only once per new bar

input bool   InpUseATRSLTP = true;   // Use ATR-based dynamic SL/TP
input int    InpATRPeriod  = 14;     // ATR period
input double InpATRSLMult  = 1.5;    // SL distance = ATR * multiplier
input double InpATRTPMult  = 2.0;    // TP distance = ATR * multiplier

input double InpBaseLot        = 0.01;   // Base lot size
input double InpAntiMultiplier = 1.6;    // Anti-martingale multiplier after each win
input int    InpMaxStep        = 5;      // Maximum anti-martingale step

input ulong InpMagicNumber    = 26050701;   // EA magic number
input int   InpDeviationPoint = 20;         // Slippage in points

CTrade g_trade;

int             g_fastHandle      = INVALID_HANDLE;
int             g_slowHandle      = INVALID_HANDLE;
int             g_atrHandle       = INVALID_HANDLE;
datetime        g_lastBarTime     = 0;
int             g_antiStep        = 0;
string          g_tradeSymbol     = "";
ENUM_TIMEFRAMES g_signalTimeframe = PERIOD_CURRENT;

string ToUpperCopy(const string value) {
   string out = value;
   StringToUpper(out);
   return out;
}

string ResolveSymbolName(const string requested) {
   string req = requested;
   StringTrimLeft(req);
   StringTrimRight(req);
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

bool IsNewBar() {
   datetime currentBar = iTime(g_tradeSymbol, g_signalTimeframe, 0);
   if(currentBar <= 0)
      return false;

   if(currentBar == g_lastBarTime)
      return false;

   g_lastBarTime = currentBar;
   return true;
}

bool GetMAValue(const int handle, const int shift, double &value) {
   double tmp[];
   int    copied = CopyBuffer(handle, 0, shift, 1, tmp);
   if(copied != 1)
      return false;

   value = tmp[0];
   return true;
}

bool GetATRValue(double &value) {
   if(g_atrHandle == INVALID_HANDLE)
      return false;

   double tmp[];
   // Use last closed bar ATR value (shift=1)
   int copied = CopyBuffer(g_atrHandle, 0, 1, 1, tmp);
   if(copied != 1 || tmp[0] <= 0.0)
      return false;

   value = tmp[0];
   return true;
}

double NormalizePrice(const string symbol, const double price) {
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

bool BuildATRSLTP(const string symbol, const int direction, double &sl, double &tp) {
   sl = 0.0;
   tp = 0.0;

   if(!InpUseATRSLTP)
      return true;

   double atr = 0.0;
   if(!GetATRValue(atr)) {
      Print("[ERROR] ATR value unavailable. Skip trade.");
      return false;
   }

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return false;

   int    stopsLevelPoints = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist          = (double)stopsLevelPoints * point;

   double slDist = MathMax(atr * InpATRSLMult, minDist);
   double tpDist = MathMax(atr * InpATRTPMult, minDist);

   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;

   if(direction > 0) {
      sl = NormalizePrice(symbol, ask - slDist);
      tp = NormalizePrice(symbol, ask + tpDist);
   } else {
      sl = NormalizePrice(symbol, bid + slDist);
      tp = NormalizePrice(symbol, bid - tpDist);
   }

   return true;
}

int GetCrossSignal() {
   double fast1 = 0.0;
   double fast2 = 0.0;
   double slow1 = 0.0;
   double slow2 = 0.0;

   // Use closed bars only: shift=1 (last closed), shift=2 (previous closed)
   if(!GetMAValue(g_fastHandle, 1, fast1) ||
      !GetMAValue(g_fastHandle, 2, fast2) ||
      !GetMAValue(g_slowHandle, 1, slow1) ||
      !GetMAValue(g_slowHandle, 2, slow2))
      return 0;

   bool upCross   = (fast2 <= slow2 && fast1 > slow1);
   bool downCross = (fast2 >= slow2 && fast1 < slow1);

   if(upCross)
      return 1;   // Rising trend
   if(downCross)
      return -1;   // Falling trend

   return 0;
}

double NormalizeVolume(const string symbol, const double requestedVolume) {
   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(requestedVolume <= 0.0 || minLot <= 0.0 || maxLot <= 0.0 || stepLot <= 0.0)
      return 0.0;

   double clipped    = MathMax(minLot, MathMin(maxLot, requestedVolume));
   double steps      = MathFloor(clipped / stepLot + 1e-10);
   double normalized = steps * stepLot;

   int    stepDigits = 0;
   double s          = stepLot;
   while(stepDigits < 8 && MathAbs(s - MathRound(s)) > 1e-10) {
      s *= 10.0;
      stepDigits++;
   }

   return NormalizeDouble(normalized, stepDigits);
}

int GetCurrentPositionState() {
   if(!PositionSelect(g_tradeSymbol))
      return 0;

   long magic = PositionGetInteger(POSITION_MAGIC);
   if((ulong)magic != InpMagicNumber)
      return 99;

   long type = PositionGetInteger(POSITION_TYPE);
   if(type == POSITION_TYPE_BUY)
      return 1;
   if(type == POSITION_TYPE_SELL)
      return -1;

   return 0;
}

bool CloseManagedPosition() {
   if(!PositionSelect(g_tradeSymbol))
      return true;

   long magic = PositionGetInteger(POSITION_MAGIC);
   if((ulong)magic != InpMagicNumber)
      return false;

   ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
   if(!g_trade.PositionClose(ticket)) {
      PrintFormat("[ERROR] Close failed ticket=%I64u ret=%d %s",
                  ticket,
                  g_trade.ResultRetcode(),
                  g_trade.ResultRetcodeDescription());
      return false;
   }

   return true;
}

bool OpenTrendPosition(const int direction) {
   if(direction != 1 && direction != -1)
      return false;

   double rawLot = InpBaseLot * MathPow(InpAntiMultiplier, g_antiStep);
   double lot    = NormalizeVolume(g_tradeSymbol, rawLot);
   if(lot <= 0.0) {
      PrintFormat("[ERROR] Invalid lot (raw=%.6f)", rawLot);
      return false;
   }

   double sl = 0.0;
   double tp = 0.0;
   if(!BuildATRSLTP(g_tradeSymbol, direction, sl, tp))
      return false;

   g_trade.SetTypeFillingBySymbol(g_tradeSymbol);

   bool ok = false;
   if(direction > 0)
      ok = g_trade.Buy(lot, g_tradeSymbol, 0.0, sl, tp);
   else
      ok = g_trade.Sell(lot, g_tradeSymbol, 0.0, sl, tp);

   if(!ok) {
      PrintFormat("[ERROR] Open failed dir=%d lot=%.2f sl=%.5f tp=%.5f ret=%d %s",
                  direction,
                  lot,
                  sl,
                  tp,
                  g_trade.ResultRetcode(),
                  g_trade.ResultRetcodeDescription());
      return false;
   }

   PrintFormat("[OPEN] %s lot=%.2f anti_step=%d sl=%.5f tp=%.5f",
               (direction > 0 ? "BUY" : "SELL"),
               lot,
               g_antiStep,
               sl,
               tp);
   return true;
}

int OnInit() {
   if(InpFastMAPeriod <= 1 || InpSlowMAPeriod <= 1 || InpFastMAPeriod >= InpSlowMAPeriod) {
      Print("[ERROR] Require FastMA < SlowMA and both > 1");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpBaseLot <= 0.0 || InpAntiMultiplier < 1.0 || InpMaxStep < 0) {
      Print("[ERROR] Invalid anti-martingale parameters");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseATRSLTP && (InpATRPeriod <= 1 || InpATRSLMult <= 0.0 || InpATRTPMult <= 0.0)) {
      Print("[ERROR] Invalid ATR SL/TP parameters");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoint);

   if(StringLen(InpTradeSymbol) == 0)
      g_tradeSymbol = _Symbol;
   else {
      g_tradeSymbol = ResolveSymbolName(InpTradeSymbol);
      if(StringLen(g_tradeSymbol) == 0) {
         PrintFormat("[ERROR] Trade symbol not found: %s", InpTradeSymbol);
         return INIT_PARAMETERS_INCORRECT;
      }
   }

   if(!SymbolSelect(g_tradeSymbol, true)) {
      PrintFormat("[ERROR] Could not select symbol: %s", g_tradeSymbol);
      return INIT_FAILED;
   }

   g_signalTimeframe = (InpSignalTimeframe == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : InpSignalTimeframe);
   if(PeriodSeconds(g_signalTimeframe) <= 0) {
      Print("[ERROR] Invalid signal timeframe");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_fastHandle = iMA(g_tradeSymbol, g_signalTimeframe, InpFastMAPeriod, 0, InpMAMethod, InpAppliedPrice);
   g_slowHandle = iMA(g_tradeSymbol, g_signalTimeframe, InpSlowMAPeriod, 0, InpMAMethod, InpAppliedPrice);

   if(InpUseATRSLTP)
      g_atrHandle = iATR(g_tradeSymbol, g_signalTimeframe, InpATRPeriod);

   if(g_fastHandle == INVALID_HANDLE || g_slowHandle == INVALID_HANDLE || (InpUseATRSLTP && g_atrHandle == INVALID_HANDLE)) {
      Print("[ERROR] Failed to create SMA handles");
      return INIT_FAILED;
   }

   PrintFormat("[INIT] sma_antiMartingale started on %s %s | Fast=%d Slow=%d | BaseLot=%.2f Mult=%.2f MaxStep=%d | ATR_SLTP=%s ATR(%d) SLx%.2f TPx%.2f",
               g_tradeSymbol,
               EnumToString(g_signalTimeframe),
               InpFastMAPeriod,
               InpSlowMAPeriod,
               InpBaseLot,
               InpAntiMultiplier,
               InpMaxStep,
               (InpUseATRSLTP ? "ON" : "OFF"),
               InpATRPeriod,
               InpATRSLMult,
               InpATRTPMult);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   if(g_fastHandle != INVALID_HANDLE)
      IndicatorRelease(g_fastHandle);
   if(g_slowHandle != INVALID_HANDLE)
      IndicatorRelease(g_slowHandle);
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);

   PrintFormat("[DEINIT] sma_antiMartingale stopped. reason=%d", reason);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result) {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong deal = trans.deal;
   if(deal == 0 || !HistoryDealSelect(deal))
      return;

   string symbol = HistoryDealGetString(deal, DEAL_SYMBOL);
   if(symbol != g_tradeSymbol)
      return;

   long magic = HistoryDealGetInteger(deal, DEAL_MAGIC);
   if((ulong)magic != InpMagicNumber)
      return;

   long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;

   double net = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP) + HistoryDealGetDouble(deal, DEAL_COMMISSION);

   if(net > 0.0) {
      g_antiStep = MathMin(InpMaxStep, g_antiStep + 1);
      PrintFormat("[ANTI] Win detected (%.2f). Increase step to %d", net, g_antiStep);
   } else if(net < 0.0) {
      g_antiStep = 0;
      PrintFormat("[ANTI] Loss detected (%.2f). Reset step to %d", net, g_antiStep);
   }
}

void OnTick() {
   if(InpTradeOnNewBar && !IsNewBar())
      return;

   int signal = GetCrossSignal();
   if(signal == 0)
      return;

   int state = GetCurrentPositionState();
   if(state == 99) {
      Print("[WARN] Existing position on symbol is not managed by this EA (magic mismatch). No action taken.");
      return;
   }

   if(state == signal)
      return;

   if(state != 0) {
      if(!CloseManagedPosition())
         return;
   }

   OpenTrendPosition(signal);
}

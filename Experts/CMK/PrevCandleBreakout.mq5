#property copyright "Copyright 2024, MetaQuotes Ltd."
#property link "https://www.mql5.com"
#property version "1.00"
#include <Trade/Trade.mqh>

input ENUM_TIMEFRAMES Timeframe        = PERIOD_M15;
input double          RiskMoney        = 500;
input int             SlPoints         = 30;
input int             TpPoints         = 60;
input int             TslTriggerPoints = 20;   // Trading stop loss
input int             TslPoints        = 10;
input int             gapPoints        = 20;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   return (INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   //---
}
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   //  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   //  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //  for(int i = PositionsTotal() - 1; i >= 0; i--) {
   //     CPositionInfo pos;
   //     if(pos.SelectByIndex(i)) {
   //        if(TslTriggerPoints > 0) {
   //           if(pos.PositionType() == POSITION_TYPE_BUY) {
   //              if(bid > pos.PriceOpen() + TslTriggerPoints * _Point) {
   //                 double sl = bid - TslPoints * _Point;
   //                 sl        = NormalizeDouble(sl, _Digits);
   //                 if(sl > pos.StopLoss()) {
   //                    CTrade trade;
   //                    if(trade.PositionModify(pos.Ticket(), sl, pos.TakeProfit())) {
   //                       Print("Pos #", pos.Ticket(), " was modified by tsl ... ");
   //                    }
   //                 }
   //              }

   //           } else if(pos.PositionType() == POSITION_TYPE_SELL) {
   //              if(ask < pos.PriceOpen() - TslTriggerPoints * _Point) {
   //                 double sl = ask + TslPoints * _Point;
   //                 sl        = NormalizeDouble(sl, _Digits);

   //                 if(sl < pos.StopLoss() || pos.StopLoss() == 0) {
   //                    CTrade trade;
   //                    if(trade.PositionModify(pos.Ticket(), sl, pos.TakeProfit())) {
   //                       Print("Pos #", pos.Ticket(), " was modified by tsl ... ");
   //                    }
   //                 }
   //              }
   //           }
   //        }
   //     }
   //  }

   MqlRates rates[];
   CopyRates(_Symbol, Timeframe, 1, 2, rates);
   ArraySetAsSeries(rates, true);

   static datetime timestamp;
   if(timestamp != rates[0].time) {
      timestamp = rates[0].time;

      CTrade trade;
      if(rates[0].open > rates[1].high + gapPoints * _Point) {
         Print("-------------------- Buy --------------------");
         Print("timestamp: ", timestamp);
         Print(rates[0].open, " ", rates[1].high + gapPoints * _Point);
         Print("rates[1].high:", rates[1].high, "; gapPoints * _Point: ", gapPoints * _Point);
         Print("---------------------------------------------");
         // open buy
         double entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double sl    = entry - SlPoints * _Point;
         double tp    = entry + TpPoints * _Point;

         double lots = calcLots(entry - sl);
         trade.Buy(lots, _Symbol, entry, sl, tp);
      } else if(rates[0].open < rates[1].low - gapPoints * _Point) {
         Print("-------------------- Sell --------------------");
         Print("timestamp: ", timestamp);
         Print(rates[0].open, " ", rates[1].low - gapPoints * _Point);
         Print("rates[1].low:", rates[1].low, "; gapPoints * _Point: ", gapPoints * _Point);
         Print("---------------------------------------------");
         // open sell
         double entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double sl    = entry + SlPoints * _Point;
         double tp    = entry - TpPoints * _Point;

         double lots = calcLots(sl - entry);
         trade.Sell(lots, _Symbol, entry, sl, tp);
      }
   }
}
//+------------------------------------------------------------------+

double calcLots(double slPoints) {
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   Print("tickValue: ", tickValue, "; tickSize: ", tickSize, "; lotStep: ", lotStep, "; slPoints: ", NormalizeDouble(slPoints, _Digits));

   int    ticks = (int)(NormalizeDouble(slPoints, _Digits) / tickSize);
   double risk  = ticks * tickValue;

   Print(ticks, " << ticks, risk >> ", risk);

   double lots = RiskMoney / risk;
   Print("Before: ", lots);
   lots = (int)(lots / lotStep) * lotStep;
   Print("After: ", lots);
   return lots;
}

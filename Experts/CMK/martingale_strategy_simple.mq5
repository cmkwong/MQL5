//+------------------------------------------------------------------+
//|                                                    MartingaleMA.mq5|
//|                        Copyright 2025, YourName                  |
//|                                       https://www.yourwebsite.com |
//+------------------------------------------------------------------+
#include <Trade/Trade.mqh>
CTrade trade;
#include <Trade/AccountInfo.mqh>
static CAccountInfo accountInfo;

// grid parameters
double initialLotSize    = 0.1;
double lotMultiplier     = 3.5;
int    gridStepPoints    = 15;
double gridStep          = gridStepPoints * _Point;
int    breakEvenTPPoints = 100;
double breakEvenTP       = breakEvenTPPoints * _Point;
int    digits_number;

// Grid tracking variable
double currentBuyGridStep = 0;

int    handle_rsi;
double rsi_array[3];

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit() {
   // create the RSI handler
   handle_rsi = iRSI(_Symbol, PERIOD_M30, 14, PRICE_CLOSE);
   return (INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
}
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {

   // CopyBuffer(handle_rsi, 0, 0, 3, rsi_array);
   InitializeVariables();
   RunTradingStrategy();
}
//+------------------------------------------------------------------+
//| Function to execute trades                                        |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
void InitializeVariables() {
   digits_number = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(currentBuyGridStep == 0) {
      currentBuyGridStep = gridStep;
   }
}

void RunTradingStrategy() {
   int    nr_buy_positions = CountBuyPositions();
   double askPrice         = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Open inital buy position if no buy positions
   if(nr_buy_positions == 0) {
      OpenInitialBuyPosition();
   }

   CheckBuyGridLevels();
   SetBreakEvenTP();
}

// get how many position being hold
int CountBuyPositions() {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) &&
         PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
         count++;
      }
   }
   return count;
}

void OpenInitialBuyPosition() {
   double askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);   // Get current ask price
   //  double lotSize  = NormalizeLotSize(initialLotSize);
   double requiredMargin = accountInfo.MarginCheck(_Symbol, ORDER_TYPE_BUY, initialLotSize, askPrice);

   // check if enough of margin to buy
   if(requiredMargin > accountInfo.FreeMargin()) {
      Print("Not enough margin for initial buy! Required: ", requiredMargin, " Free: ", accountInfo.FreeMargin());
      return;
   }
   // trigger the action for buy
   if(!trade.Buy(initialLotSize, _Symbol, askPrice, 0, 0, "Initial Buy")) {
      Print("Initial buy error: ", GetLastError());
   } else {
      Print("Initial buy position opened at ", askPrice, " with lot size ", initialLotSize);
   }
}

void CheckBuyGridLevels() {
   double minBuyPrice      = DBL_MAX;
   int    nr_buy_positions = 0;

   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == _Symbol) {
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
            double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            if(entryPrice < minBuyPrice) {
               minBuyPrice = entryPrice;
            }
            nr_buy_positions++;
         }
      }
   }

   if(nr_buy_positions > 0) {
      double nextGridBuyPrice = NormalizeDouble(minBuyPrice - currentBuyGridStep, digits_number);
      double currentAsk       = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_ASK), digits_number);

      if(currentAsk <= nextGridBuyPrice) {
         double newLotSize     = initialLotSize * MathPow(lotMultiplier, nr_buy_positions);
         double requiredMargin = accountInfo.MarginCheck(_Symbol, ORDER_TYPE_BUY, newLotSize, currentAsk);

         if(requiredMargin > accountInfo.FreeMargin()) {
            Print("Not enough margin for grid buy!");
            return;
         }

         if(!trade.Buy(newLotSize, _Symbol, currentAsk, 0, 0, "Grid Buy")) {
            Print("Grid buy error: ", GetLastError());
         }
      }
   }
}

// calculate the break even point account with profit token
void SetBreakEvenTP() {
   double totalBuyVolume = 0;
   double totalBuyCost   = 0;

   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == _Symbol) {
         double volume      = PositionGetDouble(POSITION_VOLUME);
         double entryPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
         totalBuyVolume    += volume;
         totalBuyCost      += entryPrice * volume;
      }
   }

   if(totalBuyVolume > 0) {
      double breakEvenBuyPrice = NormalizeDouble((totalBuyCost / totalBuyVolume) + breakEvenTP, digits_number);
      double currentBid        = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID), digits_number);

      if(currentBid >= breakEvenBuyPrice) {
         CloseAllBuyPositions();
      }
   }
}

// close all positions
void CloseAllBuyPositions() {
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == _Symbol) {
         if(!trade.PositionClose(ticket, 20)) {
            Print("There is error when close position - ", ticket, "with error - ", GetLastError());
         }
      }
   }
}
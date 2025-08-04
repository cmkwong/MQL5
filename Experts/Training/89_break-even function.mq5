//+------------------------------------------------------------------+
//|                             Simple Moving Average Hedging EA.mq5 |
//|                                  Copyright 2024, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"
// EA Enumerations

// Input & Global Variables
sinput group "EA General Settings";
input ulong MagicNumber = 101;

input bool UseFillingPolicy = false;
input ENUM_ORDER_TYPE_FILLING FillingPolicy = ORDER_FILLING_FOK;

sinput group "Moving Average Settings";
input int MAPeriod = 30;
input ENUM_MA_METHOD MAMethod = MODE_SMA;
input int MAShift = 0;
input ENUM_APPLIED_PRICE MAPrice = PRICE_CLOSE;

sinput group "Money Management";
input double FixedVolume = 0.01;

sinput group "Position Management";
input ushort SLFixedPoints = 0;
input ushort SLFixedPointsMA = 0;
input ushort TPFixedPoints = 0;
input ushort TSLFixedPoints = 0;
input ushort BEFixedPoints = 0;

datetime glTimeBarOpen;
int MAHandle;


//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   glTimeBarOpen = D'1971.01.01 00:00';
   
   // ------------------------- To normalize data
   // Method 1
   double close = Close(1);
   close = NormalizeDouble(close, _Digits);
   Print("Method 1: NormalizeDouble() close 1: ", close);
   
   // Method 2
   // Normalization of close price to tick size
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE); // Tick Size: USDJPY 100.105 --> 0.001   TSL 85.54 --> 0.01
   double closeTickSize = round(close / tickSize) * tickSize;           // round(85.5210000001 / 0.001) * 0.001
   Print("Method 2: Normalize close 2: ", closeTickSize, " - ", SYMBOL_TRADE_TICK_SIZE);
     
   // ------------------------- Create MA Handle
   MAHandle = MA_Init(MAPeriod, MAShift, MAMethod, MAPrice);
   if (MAHandle == -1) {
      return(INIT_FAILED);
   }
      // Moving Average
   double ma1 = ma(MAHandle, 2);
   Print("MA Value for bar 2: ", DoubleToString(ma1, _Digits));
   
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Print("Expert removed");
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
  bool newBar = false;
  
  // Check for New Bar
  if (glTimeBarOpen != iTime(_Symbol, PERIOD_CURRENT, 0)) 
  {
   newBar = true;
   glTimeBarOpen = iTime(_Symbol, PERIOD_CURRENT, 0);
  }

   // New Bar Control
   if (newBar == true) {
      // -------------- Price & Indicators
      double close = Close(1);
      Print(close);
      
      close = NormalizeDouble(close, _Digits);
      Print("Normalize close: ", close);
      
      // Normalization of close price to tick size
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE); // Tick Size: USDJPY 100.105 --> 0.001   TSL 85.54 --> 0.01
      double closeTickSize = round(close / tickSize) * tickSize;           // round(85.5210000001 / 0.001) * 0.001
      Print("Normalize close 2: ", close);

      // Price
      double close1 = Close(1);
      double close2 = Close(2);

      // Moving Average
      double ma1 = ma(MAHandle, 1);
      double ma2 = ma(MAHandle, 2);

      // -------------- Trade Exit
      string exitSignal = MA_ExitSignal(close1, close2, ma1, ma2);

      if (exitSignal == "EXIT_LONG" || exitSignal == "EXIT_SHORT") {
         CloseTrades(MagicNumber, exitSignal);
      }
      
      Sleep(1000);

      // -------------- Trade Placement
      string entrySignal = MA_EntrySignal(close1, close2, ma1, ma2);
      Comment("EA #", MagicNumber, " | ", exitSignal, " | ", entrySignal, " SIGNALS DETECTED");

      if ((entrySignal == "LONG" || entrySignal == "SHORT") && CheckPlacedPositions(MagicNumber) == false) {
         ulong ticket = OpenTrades(entrySignal, MagicNumber, FixedVolume);

         // SL & TP Trade Modification
         if (ticket > 0) {
            // double stopLoss = CalculateStopLoss(entrySignal, SLFixedPoints, SLFixedPointsMA, ma1);
            double stopLoss = CalculateStopLoss(entrySignal, SLFixedPoints, SLFixedPointsMA, ma1);
            double takeProfit = CalculateTakeProfit(entrySignal, TPFixedPoints);
            TradeModification(ticket, MagicNumber, stopLoss, takeProfit);
         }
      }
      // -------------- Position Management
      if (TSLFixedPoints > 0) TrailingStopLoss(MagicNumber, TSLFixedPoints);
      if (BEFixedPoints > 0) BreakEven(MagicNumber, BEFixedPoints);
   }
}
//+------------------------------------------------------------------+

// EA Functions

// getting close price, but it same as
// double close = iClose(_Symbol, PERIOD_CURRENT, 1);
double Close(int pShift) {
   
   MqlRates bar[];               // it creates an object array of MqlRates structure
   
   ArraySetAsSeries(bar, true);  // it sets our array as a series array (so current bar is position 0, previous bar is 1 ... )
   
   CopyRates(_Symbol, PERIOD_CURRENT, 0, 3, bar);  // it copies the bar price information of bars position 0, 1, 2 to our array 'bar'
   
   return bar[pShift].close;
}

// getting open price
double Open(int pShift) {
   
   MqlRates bar[];               // it creates an object array of MqlRates structure
   
   ArraySetAsSeries(bar, true);  // it sets our array as a series array (so current bar is position 0, previous bar is 1 ... )
   
   CopyRates(_Symbol, PERIOD_CURRENT, 0, 3, bar);  // it copies the bar price information of bars position 0, 1, 2 to our array 'bar'
   
   return bar[pShift].open;
}

// -------- Moving Average Function -------- 
int MA_Init(int pMAPeriod, int pMAShift, ENUM_MA_METHOD pMAMethod, ENUM_APPLIED_PRICE pMAPrice) {
   
   // In case of error when initializing the MA, GetLastError() will get the error code and store it in _lastError.
   // ResetLastError will change _lastError variable to 0
   ResetLastError();
   
   // A unique identifier for the indicator. Used for all actions related to the indicator, such as copying data and removing the indicator
   int Handle = iMA(_Symbol, PERIOD_CURRENT, pMAPeriod, pMAShift, pMAMethod, pMAPrice);
   
   if (Handle == INVALID_HANDLE) {
      Print("There was an error creating the MA Indicator Handle: ", GetLastError());
      return -1;
   }
   Print("MA Indicator handle initialized successfully. ");
   
   return Handle;
}

// -------- Bollinger Bands Function -------- 
int BB_Init(int pBBPeriod, int pBBShift, double pBBDeviation, ENUM_APPLIED_PRICE pBBPrice) {
   
   // In case of error when initializing the MA, GetLastError() will get the error code and store it in _lastError.
   // ResetLastError will change _lastError variable to 0
   ResetLastError();
   
   // A unique identifier for the indicator. Used for all actions related to the indicator, such as copying data and removing the indicator
   int Handle = iBands(_Symbol, PERIOD_CURRENT, pBBPeriod, pBBShift, pBBDeviation, pBBPrice);
   
   if (Handle == INVALID_HANDLE) {
      Print("There was an error creating the BB Indicator Handle: ", GetLastError());
      return -1;
   }
   Print("BB Indicator handle initialized successfully. ");
   
   return Handle;
}

double ma(int pMAHandle, int pShift) {
   ResetLastError();
   
   // We create and fill an array with MA values
   double ma_array[];
   ArraySetAsSeries(ma_array, true);
   
   // We fill the array with the 3 most recent ma_array values
   bool fillResult = CopyBuffer(pMAHandle, 0, 0, 3, ma_array);
   if (fillResult == false) {
      Print("Fill Error: ", GetLastError()); 
   }
   
   // We ask for the MA value stored in pShift
   double maValue = ma_array[pShift];
   
   // We normalize the maValue to our symbol's digits and return it
   maValue = NormalizeDouble(maValue, _Digits);
   
   return maValue;
}

double BB(int pBBHandle, int pBBLineBuffer, int pShift) {
   ResetLastError();
   
   // We create and fill an array with MA values
   double bb_array[];
   ArraySetAsSeries(bb_array, true);
   
   // We fill the array with the 3 most recent bb_array values
   bool fillResult = CopyBuffer(pBBHandle, pBBLineBuffer, 0, 3, bb_array);
   if (fillResult == false) {
      Print("Fill Error: ", GetLastError()); 
   }
   
   // We ask for the MA value stored in pShift
   double BBValue = bb_array[pShift];
   
   // We normalize the BBValue to our symbol's digits and return it
   BBValue = NormalizeDouble(BBValue, _Digits);
   
   return BBValue;
}


string MA_EntrySignal(double pPrice1, double pPrice2, double pMA1, double pMA2) {
   string str = "";
   string indicatorValues;

   if (pPrice1 > pMA1 && pPrice2 <= pMA2) {
      str = "LONG";
   } else if (pPrice1 < pMA1 && pPrice2 >= pMA2) {
      str = "SHORT";
   } else {
      str = "NO_TRADE";
   }

   StringConcatenate(indicatorValues, "MA 1: ", DoubleToString(pMA1, _Digits), " | ", "MA 2: ", DoubleToString(pMA2, _Digits), " | ", "Close 1: ", DoubleToString(pPrice1, _Digits), " | ", "Close 2: ", DoubleToString(pPrice2, _Digits));

   Print("Indicator Values: ", indicatorValues);

   return str;
}

string MA_ExitSignal(double pPrice1, double pPrice2, double pMA1, double pMA2) {
   string str = "";
   string indicatorValues;

   if (pPrice1 > pMA1 && pPrice2 <= pMA2) {
      str = "EXIT_SHORT";
   } else if (pPrice1 < pMA1 && pPrice2 >= pMA2) {
      str = "EXIT_LONG";
   } else {
      str = "NO_EXIT";
   }

   StringConcatenate(indicatorValues, "MA 1: ", DoubleToString(pMA1, _Digits), " | ", "MA 2: ", DoubleToString(pMA2, _Digits), " | ", "Close 1: ", DoubleToString(pPrice1, _Digits), " | ", "Close 2: ", DoubleToString(pPrice2, _Digits));

   Print("Indicator Values: ", indicatorValues);

   return str;
}

// Order Placement Function
ulong OpenTrades(string pEntrySignal, ulong pMagicNumber, double pFixedVol) {
   // Buy positions open trades at Ask but close them at Bid
   // Sell positions open trades at Bid but close them at Ask
   double askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   // Price must be normalized either to digits or ticksize
   askPrice = round(askPrice / tickSize) * tickSize;
   bidPrice = round(bidPrice / tickSize) * tickSize;

   string comment = pEntrySignal + " | " + _Symbol + " | " + string(MagicNumber);;

   // Request and Result Declaration and Initialization
   MqlTradeRequest request = {}; // fill of their values into empty
   MqlTradeResult result = {};

   if (pEntrySignal == "LONG") {
      // assign some of them as value
      request.action = TRADE_ACTION_DEAL;
      request.symbol = _Symbol;
      request.volume = pFixedVol;
      request.type = ORDER_TYPE_BUY;
      request.price = askPrice;
      request.deviation = 10;
      request.magic = pMagicNumber;
      request.comment = comment;

      // change the filling policy
      if (UseFillingPolicy == true) {
         request.type_filling = FillingPolicy;
      }
      
      if (!OrderSend(request, result)) {
         Print("Order Send trade placement error: ", GetLastError());
      }

      // Trade Information
      Print("Open ",request.symbol," ", pEntrySignal, " order #",result.order,": ",result.retcode,", Volume: ",result.volume,", Price: ",DoubleToString(askPrice,_Digits));

   } else if (pEntrySignal == "SHORT") {
      // assign some of them as value
      request.action = TRADE_ACTION_DEAL;
      request.symbol = _Symbol;
      request.volume = pFixedVol;
      request.type = ORDER_TYPE_SELL;
      request.price = bidPrice;
      request.deviation = 10;
      request.magic = pMagicNumber;
      request.comment = comment;

      // change the filling policy
      if (UseFillingPolicy == true) {
         request.type_filling = FillingPolicy;
      }
      
      if (!OrderSend(request, result)) {
         Print("Order Send trade placement error: ", GetLastError());
      }

      // Trade Information
      Print("Open ",request.symbol," ", pEntrySignal, " order #",result.order,": ",result.retcode,", Volume: ",result.volume,", Price: ",DoubleToString(bidPrice,_Digits));
   }

   if (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_DONE_PARTIAL || result.retcode == TRADE_RETCODE_PLACED || result.retcode == TRADE_RETCODE_NO_CHANGES) {
      return result.order;
   } else return 0;
}

void TradeModification(ulong ticket, ulong pMagic, double pSLPrice, double pTPPrice) {
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol = _Symbol;
   request.sl = round(pSLPrice / tickSize) * tickSize;
   request.tp = round(pTPPrice / tickSize) * tickSize;
   request.comment = "MOD. " + " | " + _Symbol + " | " + string(pMagic) + ", SL: " + DoubleToString(request.sl, _Digits) + ", TP: " + DoubleToString(request.tp, _Digits);

   if (request.sl > 0 || request.tp > 0) {
      Sleep(1000);
      bool sent = OrderSend(request, result);
      Print(result.comment);

      // error handle
      if (!sent) {
         Print("OrderSend Modification Error: ", GetLastError());
         Sleep(3000);
         // re-send again
         sent = OrderSend(request, result);
         Print(result.comment);
         if (!sent) Print("OrderSend 2nd Try Modification Error: ", GetLastError());
      }
   }
}

// check position
bool CheckPlacedPositions(ulong pMagic) {
   bool placedPositions = false;

   for (int i = PositionsTotal() - 1; i >= 0; i --) {
      ulong posMagic = PositionGetInteger(POSITION_MAGIC);

      if (posMagic == pMagic) {
         placedPositions = true;
         break;
      }
   }
   return placedPositions;
}

// close trade function
void CloseTrades(ulong pMagic, string pExitSignal) {
   // Request and result declaration and initialization
   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      // Reset of request and result values
      ZeroMemory(request);
      ZeroMemory(result);

      ulong positionTicket = PositionGetTicket(i);
      PositionSelectByTicket(positionTicket);

      ulong posMagic = PositionGetInteger(POSITION_MAGIC);
      ulong posType = PositionGetInteger(POSITION_TYPE);

      if (posMagic == pMagic && pExitSignal == "EXIT_LONG" && posType == ORDER_TYPE_BUY) {
         request.action = TRADE_ACTION_DEAL;
         request.type = ORDER_TYPE_SELL;
         request.symbol = _Symbol;
         request.position = positionTicket;
         request.volume = PositionGetDouble(POSITION_VOLUME);
         request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         request.deviation = 10;

         bool sent = OrderSend(request, result);
         if (sent == true) {
            Print("Position #", positionTicket, " closed");
         }
      }  else if (posMagic == pMagic && pExitSignal == "EXIT_SHORT" && posType == ORDER_TYPE_SELL) {
         request.action = TRADE_ACTION_DEAL;
         request.type = ORDER_TYPE_BUY;
         request.symbol = _Symbol;
         request.position = positionTicket;
         request.volume = PositionGetDouble(POSITION_VOLUME);
         request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         request.deviation = 10;

         bool sent = OrderSend(request, result);
         if (sent == true) {
            Print("Position #", positionTicket, " closed");
         }
      }
   }
}

// -------- Position Management Function -------- 
double CalculateStopLoss(string pEntrySignal, int pSLFixedPoints, int pSLFixedPointsMA, double pMA) {
   double stopLoss = 0.0;
   
   // Buy positions open trades at Ask but close them at Bid
   // Sell positions open trades at Bid but close them at Ask
   double askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if (pEntrySignal > "LONG") {
      if (pSLFixedPoints > 0) {
         stopLoss = bidPrice - (pSLFixedPoints * _Point);
      } else if (pSLFixedPointsMA > 0) {
         stopLoss = pMA - (pSLFixedPointsMA * _Point);
      }
   } else if (pEntrySignal == "SHORT") {
      if (pSLFixedPoints > 0) {
         stopLoss = bidPrice + (pSLFixedPoints * _Point);
      } else if (pSLFixedPointsMA > 0) {
         stopLoss = pMA + (pSLFixedPointsMA * _Point);
      }
   }
   // calculate the stop loss
   stopLoss = round(stopLoss / tickSize) * tickSize;
   return stopLoss;
}

// Take profit function
double CalculateTakeProfit(string pEntrySignal, int pTPFixedPoints) {
   double takeProfit = 0.0;
   
   // Buy positions open trades at Ask but close them at Bid
   // Sell positions open trades at Bid but close them at Ask
   double askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if (pEntrySignal > "LONG") {
      if (pTPFixedPoints > 0) {
         takeProfit = bidPrice + (pTPFixedPoints * _Point);
      }
   } else if (pEntrySignal == "SHORT") {
      if (pTPFixedPoints > 0) {
         takeProfit = bidPrice - (pTPFixedPoints * _Point);
      }
   }
   // calculate the stop loss
   takeProfit = round(takeProfit / tickSize) * tickSize;
   return takeProfit;
}

void TrailingStopLoss(ulong pMagic, int pTSLFixedPoints) {
   // Request and Result Declaration and Initialization
   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   for (int i=PositionsTotal() - 1; i>=0; i--) {
      // Reset of request and result values
      ZeroMemory(request);
      ZeroMemory(result);

      ulong positionTicket = PositionGetTicket(i);
      PositionSelectByTicket(positionTicket);

      ulong posMagic = PositionGetInteger(POSITION_MAGIC);
      ulong posType = PositionGetInteger(POSITION_TYPE);
      double currentStopLoss = PositionGetDouble(POSITION_SL);
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double newStopLoss; 

      if (posMagic == pMagic && posType == ORDER_TYPE_BUY) {
         double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         newStopLoss = bidPrice - (pTSLFixedPoints * _Point);
         newStopLoss = round(newStopLoss / tickSize) * tickSize;

         if (newStopLoss > currentStopLoss) {
            request.action = TRADE_ACTION_SLTP;
            request.position = positionTicket;
            request.comment = "TSL. " + " | " + _Symbol + " | " + string(pMagic);
            request.sl = newStopLoss;
            
            bool sent = OrderSend(request, result);
            if (!sent) Print("Order Send TSL error: ", GetLastError());

         }
      } else if (posMagic == pMagic && posType == ORDER_TYPE_SELL) {
         double askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         newStopLoss = askPrice + (pTSLFixedPoints * _Point);
         newStopLoss = round(newStopLoss / tickSize) * tickSize;

         if (newStopLoss < currentStopLoss) {
            request.action = TRADE_ACTION_SLTP;
            request.position = positionTicket;
            request.comment = "TSL. " + " | " + _Symbol + " | " + string(pMagic);
            request.sl = newStopLoss;
            
            bool sent = OrderSend(request, result);
            if (!sent) Print("Order Send TSL error: ", GetLastError());

         }
      }

   }
}

void BreakEven(ulong pMagic, int pBEFixedPoints) {
   // Request and Result Declaration and Initialization
   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   for (int i=PositionsTotal() - 1; i>=0; i--) {
      // Reset of request and result values
      ZeroMemory(request);
      ZeroMemory(result);

      ulong positionTicket = PositionGetTicket(i);
      PositionSelectByTicket(positionTicket);

      ulong posMagic = PositionGetInteger(POSITION_MAGIC);
      ulong posType = PositionGetInteger(POSITION_TYPE);
      double currentStopLoss = PositionGetDouble(POSITION_SL);
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double newStopLoss = round(openPrice / tickSize) * tickSize;

      if (posMagic == pMagic && posType == ORDER_TYPE_BUY) {
         double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double BEThreshold = openPrice + (pBEFixedPoints * _Point);

         if (newStopLoss > currentStopLoss && bidPrice > BEThreshold) {
            request.action = TRADE_ACTION_SLTP;
            request.position = positionTicket;
            request.comment = "BE. " + " | " + _Symbol + " | " + string(pMagic);
            request.sl = newStopLoss;
            
            bool sent = OrderSend(request, result);
            if (!sent) Print("Order Send BE error: ", GetLastError());

         }
      } else if (posMagic == pMagic && posType == ORDER_TYPE_SELL) {
         double askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double BEThreshold = openPrice - (pBEFixedPoints * _Point);

         if (newStopLoss < currentStopLoss && askPrice < BEThreshold) {
            request.action = TRADE_ACTION_SLTP;
            request.position = positionTicket;
            request.comment = "BE. " + " | " + _Symbol + " | " + string(pMagic);
            request.sl = newStopLoss;
            
            bool sent = OrderSend(request, result);
            if (!sent) Print("Order Send BE error: ", GetLastError());

         }
      }

   }
}
#property copyright "Copyright 2025, Chris Cheung";
#property link "";
#property version "1.00"
#property script_show_inputs

input bool UseFillingPolicy = false;
input ENUM_ORDER_TYPE_FILLING FillingPolicy = ORDER_FILLING_FOK;

uint MagicNumber = 101;

void OnStart() {

   
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
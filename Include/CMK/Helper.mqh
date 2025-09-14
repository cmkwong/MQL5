#include <Trade/AccountInfo.mqh>
#include <Trade/Trade.mqh>
static CAccountInfo accountInfo;
CTrade              trade;

// get how many position being hold (position type: buy = 0 / sell = 1 / all = -1)
int CountAllPositions(int positionType = -1) {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == _Symbol) {
         if(positionType == 0 && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
            count++;
         } else if(positionType == 1 && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) {
            count++;
         } else {
            count++;
         }
      }
   }
   return count;
}

// getting required tickets
// filterSymbol: "" = all; actionType: buy = 0 / sell = 1 / all = -1
void GetAllTickets(ulong &tickets[], string filterSymbol, int actionType = -1) {
   // getting all position tickets
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong requiredTicket = PositionGetTicket(i);
      PositionSelectByTicket(requiredTicket);
      // filter required symbol
      if(filterSymbol != "" && PositionGetString(POSITION_SYMBOL) != filterSymbol) {
         continue;
      }
      // all positions
      if(actionType == 0) {
         if(PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) {
            continue;
         }
      } else if(actionType == 1) {
         if(PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL) {
            continue;
         }
      } else if(actionType == -1) {
         continue;
      }
      int currentSize = ArraySize(tickets);
      ArrayResize(tickets, currentSize + 1);
      tickets[currentSize] = PositionGetTicket(i);
      // Print(">>>>>>>>>>>>>>>>>> Prepare to close ticket / num: ", tickets[currentSize], " / ", ArrayRange(tickets, 0) + 1, " <<<<<<<<<<<<<<<<<<<<");
   }
}

// close all positions
// filterSymbol: "" = all; actionType: buy = 0 / sell = 1 / all = -1
void CloseAllPositions(string filterSymbol, int actionType = -1) {
   ulong tickets[];
   GetAllTickets(tickets, filterSymbol, actionType);
   // looping for each of tickets array
   for(int i = 0; i < ArraySize(tickets); i++) {
      ulong ticket = tickets[i];
      if(PositionSelectByTicket(ticket)) {
         trade.PositionClose(ticket, ULONG_MAX);
         Sleep(100);   // Relax for 100 ms
      }
   }
   Print(">>>>>>>>>>>>>>>>>> Position Closed Completed <<<<<<<<<<<<<<<<<<<<");
}

// void OpenInitialPosition(string positionType, double lotSize) {
//    double requiredMargin = 0.0;
//    double actionPrice    = 0.0;
//    if(positionType == "BUY") {
//       actionPrice    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);   // Get current ask price
//       requiredMargin = accountInfo.MarginCheck(_Symbol, ORDER_TYPE_BUY, lotSize, actionPrice);
//    } else if(positionType == "SELL") {
//       actionPrice    = SymbolInfoDouble(_Symbol, SYMBOL_BID);   // Get current ask price
//       requiredMargin = accountInfo.MarginCheck(_Symbol, ORDER_TYPE_SELL, lotSize, actionPrice);
//    }

//    // check if enough of margin to buy
//    if(requiredMargin > accountInfo.FreeMargin()) {
//       Print("Not enough margin for initial buy! Required: ", requiredMargin, " Free: ", accountInfo.FreeMargin());
//       return;
//    }
//    // trigger the action for buy
//    if(positionType == "BUY" && !trade.Buy(lotSize, _Symbol, actionPrice, 0, 0, "Initial Buy")) {
//       Print("Initial buy error: ", GetLastError());
//    } else if(positionType == "SELL" && !trade.Sell(lotSize, _Symbol, actionPrice, 0, 0, "Initial Sell")) {
//       Print("Initial buy error: ", GetLastError());
//    } else {
//       Print("Initial ", positionType, " position opened at ", actionPrice, " with lot size ", lotSize);
//    }
// }

// open the position by current price
ulong OpenInitialPosition(string requiredSymbol, double lotSize = 1.0, int actionType = 0) {   // 0 = Long, 1 = Short
   double actionPrice    = 0.0;
   double requiredMargin = 0.0;
   string actionTypeStr  = "";
   if(actionType == 0) {
      actionTypeStr = "Long";
   } else {
      actionTypeStr = "Short";
   }
   if(actionType == 0) {
      // get current ask price
      actionPrice    = SymbolInfoDouble(requiredSymbol, SYMBOL_ASK);
      requiredMargin = accountInfo.MarginCheck(requiredSymbol, ORDER_TYPE_BUY, lotSize, actionPrice);
   } else if(actionType == 1) {
      // get current bid price
      actionPrice    = SymbolInfoDouble(requiredSymbol, SYMBOL_BID);
      requiredMargin = accountInfo.MarginCheck(requiredSymbol, ORDER_TYPE_SELL, lotSize, actionPrice);
   }

   // check if enough of margin to buy / sell
   if(requiredMargin > accountInfo.FreeMargin()) {
      Print("Not enough margin for initial ", actionTypeStr, "! Required: ", requiredMargin, " Free: ", accountInfo.FreeMargin());
      return false;
   }
   // trigger the action for buy
   if(actionType == 0 && trade.Buy(lotSize, requiredSymbol, actionPrice, 0, 0, "Initial Buy")) {
      Print("Initial position opened at ", actionPrice, " with lot size ", lotSize);
   } else if(actionType == 1 && trade.Sell(lotSize, requiredSymbol, actionPrice, 0, 0, "Initial Sell")) {
      Print("Initial position opened at ", actionPrice, " with lot size ", lotSize);
   } else {
      Print("Initial position error: ", GetLastError());
   }
   // return a ticket
   return PositionGetTicket(PositionsTotal() - 1);
}

// normalized into valid lot size corresponding to the Symbol
double NormalizeLot(double rawLot) {
   // new lot size
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return (int)(rawLot / lotStep) * lotStep;
}
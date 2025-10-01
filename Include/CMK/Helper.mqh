#include <Trade/AccountInfo.mqh>
#include <Trade/Trade.mqh>

// get how many position being hold (position type: buy = 0 / sell = 1 / all = -1)
int CountAllPositions(string requiredSymbol, int positionType = -1) {
   int count = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      if(StringCompare(sym, requiredSymbol) != 0)
         continue;

      long ptype = PositionGetInteger(POSITION_TYPE);

      if(positionType == -1 ||
         (positionType == 0 && ptype == POSITION_TYPE_BUY) ||
         (positionType == 1 && ptype == POSITION_TYPE_SELL)) {
         count++;
      }
   }
   return count;
}

// getting required tickets
// filterSymbol: "" = all; actionType: buy = 0 / sell = 1 / all = -1
void GetAllTickets(ulong &tickets[], string filterSymbol, int actionType = -1) {
   ArrayResize(tickets, 0);
   int total = PositionsTotal();

   for(int i = 0; i < total; i++) {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(!PositionSelectByTicket(tk))
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      if(filterSymbol != "" && StringCompare(sym, filterSymbol) != 0)
         continue;

      long ptype = PositionGetInteger(POSITION_TYPE);

      if(actionType != -1) {
         if(actionType == 0 && ptype != POSITION_TYPE_BUY)
            continue;
         if(actionType == 1 && ptype != POSITION_TYPE_SELL)
            continue;
      }

      int n = ArraySize(tickets);
      ArrayResize(tickets, n + 1);
      tickets[n] = tk;
   }
}

// close all positions
// filterSymbol: "" = all; actionType: buy = 0 / sell = 1 / all = -1
void CloseAllPositions(string filterSymbol, int actionType = -1) {
   CTrade trade;
   ulong  tickets[];
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

// open the position by current price
ulong OpenInitialPosition(string requiredSymbol, double lotSize = 1.0, int actionType = 0) {   // 0 = Long, 1 = Short
   static CAccountInfo accountInfo;
   CTrade              trade;
   double              actionPrice    = 0.0;
   double              requiredMargin = 0.0;
   string              actionTypeStr  = "";
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

// get the total balance from same magic number
double GetMagicBalance(int magicNum) {
   double positionBalance = 0;
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == magicNum) {
         positionBalance += PositionGetDouble(POSITION_PROFIT);
      }
   }
   return positionBalance;
}

// normalized into valid lot size corresponding to the Symbol
double NormalizeLot(string symbol, double rawLot) {
   // new lot size
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   return (int)(rawLot / lotStep) * lotStep;
}
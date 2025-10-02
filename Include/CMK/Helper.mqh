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
// symbol: "" = all; actionType: buy = 0 / sell = 1 / all = -1
void GetAllTickets(ulong &tickets[], string symbol, int actionType = -1) {
   ArrayResize(tickets, 0);
   int totalPos = PositionsTotal();

   for(int i = 0; i < totalPos; i++) {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(!PositionSelectByTicket(tk))
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      if(symbol != "" && StringCompare(sym, symbol) != 0)
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

// get all ticket by magic
int GetTickets_ByMagic(ulong &tickets[], ulong magic, bool includePending = false) {
   ArrayResize(tickets, 0);

   // 1) Positions (market positions)
   int totalPos = PositionsTotal();
   for(int i = 0; i < totalPos; i++) {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(!PositionSelectByTicket(tk))
         continue;

      ulong posMagic = PositionGetInteger(POSITION_MAGIC);
      if(posMagic == magic) {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         int   n      = ArraySize(tickets);
         ArrayResize(tickets, n + 1);
         tickets[n] = ticket;
      }
   }

   // 2) Pending Orders (optional)
   if(includePending) {
      int totalOrd = OrdersTotal();
      for(int i = 0; i < totalOrd; i++) {
         ulong tk = OrderGetTicket(i);
         if(tk == 0)
            continue;
         if(!OrderSelect(tk))
            continue;

         ulong ordMagic = OrderGetInteger(ORDER_MAGIC);
         if(ordMagic == magic) {
            ulong ticket = OrderGetInteger(ORDER_TICKET);
            int   n      = ArraySize(tickets);
            ArrayResize(tickets, n + 1);
            tickets[n] = ticket;
         }
      }
   }

   return ArraySize(tickets);
}

// close all positions
// symbol: "" = all; actionType: buy = 0 / sell = 1 / all = -1
void CloseAllPositions(string symbol = NULL, int actionType = -1, bool byMagic = false, ulong magicNum = NULL) {
   CTrade trade;
   ulong  tickets[];
   if(!byMagic) {
      GetAllTickets(tickets, symbol, actionType);
   } else {
      GetTickets_ByMagic(tickets, magicNum);
   }
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
ulong OpenInitialPosition(string requiredSymbol, double lotSize = 1.0, int actionType = 0, ulong magic = NULL) {   // 0 = Long, 1 = Short
   static CAccountInfo accountInfo;
   CTrade              trade;
   double              actionPrice    = 0.0;
   double              requiredMargin = 0.0;
   string              actionTypeStr  = "";
   // magic assign
   if(magic) {
      trade.SetExpertMagicNumber(magic);
   }
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

// get the total balance from same symbol
double GetSymbolBalance(string symbol) {
   double positionBalance = 0;
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == symbol) {
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

// get the points difference between two prices
int PointsBetween(double lastPrice, double firstPrice, string symbol) {
   // Get point size and tick size for the symbol
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   // double ticksize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);

   // if(point <= 0.0)
   //    return 0.0;

   // // Prefer tick size if the broker defines it (handles non-decimal increments)
   // double unit = (ticksize > 0.0) ? ticksize : point;

   // Convert price difference to "points"
   double diff = lastPrice - firstPrice;
   double pts  = diff / point;
   // Print("lastPrice: ", DoubleToString(lastPrice));
   // Print("firstPrice: ", DoubleToString(firstPrice));
   // Print("double diff = lastPrice - firstPrice: ", DoubleToString(lastPrice - firstPrice));
   // Print("double pts  = diff / point: ", DoubleToString(diff / point));
   // Print("pts: ", pts);
   if(pts < 0) {
      return (int)MathFloor(pts);
   } else {
      return (int)MathCeil(pts);
   }
}
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

// close all position by tickets
int CloseAllTickets(ulong &tickets[]) {
   CTrade trade;
   int    closed = 0;
   int    n      = ArraySize(tickets);
   for(int i = 0; i < n; i++) {
      ulong tk = tickets[i];
      if(!PositionSelectByTicket(tk))
         continue;

      if(trade.PositionClose(tk, ULONG_MAX))
         closed++;

      Sleep(100);   // avoid server slowdown
   }
   return closed;
}

// close all positions
// symbol: "" = all; actionType: buy = 0 / sell = 1 / all = -1
int CloseAllPositions(string symbol = "", int actionType = -1, bool byMagic = false, ulong magicNum = 0) {
   ulong tickets[];

   // get required ticket
   if(byMagic)
      GetTickets_ByMagic(tickets, magicNum, false);
   else
      GetAllTickets(tickets, symbol, actionType);

   int n      = ArraySize(tickets);
   int closed = CloseAllTickets(tickets);
   PrintFormat(">>>>>>>> Closed %d/%d positions <<<<<<<<", closed, n);
   return closed;
}

// open the position by current price
ulong OpenInitialPosition(string requiredSymbol,
                          double lotSize    = 1.0,
                          int    actionType = 0,   // 0 = Long, 1 = Short
                          ulong  magic      = NULL,
                          string comment    = "")   // 新增：下單注釋
{
   static CAccountInfo accountInfo;
   CTrade              trade;

   double actionPrice    = 0.0;
   double requiredMargin = 0.0;
   string actionTypeStr  = (actionType == 0 ? "Long" : "Short");

   // 設置魔術號
   if(magic)
      trade.SetExpertMagicNumber(magic);

   // 取得當前報價與所需保證金
   if(actionType == 0) {
      actionPrice    = SymbolInfoDouble(requiredSymbol, SYMBOL_ASK);
      requiredMargin = accountInfo.MarginCheck(requiredSymbol, ORDER_TYPE_BUY, lotSize, actionPrice);
   } else {
      actionPrice    = SymbolInfoDouble(requiredSymbol, SYMBOL_BID);
      requiredMargin = accountInfo.MarginCheck(requiredSymbol, ORDER_TYPE_SELL, lotSize, actionPrice);
   }

   // 檢查可用保證金
   if(requiredMargin > accountInfo.FreeMargin()) {
      PrintFormat("Not enough margin for initial %s! Required: %.2f Free: %.2f",
                  actionTypeStr, requiredMargin, accountInfo.FreeMargin());
      return 0;   // 失敗
   }

   // 執行下單（注意：CTrade::Buy/Sell 的 price 可為 0 以使用當前市價）
   bool  placed     = false;
   ulong pos_ticket = 0;

   double normalized_lostSize = NormalizeLot(requiredSymbol, lotSize);
   if(actionType == 0) {
      placed = trade.Buy(normalized_lostSize, requiredSymbol, 0.0, 0.0, 0.0, comment);
   } else {
      placed = trade.Sell(normalized_lostSize, requiredSymbol, 0.0, 0.0, 0.0, comment);
   }

   if(!placed) {
      Print("Initial position error: ", GetLastError());
      return 0;
   }

   // 取得最近的訂單/倉位票號
   // 對於市價單，成功後通常會有持倉，優先從 PositionGetInteger 取得
   ulong order_ticket = trade.ResultOrder();
   ulong deal_ticket  = trade.ResultDeal();
   ulong ret_ticket   = 0;

   // 嘗試從持倉表找到該 symbol 的最新倉位
   if(PositionSelect(requiredSymbol)) {
      ret_ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      PrintFormat("Initial position opened at %s with lot size %.2f (ticket=%I64u)",
                  actionTypeStr, lotSize, ret_ticket);
      return ret_ticket;
   }

   // 若未能直接選中倉位，回退返回成交或訂單票號
   if(deal_ticket != 0)
      ret_ticket = deal_ticket;
   else
      ret_ticket = order_ticket;

   PrintFormat("Initial position placed %s with lot size %.2f (ticket=%I64u)",
               actionTypeStr, lotSize, ret_ticket);

   return ret_ticket;
}

// // open the position by current price
// ulong OpenInitialPosition(string requiredSymbol, double lotSize = 1.0, int actionType = 0, ulong magic = NULL) {   // 0 = Long, 1 = Short
//    static CAccountInfo accountInfo;
//    CTrade              trade;
//    double              actionPrice    = 0.0;
//    double              requiredMargin = 0.0;
//    string              actionTypeStr  = "";
//    // magic assign
//    if(magic) {
//       trade.SetExpertMagicNumber(magic);
//    }
//    if(actionType == 0) {
//       actionTypeStr = "Long";
//    } else {
//       actionTypeStr = "Short";
//    }
//    if(actionType == 0) {
//       // get current ask price
//       actionPrice    = SymbolInfoDouble(requiredSymbol, SYMBOL_ASK);
//       requiredMargin = accountInfo.MarginCheck(requiredSymbol, ORDER_TYPE_BUY, lotSize, actionPrice);
//    } else if(actionType == 1) {
//       // get current bid price
//       actionPrice    = SymbolInfoDouble(requiredSymbol, SYMBOL_BID);
//       requiredMargin = accountInfo.MarginCheck(requiredSymbol, ORDER_TYPE_SELL, lotSize, actionPrice);
//    }

//    // check if enough of margin to buy / sell
//    if(requiredMargin > accountInfo.FreeMargin()) {
//       Print("Not enough margin for initial ", actionTypeStr, "! Required: ", requiredMargin, " Free: ", accountInfo.FreeMargin());
//       return false;
//    }
//    // trigger the action for buy
//    if(actionType == 0 && trade.Buy(lotSize, requiredSymbol, actionPrice, 0, 0, "Initial Buy")) {
//       Print("Initial position opened at ", actionPrice, " with lot size ", lotSize);
//    } else if(actionType == 1 && trade.Sell(lotSize, requiredSymbol, actionPrice, 0, 0, "Initial Sell")) {
//       Print("Initial position opened at ", actionPrice, " with lot size ", lotSize);
//    } else {
//       Print("Initial position error: ", GetLastError());
//    }
//    // return a ticket
//    return PositionGetTicket(PositionsTotal() - 1);
// }

// get the total balance from same magic number
double GetMagicBalance(ulong magicNum) {
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
int PointsDiff(double lastPrice, double firstPrice, string symbol) {
   // Get point size and tick size for the symbol
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

   // Convert price difference to "points"
   double diff = lastPrice - firstPrice;
   double pts  = diff / point;

   if(pts < 0) {
      // eg: -5.3 -> -6.0
      return (int)MathFloor(pts);
   } else {
      // eg: +5.3 -> +6.0
      return (int)MathCeil(pts);
   }
}

// must be same position type
double GetPositionCost(ulong &tickets[], double &totalPositionVolume, int tickets_actionType = 0) {
   // let the first position is the direction
   ENUM_POSITION_TYPE _positionType;
   if(tickets_actionType == 0) {
      _positionType = POSITION_TYPE_BUY;
   } else {
      _positionType = POSITION_TYPE_SELL;
   }
   double positionCost      = 0.0;
   double totalPositionCost = 0.0;
   totalPositionVolume      = 0.0;
   for(int i = 0; i < ArraySize(tickets); i++) {
      ulong ticket = tickets[i];
      // select the position and with the same symbol & checking to keep in same position type
      if(PositionSelectByTicket(ticket) && _positionType == PositionGetInteger(POSITION_TYPE)) {
         double volume        = PositionGetDouble(POSITION_VOLUME);
         double entryPrice    = PositionGetDouble(POSITION_PRICE_OPEN);
         totalPositionVolume += volume;
         totalPositionCost   += entryPrice * volume;
      }
   }
   // assign position cost
   if(totalPositionVolume > 0) {
      positionCost = totalPositionCost / totalPositionVolume;
   }
   return positionCost;
}
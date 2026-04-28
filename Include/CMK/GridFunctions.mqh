//+------------------------------------------------------------------+
//| Helper function to open a position at a specific level           |
//+------------------------------------------------------------------+
void OpenLevelPosition(int symbolIndex, int main_actionType, int level, int action_type, string actionType_word) {
   // Calculate lot size based on level and accumulated loss
   double lotSize = i_initialLotSize;
   if(level > 0) {
      // Get accumulated loss for this symbol and main action type
      double accumulatedLoss = GetAccumulatedLoss(symbolIndex, main_actionType);
      // Calculate base multiplier from level
      double levelMultiplier = MathPow(HedgingMultiplier[symbolIndex], level);
      // Adjust lot size based on both level and loss
      lotSize = CalculateAdjustedLotSize(symbolIndex, i_initialLotSize, levelMultiplier, accumulatedLoss);
      lotSize = NormalizeLot(Symbols[symbolIndex], lotSize);
   }
   // Set magic number and comment
   ulong  magic   = Encode4_Bytes(symbolIndex, main_actionType, level, action_type);
   string comment = "Initial " + actionType_word + " level - " + IntegerToString(level);
   // Open the position
   OpenInitialPosition(Symbols[symbolIndex], lotSize, action_type, magic, comment);
}

//+------------------------------------------------------------------+
//| Setup grid trading parameters based on action type               |
//+------------------------------------------------------------------+
void SetupGridParameters(int sub_actionType, double &lastEntryPrice,
                         ENUM_POSITION_TYPE &positionType, ENUM_ORDER_TYPE &orderType,
                         string &long_short_wording) {
   if(sub_actionType == 0) {
      lastEntryPrice     = DBL_MAX;
      positionType       = POSITION_TYPE_BUY;
      orderType          = ORDER_TYPE_BUY;
      long_short_wording = "Buy";
   } else {
      lastEntryPrice     = DBL_MIN;
      positionType       = POSITION_TYPE_SELL;
      orderType          = ORDER_TYPE_SELL;
      long_short_wording = "Sell";
   }
}

//+------------------------------------------------------------------+
//| Find existing positions and their details                        |
//+------------------------------------------------------------------+
int FindExistingPositions(ulong &tickets[], int sub_actionType, double &lastEntryPrice, double &lastLotSize) {
   int    nr_positions     = 0;
   double closestPriceDiff = DBL_MAX;

   // First pass - determine the number of positions and find the last entry price
   for(int i = 0; i < ArraySize(tickets); i++) {
      ulong ticket = tickets[i];
      // select the position and with the same symbol
      if(PositionSelectByTicket(ticket)) {
         // get the position entry price
         double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         if(sub_actionType == 0 && entryPrice < lastEntryPrice) {
            lastEntryPrice = entryPrice;
            // level of positions
            nr_positions++;
         } else if(sub_actionType == 1 && entryPrice > lastEntryPrice) {
            lastEntryPrice = entryPrice;
            // level of positions
            nr_positions++;
         }
      }
   }

   // Second pass - find the lot size of the most recent position
   // We need to track the position with the price closest to lastEntryPrice
   for(int i = 0; i < ArraySize(tickets); i++) {
      ulong ticket = tickets[i];
      if(PositionSelectByTicket(ticket)) {
         double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double priceDiff  = MathAbs(entryPrice - lastEntryPrice);
         if(priceDiff < closestPriceDiff) {
            closestPriceDiff = priceDiff;
            lastLotSize      = PositionGetDouble(POSITION_VOLUME);
         }
      }
   }

   return nr_positions;
}

//+------------------------------------------------------------------+
//| Calculate the next grid price and get current market price       |
//+------------------------------------------------------------------+
void CalculateGridPrices(int symbolIndex, int sub_actionType, double lastEntryPrice,
                         int nr_positions, double &nextGridPrice, double &currentPrice) {
   if(sub_actionType == 0) {
      // calculate the next grid buying price
      nextGridPrice = NormalizeDouble(lastEntryPrice - (v_actionGridSteps[symbolIndex]) *
                                                           MathPow(i_gridStepMultiplier, nr_positions),
                                      v_digits_numbers[symbolIndex]);
      // get normalized ask price
      currentPrice = NormalizeDouble(SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_ASK), v_digits_numbers[symbolIndex]);
   } else {
      // calculate the next grid selling price
      nextGridPrice = NormalizeDouble(lastEntryPrice + (v_actionGridSteps[symbolIndex]) *
                                                           MathPow(i_gridStepMultiplier, nr_positions),
                                      v_digits_numbers[symbolIndex]);
      // get normalized bid price
      currentPrice = NormalizeDouble(SymbolInfoDouble(Symbols[symbolIndex], SYMBOL_BID), v_digits_numbers[symbolIndex]);
   }
}

//+------------------------------------------------------------------+
//| Check if there's enough margin for the trade                     |
//+------------------------------------------------------------------+
bool CheckMarginRequirements(int symbolIndex, ENUM_ORDER_TYPE orderType,
                             double newLotSize, double currentPrice, string long_short_wording) {
   double requiredMargin = accountInfo.MarginCheck(Symbols[symbolIndex], orderType, newLotSize, currentPrice);

   if(requiredMargin > accountInfo.FreeMargin()) {
      Print("Not enough margin for grid ", long_short_wording, "! Required Margin / Free Margin: ",
            DoubleToString(requiredMargin), " / ", DoubleToString(accountInfo.FreeMargin()));
      CloseAllPositions(Symbols[symbolIndex], 0);
      datetime currDatetime           = TimeCurrent();
      v_backToTradeUntil[symbolIndex] = AddDate(currDatetime, i_sleepDays);
      Print("==============> Restarted ", TimeToString(currDatetime), " until ",
            TimeToString(v_backToTradeUntil[symbolIndex]), " <==============");
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Execute the grid trade                                           |
//+------------------------------------------------------------------+
void ExecuteGridTrade(int symbolIndex, int main_actionType, int sub_actionType,
                      int level, double newLotSize, double currentPrice,
                      string long_short_wording, int nr_positions, double initLevelLot) {
   string master_actionType_word = main_actionType == 0 ? "Buy" : "Sell";

   if(sub_actionType == 0) {
      if(!trade.Buy(newLotSize, Symbols[symbolIndex], currentPrice, 0, 0,
                    "Grid " + master_actionType_word + " level - " + IntegerToString(level))) {
         Print("Grid buy error: ", GetLastError());
      } else {
         // Log successful grid trade
         LogTradeExecution(symbolIndex, "Grid " + long_short_wording, newLotSize, currentPrice, level,
                           "Grid step: " + IntegerToString(nr_positions) + ", Base lot: " +
                               DoubleToString(initLevelLot, 2));
      }
   } else {
      if(!trade.Sell(newLotSize, Symbols[symbolIndex], currentPrice, 0, 0,
                     "Grid " + master_actionType_word + " level - " + IntegerToString(level))) {
         Print("Grid sell error: ", GetLastError());
      } else {
         // Log successful grid trade
         LogTradeExecution(symbolIndex, "Grid " + long_short_wording, newLotSize, currentPrice, level,
                           "Grid step: " + IntegerToString(nr_positions) + ", Base lot: " +
                               DoubleToString(initLevelLot, 2));
      }
   }
}

//+------------------------------------------------------------------+
//| Check the grid level and execute trades if conditions are met    |
//+------------------------------------------------------------------+
void CheckGridLevels(int symbolIndex, int main_actionType, int level, int sub_actionType) {
   double             lastEntryPrice;
   string             long_short_wording;
   ENUM_POSITION_TYPE positionType;
   ENUM_ORDER_TYPE    orderType;

   // Setup parameters based on action type
   SetupGridParameters(sub_actionType, lastEntryPrice, positionType, orderType, long_short_wording);

   // The init lot for the level - start with initial lot size instead of DBL_MAX
   double initLevelLot = i_initialLotSize;
   double lastLotSize  = 0;   // To track the lot size of the last position in the grid

   // Get tickets by magic number
   ulong tickets[];
   ulong magic = Encode4_Bytes(symbolIndex, main_actionType, level, sub_actionType);
   GetTickets_ByMagic(tickets, magic);

   // Find existing positions and their details
   int nr_positions = FindExistingPositions(tickets, sub_actionType, lastEntryPrice, lastLotSize);

   // If we found positions, use the last lot size as our base
   if(nr_positions > 0 && lastLotSize > 0) {
      initLevelLot = lastLotSize;
   }

   if(nr_positions > 0) {
      double nextGridPrice;
      double currentPrice;

      // Setting the magic number (setting in global)
      trade.SetExpertMagicNumber(Encode4_Bytes(symbolIndex, main_actionType, level, sub_actionType));

      // Calculate grid prices
      CalculateGridPrices(symbolIndex, sub_actionType, lastEntryPrice, nr_positions,
                          nextGridPrice, currentPrice);

      // Check if price has reached the next grid level
      if((sub_actionType == 0 && currentPrice <= nextGridPrice) ||
         (sub_actionType == 1 && currentPrice >= nextGridPrice)) {

         // Calculate new lot size
         double newLotSize = initLevelLot * i_lotMultiplier;   // Multiply by i_lotMultiplier directly
         newLotSize        = NormalizeLot(Symbols[symbolIndex], newLotSize);

         // Check margin requirements
         if(!CheckMarginRequirements(symbolIndex, orderType, newLotSize, currentPrice, long_short_wording)) {
            return;
         }

         // Execute the trade
         ExecuteGridTrade(symbolIndex, main_actionType, sub_actionType, level,
                          newLotSize, currentPrice, long_short_wording, nr_positions, initLevelLot);
      }
   }
}
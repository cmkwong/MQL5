//+------------------------------------------------------------------+
//|                                                    MartingaleMA.mq5|
//|                        Copyright 2025, YourName                  |
//|                                       https://www.yourwebsite.com |
//+------------------------------------------------------------------+
input double LotSize       = 0.1;     // Initial lot size
input double Multiplier    = 2.0;     // Martingale multiplier
input int MovingAveragePeriod = 14;    // Moving Average period
input double TakeProfit    = 50;       // Take profit in points
input double StopLoss      = 50;       // Stop loss in points
input double AccountRisk   = 0.01;     // Risk per trade

double maPrevious, maCurrent;
int ticket;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
  {
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Calculate the moving average
   maCurrent = iMA(_Symbol, 0, MovingAveragePeriod, 0, MODE_SMA, PRICE_CLOSE, 0);
   maPrevious = iMA(_Symbol, 0, MovingAveragePeriod, 0, MODE_SMA, PRICE_CLOSE, 1);

   // Check for buy signal
   if (maPrevious < Close(1) && maCurrent > Close(1))
     {
      ExecuteTrade(ORDER_BUY);
     }
   // Check for sell signal
   else if (maPrevious > Close(1) && maCurrent < Close(1))
     {
      ExecuteTrade(ORDER_SELL);
     }
  }
//+------------------------------------------------------------------+
//| Function to execute trades                                        |
//+------------------------------------------------------------------+
void ExecuteTrade(int orderType)
  {
   double lotSize = LotSize;
   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = accountBalance * AccountRisk;

   // Calculate the lot size based on the risk amount
   if (orderType == ORDER_BUY)
     {
      ticket = OrderSend(Symbol(), orderType, lotSize, Ask, 3, 0, 0, "Martingale Buy", 0, 0, clrGreen);
     }
   else
     {
      ticket = OrderSend(Symbol(), orderType, lotSize, Bid, 3, 0, 0, "Martingale Sell", 0, 0, clrRed);
     }

   if (ticket > 0)
     {
      // Set take profit and stop loss
      double tp = orderType == ORDER_BUY ? NormalizeDouble(Ask + TakeProfit * _Point, _Digits) : NormalizeDouble(Bid - TakeProfit * _Point, _Digits);
      double sl = orderType == ORDER_BUY ? NormalizeDouble(Ask - StopLoss * _Point, _Digits) : NormalizeDouble(Bid + StopLoss * _Point, _Digits);
      OrderSend(Symbol(), orderType, lotSize, orderType == ORDER_BUY ? Ask : Bid, 3, sl, tp, "Martingale Trade", 0, 0, clrBlue);
     }
   else
     {
      Print("Error opening order: ", GetLastError());
     }
  }
//+------------------------------------------------------------------+
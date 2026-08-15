// Expert Advisor: GRID 06.V02 - RECOVERY & GROWTH EDITION 2026
// Adaptive Equity Scaling + Basket Risk / Exit Protection
#property strict
#property copyright "Copyright 2026, Jarvis"
#property version   "6.21"

//--- Enums ---
enum Type {Open_Buy_And_Sell, Open__Only_Buy, Open__Only_Sell};

//--- Input Parameters ---
input string SafeParameters          = "||========== SAFETY & RECOVERY ==========||";
input double MaxEquityLossPercent    = 12.0;  // Account-level last resort only
input bool   UseTrailingProfit       = true;
input double TrailingStartUSD        = 5.0;
input double TrailingStopUSD         = 2.0;

//--- Basket Risk / Exit Protection ---
input string BasketRiskSettings      = "||========== BASKET RISK / EXIT ==========||";
input bool   UseBasketLossProtection = true;
input double BasketWarningLossPct   = 3.0;   // Warning: no aggressive recovery
input double BasketFreezeLossPct    = 5.0;   // Freeze: no new grid layer
input double BasketHardLossPct     = 7.0;   // Hard close basket
input bool   UseBasketTimeout       = true;
input double MaxBasketHours         = 48.0;  // Hard close aged basket

//--- Indicator Parameters ---
input string RSI_Settings            = "||========== INDICATORS ==========||";
input int    MAPeriod                = 200;
input int    RSIPeriod               = 14;
input int    RSIUpper                = 70;
input int    RSILower                = 30;

//--- Grid Parameters ---
input string Grid_Settings            = "||========== GRID LOGIC ==========||";
input Type   TypeOrdersPlace          = Open_Buy_And_Sell;
input double PointsForFirstGap        = 5000.0;
input double GapMultiplier            = 1.3;
input double TargetProfitUSD          = 5.0;
input double ManualLotSize            = 0.01;
input int    MaxOrders                = 6;
input int    MagicNumber              = 88888;
input string CommentsOrders           = "GRID SAFE 2026";

//--- Trading Hour ---
input string TradingHourSettings      = "||========== TRADING HOURS ==========||";
input bool   UseTradingHour           = true;
input int    StartHour                = 7;
input int    EndHour                  = 22;

//--- Global Variables ---
string SymbolTrade;
int    OrdersID, HandleRSI, HandleMA;
int    BuyOrders, SellOrders;
double BuyProfits, SellProfits;
double PriceOpenLastBuy, PriceOpenLastSell;

bool   IsTerminated = false;
double HighWaterMark = 0;

double InitialBalance     = 0;
double AdaptiveEquityBase = 0;
double LockedProfit       = 0;

double MaxBuyProfitSeen  = 0;
double MaxSellProfitSeen = 0;

bool IsTradingHour()
{
   if(!UseTradingHour)
      return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   int hour = dt.hour;

   if(StartHour < EndHour)
      return (hour >= StartHour && hour < EndHour);
   else
      return (hour >= StartHour || hour < EndHour);
}

int OnInit()
{
   SymbolTrade = _Symbol;

   OrdersID = (MagicNumber == 0)
      ? 101010
      : MagicNumber;

   HandleRSI = iRSI(SymbolTrade, PERIOD_CURRENT, RSIPeriod, PRICE_CLOSE);

   HandleMA  = iMA(SymbolTrade,
                   PERIOD_CURRENT,
                   MAPeriod,
                   0,
                   MODE_SMA,
                   PRICE_CLOSE);

   HighWaterMark = AccountInfoDouble(ACCOUNT_BALANCE);

   InitialBalance     = AccountInfoDouble(ACCOUNT_BALANCE);
   AdaptiveEquityBase = InitialBalance;
   LockedProfit       = 0;

   MaxBuyProfitSeen  = 0;
   MaxSellProfitSeen = 0;

   if(HandleRSI == INVALID_HANDLE || HandleMA == INVALID_HANDLE)
   {
      Print("Gagal inisialisasi indikator!");
      return(INIT_FAILED);
   }

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   IndicatorRelease(HandleRSI);
   IndicatorRelease(HandleMA);
   Comment("");
}

void OnTick()
{
   if(IsTerminated)
      return;

   UpdateStatus();

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   LockedProfit = balance - InitialBalance;

   if(LockedProfit < 0)
      LockedProfit = 0;

   AdaptiveEquityBase = InitialBalance + LockedProfit;

   if(balance > HighWaterMark)
      HighWaterMark = balance;

   bool IsInRecovery = (balance < HighWaterMark);

   double currentDrawdown = 0;

   if(AdaptiveEquityBase > 0 && equity < AdaptiveEquityBase)
   {
      currentDrawdown =
         ((AdaptiveEquityBase - equity)
         / AdaptiveEquityBase) * 100.0;
   }

   // Account protection is the final safety layer.
   if(currentDrawdown >= MaxEquityLossPercent)
   {
      PrintFormat("!!! ACCOUNT EMERGENCY CUT: Drawdown %.2f%% !!!",
                  currentDrawdown);

      CloseAllOrders();
      IsTerminated = true;
      return;
   }

   // EXIT/RISK MANAGEMENT IS ALWAYS ACTIVE. Trading hours only control new entries.
   ManageExit(IsInRecovery);
   UpdateStatus();

   if(IsTerminated)
      return;

   double rsi   = GetRSIValue();
   double ma    = GetMAValue();
   double price = SymbolInfoDouble(SymbolTrade, SYMBOL_BID);

   int lowRSI  = IsInRecovery ? (RSILower - 5) : RSILower;
   int highRSI = IsInRecovery ? (RSIUpper + 5) : RSIUpper;

   bool canOpenBuy  = false;
   bool canOpenSell = false;

   //--- First entry
   if(BuyOrders == 0 &&
      (TypeOrdersPlace == Open_Buy_And_Sell
      || TypeOrdersPlace == Open__Only_Buy))
   {
      if(price > ma && rsi < lowRSI)
         canOpenBuy = true;
   }

   if(SellOrders == 0 &&
      (TypeOrdersPlace == Open_Buy_And_Sell
      || TypeOrdersPlace == Open__Only_Sell))
   {
      if(price < ma && rsi > highRSI)
         canOpenSell = true;
   }

   //--- Grid recovery is blocked once basket reaches freeze loss.
   bool buyFrozen  = IsBasketFrozen(POSITION_TYPE_BUY);
   bool sellFrozen = IsBasketFrozen(POSITION_TYPE_SELL);

   if(BuyOrders > 0 && BuyOrders < MaxOrders && !buyFrozen)
   {
      double gap = PointsForFirstGap * MathPow(GapMultiplier, BuyOrders - 1);

      if(SymbolInfoDouble(SymbolTrade, SYMBOL_ASK)
         <= PriceOpenLastBuy - (gap * _Point))
      {
         canOpenBuy = true;
      }
   }

   if(SellOrders > 0 && SellOrders < MaxOrders && !sellFrozen)
   {
      double gap = PointsForFirstGap * MathPow(GapMultiplier, SellOrders - 1);

      if(price >= PriceOpenLastSell + (gap * _Point))
      {
         canOpenSell = true;
      }
   }

   //--- Trading hours apply to NEW ENTRY only.
   if(!IsTradingHour())
   {
      DisplayDashboard(currentDrawdown, rsi, IsInRecovery);
      return;
   }

   if(canOpenBuy && !buyFrozen)
      ExecuteTrade(ORDER_TYPE_BUY);

   if(canOpenSell && !sellFrozen)
      ExecuteTrade(ORDER_TYPE_SELL);

   UpdateStatus();
   DisplayDashboard(currentDrawdown, rsi, IsInRecovery);
}

void ManageExit(bool recovery)
{
   //========================================================
   // BUY BASKET
   //========================================================
   if(BuyOrders <= 0)
   {
      MaxBuyProfitSeen = 0;
   }
   else
   {
      double buyLossPct = BasketLossPercent(BuyProfits);
      double buyAgeHrs  = GetBasketAgeHours(POSITION_TYPE_BUY);

      if(UseBasketLossProtection && buyLossPct >= BasketHardLossPct)
      {
         PrintFormat("BASKET HARD EXIT BUY: loss %.2f%% / P/L %.2f",
                     buyLossPct, BuyProfits);
         CloseOrdersByType(POSITION_TYPE_BUY);
         MaxBuyProfitSeen = 0;
      }
      else if(UseBasketTimeout && buyAgeHrs >= MaxBasketHours)
      {
         PrintFormat("BASKET TIMEOUT BUY: age %.2f hours / P/L %.2f",
                     buyAgeHrs, BuyProfits);
         CloseOrdersByType(POSITION_TYPE_BUY);
         MaxBuyProfitSeen = 0;
      }
      else
      {
         double target = recovery ? (TargetProfitUSD + 2.0) : TargetProfitUSD;

         if(!UseTrailingProfit)
         {
            if(BuyProfits >= target)
            {
               CloseOrdersByType(POSITION_TYPE_BUY);
               MaxBuyProfitSeen = 0;
            }
         }
         else if(BuyProfits >= TrailingStartUSD)
         {
            if(BuyProfits > MaxBuyProfitSeen)
               MaxBuyProfitSeen = BuyProfits;

            if(BuyProfits <= MaxBuyProfitSeen - TrailingStopUSD)
            {
               CloseOrdersByType(POSITION_TYPE_BUY);
               MaxBuyProfitSeen = 0;
            }
         }
         else if(BuyProfits <= 0)
         {
            MaxBuyProfitSeen = 0;
         }
      }
   }

   //========================================================
   // SELL BASKET
   //========================================================
   if(SellOrders <= 0)
   {
      MaxSellProfitSeen = 0;
   }
   else
   {
      double sellLossPct = BasketLossPercent(SellProfits);
      double sellAgeHrs  = GetBasketAgeHours(POSITION_TYPE_SELL);

      if(UseBasketLossProtection && sellLossPct >= BasketHardLossPct)
      {
         PrintFormat("BASKET HARD EXIT SELL: loss %.2f%% / P/L %.2f",
                     sellLossPct, SellProfits);
         CloseOrdersByType(POSITION_TYPE_SELL);
         MaxSellProfitSeen = 0;
      }
      else if(UseBasketTimeout && sellAgeHrs >= MaxBasketHours)
      {
         PrintFormat("BASKET TIMEOUT SELL: age %.2f hours / P/L %.2f",
                     sellAgeHrs, SellProfits);
         CloseOrdersByType(POSITION_TYPE_SELL);
         MaxSellProfitSeen = 0;
      }
      else
      {
         double target = recovery ? (TargetProfitUSD + 2.0) : TargetProfitUSD;

         if(!UseTrailingProfit)
         {
            if(SellProfits >= target)
            {
               CloseOrdersByType(POSITION_TYPE_SELL);
               MaxSellProfitSeen = 0;
            }
         }
         else if(SellProfits >= TrailingStartUSD)
         {
            if(SellProfits > MaxSellProfitSeen)
               MaxSellProfitSeen = SellProfits;

            if(SellProfits <= MaxSellProfitSeen - TrailingStopUSD)
            {
               CloseOrdersByType(POSITION_TYPE_SELL);
               MaxSellProfitSeen = 0;
            }
         }
         else if(SellProfits <= 0)
         {
            MaxSellProfitSeen = 0;
         }
      }
   }
}

double BasketLossPercent(double basketProfit)
{
   if(basketProfit >= 0 || AdaptiveEquityBase <= 0)
      return 0.0;

   return ((-basketProfit) / AdaptiveEquityBase) * 100.0;
}

bool IsBasketFrozen(ENUM_POSITION_TYPE type)
{
   if(!UseBasketLossProtection)
      return false;

   double basketProfit =
      (type == POSITION_TYPE_BUY) ? BuyProfits : SellProfits;

   if((type == POSITION_TYPE_BUY && BuyOrders <= 0) ||
      (type == POSITION_TYPE_SELL && SellOrders <= 0))
      return false;

   return (BasketLossPercent(basketProfit) >= BasketFreezeLossPct);
}

double GetBasketAgeHours(ENUM_POSITION_TYPE type)
{
   datetime oldest = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(PositionSelectByTicket(ticket)
         && PositionGetInteger(POSITION_MAGIC) == OrdersID
         && PositionGetString(POSITION_SYMBOL) == SymbolTrade
         && PositionGetInteger(POSITION_TYPE) == type)
      {
         datetime openTime =
            (datetime)PositionGetInteger(POSITION_TIME);

         if(oldest == 0 || openTime < oldest)
            oldest = openTime;
      }
   }

   if(oldest == 0)
      return 0.0;

   return (double)(TimeCurrent() - oldest) / 3600.0;
}

void UpdateStatus()
{
   BuyOrders   = 0;
   SellOrders  = 0;
   BuyProfits  = 0;
   SellProfits = 0;
   PriceOpenLastBuy  = 0;
   PriceOpenLastSell = 0;

   long latestBuyTime  = 0;
   long latestSellTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(PositionSelectByTicket(ticket)
         && PositionGetInteger(POSITION_MAGIC) == OrdersID
         && PositionGetString(POSITION_SYMBOL) == SymbolTrade)
      {
         ENUM_POSITION_TYPE type =
            (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

         double p = PositionGetDouble(POSITION_PROFIT)
                    + PositionGetDouble(POSITION_SWAP);

         long openTimeMsc = PositionGetInteger(POSITION_TIME_MSC);

         if(type == POSITION_TYPE_BUY)
         {
            BuyOrders++;
            BuyProfits += p;

            if(openTimeMsc >= latestBuyTime)
            {
               latestBuyTime = openTimeMsc;
               PriceOpenLastBuy = PositionGetDouble(POSITION_PRICE_OPEN);
            }
         }
         else if(type == POSITION_TYPE_SELL)
         {
            SellOrders++;
            SellProfits += p;

            if(openTimeMsc >= latestSellTime)
            {
               latestSellTime = openTimeMsc;
               PriceOpenLastSell = PositionGetDouble(POSITION_PRICE_OPEN);
            }
         }
      }
   }
}

double GetRSIValue()
{
   double b[];
   ArraySetAsSeries(b, true);

   return (CopyBuffer(HandleRSI, 0, 0, 1, b) > 0) ? b[0] : 50.0;
}

double GetMAValue()
{
   double b[];
   ArraySetAsSeries(b, true);

   return (CopyBuffer(HandleMA, 0, 0, 1, b) > 0) ? b[0] : 0;
}

void ExecuteTrade(ENUM_ORDER_TYPE type)
{
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   int c = (type == ORDER_TYPE_BUY) ? BuyOrders : SellOrders;

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = SymbolTrade;
   req.magic        = OrdersID;
   req.volume       = NormalizeDouble(ManualLotSize * (c + 1), 2);
   req.type         = type;
   req.deviation    = 10;
   req.type_filling = ORDER_FILLING_IOC;
   req.comment      = CommentsOrders;

   req.price = (type == ORDER_TYPE_BUY)
      ? SymbolInfoDouble(SymbolTrade, SYMBOL_ASK)
      : SymbolInfoDouble(SymbolTrade, SYMBOL_BID);

   if(!OrderSend(req, res))
   {
      PrintFormat("Gagal membuka %s. Error: %d",
                  EnumToString(type), GetLastError());
   }
}

void CloseOrdersByType(ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);

      if(PositionSelectByTicket(t)
         && PositionGetInteger(POSITION_MAGIC) == OrdersID
         && PositionGetString(POSITION_SYMBOL) == SymbolTrade
         && PositionGetInteger(POSITION_TYPE) == type)
      {
         MqlTradeRequest req = {};
         MqlTradeResult  res = {};

         req.action       = TRADE_ACTION_DEAL;
         req.position     = t;
         req.symbol       = SymbolTrade;
         req.volume       = PositionGetDouble(POSITION_VOLUME);
         req.magic        = OrdersID;
         req.deviation    = 10;
         req.type_filling = ORDER_FILLING_IOC;

         req.type = (type == POSITION_TYPE_BUY)
            ? ORDER_TYPE_SELL
            : ORDER_TYPE_BUY;

         req.price = (type == POSITION_TYPE_BUY)
            ? SymbolInfoDouble(SymbolTrade, SYMBOL_BID)
            : SymbolInfoDouble(SymbolTrade, SYMBOL_ASK);

         if(!OrderSend(req, res))
         {
            PrintFormat("Gagal menutup tiket #%I64u. Error: %d",
                        t, GetLastError());
         }
      }
   }
}

void CloseAllOrders()
{
   CloseOrdersByType(POSITION_TYPE_BUY);
   CloseOrdersByType(POSITION_TYPE_SELL);
}

void DisplayDashboard(double dd, double rsi, bool recovery)
{
   string mode = recovery ? "RECOVERY MODE" : "NORMAL GROWTH";

   double buyLossPct  = BasketLossPercent(BuyProfits);
   double sellLossPct = BasketLossPercent(SellProfits);
   double buyAge      = GetBasketAgeHours(POSITION_TYPE_BUY);
   double sellAge     = GetBasketAgeHours(POSITION_TYPE_SELL);

   string buyState =
      (BuyOrders <= 0) ? "EMPTY" :
      (buyLossPct >= BasketHardLossPct) ? "HARD EXIT" :
      (buyLossPct >= BasketFreezeLossPct) ? "FROZEN" :
      (buyLossPct >= BasketWarningLossPct) ? "WARNING" : "NORMAL";

   string sellState =
      (SellOrders <= 0) ? "EMPTY" :
      (sellLossPct >= BasketHardLossPct) ? "HARD EXIT" :
      (sellLossPct >= BasketFreezeLossPct) ? "FROZEN" :
      (sellLossPct >= BasketWarningLossPct) ? "WARNING" : "NORMAL";

   Comment(
      "======== GRID RECOVERY V6.21 ========\n",
      "Status   : ", (IsTerminated ? "TERMINATED" : "RUNNING"), "\n",
      "Mode     : ", mode, "\n",
      "Drawdown : ", DoubleToString(dd, 2), "%\n",
      "Adaptive Base : ", DoubleToString(AdaptiveEquityBase, 2), "\n",
      "Locked Profit : ", DoubleToString(LockedProfit, 2), "\n",
      "RSI (14) : ", DoubleToString(rsi, 2), "\n",
      "----------------------------------\n",
      "BUY  : ", BuyOrders,
      " | P/L: ", DoubleToString(BuyProfits, 2),
      " | DD: ", DoubleToString(buyLossPct, 2), "%",
      " | Age: ", DoubleToString(buyAge, 1), "h",
      " | ", buyState, "\n",
      "SELL : ", SellOrders,
      " | P/L: ", DoubleToString(SellProfits, 2),
      " | DD: ", DoubleToString(sellLossPct, 2), "%",
      " | Age: ", DoubleToString(sellAge, 1), "h",
      " | ", sellState, "\n",
      "----------------------------------\n",
      "Basket Warning : ", DoubleToString(BasketWarningLossPct, 1), "%\n",
      "Basket Freeze  : ", DoubleToString(BasketFreezeLossPct, 1), "%\n",
      "Basket Hard    : ", DoubleToString(BasketHardLossPct, 1), "%\n",
      "Max Basket Age : ", DoubleToString(MaxBasketHours, 1), "h\n",
      "=================================="
   );
}

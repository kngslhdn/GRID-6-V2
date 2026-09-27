//================================================================================================//
// Expert Advisor: GRID 06.V02 - RECOVERY & GROWTH EDITION 2026
// Adaptive Equity Scaling Edition - V23 FIXED ENGINE
//================================================================================================//
#property strict
#property copyright "Copyright 2026, Jarvis"
#property version   "6.23"

//--- Enums ---
enum Type {Open_Buy_And_Sell, Open__Only_Buy, Open__Only_Sell};

//--- Input Parameters ---
input string SafeParameters       = "||========== SAFETY & RECOVERY ==========||";
input double MaxEquityLossPercent = 15.0;
input bool   UseTrailingProfit    = true;
input double TrailingStartUSD     = 5.0;
input double TrailingStopUSD      = 2.0;

input string RSI_Settings         = "||========== INDICATORS ==========||";
input int    MAPeriod             = 200;
input int    RSIPeriod            = 14;
input int    RSIUpper             = 61;
input int    RSILower             = 41;

input string Grid_Settings        = "||========== GRID LOGIC ==========||";
input Type   TypeOrdersPlace      = Open_Buy_And_Sell;
input double PointsForFirstGap    = 6250.0;
input double GapMultiplier        = 1.3;
input double TargetProfitUSD      = 5.0;
input double ManualLotSize        = 0.01;
input int    MaxOrders            = 3;
input int    MagicNumber          = 16082016;
input string CommentsOrders       = "GRID 3 Buy Sell";

//--- Trading Hour ---
input string TradingHourSettings  = "||========== TRADING HOURS ==========||";
input bool   UseTradingHour       = true;
input int    StartHour            = 7;
input int    EndHour              = 22;

//--- Global Variables ---
string SymbolTrade;
int    OrdersID, HandleRSI, HandleMA;
int    BuyOrders, SellOrders;
double BuyProfits, SellProfits;
double PriceOpenLastBuy, PriceOpenLastSell;

bool   IsTerminated = false;
double HighWaterMark = 0;

//========================================================
// ADAPTIVE EQUITY VARIABLES
//========================================================
double InitialBalance     = 0;
double AdaptiveEquityBase = 0;
double LockedProfit       = 0;

//========================================================
// TRUE EQUITY HIGH-WATER MARK
// Used ONLY for equity protection.
// The original balance HighWaterMark remains unchanged
// for the existing Recovery Engine.
//========================================================
double EquityHighWaterMark = 0;

//========================================================
// BASKET / EXPOSURE LOGGING STATE
//========================================================
int    LastLoggedBuyOrders  = -1;
int    LastLoggedSellOrders = -1;
double LastLoggedBuyVolume  = -1.0;
double LastLoggedSellVolume = -1.0;
double LastLoggedBuyProfit  = 0.0;
double LastLoggedSellProfit = 0.0;

//================================================================================================//
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

//================================================================================================//
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

   //========================================================
   // ADAPTIVE EQUITY INIT
   //========================================================
   InitialBalance     = AccountInfoDouble(ACCOUNT_BALANCE);
   AdaptiveEquityBase = InitialBalance;
   LockedProfit       = 0;

   //========================================================
   // TRUE EQUITY HIGH-WATER MARK INIT
   //========================================================
   EquityHighWaterMark = AccountInfoDouble(ACCOUNT_EQUITY);

   if(HandleRSI == INVALID_HANDLE || HandleMA == INVALID_HANDLE)
   {
      Print("Gagal inisialisasi indikator!");
      return(INIT_FAILED);
   }

   return(INIT_SUCCEEDED);
}

//================================================================================================//
void OnDeinit(const int reason)
{
   IndicatorRelease(HandleRSI);
   IndicatorRelease(HandleMA);
   Comment("");
}

//================================================================================================//
void OnTick()
{
   if(IsTerminated
      || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return;

   //========================================================
   // TRUE EQUITY HIGH-WATER MARK
   // Track protection HWM even outside the trading window.
   // This does NOT permit trading outside StartHour/EndHour.
   //========================================================

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   if(equity > EquityHighWaterMark)
      EquityHighWaterMark = equity;

   // Preserve the original trading-hour restriction.
   if(!IsTradingHour())
      return;

   UpdateStatus();

   //========================================================
   // ADAPTIVE EQUITY SCALING
   // Protection base follows highest observed equity.
   // Original recovery HighWaterMark remains balance-based.
   //========================================================

   AdaptiveEquityBase = MathMax(InitialBalance,
                                EquityHighWaterMark);

   LockedProfit = AdaptiveEquityBase - InitialBalance;

   if(LockedProfit < 0)
      LockedProfit = 0;

   //========================================================
   // ORIGINAL RECOVERY ENGINE
   // DO NOT CHANGE
   //========================================================

   if(balance > HighWaterMark)
      HighWaterMark = balance;

   bool IsInRecovery = (balance < HighWaterMark);

   //========================================================
   // DRAWDOWN FROM TRUE EQUITY HIGH-WATER MARK
   //========================================================

   double currentDrawdown = 0;

   if(AdaptiveEquityBase > 0 &&
      equity < AdaptiveEquityBase)
   {
      currentDrawdown =
         ((AdaptiveEquityBase - equity)
         / AdaptiveEquityBase) * 100.0;
   }

   //========================================================
   // EQUITY PROTECTION
   //========================================================

   if(currentDrawdown >= MaxEquityLossPercent)
   {
      PrintFormat("!!! EMERGENCY CUT LOSS: Drawdown %.2f%% | Equity %.2f | HWM %.2f !!!",
                  currentDrawdown,
                  equity,
                  AdaptiveEquityBase);

      CloseAllOrders();

      IsTerminated = true;
      return;
   }

   double rsi   = GetRSIValue();
   double ma    = GetMAValue();
   double price = SymbolInfoDouble(SymbolTrade, SYMBOL_BID);

   int lowRSI  = IsInRecovery ? (RSILower - 5) : RSILower;
   int highRSI = IsInRecovery ? (RSIUpper + 5) : RSIUpper;

   bool canOpenBuy  = false;
   bool canOpenSell = false;

   //========================================================
   // FIRST ENTRY
   // DO NOT CHANGE
   //========================================================

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

   //========================================================
   // GRID RECOVERY
   // DO NOT CHANGE
   //========================================================

   if(BuyOrders > 0 && BuyOrders < MaxOrders)
   {
      double gap =
         PointsForFirstGap
         * MathPow(GapMultiplier, BuyOrders - 1);

      if(SymbolInfoDouble(SymbolTrade, SYMBOL_ASK)
         <= PriceOpenLastBuy - (gap * _Point))
      {
         canOpenBuy = true;
      }
   }

   if(SellOrders > 0 && SellOrders < MaxOrders)
   {
      double gap =
         PointsForFirstGap
         * MathPow(GapMultiplier, SellOrders - 1);

      if(price >= PriceOpenLastSell + (gap * _Point))
      {
         canOpenSell = true;
      }
   }

   //========================================================
   // EXECUTION
   // DO NOT CHANGE
   //========================================================

   if(canOpenBuy)
      ExecuteTrade(ORDER_TYPE_BUY);

   if(canOpenSell)
      ExecuteTrade(ORDER_TYPE_SELL);

   ManageExit(IsInRecovery);

   LogBasketExposure();

   DisplayDashboard(currentDrawdown, rsi, IsInRecovery);
}

//================================================================================================//
void ManageExit(bool recovery)
{
   double target =
      recovery
      ? (TargetProfitUSD + 2.0)
      : TargetProfitUSD;

   //========================================================
   // TRAILING STATE
   // Reset only when that side has no positions.
   // This preserves the original trailing behavior while
   // preventing stale state from a previous basket.
   //========================================================
   static double maxBuyProfit  = 0;
   static double maxSellProfit = 0;

   if(BuyOrders == 0)
      maxBuyProfit = 0;

   if(SellOrders == 0)
      maxSellProfit = 0;

   if(BuyOrders > 0)
   {
      if(!UseTrailingProfit)
      {
         if(BuyProfits >= target)
            CloseOrdersByType(POSITION_TYPE_BUY);
      }
      else
      {
         if(BuyProfits >= TrailingStartUSD)
         {
            if(BuyProfits > maxBuyProfit)
               maxBuyProfit = BuyProfits;

            if(BuyProfits <= maxBuyProfit - TrailingStopUSD)
            {
               CloseOrdersByType(POSITION_TYPE_BUY);
               maxBuyProfit = 0;
            }
         }
      }
   }

   if(SellOrders > 0)
   {
      if(!UseTrailingProfit)
      {
         if(SellProfits >= target)
            CloseOrdersByType(POSITION_TYPE_SELL);
      }
      else
      {
         if(SellProfits >= TrailingStartUSD)
         {
            if(SellProfits > maxSellProfit)
               maxSellProfit = SellProfits;

            if(SellProfits <= maxSellProfit - TrailingStopUSD)
            {
               CloseOrdersByType(POSITION_TYPE_SELL);
               maxSellProfit = 0;
            }
         }
      }
   }
}

//================================================================================================//
void UpdateStatus()
{
   BuyOrders   = 0;
   SellOrders  = 0;
   BuyProfits  = 0;
   SellProfits = 0;

   //========================================================
   // IMPORTANT:
   // Reset last prices before scanning current positions.
   //========================================================
   PriceOpenLastBuy  = 0;
   PriceOpenLastSell = 0;

   long latestBuyTimeMsc  = 0;
   long latestSellTimeMsc = 0;

   ulong latestBuyTicket  = 0;
   ulong latestSellTicket = 0;

   double buyVolume  = 0;
   double sellVolume = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != OrdersID)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != SymbolTrade)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double p =
         PositionGetDouble(POSITION_PROFIT)
         + PositionGetDouble(POSITION_SWAP);

      double volume =
         PositionGetDouble(POSITION_VOLUME);

      long timeMsc =
         PositionGetInteger(POSITION_TIME_MSC);

      if(type == POSITION_TYPE_BUY)
      {
         BuyOrders++;
         BuyProfits += p;
         buyVolume += volume;

         // Last opened BUY position = newest open time.
         // Ticket is used as deterministic tie-breaker.
         if(timeMsc > latestBuyTimeMsc ||
            (timeMsc == latestBuyTimeMsc &&
             ticket > latestBuyTicket))
         {
            latestBuyTimeMsc = timeMsc;
            latestBuyTicket  = ticket;

            PriceOpenLastBuy =
               PositionGetDouble(POSITION_PRICE_OPEN);
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         SellOrders++;
         SellProfits += p;
         sellVolume += volume;

         // Last opened SELL position = newest open time.
         // Ticket is used as deterministic tie-breaker.
         if(timeMsc > latestSellTimeMsc ||
            (timeMsc == latestSellTimeMsc &&
             ticket > latestSellTicket))
         {
            latestSellTimeMsc = timeMsc;
            latestSellTicket  = ticket;

            PriceOpenLastSell =
               PositionGetDouble(POSITION_PRICE_OPEN);
         }
      }
   }
}

//================================================================================================//
double GetRSIValue()
{
   double b[];
   ArraySetAsSeries(b, true);

   return (CopyBuffer(HandleRSI, 0, 0, 1, b) > 0)
      ? b[0]
      : 50.0;
}

//================================================================================================//
double GetMAValue()
{
   double b[];
   ArraySetAsSeries(b, true);

   return (CopyBuffer(HandleMA, 0, 0, 1, b) > 0)
      ? b[0]
      : 0;
}

//================================================================================================//
void ExecuteTrade(ENUM_ORDER_TYPE type)
{
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   int c =
      (type == ORDER_TYPE_BUY)
      ? BuyOrders
      : SellOrders;

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = SymbolTrade;
   req.magic        = OrdersID;
   req.volume       = NormalizeDouble(ManualLotSize * (c + 1), 2);
   req.type         = type;
   req.deviation    = 10;
   req.type_filling = ORDER_FILLING_IOC;

   req.price =
      (type == ORDER_TYPE_BUY)
      ? SymbolInfoDouble(SymbolTrade, SYMBOL_ASK)
      : SymbolInfoDouble(SymbolTrade, SYMBOL_BID);

   ResetLastError();

   if(!OrderSend(req, res))
   {
      PrintFormat("Gagal membuka %s. Error: %d",
                  EnumToString(type),
                  GetLastError());
      return;
   }

   // OrderSend() == true only means the request was accepted
   // for processing. Validate the actual trade result.
   if(res.retcode != TRADE_RETCODE_DONE &&
      res.retcode != TRADE_RETCODE_DONE_PARTIAL)
   {
      PrintFormat("OPEN REJECTED | Type=%s | Retcode=%u | Comment=%s",
                  EnumToString(type),
                  res.retcode,
                  res.comment);
      return;
   }

   PrintFormat("OPEN OK | Type=%s | Order=%I64u | Deal=%I64u | Volume=%.2f | Price=%.5f",
               EnumToString(type),
               res.order,
               res.deal,
               req.volume,
               res.price);
}

//================================================================================================//
void CloseOrdersByType(ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);

      if(!PositionSelectByTicket(t))
         continue;

      //========================================================
      // SYMBOL ISOLATION
      // Never close another symbol with the same magic number.
      //========================================================
      if(PositionGetInteger(POSITION_MAGIC) != OrdersID)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != SymbolTrade)
         continue;

      if(PositionGetInteger(POSITION_TYPE) != type)
         continue;

      MqlTradeRequest req = {};
      MqlTradeResult  res = {};

      req.action   = TRADE_ACTION_DEAL;
      req.position = t;
      req.symbol   = SymbolTrade;
      req.volume   = PositionGetDouble(POSITION_VOLUME);

      req.type =
         (type == POSITION_TYPE_BUY)
         ? ORDER_TYPE_SELL
         : ORDER_TYPE_BUY;

      req.price =
         (type == POSITION_TYPE_BUY)
         ? SymbolInfoDouble(SymbolTrade, SYMBOL_BID)
         : SymbolInfoDouble(SymbolTrade, SYMBOL_ASK);

      ResetLastError();

      if(!OrderSend(req, res))
      {
         PrintFormat("Gagal menutup tiket #%I64u. Error: %d",
                     t,
                     GetLastError());
         continue;
      }

      if(res.retcode != TRADE_RETCODE_DONE &&
         res.retcode != TRADE_RETCODE_DONE_PARTIAL)
      {
         PrintFormat("CLOSE REJECTED | Ticket=%I64u | Retcode=%u | Comment=%s",
                     t,
                     res.retcode,
                     res.comment);
         continue;
      }

      PrintFormat("CLOSE OK | Ticket=%I64u | Deal=%I64u | Volume=%.2f | Price=%.5f",
                  t,                  res.deal,
                  req.volume,
                  res.price);
   }
}

//================================================================================================//
void CloseAllOrders()
{
   CloseOrdersByType(POSITION_TYPE_BUY);
   CloseOrdersByType(POSITION_TYPE_SELL);
}

//================================================================================================//
void LogBasketExposure()
{
   double buyVolume  = 0;
   double sellVolume = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != OrdersID)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != SymbolTrade)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double volume =
         PositionGetDouble(POSITION_VOLUME);

      if(type == POSITION_TYPE_BUY)
         buyVolume += volume;
      else if(type == POSITION_TYPE_SELL)
         sellVolume += volume;
   }

   bool changed =
      BuyOrders != LastLoggedBuyOrders ||
      SellOrders != LastLoggedSellOrders ||
      MathAbs(buyVolume - LastLoggedBuyVolume) > 0.0000001 ||
      MathAbs(sellVolume - LastLoggedSellVolume) > 0.0000001;

   if(changed)
   {
      PrintFormat(
         "BASKET | Symbol=%s | BUY=%d (%.2f lot, P/L %.2f) | SELL=%d (%.2f lot, P/L %.2f) | Total=%.2f lot",
         SymbolTrade,
         BuyOrders,
         buyVolume,
         BuyProfits,
         SellOrders,
         sellVolume,
         SellProfits,
         buyVolume + sellVolume
      );

      LastLoggedBuyOrders  = BuyOrders;
      LastLoggedSellOrders = SellOrders;
      LastLoggedBuyVolume  = buyVolume;
      LastLoggedSellVolume = sellVolume;
      LastLoggedBuyProfit  = BuyProfits;
      LastLoggedSellProfit = SellProfits;
   }
}

//================================================================================================//
void DisplayDashboard(double dd, double rsi, bool recovery)
{
   string mode =
      recovery
      ? "RECOVERY MODE (Aggressive)"
      : "NORMAL GROWTH";

   Comment(
      "======== GRID RECOVERY GRID V6.V02 ========\n",
      "Status   : ", (IsTerminated ? "TERMINATED" : "RUNNING"), "\n",
      "Mode     : ", mode, "\n",
      "Drawdown : ", DoubleToString(dd, 2), "%\n",
      "Adaptive Base : ", DoubleToString(AdaptiveEquityBase, 2), "\n",
      "Equity HWM : ", DoubleToString(EquityHighWaterMark, 2), "\n",
      "Locked Profit : ", DoubleToString(LockedProfit, 2), "\n",
      "RSI (14) : ", DoubleToString(rsi, 2), "\n",
      "----------------------------------\n",
      "Buy  Lapis: ", BuyOrders,
      " | Profit: ", DoubleToString(BuyProfits, 2), "\n",
      "Sell Lapis: ", SellOrders,
      " | Profit: ", DoubleToString(SellProfits, 2), "\n",
      "=================================="
   );
}
//================================================================================================//
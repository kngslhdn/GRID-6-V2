// Expert Advisor: GRID 06.V02 - RECOVERY & GROWTH EDITION 2026
// Adaptive Equity Scaling + Hierarchical Basket Exit Protection
#property strict
#property copyright "Copyright 2026, Jarvis"
#property version   "6.23"

#include <Trade/Trade.mqh>
CTrade trade;

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
input double BasketWarningLossPct    = 3.0;
input double BasketFreezeLossPct     = 5.0;
input double BasketHardLossPct       = 7.0;
input bool   UseBasketTimeout        = true;
input double MaxBasketHours          = 48.0;

//--- Hierarchical Exit Engine ---
input string ExitEngineSettings      = "||========== HIERARCHICAL EXIT ENGINE ==========||";
input bool   UseHierarchicalExit     = true;
input bool   ExitOnRegimeDamage      = true;
input int    RegimeWarningScore      = 3;
input int    RegimeHardExitScore     = 6;
input int    RegimeConfirmBars       = 2;
input bool   UseDynamicProfitGiveback = true;
input double PeakLevel1USD           = 5.0;
input double GivebackLevel1USD       = 2.0;
input double PeakLevel2USD           = 15.0;
input double GivebackLevel2USD       = 5.0;
input double PeakLevel3USD           = 25.0;
input double GivebackLevel3USD       = 7.0;
input double PeakLevel4USD           = 40.0;
input double GivebackLevel4USD       = 10.0;
input double ATRTrailingStartUSD     = 20.0;
input double ATRTrailingMultiplier   = 2.0;
input int    CampaignGraceHours      = 4;
input int    CampaignStaleHours      = 8;
input double CampaignStaleMinProfit  = 0.0;

//--- Indicator Parameters ---
input string RSI_Settings            = "||========== INDICATORS ==========||";
input int    MAPeriod                = 200;
input int    RSIPeriod               = 14;
input int    RSIUpper                = 70;
input int    RSILower                = 30;

//--- Grid Parameters ---
input string Grid_Settings           = "||========== GRID LOGIC ==========||";
input Type   TypeOrdersPlace         = Open_Buy_And_Sell;
input double PointsForFirstGap       = 5000.0;
input double GapMultiplier            = 1.3;
input double TargetProfitUSD         = 5.0;
input double ManualLotSize           = 0.01;
input int    MaxOrders               = 6;
input int    MagicNumber             = 88888;
input string CommentsOrders          = "GRID SAFE 2026";

//--- Trading Hour ---
input string TradingHourSettings     = "||========== TRADING HOURS ==========||";
input bool   UseTradingHour          = true;
input int    StartHour               = 7;
input int    EndHour                 = 22;

//--- Global Variables ---
string SymbolTrade;
int    OrdersID, HandleRSI, HandleMA;
int    BuyOrders, SellOrders;
double BuyProfits, SellProfits;
double PriceOpenLastBuy, PriceOpenLastSell;

bool   IsTerminated = false;
double HighWaterMark = 0;
double InitialBalance = 0;
double AdaptiveEquityBase = 0;
double LockedProfit = 0;
double MaxBuyProfitSeen = 0;
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
   return (hour >= StartHour || hour < EndHour);
}

int OnInit()
{
   SymbolTrade = _Symbol;
   OrdersID = (MagicNumber == 0) ? 101010 : MagicNumber;
   HandleRSI = iRSI(SymbolTrade, PERIOD_CURRENT, RSIPeriod, PRICE_CLOSE);
   HandleMA  = iMA(SymbolTrade, PERIOD_CURRENT, MAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   HighWaterMark = AccountInfoDouble(ACCOUNT_BALANCE);
   InitialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   AdaptiveEquityBase = InitialBalance;
   LockedProfit = 0;
   MaxBuyProfitSeen = 0;
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
   if(LockedProfit < 0) LockedProfit = 0;
   AdaptiveEquityBase = InitialBalance + LockedProfit;

   if(balance > HighWaterMark)
      HighWaterMark = balance;

   bool IsInRecovery = (balance < HighWaterMark);
   double currentDrawdown = 0;

   if(AdaptiveEquityBase > 0 && equity < AdaptiveEquityBase)
      currentDrawdown = ((AdaptiveEquityBase - equity) / AdaptiveEquityBase) * 100.0;

   // Account protection remains the final safety layer.
   if(currentDrawdown >= MaxEquityLossPercent)
   {
      PrintFormat("!!! ACCOUNT EMERGENCY CUT: Drawdown %.2f%% !!!", currentDrawdown);
      CloseAllOrders();
      IsTerminated = true;
      return;
   }

   // Exit and risk management are always active. Trading hours only gate NEW entries.
   ManageExit(IsInRecovery);
   UpdateStatus();
   if(IsTerminated) return;

   double rsi = GetRSIValue();
   double ma = GetMAValue();
   double price = SymbolInfoDouble(SymbolTrade, SYMBOL_BID);

   int lowRSI = IsInRecovery ? (RSILower - 5) : RSILower;
   int highRSI = IsInRecovery ? (RSIUpper + 5) : RSIUpper;

   bool canOpenBuy = false;
   bool canOpenSell = false;

   if(BuyOrders == 0 &&
      (TypeOrdersPlace == Open_Buy_And_Sell || TypeOrdersPlace == Open__Only_Buy))
   {
      if(price > ma && rsi < lowRSI)
         canOpenBuy = true;
   }

   if(SellOrders == 0 &&
      (TypeOrdersPlace == Open_Buy_And_Sell || TypeOrdersPlace == Open__Only_Sell))
   {
      if(price < ma && rsi > highRSI)
         canOpenSell = true;
   }

   bool buyFrozen = IsBasketFrozen(POSITION_TYPE_BUY);
   bool sellFrozen = IsBasketFrozen(POSITION_TYPE_SELL);

   if(BuyOrders > 0 && BuyOrders < MaxOrders && !buyFrozen)
   {
      double gap = PointsForFirstGap * MathPow(GapMultiplier, BuyOrders - 1);
      if(SymbolInfoDouble(SymbolTrade, SYMBOL_ASK) <= PriceOpenLastBuy - (gap * _Point))
         canOpenBuy = true;
   }

   if(SellOrders > 0 && SellOrders < MaxOrders && !sellFrozen)
   {
      double gap = PointsForFirstGap * MathPow(GapMultiplier, SellOrders - 1);
      if(price >= PriceOpenLastSell + (gap * _Point))
         canOpenSell = true;
   }

   // Trading hours apply to NEW ENTRY only.
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

//========================================================
// HIERARCHICAL EXIT ENGINE
//========================================================
void ManageExit(bool recovery)
{
   // BUY basket
   if(BuyOrders <= 0)
   {
      MaxBuyProfitSeen = 0;
   }
   else
   {
      double buyLossPct = BasketLossPercent(BuyProfits);
      double buyAgeHrs = GetBasketAgeHours(POSITION_TYPE_BUY);

      if(UseBasketLossProtection && buyLossPct >= BasketHardLossPct)
      {
         PrintFormat("BASKET HARD EXIT BUY: loss %.2f%% / P/L %.2f", buyLossPct, BuyProfits);
         CloseOrdersByType(POSITION_TYPE_BUY);
         MaxBuyProfitSeen = 0;
      }
      else if(UseBasketTimeout && buyAgeHrs >= MaxBasketHours)
      {
         PrintFormat("BASKET TIMEOUT BUY: %.2fh / P/L %.2f", buyAgeHrs, BuyProfits);
         CloseOrdersByType(POSITION_TYPE_BUY);
         MaxBuyProfitSeen = 0;
      }
      else if(UseHierarchicalExit && ExitOnRegimeDamage && BuyProfits < 0)
      {
         int score = RegimeExitScore(POSITION_TYPE_BUY);
         if(score >= RegimeHardExitScore && ConfirmRegimeExit(POSITION_TYPE_BUY))
         {
            PrintFormat("THESIS INVALIDATION BUY: score=%d P/L=%.2f", score, BuyProfits);
            CloseOrdersByType(POSITION_TYPE_BUY);
            MaxBuyProfitSeen = 0;
         }
      }

      if(BuyOrders > 0)
      {
         double target = recovery ? (TargetProfitUSD + 2.0) : TargetProfitUSD;
         UpdatePeakProfit(MaxBuyProfitSeen, BuyProfits);
         double giveback = DynamicGiveback(MaxBuyProfitSeen);
         if(UseTrailingProfit && BuyProfits >= TrailingStartUSD && giveback > 0 &&
            MaxBuyProfitSeen - BuyProfits >= giveback && BuyProfits > 0)
         {
            CloseOrdersByType(POSITION_TYPE_BUY);
            MaxBuyProfitSeen = 0;
         }
         else if(!UseTrailingProfit && BuyProfits >= target)
         {
            CloseOrdersByType(POSITION_TYPE_BUY);
            MaxBuyProfitSeen = 0;
         }
      }
   }

   // SELL basket
   if(SellOrders <= 0)
   {
      MaxSellProfitSeen = 0;
   }
   else
   {
      double sellLossPct = BasketLossPercent(SellProfits);
      double sellAgeHrs = GetBasketAgeHours(POSITION_TYPE_SELL);

      if(UseBasketLossProtection && sellLossPct >= BasketHardLossPct)
      {
         PrintFormat("BASKET HARD EXIT SELL: loss %.2f%% / P/L %.2f", sellLossPct, SellProfits);
         CloseOrdersByType(POSITION_TYPE_SELL);
         MaxSellProfitSeen = 0;
      }
      else if(UseBasketTimeout && sellAgeHrs >= MaxBasketHours)
      {
         PrintFormat("BASKET TIMEOUT SELL: %.2fh / P/L %.2f", sellAgeHrs, SellProfits);
         CloseOrdersByType(POSITION_TYPE_SELL);
         MaxSellProfitSeen = 0;
      }
      else if(UseHierarchicalExit && ExitOnRegimeDamage && SellProfits < 0)
      {
         int score = RegimeExitScore(POSITION_TYPE_SELL);
         if(score >= RegimeHardExitScore && ConfirmRegimeExit(POSITION_TYPE_SELL))
         {
            PrintFormat("THESIS INVALIDATION SELL: score=%d P/L=%.2f", score, SellProfits);
            CloseOrdersByType(POSITION_TYPE_SELL);
            MaxSellProfitSeen = 0;
         }
      }

      if(SellOrders > 0)
      {
         double target = recovery ? (TargetProfitUSD + 2.0) : TargetProfitUSD;
         UpdatePeakProfit(MaxSellProfitSeen, SellProfits);
         double giveback = DynamicGiveback(MaxSellProfitSeen);
         if(UseTrailingProfit && SellProfits >= TrailingStartUSD && giveback > 0 &&
            MaxSellProfitSeen - SellProfits >= giveback && SellProfits > 0)
         {
            CloseOrdersByType(POSITION_TYPE_SELL);
            MaxSellProfitSeen = 0;
         }
         else if(!UseTrailingProfit && SellProfits >= target)
         {
            CloseOrdersByType(POSITION_TYPE_SELL);
            MaxSellProfitSeen = 0;
         }
      }
   }
}

void UpdatePeakProfit(double &peak, double current)
{
   if(current > peak)
      peak = current;
   if(current <= 0 && peak < TrailingStartUSD)
      peak = 0;
}

double DynamicGiveback(double peak)
{
   if(!UseDynamicProfitGiveback)
      return TrailingStopUSD;
   if(peak >= PeakLevel4USD) return GivebackLevel4USD;
   if(peak >= PeakLevel3USD) return GivebackLevel3USD;
   if(peak >= PeakLevel2USD) return GivebackLevel2USD;
   if(peak >= PeakLevel1USD) return GivebackLevel1USD;
   return 0.0;
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
   double basketProfit = (type == POSITION_TYPE_BUY) ? BuyProfits : SellProfits;
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
      if(PositionSelectByTicket(ticket) &&
         PositionGetInteger(POSITION_MAGIC) == OrdersID &&
         PositionGetString(POSITION_SYMBOL) == SymbolTrade &&
         PositionGetInteger(POSITION_TYPE) == type)
      {
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         if(oldest == 0 || openTime < oldest)
            oldest = openTime;
      }
   }
   if(oldest == 0) return 0.0;
   return (double)(TimeCurrent() - oldest) / 3600.0;
}

int RegimeExitScore(ENUM_POSITION_TYPE type)
{
   double ma0[];
   double ma1[];
   ArraySetAsSeries(ma0, true);
   ArraySetAsSeries(ma1, true);

   if(CopyBuffer(HandleMA, 0, 1, 1, ma0) < 1) return 0;
   if(CopyBuffer(HandleMA, 0, 2, 1, ma1) < 1) return 0;

   double price = iClose(SymbolTrade, PERIOD_CURRENT, 1);
   if(price <= 0) return 0;

   int score = 0;
   if(type == POSITION_TYPE_BUY)
   {
      if(price < ma0[0]) score += 3;
      if(ma0[0] < ma1[0]) score += 2;
      if(price < ma1[0]) score += 1;
   }
   else
   {
      if(price > ma0[0]) score += 3;
      if(ma0[0] > ma1[0]) score += 2;
      if(price > ma1[0]) score += 1;
   }
   return score;
}

bool ConfirmRegimeExit(ENUM_POSITION_TYPE type)
{
   int bars = MathMax(1, RegimeConfirmBars);
   for(int sh = 1; sh <= bars; sh++)
   {
      double ma0[];
      double ma1[];
      ArraySetAsSeries(ma0, true);
      ArraySetAsSeries(ma1, true);

      if(CopyBuffer(HandleMA, 0, sh, 1, ma0) < 1) return false;
      if(CopyBuffer(HandleMA, 0, sh + 1, 1, ma1) < 1) return false;

      double price = iClose(SymbolTrade, PERIOD_CURRENT, sh);
      if(price <= 0) return false;

      if(type == POSITION_TYPE_BUY)
      {
         if(!(price < ma0[0] && ma0[0] < ma1[0])) return false;
      }
      else
      {
         if(!(price > ma0[0] && ma0[0] > ma1[0])) return false;
      }
   }
   return true;
}

void UpdateStatus()
{
   BuyOrders = 0;
   SellOrders = 0;
   BuyProfits = 0;
   SellProfits = 0;
   PriceOpenLastBuy = 0;
   PriceOpenLastSell = 0;
   long latestBuyTime = 0;
   long latestSellTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) &&
         PositionGetInteger(POSITION_MAGIC) == OrdersID &&
         PositionGetString(POSITION_SYMBOL) == SymbolTrade)
      {
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
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
   return (CopyBuffer(HandleMA, 0, 0, 1, b) > 0) ? b[0] : 0.0;
}

void ExecuteTrade(ENUM_ORDER_TYPE type)
{
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   int c = (type == ORDER_TYPE_BUY) ? BuyOrders : SellOrders;
   req.action = TRADE_ACTION_DEAL;
   req.symbol = SymbolTrade;
   req.magic = OrdersID;
   req.volume = NormalizeDouble(ManualLotSize * (c + 1), 2);
   req.type = type;
   req.deviation = 10;
   req.type_filling = ORDER_FILLING_IOC;
   req.comment = CommentsOrders;
   req.price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(SymbolTrade, SYMBOL_ASK) : SymbolInfoDouble(SymbolTrade, SYMBOL_BID);
   if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE)
      PrintFormat("OrderSend FAILED: retcode=%u comment=%s", res.retcode, res.comment);
}

void DisplayDashboard(double currentDrawdown, double rsi, bool IsInRecovery)
{
   string buyState = IsBasketFrozen(POSITION_TYPE_BUY) ? "FROZEN" : "ACTIVE";
   string sellState = IsBasketFrozen(POSITION_TYPE_SELL) ? "FROZEN" : "ACTIVE";
   Comment(
      "GRID 6 V2 | v6.23\n",
      "Balance: ", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2),
      "  Equity: ", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2), "\n",
      "DD: ", DoubleToString(currentDrawdown,2), "%",
      "  Recovery: ", IsInRecovery ? "YES" : "NO", "\n",
      "BUY ", BuyOrders, " / P/L ", DoubleToString(BuyProfits,2), " / ", buyState, "\n",
      "SELL ", SellOrders, " / P/L ", DoubleToString(SellProfits,2), " / ", sellState, "\n",
      "RSI: ", DoubleToString(rsi,1)
   );
}

void CloseOrdersByType(ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) &&
         PositionGetInteger(POSITION_MAGIC) == OrdersID &&
         PositionGetString(POSITION_SYMBOL) == SymbolTrade &&
         PositionGetInteger(POSITION_TYPE) == type)
      {
         if(!trade.PositionClose(ticket))
            PrintFormat("PositionClose failed ticket=%I64u retcode=%u", ticket, trade.ResultRetcode());
      }
   }
}

void CloseAllOrders()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) &&
         PositionGetInteger(POSITION_MAGIC) == OrdersID &&
         PositionGetString(POSITION_SYMBOL) == SymbolTrade)
      {
         if(!trade.PositionClose(ticket))
            PrintFormat("PositionClose failed ticket=%I64u retcode=%u", ticket, trade.ResultRetcode());
      }
   }
}

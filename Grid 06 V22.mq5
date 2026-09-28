//================================================================================================//
// Expert Advisor: GRID 06.V02 - RECOVERY & GROWTH EDITION 2026
// Adaptive Equity Scaling Edition - V22 FIXED CONTROLLED RECOVERY
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
input int    RSIUpper             = 63;
input int    RSILower             = 37;

input string Grid_Settings        = "||========== GRID LOGIC ==========||";
input Type   TypeOrdersPlace      = Open_Buy_And_Sell;
input double PointsForFirstGap    = 6250.0;
input double GapMultiplier        = 1.3;
input double TargetProfitUSD      = 5.0;
input double ManualLotSize        = 0.01;
input int    MaxOrders            = 3;

//========================================================
// TWO-STAGE RECOVERY ENGINE (V12)
// R1: primary total lots x 10 after adverse 3000 points.
// R2: primary total lots x 30 after R1 adverse 1500 points.
// Primary + R1 + R2 are managed as ONE basket.
//========================================================
input string RecoverySettings       = "||========== TWO-STAGE RECOVERY ==========||";
input bool   EnableRecovery         = true;
input double Recovery1Multiplier    = 1.50;
input double Recovery1GapPoints     = 2500.0;
input double Recovery1MaxLot        = 0.05;
input double Recovery2Multiplier    = 2.0;
input double Recovery2GapPoints     = 1500.0;
input double Recovery2MaxLot        = 0.05;
input bool   RecoveryOnlyWhenMinus  = true;
input int    MaxRecoveryStages      = 1;

input int    MagicNumber          = 16082016;
input string CommentsOrders       = "GRID 3 Buy Sell";

//--- Trading Hour ---
input string TradingHourSettings  = "||========== TRADING HOURS ==========||";
input bool   UseTradingHour       = true;
input int    StartHour            = 7;
input int    EndHour              = 22;


//========================================================
// NEWS FILTER SETTINGS
// Uses MT5 Economic Calendar.
// Calendar timestamps use trade-server time.
//========================================================
input string NewsFilterSettings     = "||========== NEWS FILTER ==========||";
input bool   EnableNewsFilter       = true;
input string NewsCurrency           = "USD";
input bool   NewsHighImpactOnly     = true;
input int    NewsBeforeMinutes      = 30;
input int    NewsAfterMinutes       = 30;
input bool   CloseBeforeNews        = false;
input int    CloseBeforeNewsMinutes = 5;
input bool   BlockNewEntries        = true;
input bool   BlockGridExpansion     = true;
input bool   BlockRecovery          = true;
input int    NewsRefreshSeconds     = 10;

//--- Global Variables ---
string SymbolTrade;
int    OrdersID, HandleRSI, HandleMA;
int    BuyOrders, SellOrders;
double BuyProfits, SellProfits;
double PriceOpenLastBuy, PriceOpenLastSell;

bool   IsTerminated = false;
double HighWaterMark = 0;

//========================================================
// NEWS FILTER STATE
//========================================================
bool     NewsBlocked          = false;
bool     NewsDataAvailable    = false;
bool     TesterNewsWarningShown = false;
datetime LastNewsCheckTime    = 0;
datetime LastNewsEventTime    = 0;
string   LastNewsEventName    = "";

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

//========================================================
// TWO-STAGE RECOVERY STATE
//========================================================
int    RecoveryStage = 0;
double BuyLots = 0.0;
double SellLots = 0.0;
double BuyProfit = 0.0;
double SellProfit = 0.0;
double Buy3Price = 0.0;
double Sell3Price = 0.0;
long LastBuyTimeMsc = 0;
long LastSellTimeMsc = 0;

double Recovery1Lots = 0.0;
double Recovery1Profit = 0.0;
double Recovery1EntryPrice = 0.0;
ENUM_POSITION_TYPE Recovery1Type = WRONG_VALUE;

double Recovery2Lots = 0.0;
double Recovery2Profit = 0.0;
double Recovery2EntryPrice = 0.0;
ENUM_POSITION_TYPE Recovery2Type = WRONG_VALUE;

double RecoveryLots = 0.0;
double RecoveryProfit = 0.0;
bool   RecoveryActive = false;

double BasketProfitValue = 0.0;
double BasketPeakProfit = 0.0;
bool   BasketTrailingActive = false;

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

   // Keep protection HWM alive even outside the trading window.
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   if(equity > EquityHighWaterMark)
      EquityHighWaterMark = equity;

   UpdateStatus();

   // Original balance HWM is retained for recovery diagnostics.
   if(balance > HighWaterMark)
      HighWaterMark = balance;

   // Refresh news state before any new/recovery entry.
   bool newsBlockedNow = IsNewsBlocked();

   AdaptiveEquityBase = MathMax(InitialBalance, EquityHighWaterMark);
   LockedProfit = AdaptiveEquityBase - InitialBalance;
   if(LockedProfit < 0)
      LockedProfit = 0;

   double currentDrawdown = 0;
   if(AdaptiveEquityBase > 0 && equity < AdaptiveEquityBase)
   {
      currentDrawdown =
         ((AdaptiveEquityBase - equity)
         / AdaptiveEquityBase) * 100.0;
   }

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

   // Basket exit is evaluated before opening another recovery leg.
   ManageBasketExit();
   UpdateStatus();

   // Keep the original trading-hour restriction.
   if(!IsTradingHour())
   {
      DisplayDashboard(currentDrawdown,
                       GetRSIValue(),
                       RecoveryActive);
      return;
   }

   // Optional pre-news liquidation.
   if(IsPreNewsCloseWindow())
   {
      PrintFormat("PRE-NEWS CLOSE | event=%s | event_time=%s",
                  LastNewsEventName,
                  TimeToString(LastNewsEventTime, TIME_DATE|TIME_MINUTES));
      CloseAllOrders();
      UpdateStatus();
      DisplayDashboard(currentDrawdown,
                       GetRSIValue(),
                       RecoveryActive);
      return;
   }

   bool allowNewEntries      = !(newsBlockedNow && BlockNewEntries);
   bool allowGridExpansion   = !(newsBlockedNow && BlockGridExpansion);
   bool allowRecoveryEntries = !(newsBlockedNow && BlockRecovery);

   // V12 behavior: once recovery is active, the primary grid is frozen.
   if(RecoveryActive)
   {
      if(allowRecoveryEntries)
         ManageRecoveryStage2();

      UpdateStatus();
      DisplayDashboard(currentDrawdown,
                       GetRSIValue(),
                       RecoveryActive);
      return;
   }

   // V12 R1 trigger: all primary orders are present, basket is losing,
   // and price has moved Recovery1GapPoints beyond primary order #3.
   if(allowRecoveryEntries &&
      BuyOrders >= MaxOrders &&
      SellOrders == 0)
   {
      ManageRecoveryStage1(POSITION_TYPE_BUY);
      UpdateStatus();
      DisplayDashboard(currentDrawdown,
                       GetRSIValue(),
                       RecoveryActive);
      return;
   }

   if(allowRecoveryEntries &&
      SellOrders >= MaxOrders &&
      BuyOrders == 0)
   {
      ManageRecoveryStage1(POSITION_TYPE_SELL);
      UpdateStatus();
      DisplayDashboard(currentDrawdown,
                       GetRSIValue(),
                       RecoveryActive);
      return;
   }

   // Normal primary grid/entry.
   ManagePrimaryGrid(allowNewEntries, allowGridExpansion);

   LogBasketExposure();

   UpdateStatus();
   DisplayDashboard(currentDrawdown,
                    GetRSIValue(),
                    RecoveryActive);
}
//================================================================================================//
// NEWS FILTER ENGINE
// Uses MT5 Economic Calendar. Calendar times are trade-server times.
//================================================================================================//
bool IsNewsBlocked()
{
   //========================================================
   // STRATEGY TESTER SAFETY
   // MT5 Economic Calendar functions are not available in
   // the native Strategy Tester and return error 4014.
   // Disable only the live calendar query during backtests.
   // All trading, recovery and equity-protection logic remains active.
   //========================================================
   if(MQLInfoInteger(MQL_TESTER))
   {
      NewsBlocked       = false;
      NewsDataAvailable = false;
      LastNewsEventTime = 0;
      LastNewsEventName = "";

      if(!TesterNewsWarningShown)
      {
         Print("NEWS FILTER: disabled in Strategy Tester (Economic Calendar API is unavailable; error 4014 avoided).");
         TesterNewsWarningShown = true;
      }

      return false;
   }

   if(!EnableNewsFilter)
   {
      NewsBlocked       = false;
      NewsDataAvailable = false;
      LastNewsEventTime = 0;
      LastNewsEventName = "";
      return false;
   }

   datetime now = TimeCurrent();

   int refresh = MathMax(1, NewsRefreshSeconds);

   if(LastNewsCheckTime != 0 &&
      (now - LastNewsCheckTime) < refresh)
   {
      return NewsBlocked;
   }

   LastNewsCheckTime = now;
   NewsBlocked       = false;
   NewsDataAvailable = false;
   LastNewsEventTime = 0;
   LastNewsEventName = "";

   string currency = NewsCurrency;
   StringTrimLeft(currency);
   StringTrimRight(currency);
   StringToUpper(currency);

   if(StringLen(currency) == 0)
   {
      Print("NEWS FILTER WARNING: NewsCurrency is empty. Filter is inactive.");
      return false;
   }

   int beforeMinutes = MathMax(0, NewsBeforeMinutes);
   int afterMinutes  = MathMax(0, NewsAfterMinutes);

   datetime fromTime = now - (beforeMinutes * 60);
   datetime toTime   = now + (afterMinutes * 60);

   MqlCalendarValue values[];
   ResetLastError();

   int count = CalendarValueHistory(
      values,
      fromTime,
      toTime,
      NULL,
      currency
   );

   if(count < 0)
   {
      int err = GetLastError();

      // Fail-open: calendar availability must not terminate the EA.
      // Journal makes the condition visible for live/test diagnostics.
      PrintFormat(
         "NEWS FILTER WARNING: CalendarValueHistory failed | currency=%s | error=%d",
         currency,
         err
      );

      return false;
   }

   NewsDataAvailable = true;

   for(int i = 0; i < count; i++)
   {
      MqlCalendarEvent event;

      if(!CalendarEventById(values[i].event_id, event))
         continue;

      bool importanceOK =
         !NewsHighImpactOnly ||
         event.importance == CALENDAR_IMPORTANCE_HIGH;

      if(!importanceOK)
         continue;

      // Only events with an actual timestamp are actionable.
      if(event.time_mode != CALENDAR_TIMEMODE_DATETIME)
         continue;

      datetime eventTime = values[i].time;

      if(eventTime < fromTime || eventTime > toTime)
         continue;

      NewsBlocked = true;

      // Keep the nearest future matching event for the optional
      // pre-news close window. If there is no future event, retain
      // the first matching event for dashboard/diagnostics.
      if(LastNewsEventTime == 0 ||
         (eventTime > now && LastNewsEventTime <= now) ||
         (eventTime > now && eventTime < LastNewsEventTime))
      {
         LastNewsEventTime = eventTime;
         LastNewsEventName = event.name;
      }

      PrintFormat(
         "NEWS BLOCK | %s | %s | event=%s | event_time=%s | window=%d/%d min",
         currency,
         EnumToString((ENUM_CALENDAR_EVENT_IMPORTANCE)event.importance),
         event.name,
         TimeToString(eventTime, TIME_DATE|TIME_MINUTES),
         beforeMinutes,
         afterMinutes
      );
   }

   return NewsBlocked;
}

//================================================================================================//
bool IsPreNewsCloseWindow()
{
   if(MQLInfoInteger(MQL_TESTER))
      return false;

   if(!EnableNewsFilter || !CloseBeforeNews)
      return false;

   datetime now = TimeCurrent();

   if(LastNewsEventTime <= 0)
      return false;

   return (LastNewsEventTime > now &&
           (LastNewsEventTime - now) <= CloseBeforeNewsMinutes * 60);
}

//================================================================================================//
//================================================================================================//
void ManageBasketExit()
{
   UpdateStatus();

   int total =
      BuyOrders
      + SellOrders
      + ((RecoveryStage > 0) ? 1 : 0)
      + ((RecoveryStage > 1) ? 1 : 0);

   if(total == 0)
   {
      BasketPeakProfit = 0;
      BasketTrailingActive = false;
      return;
   }

   double p = BasketProfitValue;

   if(UseTrailingProfit)
   {
      double arm = MathMax(TargetProfitUSD, TrailingStartUSD);

      if(!BasketTrailingActive && p >= arm)
      {
         BasketTrailingActive = true;
         BasketPeakProfit = p;

         PrintFormat("BASKET TARGET REACHED -> TRAILING ON | basket=%.2f | stage=%d",
                     p, RecoveryStage);
      }

      if(BasketTrailingActive)
      {
         if(p > BasketPeakProfit)
            BasketPeakProfit = p;

         if(p <= BasketPeakProfit - TrailingStopUSD)
         {
            PrintFormat("BASKET TRAILING CLOSE | peak=%.2f | current=%.2f | stage=%d",
                        BasketPeakProfit, p, RecoveryStage);

            CloseAllOrders();
            BasketPeakProfit = 0;
            BasketTrailingActive = false;
         }
      }
   }
   else if(p >= TargetProfitUSD)
   {
      CloseAllOrders();
      BasketPeakProfit = 0;
      BasketTrailingActive = false;
   }
}

//================================================================================================//
double NormalizeRecoveryVolume(double volume)
{
   double minLot = SymbolInfoDouble(SymbolTrade, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(SymbolTrade, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(SymbolTrade, SYMBOL_VOLUME_STEP);

   if(minLot <= 0) minLot = 0.01;
   if(step <= 0) step = 0.01;
   if(maxLot <= 0) maxLot = volume;

   volume = MathMax(minLot, MathMin(maxLot, volume));
   volume = MathRound(volume / step) * step;
   volume = MathMax(minLot, MathMin(maxLot, volume));

   int digits = (step < 0.01) ? 3 : 2;
   if(step < 0.001) digits = 4;

   return NormalizeDouble(volume, digits);
}

//================================================================================================//
bool HasRecoveryPending()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;

      if(OrderGetInteger(ORDER_MAGIC) != OrdersID)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != SymbolTrade)
         continue;

      string c = OrderGetString(ORDER_COMMENT);

      if(StringFind(c, "RECOVERY 1 BUY") >= 0 ||
         StringFind(c, "RECOVERY 1 SELL") >= 0 ||
         StringFind(c, "RECOVERY 2 BUY") >= 0 ||
         StringFind(c, "RECOVERY 2 SELL") >= 0)
         return true;
   }

   return false;
}

//================================================================================================//
void DeleteRecoveryPending()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;

      if(OrderGetInteger(ORDER_MAGIC) != OrdersID)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != SymbolTrade)
         continue;

      string c = OrderGetString(ORDER_COMMENT);

      if(StringFind(c, "RECOVERY 1 BUY") < 0 &&
         StringFind(c, "RECOVERY 1 SELL") < 0 &&
         StringFind(c, "RECOVERY 2 BUY") < 0 &&
         StringFind(c, "RECOVERY 2 SELL") < 0)
         continue;

      MqlTradeRequest req = {};
      MqlTradeResult  res = {};

      req.action = TRADE_ACTION_REMOVE;
      req.order  = ticket;

      ResetLastError();

      if(!OrderSend(req, res))
      {
         PrintFormat("RECOVERY PENDING DELETE FAILED | Ticket=%I64u | Error=%d",
                     ticket, GetLastError());
         continue;
      }

      if(res.retcode != TRADE_RETCODE_DONE)
      {
         PrintFormat("RECOVERY PENDING DELETE REJECTED | Ticket=%I64u | Retcode=%u | Comment=%s",
                     ticket, res.retcode, res.comment);
      }
   }
}

//================================================================================================//
void ManageRecoveryStage1(ENUM_POSITION_TYPE primaryType)
{
   if(!EnableRecovery || RecoveryStage > 0 || HasRecoveryPending())
      return;

   if(MaxRecoveryStages < 1)
      return;

   double primaryPL =
      (primaryType == POSITION_TYPE_BUY) ? BuyProfit : SellProfit;

   double primaryLots =
      (primaryType == POSITION_TYPE_BUY) ? BuyLots : SellLots;

   double thirdPrice =
      (primaryType == POSITION_TYPE_BUY) ? Buy3Price : Sell3Price;

   if(RecoveryOnlyWhenMinus && primaryPL >= 0.0)
      return;

   if(primaryLots <= 0 || thirdPrice <= 0)
      return;

   double point = SymbolInfoDouble(SymbolTrade, SYMBOL_POINT);
   if(point <= 0)
      return;

   double bid = SymbolInfoDouble(SymbolTrade, SYMBOL_BID);
   double ask = SymbolInfoDouble(SymbolTrade, SYMBOL_ASK);

   double adversePoints =
      (primaryType == POSITION_TYPE_BUY)
      ? (thirdPrice - bid) / point
      : (ask - thirdPrice) / point;

   if(adversePoints < Recovery1GapPoints)
      return;

   UpdateStatus();

   double basketBefore = BasketProfitValue;

   if(RecoveryOnlyWhenMinus && basketBefore >= 0.0)
      return;

   double lot =
      NormalizeRecoveryVolume(primaryLots * Recovery1Multiplier);

   if(Recovery1MaxLot > 0.0)
      lot = NormalizeRecoveryVolume(MathMin(lot, Recovery1MaxLot));

   if(lot <= 0)
      return;

   ExecuteRecoveryTrade(
      primaryType == POSITION_TYPE_BUY
      ? ORDER_TYPE_SELL
      : ORDER_TYPE_BUY,
      lot,
      1
   );
}

//================================================================================================//
void ManageRecoveryStage2()
{
   if(!EnableRecovery || RecoveryStage != 1 || MaxRecoveryStages < 2)
      return;

   if(Recovery1Lots <= 0 || Recovery1EntryPrice <= 0)
      return;

   if(RecoveryOnlyWhenMinus && Recovery1Profit >= 0.0)
      return;

   if(RecoveryOnlyWhenMinus && BasketProfitValue >= 0.0)
      return;

   double point = SymbolInfoDouble(SymbolTrade, SYMBOL_POINT);
   if(point <= 0)
      return;

   double bid = SymbolInfoDouble(SymbolTrade, SYMBOL_BID);
   double ask = SymbolInfoDouble(SymbolTrade, SYMBOL_ASK);

   double adversePoints = 0.0;

   if(Recovery1Type == POSITION_TYPE_BUY)
      adversePoints = (Recovery1EntryPrice - bid) / point;
   else if(Recovery1Type == POSITION_TYPE_SELL)
      adversePoints = (ask - Recovery1EntryPrice) / point;
   else
      return;

   if(adversePoints < Recovery2GapPoints)
      return;

   UpdateStatus();

   if(RecoveryStage != 1)
      return;

   if(RecoveryOnlyWhenMinus && Recovery1Profit >= 0.0)
      return;

   if(RecoveryOnlyWhenMinus && BasketProfitValue >= 0.0)
      return;

   double primaryLots = BuyLots + SellLots;

   if(primaryLots <= 0)
      return;

   double lot =
      NormalizeRecoveryVolume(primaryLots * Recovery2Multiplier);

   if(Recovery2MaxLot > 0.0)
      lot = NormalizeRecoveryVolume(MathMin(lot, Recovery2MaxLot));

   if(lot <= 0)
      return;

   ExecuteRecoveryTrade(
      Recovery1Type == POSITION_TYPE_SELL
      ? ORDER_TYPE_BUY
      : ORDER_TYPE_SELL,
      lot,
      2
   );
}

//================================================================================================//
void ExecuteRecoveryTrade(ENUM_ORDER_TYPE type, double lot, int stage)
{
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = SymbolTrade;
   req.magic        = OrdersID;
   req.volume       = lot;
   req.type         = type;
   req.deviation    = 10;
   req.type_filling = ORDER_FILLING_IOC;

   req.price =
      (type == ORDER_TYPE_BUY)
      ? SymbolInfoDouble(SymbolTrade, SYMBOL_ASK)
      : SymbolInfoDouble(SymbolTrade, SYMBOL_BID);

   req.comment =
      StringFormat("%s RECOVERY %d %s",
                   CommentsOrders,
                   stage,
                   type == ORDER_TYPE_BUY ? "BUY" : "SELL");

   ResetLastError();

   if(!OrderSend(req, res))
   {
      PrintFormat("RECOVERY %d SEND FAILED | Type=%s | Error=%d",
                  stage, EnumToString(type), GetLastError());
      return;
   }

   if(res.retcode != TRADE_RETCODE_DONE &&
      res.retcode != TRADE_RETCODE_DONE_PARTIAL)
   {
      PrintFormat("RECOVERY %d REJECTED | Type=%s | Lot=%.2f | Retcode=%u | Comment=%s",
                  stage,
                  EnumToString(type),
                  lot,
                  res.retcode,
                  res.comment);
      return;
   }

   PrintFormat("RECOVERY %d OPEN OK | Type=%s | Lot=%.2f | Order=%I64u | Deal=%I64u",
               stage,
               EnumToString(type),
               lot,
               res.order,
               res.deal);
}

//================================================================================================//
void ManagePrimaryGrid(bool allowNewEntries, bool allowGridExpansion)
{
   UpdateStatus();

   // Do not create a mixed primary BUY+SELL basket.
   if(BuyOrders > 0 && SellOrders > 0)
      return;

   double point = SymbolInfoDouble(SymbolTrade, SYMBOL_POINT);
   if(point <= 0)
      return;

   if(BuyOrders > 0 && BuyOrders < MaxOrders)
   {
      if(!allowGridExpansion)
         return;

      double gap =
         PointsForFirstGap
         * MathPow(GapMultiplier, BuyOrders - 1)
         * point;

      if(SymbolInfoDouble(SymbolTrade, SYMBOL_ASK)
         <= PriceOpenLastBuy - gap)
      {
         ExecuteTrade(ORDER_TYPE_BUY);
      }

      return;
   }

   if(SellOrders > 0 && SellOrders < MaxOrders)
   {
      if(!allowGridExpansion)
         return;

      double gap =
         PointsForFirstGap
         * MathPow(GapMultiplier, SellOrders - 1)
         * point;

      if(SymbolInfoDouble(SymbolTrade, SYMBOL_BID)
         >= PriceOpenLastSell + gap)
      {
         ExecuteTrade(ORDER_TYPE_SELL);
      }

      return;
   }

   if(BuyOrders == 0 && SellOrders == 0 && allowNewEntries)
   {
      double rsi   = GetRSIValue();
      double ma    = GetMAValue();
      double price = SymbolInfoDouble(SymbolTrade, SYMBOL_BID);

      if((TypeOrdersPlace == Open_Buy_And_Sell ||
          TypeOrdersPlace == Open__Only_Buy) &&
         ma > 0 &&
         price > ma &&
         rsi < RSILower)
      {
         ExecuteTrade(ORDER_TYPE_BUY);
         return;
      }

      if((TypeOrdersPlace == Open_Buy_And_Sell ||
          TypeOrdersPlace == Open__Only_Sell) &&
         ma > 0 &&
         price < ma &&
         rsi > RSIUpper)
      {
         ExecuteTrade(ORDER_TYPE_SELL);
         return;
      }
   }
}

//================================================================================================//
//================================================================================================//
void UpdateStatus()
{
   BuyOrders = 0;
   SellOrders = 0;
   BuyLots = 0;
   SellLots = 0;
   BuyProfit = 0;
   SellProfit = 0;

   PriceOpenLastBuy = 0;
   PriceOpenLastSell = 0;

   Buy3Price = 0;
   Sell3Price = 0;
   LastBuyTimeMsc = 0;
   LastSellTimeMsc = 0;

   RecoveryStage = 0;

   Recovery1Lots = 0;
   Recovery1Profit = 0;
   Recovery1EntryPrice = 0;
   Recovery1Type = WRONG_VALUE;

   Recovery2Lots = 0;
   Recovery2Profit = 0;
   Recovery2EntryPrice = 0;
   Recovery2Type = WRONG_VALUE;

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

      double lot =
         PositionGetDouble(POSITION_VOLUME);

      double p =
         PositionGetDouble(POSITION_PROFIT)
         + PositionGetDouble(POSITION_SWAP);

      double open =
         PositionGetDouble(POSITION_PRICE_OPEN);

      long timeMsc =
         PositionGetInteger(POSITION_TIME_MSC);

      string c =
         PositionGetString(POSITION_COMMENT);

      bool recovery1 =
         StringFind(c, "RECOVERY 1 BUY") >= 0 ||
         StringFind(c, "RECOVERY 1 SELL") >= 0;

      bool recovery2 =
         StringFind(c, "RECOVERY 2 BUY") >= 0 ||
         StringFind(c, "RECOVERY 2 SELL") >= 0;

      if(recovery1)
      {
         Recovery1Lots += lot;
         Recovery1Profit += p;
         Recovery1EntryPrice = open;
         Recovery1Type = type;
         RecoveryStage = MathMax(RecoveryStage, 1);
         continue;
      }

      if(recovery2)
      {
         Recovery2Lots += lot;
         Recovery2Profit += p;
         Recovery2EntryPrice = open;
         Recovery2Type = type;
         RecoveryStage = MathMax(RecoveryStage, 2);
         continue;
      }

      if(type == POSITION_TYPE_BUY)
      {
         BuyOrders++;
         BuyLots += lot;
         BuyProfit += p;

         if(timeMsc >= LastBuyTimeMsc)
         {
            LastBuyTimeMsc = timeMsc;
            PriceOpenLastBuy = open;
         }

         if(StringFind(c, "PRIMARY BUY 3") >= 0)
            Buy3Price = open;
      }
      else if(type == POSITION_TYPE_SELL)
      {
         SellOrders++;
         SellLots += lot;
         SellProfit += p;

         if(timeMsc >= LastSellTimeMsc)
         {
            LastSellTimeMsc = timeMsc;
            PriceOpenLastSell = open;
         }

         if(StringFind(c, "PRIMARY SELL 3") >= 0)
            Sell3Price = open;
      }
   }

   // Fallback: if comments from an older basket do not contain #3,
   // use the latest primary position as the recovery reference.
   if(BuyOrders >= MaxOrders && Buy3Price <= 0)
      Buy3Price = PriceOpenLastBuy;

   if(SellOrders >= MaxOrders && Sell3Price <= 0)
      Sell3Price = PriceOpenLastSell;

   RecoveryLots =
      Recovery1Lots + Recovery2Lots;

   RecoveryProfit =
      Recovery1Profit + Recovery2Profit;

   RecoveryActive =
      (RecoveryStage > 0);

   BasketProfitValue =
      BuyProfit
      + SellProfit
      + RecoveryProfit;
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

   req.comment =
      StringFormat("%s PRIMARY %s %d",
                   CommentsOrders,
                   type == ORDER_TYPE_BUY ? "BUY" : "SELL",
                   c + 1);

   ResetLastError();

   if(!OrderSend(req, res))
   {
      PrintFormat("Gagal membuka %s. Error: %d",
                  EnumToString(type),
                  GetLastError());
      return;
   }

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
      ? StringFormat("RECOVERY %d ACTIVE", RecoveryStage)
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
      "News     : ", (EnableNewsFilter ? (NewsBlocked ? "BLOCKED" : "CLEAR") : "OFF"), "\n",
      "News Event : ", (LastNewsEventName == "" ? "-" : LastNewsEventName), "\n",
      "----------------------------------\n",
      "BUY Primary : ", BuyOrders,
      " | Lot: ", DoubleToString(BuyLots, 2),
      " | P/L: ", DoubleToString(BuyProfit, 2), "\n",
      "SELL Primary: ", SellOrders,
      " | Lot: ", DoubleToString(SellLots, 2),
      " | P/L: ", DoubleToString(SellProfit, 2), "\n",
      "R1 : ", (RecoveryStage >= 1 ? "ACTIVE" : "OFF"),
      " | Lot: ", DoubleToString(Recovery1Lots, 2),
      " | P/L: ", DoubleToString(Recovery1Profit, 2), "\n",
      "R2 : ", (RecoveryStage >= 2 ? "ACTIVE" : "OFF"),
      " | Lot: ", DoubleToString(Recovery2Lots, 2),
      " | P/L: ", DoubleToString(Recovery2Profit, 2), "\n",
      "Basket P/L: ", DoubleToString(BasketProfitValue, 2),
      " | Trail: ", (BasketTrailingActive ? "ON" : "OFF"),
      " | Peak: ", DoubleToString(BasketPeakProfit, 2), "\n",
      "R1: ", DoubleToString(Recovery1Multiplier, 2),
      "x / ", DoubleToString(Recovery1GapPoints, 0), " pts",
      " | R2: ", DoubleToString(Recovery2Multiplier, 2),
      "x / ", DoubleToString(Recovery2GapPoints, 0), " pts\n",
      "=================================="
   );
}
//================================================================================================//
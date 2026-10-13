//+------------------------------------------------------------------+
//| GRID 06 V24 - CONTROLLED BASKET RECOVERY                         |
//| Based on V02 primary grid; bounded calculated R1; R2 disabled    |
//| Experimental preset - compile and backtest before any live use    |
//+------------------------------------------------------------------+
#property strict
#property version   "24.00"
#property description "Controlled grid with capped Stage-1 basket recovery"

#include <Trade/Trade.mqh>
CTrade trade;

enum EntryMode { BOTH_DIRECTIONS, BUY_ONLY, SELL_ONLY };

//--- Entry and grid
input group "=== ENTRY ==="
input EntryMode TradeDirection       = BOTH_DIRECTIONS;
input int       MAPeriod              = 200;
input int       RSIPeriod             = 14;
input double    RSILower              = 43.0;
input double    RSIUpper              = 57.0;
input bool      UseClosedCandleSignal = true;

input group "=== PRIMARY GRID ==="
input double    InitialLot            = 0.01;
input int       MaxPrimaryOrders      = 3;
input double    FirstGapPoints        = 6250.0;
input double    GapMultiplier         = 1.30;
input double    MaxPrimaryLot         = 0.03;
input double    BasketTargetUSD       = 1.0;

input group "=== STAGE 1 CONTROLLED RECOVERY ==="
input bool      EnableRecoveryStage1  = true;
input double    RecoveryTriggerPoints = 6250.0;
input double    RecoveryTargetMoveUSD = 1.50;
input double    RecoveryMaxLot         = 0.12;
input double    RecoveryMaxBasketLossUSD = 35.0;
input int       MaxRecoveryStages     = 1; // V24 intentionally caps recovery at R1
input bool      EnableRecoveryStage2  = false; // reserved; not implemented in V24

input group "=== EXIT AND ACCOUNT PROTECTION ==="
input bool      UseBasketTrailing     = true;
input double    TrailingStartUSD      = 5.0;
input double    TrailingStopUSD       = 2.0;
input double    MaxEquityDrawdownPct  = 10.0;
input double    MaxMarginUsagePct     = 35.0;
input int       MaxBasketHours        = 8;
input bool      CloseBasketOnTimeout  = true;
input bool      UseTradingHours       = false;
input int       StartHour             = 7;
input int       EndHour               = 22;

input group "=== EXECUTION ==="
input long      MagicNumber           = 16082024;
input int       DeviationPoints       = 20;
input string    OrderComment          = "GRID 06 V24";

int rsiHandle = INVALID_HANDLE;
int maHandle = INVALID_HANDLE;
int atrHandle = INVALID_HANDLE;
string tradeSymbol;
bool halted = false;
double peakBasketProfit = 0.0;
datetime basketStarted = 0;
bool recoveryUsed = false;
double initialEquity = 0.0;
double highWaterEquity = 0.0;

struct BasketInfo
{
   int buys;
   int sells;
   int primaryBuys;
   int primarySells;
   int recoveryCount;
   double buyLots;
   double sellLots;
   double buyProfit;
   double sellProfit;
   double totalProfit;
   double lastBuyPrice;
   double lastSellPrice;
   datetime oldestTime;
   bool hasBuy;
   bool hasSell;
};

int OnInit()
{
   tradeSymbol = _Symbol;
   if(MagicNumber <= 0 || InitialLot <= 0 || MaxPrimaryOrders < 1 ||
      FirstGapPoints <= 0 || GapMultiplier < 1.0 ||
      RSILower <= 0 || RSIUpper >= 100 || RSILower >= RSIUpper ||
      RecoveryMaxLot < SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_MIN) ||
      MaxEquityDrawdownPct <= 0 || MaxEquityDrawdownPct >= 100)
   {
      Print("V24: invalid input parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints(DeviationPoints);
   trade.SetTypeFillingBySymbol(tradeSymbol);
   trade.SetAsyncMode(false);

   rsiHandle = iRSI(tradeSymbol, PERIOD_CURRENT, RSIPeriod, PRICE_CLOSE);
   maHandle  = iMA(tradeSymbol, PERIOD_CURRENT, MAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   atrHandle = iATR(tradeSymbol, PERIOD_CURRENT, 14);
   if(rsiHandle == INVALID_HANDLE || maHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   {
      Print("V24: failed to create indicator handles.");
      return INIT_FAILED;
   }

   initialEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   highWaterEquity = initialEquity;

   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("V24 requires a hedging account because primary and recovery positions must remain separate.");
      return INIT_FAILED;
   }
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(maHandle != INVALID_HANDLE) IndicatorRelease(maHandle);
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   Comment("");
}

void OnTick()
{
   if(halted || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;

   BasketInfo b;
   RefreshBasket(b);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > highWaterEquity) highWaterEquity = equity;
   double dd = (highWaterEquity > 0 && equity < highWaterEquity)
               ? 100.0 * (highWaterEquity - equity) / highWaterEquity : 0.0;

   // Risk management must run even outside entry hours.
   if(dd >= MaxEquityDrawdownPct)
   {
      PrintFormat("V24 emergency exit: equity drawdown %.2f%%", dd);
      CloseBasket();
      RefreshBasket(b);
      if(b.buys + b.sells == 0) halted = true;
      Display(b, dd, halted ? "HALTED: EQUITY DD LIMIT" : "RISK CLOSE RETRY");
      return;
   }

   if(b.totalProfit <= -RecoveryMaxBasketLossUSD)
   {
      PrintFormat("V24 basket loss cap reached: %.2f", b.totalProfit);
      CloseBasket();
      RefreshBasket(b);
      if(b.buys + b.sells == 0) halted = true;
      Display(b, dd, halted ? "HALTED: BASKET LOSS LIMIT" : "RISK CLOSE RETRY");
      return;
   }

   if(b.buys + b.sells == 0)
   {
      if(basketStarted != 0)
      {
         basketStarted = 0;
         peakBasketProfit = 0;
         recoveryUsed = false;
      }
   }
   else
   {
      if(basketStarted == 0) basketStarted = b.oldestTime;
      ManageBasketExit(b);
      if(halted) return;
      RefreshBasket(b);
      if(b.buys + b.sells == 0)
      {
         // Do not immediately reopen a new basket on the same tick as an exit.
         Display(b, dd, "BASKET CLOSED");
         return;
      }

      if(MaxBasketHours > 0 && basketStarted > 0 &&
         TimeCurrent() - basketStarted >= MaxBasketHours * 3600)
      {
         if(CloseBasketOnTimeout)
         {
            Print("V24: max basket holding time reached; closing basket.");
            CloseBasket();
            Display(b, dd, "BASKET TIMEOUT");
            return;
         }
         else
         {
            Display(b, dd, "TIMEOUT: ENTRY LOCKED");
            return;
         }
      }
   }

   if(!IsTradingHour())
   {
      Display(b, dd, "OUTSIDE ENTRY HOURS - RISK MANAGEMENT ACTIVE");
      return;
   }

   double rsi, ma, atr;
   if(!ReadIndicator(rsiHandle, rsi) || !ReadIndicator(maHandle, ma) ||
      !ReadIndicator(atrHandle, atr) || atr <= 0)
   {
      Display(b, dd, "WAITING FOR INDICATORS");
      return;
   }

   double signalPrice = SymbolInfoDouble(tradeSymbol, SYMBOL_BID);
   if(b.buys == 0 && b.sells == 0)
   {
      bool buySignal = (TradeDirection != SELL_ONLY && signalPrice > ma && rsi < RSILower);
      bool sellSignal = (TradeDirection != BUY_ONLY && signalPrice < ma && rsi > RSIUpper);
      // Avoid simultaneous first entry: trend/price side determines a single direction.
      if(buySignal && !sellSignal) OpenPrimary(ORDER_TYPE_BUY, 0);
      else if(sellSignal && !buySignal) OpenPrimary(ORDER_TYPE_SELL, 0);
   }
   else
   {
      // Freeze primary grid when both directions exist; recovery is only one-direction basket.
      if(b.buys > 0 && b.sells == 0 && b.primaryBuys < MaxPrimaryOrders)
      {
         double gap = FirstGapPoints * MathPow(GapMultiplier, MathMax(0, b.primaryBuys - 1));
         double ask = SymbolInfoDouble(tradeSymbol, SYMBOL_ASK);
         if(ask <= b.lastBuyPrice - gap * _Point)
            OpenPrimary(ORDER_TYPE_BUY, b.primaryBuys);
      }
      else if(b.sells > 0 && b.buys == 0 && b.primarySells < MaxPrimaryOrders)
      {
         double gap = FirstGapPoints * MathPow(GapMultiplier, MathMax(0, b.primarySells - 1));
         double bid = SymbolInfoDouble(tradeSymbol, SYMBOL_BID);
         if(bid >= b.lastSellPrice + gap * _Point)
            OpenPrimary(ORDER_TYPE_SELL, b.primarySells);
      }

      // R1 only after full primary grid, adverse move confirmed, basket still within risk budget.
      RefreshBasket(b);
      if(EnableRecoveryStage1 && MaxRecoveryStages >= 1 && !recoveryUsed &&
         b.buys + b.sells > 0 && !(b.buys > 0 && b.sells > 0) &&
         b.primaryBuys + b.primarySells >= MaxPrimaryOrders &&
         b.totalProfit < 0 && b.totalProfit > -RecoveryMaxBasketLossUSD)
      {
         bool trigger = false;
         ENUM_ORDER_TYPE recoveryType = ORDER_TYPE_BUY;
         double current = 0.0, triggerPrice = 0.0;
         if(b.buys > 0)
         {
            current = SymbolInfoDouble(tradeSymbol, SYMBOL_BID);
            triggerPrice = b.lastBuyPrice - RecoveryTriggerPoints * _Point;
            trigger = (current <= triggerPrice);
            recoveryType = ORDER_TYPE_SELL;
         }
         else if(b.sells > 0)
         {
            current = SymbolInfoDouble(tradeSymbol, SYMBOL_ASK);
            triggerPrice = b.lastSellPrice + RecoveryTriggerPoints * _Point;
            trigger = (current >= triggerPrice);
            recoveryType = ORDER_TYPE_BUY;
         }

         if(trigger && atr >= 2.0 * _Point)
            TryOpenRecovery(recoveryType, b);
         else if(!recoveryUsed && b.primaryBuys + b.primarySells >= MaxPrimaryOrders &&
                 b.totalProfit < 0 && b.totalProfit > -RecoveryMaxBasketLossUSD)
         {
            static datetime lastRecoveryDiagnostic = 0;
            if(TimeCurrent() - lastRecoveryDiagnostic >= 300)
            {
               PrintFormat("V24 R1 WAIT: trigger=%s | primary=%d/%d | basket P/L=%.2f | current=%.3f | trigger price=%.3f | adverse threshold=%.1f points",
                           (trigger ? "YES" : "NO"),
                           b.primaryBuys + b.primarySells, MaxPrimaryOrders, b.totalProfit,
                           current, triggerPrice, RecoveryTriggerPoints);
               lastRecoveryDiagnostic = TimeCurrent();
            }
         }
      }
   }

   RefreshBasket(b);
   double marginPct = (AccountInfoDouble(ACCOUNT_EQUITY) > 0)
      ? 100.0 * AccountInfoDouble(ACCOUNT_MARGIN) / AccountInfoDouble(ACCOUNT_EQUITY) : 100.0;
   if(marginPct >= MaxMarginUsagePct)
      Display(b, dd, "MARGIN GUARD: NO NEW ORDERS");
   else
      Display(b, dd, recoveryUsed ? "R1 ACTIVE/USED" : "RUNNING");
}

bool IsTradingHour()
{
   if(!UseTradingHours) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(StartHour == EndHour) return true;
   if(StartHour < EndHour) return (dt.hour >= StartHour && dt.hour < EndHour);
   return (dt.hour >= StartHour || dt.hour < EndHour);
}

bool ReadIndicator(const int handle, double &value)
{
   double buffer[];
   ArraySetAsSeries(buffer, true);
   int shift = UseClosedCandleSignal ? 1 : 0;
   if(CopyBuffer(handle, 0, shift, 1, buffer) != 1) return false;
   value = buffer[0];
   return true;
}

void RefreshBasket(BasketInfo &b)
{
   ZeroMemory(b);
   b.oldestTime = 0;
   datetime latestBuy = 0, latestSell = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != tradeSymbol ||
         PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      string comment = PositionGetString(POSITION_COMMENT);
      bool isRecovery = (StringFind(comment, "V24 R1") >= 0);
      // Position-level commission is deprecated in current MQL5 builds.
      // Basket P/L uses floating profit + swap; check tester deal history
      // for commissions when evaluating final net results.
      double profit = PositionGetDouble(POSITION_PROFIT) +
                      PositionGetDouble(POSITION_SWAP);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(b.oldestTime == 0 || openTime < b.oldestTime) b.oldestTime = openTime;
      if(isRecovery) b.recoveryCount++;

      if(type == POSITION_TYPE_BUY)
      {
         b.buys++; b.buyLots += volume; b.buyProfit += profit; b.hasBuy = true;
         if(!isRecovery) b.primaryBuys++;
         if(openTime >= latestBuy) { latestBuy = openTime; b.lastBuyPrice = openPrice; }
      }
      else
      {
         b.sells++; b.sellLots += volume; b.sellProfit += profit; b.hasSell = true;
         if(!isRecovery) b.primarySells++;
         if(openTime >= latestSell) { latestSell = openTime; b.lastSellPrice = openPrice; }
      }
      b.totalProfit += profit;
   }
   if(b.recoveryCount > 0) recoveryUsed = true;
}

void ManageBasketExit(BasketInfo &b)
{
   if(b.buys + b.sells == 0) return;

   // Once R1 has been used, prioritize a small net recovery exit over waiting
   // for the normal $5 trailing activation. This is still not a guarantee
   // that the basket will reach the target.
   if(recoveryUsed && b.totalProfit >= BasketTargetUSD)
   {
      PrintFormat("V24 recovery basket target reached: %.2f", b.totalProfit);
      CloseBasket();
      return;
   }

   if(!UseBasketTrailing)
   {
      if(b.totalProfit >= BasketTargetUSD) CloseBasket();
      return;
   }
   if(b.totalProfit >= TrailingStartUSD && b.totalProfit > peakBasketProfit)
      peakBasketProfit = b.totalProfit;

   if(peakBasketProfit >= TrailingStartUSD &&
      b.totalProfit <= peakBasketProfit - TrailingStopUSD)
   {
      PrintFormat("V24 basket trail exit: peak %.2f current %.2f", peakBasketProfit, b.totalProfit);
      CloseBasket();
   }
}

bool OpenPrimary(ENUM_ORDER_TYPE type, int existingCount)
{
   double lot = MathMin(InitialLot * (existingCount + 1), MaxPrimaryLot);
   lot = NormalizeVolume(lot);
   if(lot <= 0 || !CanAddExposure(lot, type)) return false;
   bool ok = (type == ORDER_TYPE_BUY)
      ? trade.Buy(lot, tradeSymbol, 0, 0, 0, OrderComment + " PRIMARY BUY")
      : trade.Sell(lot, tradeSymbol, 0, 0, 0, OrderComment + " PRIMARY SELL");
   if(!ok || !TradeRetcodeOK())
   {
      PrintFormat("V24 primary order failed. retcode=%u %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
   }
   if(basketStarted == 0) basketStarted = TimeCurrent();
   return true;
}

void TryOpenRecovery(ENUM_ORDER_TYPE type, BasketInfo &b)
{
   double ask = SymbolInfoDouble(tradeSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(tradeSymbol, SYMBOL_BID);
   double entry = (type == ORDER_TYPE_BUY) ? ask : bid;
   double target = (type == ORDER_TYPE_BUY)
      ? entry + RecoveryTargetMoveUSD
      : entry - RecoveryTargetMoveUSD;

   double lot = FindRecoveryLot(type, entry, target, b);
   if(lot <= 0)
   {
      PrintFormat("V24 R1 SKIPPED: target not reachable within cap %.2f lots. Basket P/L=%.2f, target move=%.2f, basket target=%.2f. Reduce target, trigger earlier, or accept that this basket cannot be recovered within current risk cap.",
                  RecoveryMaxLot, b.totalProfit, RecoveryTargetMoveUSD, BasketTargetUSD);
      return;
   }
   if(!CanAddExposure(lot, type))
   {
      PrintFormat("V24 R1 BLOCKED by margin guard. Required lot=%.2f, current basket P/L=%.2f, margin usage limit=%.1f%%.",
                  lot, b.totalProfit, MaxMarginUsagePct);
      return;
   }

   bool ok = (type == ORDER_TYPE_BUY)
      ? trade.Buy(lot, tradeSymbol, 0, 0, 0, OrderComment + " V24 R1 BUY")
      : trade.Sell(lot, tradeSymbol, 0, 0, 0, OrderComment + " V24 R1 SELL");
   if(!ok || !TradeRetcodeOK())
   {
      PrintFormat("V24 R1 failed. retcode=%u %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return;
   }
   recoveryUsed = true;
   PrintFormat("V24 R1 opened %.2f lot. basket before R1 %.2f, projected target %.2f",
               lot, b.totalProfit, BasketTargetUSD);
}

double FindRecoveryLot(ENUM_ORDER_TYPE type, double entry, double target, BasketInfo &b)
{
   double step = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = MathMin(RecoveryMaxLot, SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_MAX));
   if(step <= 0 || minLot <= 0 || maxLot < minLot) return 0;

   double chosen = 0;
   for(double lot = minLot; lot <= maxLot + step/2.0; lot += step)
   {
      double projected = b.totalProfit;
      // Replace current floating P/L with P/L projected at the target price.
      for(int i = PositionsTotal() - 1; i >= 0; --i)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) != tradeSymbol ||
            PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
         ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         ENUM_ORDER_TYPE ot = (ptype == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         double pl = 0;
         if(!OrderCalcProfit(ot, tradeSymbol, PositionGetDouble(POSITION_VOLUME),
                             PositionGetDouble(POSITION_PRICE_OPEN), target, pl))
         { projected = -DBL_MAX; break; }
         projected += pl - (PositionGetDouble(POSITION_PROFIT) +
                            PositionGetDouble(POSITION_SWAP));
      }
      double r1pl = 0;
      if(!OrderCalcProfit(type, tradeSymbol, lot, entry, target, r1pl)) continue;
      projected += r1pl;
      if(projected >= BasketTargetUSD) { chosen = NormalizeVolume(lot); break; }
   }
   return chosen;
}

bool CanAddExposure(double lot, ENUM_ORDER_TYPE type)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin = AccountInfoDouble(ACCOUNT_MARGIN);
   if(equity <= 0) return false;
   double projectedMargin = 0;
   double price = (type == ORDER_TYPE_BUY)
      ? SymbolInfoDouble(tradeSymbol, SYMBOL_ASK)
      : SymbolInfoDouble(tradeSymbol, SYMBOL_BID);
   if(!OrderCalcMargin(type, tradeSymbol, lot, price, projectedMargin))
   {
      Print("V24: OrderCalcMargin failed; reject new exposure.");
      return false;
   }
   if(100.0 * (margin + projectedMargin) / equity > MaxMarginUsagePct)
   {
      Print("V24: margin guard rejected new order.");
      return false;
   }
   return true;
}

double NormalizeVolume(double volume)
{
   double minLot = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(tradeSymbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) return 0;
   volume = MathMin(volume, maxLot);
   volume = MathFloor(volume / step + 1e-8) * step;
   volume = NormalizeDouble(volume, 8);
   if(volume < minLot) return 0;
   return volume;
}

bool TradeRetcodeOK()
{
   uint rc = trade.ResultRetcode();
   return (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL ||
           rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_NO_CHANGES);
}

void CloseBasket()
{
   // First close all positions; verify server result for every ticket.
   for(int pass = 0; pass < 3; pass++)
   {
      bool found = false;
      for(int i = PositionsTotal() - 1; i >= 0; --i)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) != tradeSymbol ||
            PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
         found = true;
         if(!trade.PositionClose(ticket) || !TradeRetcodeOK())
            PrintFormat("V24 close failed ticket=%I64u retcode=%u %s",
                        ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
      if(!found) break;
   }
   RefreshAfterCloseState();
}

void RefreshAfterCloseState()
{
   BasketInfo b;
   RefreshBasket(b);
   if(b.buys + b.sells == 0)
   {
      basketStarted = 0;
      peakBasketProfit = 0;
      recoveryUsed = false;
   }
}

void Display(BasketInfo &b, double dd, string state)
{
   Comment("========== GRID 06 V24 ==========\n",
           "State: ", state, "\n",
           "Symbol: ", tradeSymbol, " | TF: ", EnumToString((ENUM_TIMEFRAMES)_Period), "\n",
           "Primary BUY/SELL: ", b.primaryBuys, "/", b.primarySells, "\n",
           "All BUY/SELL: ", b.buys, "/", b.sells, "\n",
           "Basket P/L: $", DoubleToString(b.totalProfit, 2), "\n",
           "Buy P/L: $", DoubleToString(b.buyProfit, 2),
           " | Sell P/L: $", DoubleToString(b.sellProfit, 2), "\n",
           "Equity DD from high-water: ", DoubleToString(dd, 2), "%\n",
           "Recovery R1 used: ", (recoveryUsed ? "YES" : "NO"), "\n",
           "RSI thresholds: ", DoubleToString(RSILower, 1), "/", DoubleToString(RSIUpper, 1), "\n",
           "Basket peak: $", DoubleToString(peakBasketProfit, 2), "\n",
           "================================");
}

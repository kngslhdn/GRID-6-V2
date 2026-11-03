//+------------------------------------------------------------------+
//| GRID 06 V25 - PROFIT-TRIGGERED ORDER 2 + TWO-STAGE RECOVERY      |
//| Optimized preset from Strategy Tester 2026.01.01-2026.08.17   |
//| XAUUSDm / M5 / 100% real ticks                                  |
//+------------------------------------------------------------------+
#property strict
#property version "25.00"

#include <Trade/Trade.mqh>
CTrade trade;

enum Type {Open_Buy_And_Sell,Open__Only_Buy,Open__Only_Sell};

//================ BASKET =================//
// Backtest winner used TargetProfitUSD=10, trailing start=5, stop=3.
input double TargetProfitUSD        = 10.0;
input bool   UseTrailingProfit       = true;
input double TrailingStartUSD        = 5.0;
input double TrailingStopUSD         = 3.0;

//================ RISK =================//
// Keep aligned with the tested configuration. Note: report equity DD
// reached ~49.95%, so this is a cap setting, not a guarantee of DD.
input double MaxEquityLossPercent    = 80.0;

//================ PRIMARY =================//
input int    MAPeriod                = 200;
input int    RSIPeriod               = 14;
input int    RSIUpper                = 61;
input int    RSILower                = 41;
input Type   TypeOrdersPlace         = Open_Buy_And_Sell;
input double PointsForFirstGap       = 6250.0;
input double GapMultiplier           = 1.30;
input double ManualLotSize           = 0.01;
input int    MaxOrders               = 3;

//================ PROFIT-TRIGGERED ORDER 2 =================//
input bool   EnableProfitOrder2       = true;
input double ProfitTriggerOrder2USD   = 2.00;
input double ProfitOrder2Lot          = 5.00;

//================ TWO-STAGE RECOVERY =================//
// Tested configuration produced 0.60 lot R1 and 1.80 lot R2
// from the 0.01 / 0.02 / 0.03 primary basket.
input bool   EnableRecovery          = true;
input double Recovery1Multiplier     = 10.0;
input double Recovery1GapPoints      = 10000.0;
input double Recovery1MaxLot         = 2.0;
input double Recovery2Multiplier     = 30.0;
input double Recovery2GapPoints      = 6250.0;
input double Recovery2MaxLot         = 2.0;
input bool   RecoveryOnlyWhenMinus   = true;
input int    MaxRecoveryStages       = 2;

//================ HOURS =================//
input bool   UseTradingHour          = true;
input int    StartHour               = 7;
input int    EndHour                 = 22;

//================ ENGINE =================//
input int    MagicNumber             = 16082016;
input string CommentsOrders          = "GRID 06 V12";

string SymbolTrade;
int OrdersID,HandleRSI,HandleMA;

int BuyOrders=0,SellOrders=0; // primary grid counts only
int ProfitOrder2Count=0;
double ProfitOrder2Lots=0,ProfitOrder2Profit=0;
double PrimaryBuyLots=0,PrimarySellLots=0;
double PrimaryBuyProfit=0,PrimarySellProfit=0;
bool ProfitOrder2RequestInFlight=false;
double BuyLots=0,SellLots=0;
double BuyProfit=0,SellProfit=0;
double LastBuyPrice=0,LastSellPrice=0;
double Buy3Price=0,Sell3Price=0;
datetime LastBuyTime=0,LastSellTime=0;

int RecoveryStage=0;
double Recovery1Lots=0,Recovery1Profit=0,Recovery1EntryPrice=0;
double Recovery2Lots=0,Recovery2Profit=0,Recovery2EntryPrice=0;
ENUM_POSITION_TYPE Recovery1Type=WRONG_VALUE;
ENUM_POSITION_TYPE Recovery2Type=WRONG_VALUE;

double RecoveryLots=0,RecoveryProfit=0;
bool RecoveryActive=false;

double BasketProfitValue=0;
double BasketPeakProfit=0;
bool BasketTrailingActive=false;
bool IsTerminated=false;
double InitialBalance=0;
double HighWaterMark=0;

//+------------------------------------------------------------------+
//| FUNCTION: IsTradingHour                                         |
//+------------------------------------------------------------------+
bool IsTradingHour(){
   if(!UseTradingHour) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(StartHour<EndHour) return dt.hour>=StartHour && dt.hour<EndHour;
   return dt.hour>=StartHour || dt.hour<EndHour;
}

//+------------------------------------------------------------------+
//| FUNCTION: IsOurPosition                                         |
//+------------------------------------------------------------------+
bool IsOurPosition(ulong ticket){
   if(ticket==0 || !PositionSelectByTicket(ticket)) return false;
   return PositionGetInteger(POSITION_MAGIC)==OrdersID && PositionGetString(POSITION_SYMBOL)==SymbolTrade;
}

//+------------------------------------------------------------------+
//| FUNCTION: IsOurOrder                                            |
//+------------------------------------------------------------------+
bool IsOurOrder(ulong ticket){
   if(ticket==0 || !OrderSelect(ticket)) return false;
   return OrderGetInteger(ORDER_MAGIC)==OrdersID && OrderGetString(ORDER_SYMBOL)==SymbolTrade;
}

//+------------------------------------------------------------------+
//| FUNCTION: TradeOK                                               |
//+------------------------------------------------------------------+
bool TradeOK(){
   uint r=trade.ResultRetcode();
   return r==TRADE_RETCODE_DONE || r==TRADE_RETCODE_DONE_PARTIAL || r==TRADE_RETCODE_PLACED;
}

//+------------------------------------------------------------------+
//| FUNCTION: NormalizeVolume                                       |
//+------------------------------------------------------------------+
double NormalizeVolume(double v){
   double mn=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MIN);
   double mx=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MAX);
   double st=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_STEP);
   if(mn<=0) mn=0.01; if(st<=0) st=0.01; if(mx<=0) mx=v;
   v=MathMax(mn,MathMin(mx,v));
   v=MathRound(v/st)*st;
   v=MathMax(mn,MathMin(mx,v));
   int digits=(st<0.01)?3:2; if(st<0.001) digits=4;
   return NormalizeDouble(v,digits);
}


//+------------------------------------------------------------------+
//| FUNCTION: IsProfitOrder2Comment                                  |
//+------------------------------------------------------------------+
bool IsProfitOrder2Comment(string comment){
   return StringFind(comment,"PROFIT ORDER 2")>=0;
}

//+------------------------------------------------------------------+
//| FUNCTION: HasProfitOrder2Exposure                                |
//+------------------------------------------------------------------+
bool HasProfitOrder2Exposure(){
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong ticket=PositionGetTicket(i); if(!IsOurPosition(ticket)) continue;
      if(IsProfitOrder2Comment(PositionGetString(POSITION_COMMENT))) return true;
   }
   for(int i=OrdersTotal()-1;i>=0;i--){
      ulong ticket=OrderGetTicket(i); if(!IsOurOrder(ticket)) continue;
      if(IsProfitOrder2Comment(OrderGetString(ORDER_COMMENT))) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| FUNCTION: HasProfitOrder2History                                 |
//+------------------------------------------------------------------+
bool HasProfitOrder2History(datetime cycleStart){
   if(cycleStart<=0 || !HistorySelect(cycleStart,TimeCurrent())) return false;
   for(int i=HistoryDealsTotal()-1;i>=0;i--){
      ulong deal=HistoryDealGetTicket(i); if(deal==0) continue;
      if((long)HistoryDealGetInteger(deal,DEAL_MAGIC)!=OrdersID) continue;
      if(HistoryDealGetString(deal,DEAL_SYMBOL)!=SymbolTrade) continue;
      if(IsProfitOrder2Comment(HistoryDealGetString(deal,DEAL_COMMENT))) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| FUNCTION: ManageProfitTriggeredOrder2                            |
//+------------------------------------------------------------------+
void ManageProfitTriggeredOrder2(){
   if(!EnableProfitOrder2 || ProfitTriggerOrder2USD<=0 || ProfitOrder2Lot<=0) return;
   if(RecoveryActive || RecoveryStage>0 || BuyOrders+SellOrders!=1) return;
   if(ProfitOrder2RequestInFlight || HasProfitOrder2Exposure()) return;

   ulong firstTicket=0; datetime firstTime=0; double firstPL=0.0;
   ENUM_POSITION_TYPE firstType=WRONG_VALUE;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong ticket=PositionGetTicket(i); if(!IsOurPosition(ticket)) continue;
      string comment=PositionGetString(POSITION_COMMENT);
      if(StringFind(comment,"RECOVERY 1")>=0 || StringFind(comment,"RECOVERY 2")>=0 ||
         IsProfitOrder2Comment(comment)) continue;
      datetime tm=(datetime)PositionGetInteger(POSITION_TIME);
      if(firstTicket==0 || tm<firstTime){
         firstTicket=ticket; firstTime=tm;
         firstPL=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
         firstType=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      }
   }
   // Trigger only on the first primary position's individual P/L.
   if(firstTicket==0 || firstPL<ProfitTriggerOrder2USD) return;
   if(HasProfitOrder2History(firstTime)) return;

   double lot=NormalizeVolume(ProfitOrder2Lot);
   double minLot=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_STEP);
   if(step<=0 || lot<minLot || lot>maxLot ||
      MathAbs(lot/step-MathRound(lot/step))>1e-7){
      PrintFormat("V25 PROFIT ORDER 2 REJECTED: volume %.4f invalid (min %.4f max %.4f step %.4f)",lot,minLot,maxLot,step);
      return;
   }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) return;

   ENUM_ORDER_TYPE ot=(firstType==POSITION_TYPE_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double price=(ot==ORDER_TYPE_BUY)?SymbolInfoDouble(SymbolTrade,SYMBOL_ASK):SymbolInfoDouble(SymbolTrade,SYMBOL_BID);
   double margin=0.0;
   if(!OrderCalcMargin(ot,SymbolTrade,lot,price,margin)){
      Print("V25 PROFIT ORDER 2 rejected: OrderCalcMargin failed."); return;
   }
   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE)<margin){
      PrintFormat("V25 PROFIT ORDER 2 rejected: insufficient margin, required=%.2f free=%.2f",margin,AccountInfoDouble(ACCOUNT_MARGIN_FREE));
      return;
   }

   string c=CommentsOrders+" PROFIT ORDER 2";
   trade.SetExpertMagicNumber(OrdersID); trade.SetTypeFillingBySymbol(SymbolTrade);
   ProfitOrder2RequestInFlight=true;
   bool sent=(ot==ORDER_TYPE_BUY)?trade.Buy(lot,SymbolTrade,0,0,0,c):trade.Sell(lot,SymbolTrade,0,0,0,c);
   bool accepted=(sent && TradeOK());
   ProfitOrder2RequestInFlight=false;
   if(accepted)
      PrintFormat("V25 PROFIT ORDER 2 OPENED | type=%s | lot=%.2f | firstTicket=%I64u | firstPL=%.2f | trigger=%.2f",
         ot==ORDER_TYPE_BUY?"BUY":"SELL",lot,firstTicket,firstPL,ProfitTriggerOrder2USD);
   else
      PrintFormat("V25 PROFIT ORDER 2 FAILED | sent=%s | retcode=%u | %s",sent?"true":"false",trade.ResultRetcode(),trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| FUNCTION: GetRSI                                                |
//+------------------------------------------------------------------+
double GetRSI(){
   double b[]; ArraySetAsSeries(b,true);
   return CopyBuffer(HandleRSI,0,0,1,b)>0 ? b[0] : 50.0;
}

//+------------------------------------------------------------------+
//| FUNCTION: GetMA                                                 |
//+------------------------------------------------------------------+
double GetMA(int shift=0){
   double b[]; ArraySetAsSeries(b,true);
   return CopyBuffer(HandleMA,0,shift,1,b)>0 ? b[0] : 0.0;
}

//+------------------------------------------------------------------+
//| FUNCTION: OnInit                                                 |
//+------------------------------------------------------------------+
int OnInit(){
   SymbolTrade=_Symbol; OrdersID=(MagicNumber==0)?101010:MagicNumber;
   if(EnableProfitOrder2 && (ProfitTriggerOrder2USD<=0 || ProfitOrder2Lot<=0)){
      Print("V25: invalid Profit Order 2 inputs."); return INIT_PARAMETERS_INCORRECT;
   }
   InitialBalance=AccountInfoDouble(ACCOUNT_BALANCE); HighWaterMark=InitialBalance;
   HandleRSI=iRSI(SymbolTrade,PERIOD_CURRENT,RSIPeriod,PRICE_CLOSE);
   HandleMA=iMA(SymbolTrade,PERIOD_CURRENT,MAPeriod,0,MODE_SMA,PRICE_CLOSE);
   trade.SetExpertMagicNumber(OrdersID); trade.SetDeviationInPoints(10); trade.SetTypeFillingBySymbol(SymbolTrade);
   if(HandleRSI==INVALID_HANDLE || HandleMA==INVALID_HANDLE) return INIT_FAILED;
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING) return INIT_FAILED;
   UpdateStatus(); return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| FUNCTION: OnDeinit                                               |
//+------------------------------------------------------------------+
void OnDeinit(const int reason){
   IndicatorRelease(HandleRSI); IndicatorRelease(HandleMA); Comment("");
}

//+------------------------------------------------------------------+
//| FUNCTION: OnTick                                                 |
//+------------------------------------------------------------------+
void OnTick(){
   if(IsTerminated || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;

   UpdateStatus();
   double balance=AccountInfoDouble(ACCOUNT_BALANCE), equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance>HighWaterMark) HighWaterMark=balance;
   double dd=(equity<balance && balance>0)?(balance-equity)/balance*100.0:0.0;
   if(dd>=MaxEquityLossPercent){
      DeleteRecoveryPending(); CloseBasket(); IsTerminated=true; return;
   }

   ManageBasketExit();
   UpdateStatus();
   ManageProfitTriggeredOrder2();
   UpdateStatus();

   // HARD SESSION CLOSE: outside 07:00-22:00 no EA exposure.
   if(UseTradingHour && !IsTradingHour()){
      CloseAllExposure();
      DisplayDashboard(dd);
      return;
   }

   // Once any recovery stage is active, primary grid is frozen.
   if(RecoveryActive){
      ManageRecoveryStage2();
      DisplayDashboard(dd);
      return;
   }

   if(BuyOrders>=MaxOrders && SellOrders==0){
      ManageRecoveryStage1(POSITION_TYPE_BUY);
      DisplayDashboard(dd); return;
   }
   if(SellOrders>=MaxOrders && BuyOrders==0){
      ManageRecoveryStage1(POSITION_TYPE_SELL);
      DisplayDashboard(dd); return;
   }

   ManagePrimaryGrid(); DisplayDashboard(dd);
}

//+------------------------------------------------------------------+
//| FUNCTION: UpdateStatus                                          |
//+------------------------------------------------------------------+
void UpdateStatus(){
   BuyOrders=SellOrders=0; BuyLots=SellLots=0; BuyProfit=SellProfit=0;
   ProfitOrder2Count=0; ProfitOrder2Lots=0; ProfitOrder2Profit=0;
   PrimaryBuyLots=PrimarySellLots=0; PrimaryBuyProfit=PrimarySellProfit=0;
   LastBuyPrice=LastSellPrice=0; Buy3Price=Sell3Price=0; LastBuyTime=LastSellTime=0;

   RecoveryStage=0;
   Recovery1Lots=Recovery1Profit=Recovery1EntryPrice=0;
   Recovery2Lots=Recovery2Profit=Recovery2EntryPrice=0;
   Recovery1Type=WRONG_VALUE; Recovery2Type=WRONG_VALUE;

   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong ticket=PositionGetTicket(i); if(!IsOurPosition(ticket)) continue;
      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double lot=PositionGetDouble(POSITION_VOLUME);
      double p=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      datetime tm=(datetime)PositionGetInteger(POSITION_TIME);
      string c=PositionGetString(POSITION_COMMENT);

      bool recovery1=StringFind(c,"RECOVERY 1 BUY")>=0 || StringFind(c,"RECOVERY 1 SELL")>=0;
      bool recovery2=StringFind(c,"RECOVERY 2 BUY")>=0 || StringFind(c,"RECOVERY 2 SELL")>=0;

      if(recovery1){
         Recovery1Lots+=lot; Recovery1Profit+=p; Recovery1EntryPrice=open; Recovery1Type=type; RecoveryStage=MathMax(RecoveryStage,1); continue;
      }
      if(recovery2){
         Recovery2Lots+=lot; Recovery2Profit+=p; Recovery2EntryPrice=open; Recovery2Type=type; RecoveryStage=MathMax(RecoveryStage,2); continue;
      }

      if(IsProfitOrder2Comment(c)){
         ProfitOrder2Count++; ProfitOrder2Lots+=lot; ProfitOrder2Profit+=p;
         // Included in basket totals, excluded from primary-grid counts and recovery sizing.
         if(type==POSITION_TYPE_BUY){ BuyLots+=lot; BuyProfit+=p; }
         else if(type==POSITION_TYPE_SELL){ SellLots+=lot; SellProfit+=p; }
         continue;
      }

      if(type==POSITION_TYPE_BUY){
         BuyOrders++; BuyLots+=lot; BuyProfit+=p; PrimaryBuyLots+=lot; PrimaryBuyProfit+=p;
         if(tm>=LastBuyTime){ LastBuyTime=tm; LastBuyPrice=open; }
         if(StringFind(c,"PRIMARY BUY 3")>=0) Buy3Price=open;
      }else if(type==POSITION_TYPE_SELL){
         SellOrders++; SellLots+=lot; SellProfit+=p; PrimarySellLots+=lot; PrimarySellProfit+=p;
         if(tm>=LastSellTime){ LastSellTime=tm; LastSellPrice=open; }
         if(StringFind(c,"PRIMARY SELL 3")>=0) Sell3Price=open;
      }
   }

   RecoveryLots=Recovery1Lots+Recovery2Lots;
   RecoveryProfit=Recovery1Profit+Recovery2Profit;
   RecoveryActive=(RecoveryStage>0);
   BasketProfitValue=BuyProfit+SellProfit+RecoveryProfit;
}

//+------------------------------------------------------------------+
//| FUNCTION: HasRecoveryPending                                    |
//+------------------------------------------------------------------+
bool HasRecoveryPending(){
   for(int i=OrdersTotal()-1;i>=0;i--){
      ulong ticket=OrderGetTicket(i); if(!IsOurOrder(ticket)) continue;
      string c=OrderGetString(ORDER_COMMENT);
      if(StringFind(c,"RECOVERY 1 BUY")>=0 || StringFind(c,"RECOVERY 1 SELL")>=0 ||
         StringFind(c,"RECOVERY 2 BUY")>=0 || StringFind(c,"RECOVERY 2 SELL")>=0) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| FUNCTION: DeleteRecoveryPending                                 |
//+------------------------------------------------------------------+
void DeleteRecoveryPending(){
   for(int i=OrdersTotal()-1;i>=0;i--){
      ulong ticket=OrderGetTicket(i); if(!IsOurOrder(ticket)) continue;
      string c=OrderGetString(ORDER_COMMENT);
      if(StringFind(c,"RECOVERY 1 BUY")<0 && StringFind(c,"RECOVERY 1 SELL")<0 &&
         StringFind(c,"RECOVERY 2 BUY")<0 && StringFind(c,"RECOVERY 2 SELL")<0) continue;
      trade.OrderDelete(ticket);
   }
}

//+------------------------------------------------------------------+
//| FUNCTION: ManageRecoveryStage1                                  |
//+------------------------------------------------------------------+
void ManageRecoveryStage1(ENUM_POSITION_TYPE primaryType){
   if(!EnableRecovery || RecoveryStage>0 || HasRecoveryPending()) return;
   if(MaxRecoveryStages<1) return;

   double primaryPL=(primaryType==POSITION_TYPE_BUY)?PrimaryBuyProfit:PrimarySellProfit;
   double primaryLots=(primaryType==POSITION_TYPE_BUY)?PrimaryBuyLots:PrimarySellLots;
   double thirdPrice=(primaryType==POSITION_TYPE_BUY)?Buy3Price:Sell3Price;

   if(RecoveryOnlyWhenMinus && primaryPL>=0.0) return;
   if(primaryLots<=0 || thirdPrice<=0) return;

   double point=SymbolInfoDouble(SymbolTrade,SYMBOL_POINT); if(point<=0) return;
   double bid=SymbolInfoDouble(SymbolTrade,SYMBOL_BID), ask=SymbolInfoDouble(SymbolTrade,SYMBOL_ASK);
   double adversePoints=(primaryType==POSITION_TYPE_BUY)?(thirdPrice-bid)/point:(ask-thirdPrice)/point;
   if(adversePoints<Recovery1GapPoints) return;

   UpdateStatus();
   double basketBefore=BasketProfitValue;
   if(RecoveryOnlyWhenMinus && basketBefore>=0.0) return;

   double lot=NormalizeVolume(primaryLots*Recovery1Multiplier);
   if(Recovery1MaxLot>0.0) lot=NormalizeVolume(MathMin(lot,Recovery1MaxLot));
   if(lot<=0) return;

   trade.SetExpertMagicNumber(OrdersID); trade.SetTypeFillingBySymbol(SymbolTrade);
   bool ok=false; string c;
   if(primaryType==POSITION_TYPE_BUY){
      c=CommentsOrders+" RECOVERY 1 SELL";
      ok=trade.Sell(lot,SymbolTrade,0,0,0,c);
   }else{
      c=CommentsOrders+" RECOVERY 1 BUY";
      ok=trade.Buy(lot,SymbolTrade,0,0,0,c);
   }

   if(ok && TradeOK())
      PrintFormat("V12 R1 OPEN | primary=%s | basket=%.2f | primaryLots=%.2f | R1Lot=%.2f | adverse=%.0f",
                  primaryType==POSITION_TYPE_BUY?"BUY":"SELL",basketBefore,primaryLots,lot,adversePoints);
   else
      PrintFormat("V12 R1 FAILED | basket=%.2f | lot=%.2f | retcode=%u | %s",
                  basketBefore,lot,trade.ResultRetcode(),trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| FUNCTION: ManageRecoveryStage2                                  |
//+------------------------------------------------------------------+
void ManageRecoveryStage2(){
   if(!EnableRecovery || RecoveryStage!=1 || MaxRecoveryStages<2) return;
   if(Recovery1Lots<=0 || Recovery1EntryPrice<=0) return;
   if(Recovery1Profit>=0.0) return;
   if(RecoveryOnlyWhenMinus && BasketProfitValue>=0.0) return;

   double point=SymbolInfoDouble(SymbolTrade,SYMBOL_POINT); if(point<=0) return;
   double bid=SymbolInfoDouble(SymbolTrade,SYMBOL_BID), ask=SymbolInfoDouble(SymbolTrade,SYMBOL_ASK);
   double adversePoints=0;
   if(Recovery1Type==POSITION_TYPE_BUY) adversePoints=(Recovery1EntryPrice-bid)/point;
   else if(Recovery1Type==POSITION_TYPE_SELL) adversePoints=(ask-Recovery1EntryPrice)/point;
   else return;

   if(adversePoints<Recovery2GapPoints) return;

   double baseLots=PrimaryBuyLots+PrimarySellLots;
   if(baseLots<=0) return;

   double lot=NormalizeVolume(baseLots*Recovery2Multiplier);
   if(Recovery2MaxLot>0.0) lot=NormalizeVolume(MathMin(lot,Recovery2MaxLot));
   if(lot<=0) return;

   trade.SetExpertMagicNumber(OrdersID); trade.SetTypeFillingBySymbol(SymbolTrade);
   bool ok=false; string c;
   if(Recovery1Type==POSITION_TYPE_BUY){
      c=CommentsOrders+" RECOVERY 2 SELL";
      ok=trade.Sell(lot,SymbolTrade,0,0,0,c);
   }else{
      c=CommentsOrders+" RECOVERY 2 BUY";
      ok=trade.Buy(lot,SymbolTrade,0,0,0,c);
   }

   if(ok && TradeOK())
      PrintFormat("V12 R2 OPEN | basket=%.2f | R1PL=%.2f | R2Lot=%.2f | adverse=%.0f",
                  BasketProfitValue,Recovery1Profit,lot,adversePoints);
   else
      PrintFormat("V12 R2 FAILED | basket=%.2f | lot=%.2f | retcode=%u | %s",
                  BasketProfitValue,lot,trade.ResultRetcode(),trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| FUNCTION: ManagePrimaryGrid                                     |
//+------------------------------------------------------------------+
void ManagePrimaryGrid(){
   UpdateStatus(); if(BuyOrders>0 && SellOrders>0) return;
   double point=SymbolInfoDouble(SymbolTrade,SYMBOL_POINT); if(point<=0) return;

   if(BuyOrders>0 && BuyOrders<MaxOrders){
      double gap=PointsForFirstGap*MathPow(GapMultiplier,BuyOrders-1)*point;
      if(SymbolInfoDouble(SymbolTrade,SYMBOL_ASK)<=LastBuyPrice-gap)
         ExecutePrimary(ORDER_TYPE_BUY);
      return;
   }

   if(SellOrders>0 && SellOrders<MaxOrders){
      double gap=PointsForFirstGap*MathPow(GapMultiplier,SellOrders-1)*point;
      if(SymbolInfoDouble(SymbolTrade,SYMBOL_BID)>=LastSellPrice+gap)
         ExecutePrimary(ORDER_TYPE_SELL);
      return;
   }

   if(BuyOrders==0 && SellOrders==0){
      double r=GetRSI(), ma=GetMA(0), price=SymbolInfoDouble(SymbolTrade,SYMBOL_BID);
      if(TypeOrdersPlace!=Open__Only_Sell && ma>0 && price>ma && r<RSILower){ ExecutePrimary(ORDER_TYPE_BUY); return; }
      if(TypeOrdersPlace!=Open__Only_Buy && ma>0 && price<ma && r>RSIUpper){ ExecutePrimary(ORDER_TYPE_SELL); return; }
   }
}

//+------------------------------------------------------------------+
//| FUNCTION: ExecutePrimary                                        |
//+------------------------------------------------------------------+
bool ExecutePrimary(ENUM_ORDER_TYPE type){
   int count=(type==ORDER_TYPE_BUY)?BuyOrders:SellOrders;
   if(count>=MaxOrders) return false;

   double lot=NormalizeVolume(ManualLotSize*(count+1));
   string c=(type==ORDER_TYPE_BUY)
            ?StringFormat("%s PRIMARY BUY %d",CommentsOrders,count+1)
            :StringFormat("%s PRIMARY SELL %d",CommentsOrders,count+1);

   trade.SetExpertMagicNumber(OrdersID); trade.SetTypeFillingBySymbol(SymbolTrade);
   bool ok=(type==ORDER_TYPE_BUY)
           ?trade.Buy(lot,SymbolTrade,0,0,0,c)
           :trade.Sell(lot,SymbolTrade,0,0,0,c);

   if(ok && TradeOK()) return true;
   PrintFormat("V12 PRIMARY FAILED retcode=%u | %s",trade.ResultRetcode(),trade.ResultRetcodeDescription());
   return false;
}

//+------------------------------------------------------------------+
//| FUNCTION: ManageBasketExit                                      |
//| Primary + R1 + R2 are always treated as one basket.             |
//+------------------------------------------------------------------+
void ManageBasketExit(){
   UpdateStatus();
   int total=BuyOrders+SellOrders+ProfitOrder2Count+((RecoveryStage>0)?1:0)+((RecoveryStage>1)?1:0);
   if(total==0){ BasketPeakProfit=0; BasketTrailingActive=false; return; }

   double p=BasketProfitValue;
   if(UseTrailingProfit){
      double arm=MathMax(TargetProfitUSD,TrailingStartUSD);
      if(!BasketTrailingActive && p>=arm){
         BasketTrailingActive=true; BasketPeakProfit=p;
         PrintFormat("V12 BASKET TARGET REACHED -> TRAILING ON | basket=%.2f | stage=%d",p,RecoveryStage);
      }
      if(BasketTrailingActive){
         if(p>BasketPeakProfit) BasketPeakProfit=p;
         if(p<=BasketPeakProfit-TrailingStopUSD){
            PrintFormat("V12 BASKET TRAILING CLOSE | peak=%.2f | current=%.2f | stage=%d",BasketPeakProfit,p,RecoveryStage);
            DeleteRecoveryPending(); CloseBasket();
         }
      }
   }else if(p>=TargetProfitUSD){
      DeleteRecoveryPending(); CloseBasket();
   }
}

//+------------------------------------------------------------------+
//| FUNCTION: CloseAllExposure                                      |
//| HARD SESSION-END EXIT: close every EA position and delete every |
//| EA pending order, regardless of basket stage or P/L.             |
//+------------------------------------------------------------------+
void CloseAllExposure(){
   for(int i=OrdersTotal()-1;i>=0;i--){
      ulong ticket=OrderGetTicket(i);
      if(!IsOurOrder(ticket)) continue;
      trade.OrderDelete(ticket);
   }

   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong ticket=PositionGetTicket(i);
      if(!IsOurPosition(ticket)) continue;
      trade.PositionClose(ticket);
   }

   BasketPeakProfit=0;
   BasketTrailingActive=false;
}

//+------------------------------------------------------------------+
//| FUNCTION: CloseBasket                                           |
//+------------------------------------------------------------------+
void CloseBasket(){
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong ticket=PositionGetTicket(i); if(!IsOurPosition(ticket)) continue;
      trade.PositionClose(ticket);
   }
   BasketPeakProfit=0; BasketTrailingActive=false;
}

//+------------------------------------------------------------------+
//| FUNCTION: DisplayDashboard                                      |
//+------------------------------------------------------------------+
void DisplayDashboard(double dd){
   string state="IDLE";
   if(RecoveryStage==2) state="ONE BASKET / RECOVERY 2 ACTIVE";
   else if(RecoveryStage==1) state="ONE BASKET / RECOVERY 1 ACTIVE";
   else if(BuyOrders==3 && BuyProfit<0) state="BUY 3 MINUS / RECOVERY 1 READY";
   else if(SellOrders==3 && SellProfit<0) state="SELL 3 MINUS / RECOVERY 1 READY";
   else if(BuyOrders>0) state="PRIMARY BUY";
   else if(SellOrders>0) state="PRIMARY SELL";

   Comment("===== GRID 06 V25 =====\n",
           "State: ",state,"\n",
           "BASKET P/L: ",DoubleToString(BasketProfitValue,2),"\n",
           "PROFIT ORDER 2: ",ProfitOrder2Count," | lot=",DoubleToString(ProfitOrder2Lots,2),
           " | P/L=",DoubleToString(ProfitOrder2Profit,2),"\n",
           "BUY: ",BuyOrders," | lot=",DoubleToString(BuyLots,2)," | P/L=",DoubleToString(BuyProfit,2),"\n",
           "SELL: ",SellOrders," | lot=",DoubleToString(SellLots,2)," | P/L=",DoubleToString(SellProfit,2),"\n",
           "R1: ",(RecoveryStage>=1?"ACTIVE":"OFF")," | lot=",DoubleToString(Recovery1Lots,2)," | P/L=",DoubleToString(Recovery1Profit,2),"\n",
           "R2: ",(RecoveryStage>=2?"ACTIVE":"OFF")," | lot=",DoubleToString(Recovery2Lots,2)," | P/L=",DoubleToString(Recovery2Profit,2),"\n",
           "R1: ",DoubleToString(Recovery1Multiplier,2),"x | Gap: ",DoubleToString(Recovery1GapPoints,0)," points\n",
           "R2: ",DoubleToString(Recovery2Multiplier,2),"x | Gap: ",DoubleToString(Recovery2GapPoints,0)," points\n",
           "Target: ",DoubleToString(TargetProfitUSD,2)," | Trail: ",(BasketTrailingActive?"ON":"OFF")," | Peak: ",DoubleToString(BasketPeakProfit,2),"\n",
           "DD: ",DoubleToString(dd,2),"%");
}

//+------------------------------------------------------------------+
//| END GRID 06 V25                                                  |
//+------------------------------------------------------------------+
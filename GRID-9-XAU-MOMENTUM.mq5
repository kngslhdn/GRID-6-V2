// Expert Advisor: GRID 06.V02 - XAU INTRADAY MOMENTUM ENGINE
// v9.00 - Opening Range + VWAP + Trend + Momentum + ATR Risk
#property strict
#property copyright "Copyright 2026, Jarvis"
#property version   "9.00"

#include <Trade/Trade.mqh>
CTrade trade;

enum Type {Open_Buy_And_Sell, Open__Only_Buy, Open__Only_Sell};

input string RiskSettings            = "||========== DAILY PROFIT / RISK ==========||";
input double RiskPerTradePercent     = 0.75;
input double MaxRiskPerTradePercent  = 1.00;
input double MaxEquityLossPercent    = 12.0;
input double DailyLossLimitUSD       = 75.0;
input double DailyProfitTargetUSD    = 100.0;
input int    MaxTradesPerDay         = 4;
input int    MaxConsecutiveLosses    = 3;
input int    CooldownMinutes         = 30;
input double MaxLotSize              = 0.50;
input bool   RejectIfMinLotOverRisk  = true;

input string SessionSettings          = "||========== XAU SESSION ENGINE ==========||";
input bool   UseTradingHour           = true;
input int    StartHour                = 7;
input int    EndHour                  = 22;
input int    LondonRangeStartHour     = 7;
input int    LondonRangeMinutes       = 60;
input int    NYRangeStartHour         = 13;
input int    NYRangeMinutes            = 30;
input bool   TradeLondonWindow        = true;
input bool   TradeNewYorkWindow       = true;
input int    SessionEndBufferMinutes  = 15;

input string TrendSettings            = "||========== TREND / REGIME ==========||";
input ENUM_TIMEFRAMES TrendTF         = PERIOD_H1;
input int    FastMAPeriod             = 50;
input int    SlowMAPeriod             = 200;
input int    ADXPeriod                = 14;
input double ADXMin                   = 18.0;
input double ADXStrong                = 25.0;
input bool   RequireTrendAlignment   = true;

input string EntrySettings            = "||========== OPENING RANGE / VWAP ==========||";
input ENUM_TIMEFRAMES EntryTF         = PERIOD_M5;
input int    OpeningRangeMinutes      = 30;
input double BreakoutBufferATR        = 0.08;
input double MinBreakoutBodyATR       = 0.25;
input double MaxBreakoutExtensionATR  = 1.20;
input double PullbackToleranceATR     = 0.25;
input int    RSIPeriod                = 14;
input double BuyRSIMin                = 52.0;
input double BuyRSIMax                = 75.0;
input double SellRSIMin               = 25.0;
input double SellRSIMax               = 48.0;

input string VolatilitySettings       = "||========== VOLATILITY ==========||";
input int    ATRPeriod                = 14;
input int    ATRBaselineBars          = 48;
input double MinATRPrice              = 0.50;
input double HighVolRatio             = 1.60;
input double ExtremeVolRatio          = 2.20;
input double MaxSpreadATRPercent      = 10.0;

input string ExitSettings             = "||========== DYNAMIC EXIT ==========||";
input double InitialSL_ATR            = 1.35;
input double MinSL_ATR                = 1.00;
input double MaxSL_ATR                = 2.20;
input double BreakEven_R              = 1.00;
input double BreakEvenLock_R          = 0.10;
input double TrailStart_R             = 1.80;
input double TrailATRMultiplier       = 1.80;
input double StrongTrailATRMultiplier = 2.20;
input double MaxTradeMinutes          = 360.0;
input double StaleTradeMinutes        = 60.0;
input double StaleMinR                = 0.15;

input Type   TypeOrdersPlace          = Open_Buy_And_Sell;
input int    MagicNumber              = 88900;
input string CommentsOrders            = "GRID V9 XAU MOMENTUM";

string SymbolTrade;
int OrdersID;
int HandleFastMA, HandleSlowMA, HandleADX, HandleATR, HandleRSI;
datetime DayStartTime=0, LastEntryTime=0, LastExitTime=0;
double DayStartBalance=0.0;
double HighWaterMark=0.0;
int TradesToday=0, ConsecutiveLosses=0;
bool IsTerminated=false;
ulong PositionTicketState=0;
double InitialRiskDistance=0.0, EntryPriceState=0.0, PeakPriceState=0.0;
datetime LastBarTime=0;
bool LondonTradedToday=false;
bool NYTradedToday=false;

bool IsTradingHour()
{
   if(!UseTradingHour) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(StartHour<EndHour) return dt.hour>=StartHour && dt.hour<EndHour;
   return dt.hour>=StartHour || dt.hour<EndHour;
}

void ResetDailyState()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   datetime d=StructToTime(dt);
   if(DayStartTime!=d)
   {
      DayStartTime=d;
      DayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);
      TradesToday=0;
      ConsecutiveLosses=0;
      LondonTradedToday=false;
      NYTradedToday=false;
   }
}

bool GetBufferValue(int handle,int buffer,int shift,double &value)
{
   if(handle==INVALID_HANDLE) return false;
   double b[]; ArraySetAsSeries(b,true);
   if(CopyBuffer(handle,buffer,shift,1,b)<1) return false;
   value=b[0]; return true;
}

double GetATR(int shift=1)
{
   double v=0.0;
   return GetBufferValue(HandleATR,0,shift,v)?v:0.0;
}

double AverageATR(int bars,int start=2)
{
   double sum=0.0; int n=0;
   for(int i=start;i<start+bars;i++)
   {
      double v=GetATR(i);
      if(v>0){sum+=v;n++;}
   }
   return n>0?sum/n:0.0;
}

double ATRRatio(double atr)
{
   double base=AverageATR(ATRBaselineBars,2);
   return (atr>0 && base>0)?atr/base:1.0;
}

double HighestHigh(int bars,int start)
{
   double hi=-DBL_MAX;
   for(int i=start;i<start+bars;i++) hi=MathMax(hi,iHigh(SymbolTrade,EntryTF,i));
   return hi;
}

double LowestLow(int bars,int start)
{
   double lo=DBL_MAX;
   for(int i=start;i<start+bars;i++) lo=MathMin(lo,iLow(SymbolTrade,EntryTF,i));
   return lo;
}

bool IsNewBar()
{
   datetime t=iTime(SymbolTrade,EntryTF,0);
   if(t<=0 || t==LastBarTime) return false;
   LastBarTime=t;
   return true;
}

int TrendDirection()
{
   double fast,slow,adx,plusDI,minusDI;
   if(!GetBufferValue(HandleFastMA,0,1,fast) ||
      !GetBufferValue(HandleSlowMA,0,1,slow) ||
      !GetBufferValue(HandleADX,0,1,adx) ||
      !GetBufferValue(HandleADX,1,1,plusDI) ||
      !GetBufferValue(HandleADX,2,1,minusDI)) return 99;

   double price=iClose(SymbolTrade,TrendTF,1);
   if(price<=0) return 99;
   if(adx<ADXMin) return 0;

   if(price>fast && fast>slow && plusDI>minusDI) return 1;
   if(price<fast && fast<slow && minusDI>plusDI) return -1;
   return 0;
}

double SessionVWAP(int startHour,int durationMinutes)
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   dt.hour=startHour; dt.min=0; dt.sec=0;
   datetime start=StructToTime(dt);
   datetime now=TimeCurrent();
   datetime end=start+durationMinutes*60;
   if(now<=start) return 0.0;
   if(now<end) end=now;

   int startShift=iBarShift(SymbolTrade,EntryTF,start,false);
   int endShift=iBarShift(SymbolTrade,EntryTF,end,false);
   if(startShift<0) return 0.0;
   if(endShift<0) endShift=0;
   int from=MathMin(startShift,endShift);
   int to=MathMax(startShift,endShift);

   double pv=0.0, vol=0.0;
   for(int i=from;i<=to;i++)
   {
      datetime bt=iTime(SymbolTrade,EntryTF,i);
      if(bt<start || bt>end) continue;
      double h=iHigh(SymbolTrade,EntryTF,i);
      double l=iLow(SymbolTrade,EntryTF,i);
      double c=iClose(SymbolTrade,EntryTF,i);
      long v=iVolume(SymbolTrade,EntryTF,i);
      double typ=(h+l+c)/3.0;
      double weight=(v>0)?(double)v:1.0;
      pv+=typ*weight;
      vol+=weight;
   }
   return vol>0?pv/vol:0.0;
}

bool GetOpeningRange(int startHour,int minutes,double &hi,double &lo,datetime &rangeEnd)
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   dt.hour=startHour; dt.min=0; dt.sec=0;
   datetime start=StructToTime(dt);
   rangeEnd=start+minutes*60;
   if(TimeCurrent()<rangeEnd) return false;

   int s1=iBarShift(SymbolTrade,EntryTF,start,false);
   int s2=iBarShift(SymbolTrade,EntryTF,rangeEnd,false);
   if(s1<0 || s2<0) return false;

   hi=-DBL_MAX; lo=DBL_MAX;
   int from=MathMin(s1,s2), to=MathMax(s1,s2);
   for(int i=from;i<=to;i++)
   {
      datetime bt=iTime(SymbolTrade,EntryTF,i);
      if(bt<start || bt>=rangeEnd) continue;
      hi=MathMax(hi,iHigh(SymbolTrade,EntryTF,i));
      lo=MathMin(lo,iLow(SymbolTrade,EntryTF,i));
   }
   return hi>-DBL_MAX/2 && lo<DBL_MAX/2 && hi>lo;
}

bool IsInPostRangeWindow(datetime rangeEnd)
{
   return TimeCurrent()>=rangeEnd+SessionEndBufferMinutes*60;
}

bool SpreadOK(double atr)
{
   double ask=SymbolInfoDouble(SymbolTrade,SYMBOL_ASK);
   double bid=SymbolInfoDouble(SymbolTrade,SYMBOL_BID);
   if(ask<=0 || bid<=0 || atr<=0) return false;
   double spread=ask-bid;
   return spread<=atr*(MaxSpreadATRPercent/100.0);
}

double NormalizeVolume(double lots)
{
   double minLot=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_STEP);
   double cap=MathMin(MaxLotSize,maxLot);
   if(lots<minLot)
   {
      if(RejectIfMinLotOverRisk) return 0.0;
      lots=minLot;
   }
   lots=MathMin(lots,cap);
   if(step<=0) return NormalizeDouble(lots,2);
   lots=MathFloor(lots/step)*step;
   if(lots<minLot) return RejectIfMinLotOverRisk?0.0:NormalizeDouble(minLot,2);
   return NormalizeDouble(lots,2);
}

double EstimateLossMoney(ENUM_ORDER_TYPE type,double volume,double stopDistance)
{
   if(volume<=0 || stopDistance<=0) return 0.0;
   double entry=(type==ORDER_TYPE_BUY)?SymbolInfoDouble(SymbolTrade,SYMBOL_ASK):SymbolInfoDouble(SymbolTrade,SYMBOL_BID);
   double stop=(type==ORDER_TYPE_BUY)?entry-stopDistance:entry+stopDistance;
   double p=0.0;
   if(!OrderCalcProfit(type,SymbolTrade,volume,entry,stop,p)) return 0.0;
   return MathAbs(p);
}

double CalculateLot(ENUM_ORDER_TYPE type,double stopDistance)
{
   double riskPct=MathMin(RiskPerTradePercent,MaxRiskPerTradePercent);
   double riskMoney=AccountInfoDouble(ACCOUNT_EQUITY)*riskPct/100.0;
   if(riskMoney<=0) return 0.0;

   double minLot=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MIN);
   if(RejectIfMinLotOverRisk && EstimateLossMoney(type,minLot,stopDistance)>riskMoney*1.02) return 0.0;

   double tickSize=SymbolInfoDouble(SymbolTrade,SYMBOL_TRADE_TICK_SIZE);
   double tickValue=SymbolInfoDouble(SymbolTrade,SYMBOL_TRADE_TICK_VALUE);
   if(tickSize<=0 || tickValue<=0) return 0.0;
   double lossPerLot=(stopDistance/tickSize)*tickValue;
   if(lossPerLot<=0) return 0.0;

   double lots=NormalizeVolume(riskMoney/lossPerLot);
   if(lots<=0) return 0.0;
   if(EstimateLossMoney(type,lots,stopDistance)>riskMoney*1.02) return 0.0;
   return lots;
}

bool DailyBlocked()
{
   if(DayStartBalance<=0) return true;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyPnL=eq-DayStartBalance;
   if(dailyPnL>=DailyProfitTargetUSD) return true;
   if(dailyPnL<=-DailyLossLimitUSD) return true;
   if(TradesToday>=MaxTradesPerDay) return true;
   if(ConsecutiveLosses>=MaxConsecutiveLosses) return true;
   return false;
}

bool HasOpenPosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) &&
         PositionGetInteger(POSITION_MAGIC)==OrdersID &&
         PositionGetString(POSITION_SYMBOL)==SymbolTrade) return true;
   }
   return false;
}

ulong FindOurPosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) &&
         PositionGetInteger(POSITION_MAGIC)==OrdersID &&
         PositionGetString(POSITION_SYMBOL)==SymbolTrade) return ticket;
   }
   return 0;
}

void ResetPositionStateIfNeeded()
{
   ulong ticket=FindOurPosition();
   if(ticket==0)
   {
      PositionTicketState=0;
      InitialRiskDistance=0.0;
      EntryPriceState=0.0;
      PeakPriceState=0.0;
      return;
   }
   if(!PositionSelectByTicket(ticket)) return;
   if(PositionTicketState!=ticket)
   {
      PositionTicketState=ticket;
      EntryPriceState=PositionGetDouble(POSITION_PRICE_OPEN);
      InitialRiskDistance=MathAbs(EntryPriceState-PositionGetDouble(POSITION_SL));
      PeakPriceState=EntryPriceState;
   }
}

bool DirectionAllowed(int direction)
{
   if(TypeOrdersPlace==Open__Only_Buy && direction<0) return false;
   if(TypeOrdersPlace==Open__Only_Sell && direction>0) return false;
   return true;
}

bool EvaluateSignal(int direction,double atr,double rangeHi,double rangeLo,double vwap,bool useRange)
{
   double close1=iClose(SymbolTrade,EntryTF,1);
   double open1=iOpen(SymbolTrade,EntryTF,1);
   double close2=iClose(SymbolTrade,EntryTF,2);
   double high1=iHigh(SymbolTrade,EntryTF,1);
   double low1=iLow(SymbolTrade,EntryTF,1);
   if(close1<=0 || open1<=0 || close2<=0) return false;

   double body=MathAbs(close1-open1);
   if(body<atr*MinBreakoutBodyATR) return false;

   double rsi;
   if(!GetBufferValue(HandleRSI,0,1,rsi)) return false;
   if(direction>0 && (rsi<BuyRSIMin || rsi>BuyRSIMax)) return false;
   if(direction<0 && (rsi<SellRSIMin || rsi>SellRSIMax)) return false;

   double trendMA;
   if(!GetBufferValue(HandleFastMA,0,1,trendMA)) return false;
   bool trendOK=(direction>0)?close1>trendMA:close1<trendMA;
   if(RequireTrendAlignment && !trendOK) return false;

   bool momentum=(direction>0)?close1>open1:close1<open1;
   if(!momentum) return false;

   double extension=0.0;
   bool breakout=false;
   bool pullback=false;

   if(useRange)
   {
      breakout=(direction>0)
         ? close1>rangeHi+atr*BreakoutBufferATR
         : close1<rangeLo-atr*BreakoutBufferATR;

      if(direction>0)
         pullback=low1<=rangeHi+atr*PullbackToleranceATR && close1>rangeHi && close2>rangeHi;
      else
         pullback=high1>=rangeLo-atr*PullbackToleranceATR && close1<rangeLo && close2<rangeLo;

      extension=(direction>0)?close1-rangeHi:rangeLo-close1;
   }
   else
   {
      double hi=HighestHigh(12,2), lo=LowestLow(12,2);
      breakout=(direction>0)
         ? close1>hi+atr*BreakoutBufferATR
         : close1<lo-atr*BreakoutBufferATR;
      extension=(direction>0)?close1-hi:lo-close1;
   }

   bool vwapOK=(vwap>0)?((direction>0)?close1>vwap:close1<vwap):true;
   if(!vwapOK) return false;
   if(!breakout && !pullback) return false;
   if(extension>atr*MaxBreakoutExtensionATR && !pullback) return false;

   double closeLocation=(high1-low1>0)
      ? ((direction>0)?(close1-low1)/(high1-low1):(high1-close1)/(high1-low1))
      : 0.0;
   if(closeLocation<0.55) return false;

   return true;
}

bool PlaceTrade(int direction,double atr,double rangeHi,double rangeLo,double vwap,bool useRange)
{
   if(direction==0 || !DirectionAllowed(direction)) return false;
   if(HasOpenPosition() || DailyBlocked() || !IsTradingHour()) return false;
   if(TimeCurrent()-LastEntryTime<CooldownMinutes*60 ||
      TimeCurrent()-LastExitTime<CooldownMinutes*60) return false;
   if(!EvaluateSignal(direction,atr,rangeHi,rangeLo,vwap,useRange)) return false;

   double ratio=ATRRatio(atr);
   if(ratio>=ExtremeVolRatio) return false;

   double slATR=MathMax(MinSL_ATR,MathMin(MaxSL_ATR,InitialSL_ATR));
   double stopDistance=atr*slATR;

   ENUM_ORDER_TYPE type=(direction>0)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double entry=(direction>0)?SymbolInfoDouble(SymbolTrade,SYMBOL_ASK):SymbolInfoDouble(SymbolTrade,SYMBOL_BID);
   double sl=(direction>0)?entry-stopDistance:entry+stopDistance;
   double lots=CalculateLot(type,stopDistance);
   if(lots<=0) return false;

   trade.SetExpertMagicNumber(OrdersID);
   trade.SetDeviationInPoints(30);
   bool ok=(direction>0)
      ?trade.Buy(lots,SymbolTrade,entry,sl,0,CommentsOrders)
      :trade.Sell(lots,SymbolTrade,entry,sl,0,CommentsOrders);

   if(ok)
   {
      LastEntryTime=TimeCurrent();
      TradesToday++;
      PositionTicketState=0;
   }
   return ok;
}

void ManageOpenPosition()
{
   ulong ticket=FindOurPosition();
   if(ticket==0 || !PositionSelectByTicket(ticket)) return;
   ResetPositionStateIfNeeded();

   ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double open=PositionGetDouble(POSITION_PRICE_OPEN);
   double sl=PositionGetDouble(POSITION_SL);
   double price=(type==POSITION_TYPE_BUY)?SymbolInfoDouble(SymbolTrade,SYMBOL_BID):SymbolInfoDouble(SymbolTrade,SYMBOL_ASK);
   double risk=InitialRiskDistance;
   if(risk<=0) risk=MathAbs(open-sl);
   if(risk<=0) return;

   if(type==POSITION_TYPE_BUY) PeakPriceState=MathMax(PeakPriceState,price);
   else PeakPriceState=(PeakPriceState==0)?price:MathMin(PeakPriceState,price);

   double r=(type==POSITION_TYPE_BUY)?(price-open)/risk:(open-price)/risk;
   double atr=GetATR(1);
   datetime openTime=(datetime)PositionGetInteger(POSITION_TIME);
   double ageMin=(double)(TimeCurrent()-openTime)/60.0;

   if(ageMin>=MaxTradeMinutes)
   {
      if(trade.PositionClose(ticket)) LastExitTime=TimeCurrent();
      return;
   }

   if(ageMin>=StaleTradeMinutes && r<StaleMinR)
   {
      int trend=TrendDirection();
      if((type==POSITION_TYPE_BUY && trend!=1)||(type==POSITION_TYPE_SELL && trend!=-1))
      {
         if(trade.PositionClose(ticket)) LastExitTime=TimeCurrent();
         return;
      }
   }

   double newSL=sl;
   if(r>=BreakEven_R)
   {
      double lock=(type==POSITION_TYPE_BUY)?open+risk*BreakEvenLock_R:open-risk*BreakEvenLock_R;
      if(type==POSITION_TYPE_BUY) newSL=MathMax(newSL,lock);
      else newSL=(newSL==0)?lock:MathMin(newSL,lock);
   }

   if(r>=TrailStart_R && atr>0)
   {
      double ratio=ATRRatio(atr);
      double mult=(ratio>=1.35)?StrongTrailATRMultiplier:TrailATRMultiplier;
      double trail=(type==POSITION_TYPE_BUY)?PeakPriceState-mult*atr:PeakPriceState+mult*atr;
      if(type==POSITION_TYPE_BUY) newSL=MathMax(newSL,trail);
      else newSL=(newSL==0)?trail:MathMin(newSL,trail);
   }

   double point=SymbolInfoDouble(SymbolTrade,SYMBOL_POINT);
   int digits=(int)SymbolInfoInteger(SymbolTrade,SYMBOL_DIGITS);
   if(type==POSITION_TYPE_BUY && newSL>sl+point)
      trade.PositionModify(ticket,NormalizeDouble(newSL,digits),0);
   if(type==POSITION_TYPE_SELL && newSL>0 && (sl==0 || newSL<sl-point))
      trade.PositionModify(ticket,NormalizeDouble(newSL,digits),0);
}

void UpdateClosedStats()
{
   static datetime lastScan=0;
   datetime from=(lastScan>0)?lastScan:DayStartTime;
   if(from<=0) from=TimeCurrent()-86400;
   if(!HistorySelect(from,TimeCurrent())) return;

   int total=HistoryDealsTotal();
   for(int i=total-1;i>=0;i--)
   {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0) continue;
      if((long)HistoryDealGetInteger(deal,DEAL_MAGIC)!=OrdersID) continue;
      if(HistoryDealGetString(deal,DEAL_SYMBOL)!=SymbolTrade) continue;

      datetime t=(datetime)HistoryDealGetInteger(deal,DEAL_TIME);
      if(t<=lastScan) break;

      long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
      if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
      {
         double p=HistoryDealGetDouble(deal,DEAL_PROFIT)+
                  HistoryDealGetDouble(deal,DEAL_SWAP)+
                  HistoryDealGetDouble(deal,DEAL_COMMISSION);
         if(p<0) ConsecutiveLosses++;
         else if(p>0) ConsecutiveLosses=0;
         LastExitTime=t;
      }
      if(t>lastScan) lastScan=t;
   }
}

int OnInit()
{
   SymbolTrade=_Symbol;
   OrdersID=(MagicNumber==0)?88900:MagicNumber;
   trade.SetExpertMagicNumber(OrdersID);

   HandleFastMA=iMA(SymbolTrade,TrendTF,FastMAPeriod,0,MODE_EMA,PRICE_CLOSE);
   HandleSlowMA=iMA(SymbolTrade,TrendTF,SlowMAPeriod,0,MODE_EMA,PRICE_CLOSE);
   HandleADX=iADX(SymbolTrade,TrendTF,ADXPeriod);
   HandleATR=iATR(SymbolTrade,EntryTF,ATRPeriod);
   HandleRSI=iRSI(SymbolTrade,EntryTF,RSIPeriod,PRICE_CLOSE);

   DayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);
   HighWaterMark=DayStartBalance;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   DayStartTime=StructToTime(dt);

   if(HandleFastMA==INVALID_HANDLE || HandleSlowMA==INVALID_HANDLE ||
      HandleADX==INVALID_HANDLE || HandleATR==INVALID_HANDLE ||
      HandleRSI==INVALID_HANDLE) return INIT_FAILED;

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(HandleFastMA!=INVALID_HANDLE) IndicatorRelease(HandleFastMA);
   if(HandleSlowMA!=INVALID_HANDLE) IndicatorRelease(HandleSlowMA);
   if(HandleADX!=INVALID_HANDLE) IndicatorRelease(HandleADX);
   if(HandleATR!=INVALID_HANDLE) IndicatorRelease(HandleATR);
   if(HandleRSI!=INVALID_HANDLE) IndicatorRelease(HandleRSI);
   Comment("");
}

void OnTick()
{
   if(IsTerminated) return;

   ResetDailyState();
   UpdateClosedStats();
   ResetPositionStateIfNeeded();

   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance>HighWaterMark) HighWaterMark=balance;

   double dd=HighWaterMark>0?((HighWaterMark-equity)/HighWaterMark)*100.0:0.0;
   if(dd>=MaxEquityLossPercent)
   {
      ulong t=FindOurPosition();
      if(t>0) trade.PositionClose(t);
      IsTerminated=true;
      return;
   }

   ManageOpenPosition();
   if(HasOpenPosition()) return;
   if(!IsNewBar()) return;
   if(DailyBlocked() || !IsTradingHour()) return;

   double atr=GetATR(1);
   if(atr<MinATRPrice || !SpreadOK(atr)) return;

   int trend=TrendDirection();
   if(trend!=1 && trend!=-1) return;

   if(TradeLondonWindow && !LondonTradedToday)
   {
      double hi,lo; datetime rangeEnd;
      if(GetOpeningRange(LondonRangeStartHour,LondonRangeMinutes,hi,lo,rangeEnd) &&
         IsInPostRangeWindow(rangeEnd))
      {
         int elapsed=(int)MathMax(1,(TimeCurrent()-(rangeEnd-LondonRangeMinutes*60))/60);
         double vwap=SessionVWAP(LondonRangeStartHour,elapsed);
         bool placed=false;
         if(trend==1) placed=PlaceTrade(1,atr,hi,lo,vwap,true);
         else if(trend==-1) placed=PlaceTrade(-1,atr,hi,lo,vwap,true);
         if(placed) LondonTradedToday=true;
         if(HasOpenPosition()) return;
      }
   }

   if(TradeNewYorkWindow && !NYTradedToday && !HasOpenPosition())
   {
      double hi,lo; datetime rangeEnd;
      if(GetOpeningRange(NYRangeStartHour,NYRangeMinutes,hi,lo,rangeEnd) &&
         IsInPostRangeWindow(rangeEnd))
      {
         int elapsed=(int)MathMax(1,(TimeCurrent()-(rangeEnd-NYRangeMinutes*60))/60);
         double vwap=SessionVWAP(NYRangeStartHour,elapsed);
         bool placed=false;
         if(trend==1) placed=PlaceTrade(1,atr,hi,lo,vwap,true);
         else if(trend==-1) placed=PlaceTrade(-1,atr,hi,lo,vwap,true);
         if(placed) NYTradedToday=true;
      }
   }

   Comment("GRID V9 XAU MOMENTUM\n",
           "Balance: ",DoubleToString(balance,2),
           " Equity: ",DoubleToString(equity,2),"\n",
           "Day PnL: ",DoubleToString(equity-DayStartBalance,2),
           " Trades: ",IntegerToString(TradesToday),"\n",
           "Trend: ",IntegerToString(trend),
           " ATR: ",DoubleToString(atr,2),
           " ATRRatio: ",DoubleToString(ATRRatio(atr),2));
}

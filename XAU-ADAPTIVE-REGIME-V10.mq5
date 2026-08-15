//+------------------------------------------------------------------+
//| XAU ADAPTIVE REGIME ENGINE                                       |
//| v10.00 - Trend Pullback + Failed Breakout + Volatility Regime    |
//| Single-position, no grid, no martingale                          |
//+------------------------------------------------------------------+
#property strict
#property version "10.00"
#property description "Adaptive XAU intraday regime EA: trend continuation and failed-breakout reversal."

#include <Trade/Trade.mqh>
CTrade trade;

enum StrategyMode
{
   MODE_ADAPTIVE=0,
   MODE_TREND_ONLY=1,
   MODE_REVERSAL_ONLY=2
};

enum SessionMode
{
   SESSION_LONDON_NY=0,
   SESSION_LONDON_ONLY=1,
   SESSION_NEWYORK_ONLY=2
};

input string RiskSection = "||========== RISK ENGINE ==========||";
input double RiskPercent = 0.50;
input double MaxRiskPercent = 0.75;
input double MaxDailyLossPercent = 1.50;
input double DailyProfitTargetUSD = 100.0;
input int MaxTradesPerDay = 4;
input int MaxConsecutiveLosses = 3;
input int CooldownMinutes = 30;
input double MaxLotSize = 0.50;
input bool RejectMinLotIfRiskExceeded = true;

input string SessionSection = "||========== SESSION ENGINE ==========||";
input SessionMode TradingSession = SESSION_LONDON_NY;
input bool UseSessionFilter = true;
input int LondonStartHour = 8;
input int LondonEndHour = 12;
input int NewYorkStartHour = 13;
input int NewYorkEndHour = 20;

input string RegimeSection = "||========== MULTI-TF REGIME ==========||";
input StrategyMode Mode = MODE_ADAPTIVE;
input ENUM_TIMEFRAMES RegimeTF = PERIOD_H4;
input ENUM_TIMEFRAMES BiasTF = PERIOD_H1;
input ENUM_TIMEFRAMES EntryTF = PERIOD_M15;
input int FastMAPeriod = 50;
input int SlowMAPeriod = 200;
input int ADXPeriod = 14;
input double MinADXTrend = 18.0;
input double StrongADX = 25.0;
input int StructureLookback = 12;

input string VolatilitySection = "||========== VOLATILITY REGIME ==========||";
input int ATRPeriod = 14;
input int ATRBaselineBars = 48;
input double MinATRPrice = 0.40;
input double MinATRRatio = 0.80;
input double ExpansionATRRatio = 1.25;
input double ExtremeATRRatio = 2.20;
input double MaxSpreadATRPercent = 12.0;

input string TrendEntrySection = "||========== TREND PULLBACK ==========||";
input double BreakoutBufferATR = 0.10;
input double RetestToleranceATR = 0.30;
input double MinBodyATR = 0.20;
input double MinCloseLocation = 0.60;
input bool RequireVWAPAlignment = true;

input string ReversalSection = "||========== FAILED BREAKOUT ==========||";
input double SweepATR = 0.10;
input double ReentryATR = 0.05;
input double MaxSweepATR = 0.80;
input bool RequireReversalCandle = true;

input string ExitSection = "||========== STRUCTURE + R EXIT ==========||";
input double StopATRBuffer = 0.25;
input double MinStopATR = 0.90;
input double MaxStopATR = 2.50;
input double PartialTP_R = 1.00;
input double PartialClosePercent = 40.0;
input double RunnerStart_R = 1.80;
input double TrailATR = 2.80;
input double StrongTrailATR = 3.40;
input double BreakEven_R = 1.10;
input double BreakEvenLock_R = 0.05;
input int MaxTradeMinutes = 480;

input string GeneralSection = "||========== GENERAL ==========||";
input int MagicNumber = 91000;
input string TradeComment = "XAU ADAPTIVE V10";
input int DeviationPoints = 40;

string Sym;
int H4Fast=-1,H4Slow=-1,H4ADX=-1,H1Fast=-1,H1Slow=-1,H1ADX=-1,ATRHandle=-1;
datetime DayStart=0,LastEntry=0,LastExit=0,LastBar=0;
double DayStartEquity=0.0;
int TradesToday=0,LossStreak=0;
ulong StateTicket=0;
double StateEntry=0.0,StateRisk=0.0,StatePeak=0.0;
bool PartialDone=false;

bool Buf(int h,int buffer,int shift,double &v)
{
   if(h<0) return false;
   double a[]; ArraySetAsSeries(a,true);
   if(CopyBuffer(h,buffer,shift,1,a)!=1) return false;
   v=a[0]; return true;
}

double ATR(int shift=1){double v=0; return Buf(ATRHandle,0,shift,v)?v:0;}

double AvgATR()
{
   double s=0; int n=0;
   for(int i=2;i<2+ATRBaselineBars;i++){double v=ATR(i);if(v>0){s+=v;n++;}}
   return n>0?s/n:0;
}

double ATRRatio(double a){double b=AvgATR();return (a>0&&b>0)?a/b:0;}

bool NewBar()
{
   datetime t=iTime(Sym,EntryTF,0);
   if(t<=0||t==LastBar)return false;
   LastBar=t;return true;
}

void ResetDay()
{
   MqlDateTime d;TimeToStruct(TimeCurrent(),d);d.hour=0;d.min=0;d.sec=0;
   datetime x=StructToTime(d);
   if(x!=DayStart){DayStart=x;DayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);TradesToday=0;LossStreak=0;}
}

bool InSession()
{
   if(!UseSessionFilter)return true;
   MqlDateTime d;TimeToStruct(TimeCurrent(),d);int h=d.hour;
   bool lon=(h>=LondonStartHour&&h<LondonEndHour);
   bool ny=(h>=NewYorkStartHour&&h<NewYorkEndHour);
   if(TradingSession==SESSION_LONDON_ONLY)return lon;
   if(TradingSession==SESSION_NEWYORK_ONLY)return ny;
   return lon||ny;
}

bool DailyBlocked()
{
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(DayStartEquity<=0)return true;
   double pnl=eq-DayStartEquity;
   if(DailyProfitTargetUSD>0&&pnl>=DailyProfitTargetUSD)return true;
   if(pnl<=-(DayStartEquity*MaxDailyLossPercent/100.0))return true;
   if(TradesToday>=MaxTradesPerDay)return true;
   if(LossStreak>=MaxConsecutiveLosses)return true;
   return false;
}

bool SpreadOK(double a)
{
   double ask=SymbolInfoDouble(Sym,SYMBOL_ASK),bid=SymbolInfoDouble(Sym,SYMBOL_BID);
   return ask>0&&bid>0&&a>0&&(ask-bid)<=a*(MaxSpreadATRPercent/100.0);
}

int DirectionTF(int fastHandle,int slowHandle,int adxHandle,ENUM_TIMEFRAMES tf)
{
   double f,s,a,p,m;
   if(!Buf(fastHandle,0,1,f)||!Buf(slowHandle,0,1,s)||!Buf(adxHandle,0,1,a)||!Buf(adxHandle,1,1,p)||!Buf(adxHandle,2,1,m))return 0;
   double c=iClose(Sym,tf,1); if(c<=0||a<MinADXTrend)return 0;
   if(c>f&&f>s&&p>m)return 1;
   if(c<f&&f<s&&m>p)return -1;
   return 0;
}

int RegimeDirection()
{
   int h4=DirectionTF(H4Fast,H4Slow,H4ADX,RegimeTF);
   int h1=DirectionTF(H1Fast,H1Slow,H1ADX,BiasTF);
   if(h4!=0&&h1==h4)return h4;
   return 0;
}

bool StrongTrend(int dir)
{
   int h=H1ADX;double a=0;if(!Buf(h,0,1,a))return false;return a>=StrongADX;
}

double Highest(int bars,int start=1)
{
   double x=-DBL_MAX;for(int i=start;i<start+bars;i++)x=MathMax(x,iHigh(Sym,EntryTF,i));return x;
}

double Lowest(int bars,int start=1)
{
   double x=DBL_MAX;for(int i=start;i<start+bars;i++)x=MathMin(x,iLow(Sym,EntryTF,i));return x;
}

double VWAP(int bars=32)
{
   double pv=0,vv=0;
   for(int i=1;i<=bars;i++){
      double h=iHigh(Sym,EntryTF,i),l=iLow(Sym,EntryTF,i),c=iClose(Sym,EntryTF,i);long v=iVolume(Sym,EntryTF,i);
      if(h<=0||l<=0||c<=0)continue;double w=v>0?(double)v:1.0;pv+=((h+l+c)/3.0)*w;vv+=w;
   }
   return vv>0?pv/vv:0;
}

bool BullStructure()
{
   double h1=Highest(StructureLookback,1),h2=Highest(StructureLookback,StructureLookback+1);
   double l1=Lowest(StructureLookback,1),l2=Lowest(StructureLookback,StructureLookback+1);
   return h1>h2&&l1>l2;
}

bool BearStructure()
{
   double h1=Highest(StructureLookback,1),h2=Highest(StructureLookback,StructureLookback+1);
   double l1=Lowest(StructureLookback,1),l2=Lowest(StructureLookback,StructureLookback+1);
   return h1<h2&&l1<l2;
}

bool TrendPullback(int dir,double a)
{
   double hi=Highest(StructureLookback,2),lo=Lowest(StructureLookback,2);
   double c1=iClose(Sym,EntryTF,1),o1=iOpen(Sym,EntryTF,1),h1=iHigh(Sym,EntryTF,1),l1=iLow(Sym,EntryTF,1),c2=iClose(Sym,EntryTF,2);
   if(c1<=0||a<=0)return false;
   double body=MathAbs(c1-o1);if(body<a*MinBodyATR)return false;
   double vwap=VWAP();if(RequireVWAPAlignment&&vwap>0&&((dir>0&&c1<vwap)||(dir<0&&c1>vwap)))return false;
   bool structure=(dir>0)?BullStructure():BearStructure();if(!structure)return false;
   bool retest=(dir>0)?(l1<=hi+a*RetestToleranceATR&&c1>hi&&c2>hi):(h1>=lo-a*RetestToleranceATR&&c1<lo&&c2<lo);
   if(!retest)return false;
   bool candle=(dir>0)?c1>o1:c1<o1;if(!candle)return false;
   double loc=(h1-l1>0)?((dir>0)?(c1-l1)/(h1-l1):(h1-c1)/(h1-l1)):0;
   return loc>=MinCloseLocation;
}

bool FailedBreakout(int dir,double a)
{
   double hi=Highest(StructureLookback,2),lo=Lowest(StructureLookback,2);
   double c1=iClose(Sym,EntryTF,1),o1=iOpen(Sym,EntryTF,1),h1=iHigh(Sym,EntryTF,1),l1=iLow(Sym,EntryTF,1);
   if(c1<=0||a<=0)return false;
   if(dir<0)
   {
      bool sweep=h1>hi+a*SweepATR&&h1<hi+a*MaxSweepATR;
      bool back=c1<hi-a*ReentryATR;
      bool candle=!RequireReversalCandle||c1<o1;
      return sweep&&back&&candle;
   }
   bool sweep=l1<lo-a*SweepATR&&l1>lo-a*MaxSweepATR;
   bool back=c1>lo+a*ReentryATR;
   bool candle=!RequireReversalCandle||c1>o1;
   return sweep&&back&&candle;
}

int Signal(double a)
{
   double ratio=ATRRatio(a);if(a<MinATRPrice||ratio<MinATRRatio||ratio>=ExtremeATRRatio)return 0;
   int trend=RegimeDirection();
   bool expansion=ratio>=ExpansionATRRatio;
   if(Mode!=MODE_REVERSAL_ONLY&&trend!=0)
   {
      if(TrendPullback(trend,a))return trend;
      if(expansion)
      {
         double hi=Highest(StructureLookback,2),lo=Lowest(StructureLookback,2),c=iClose(Sym,EntryTF,1);
         if(trend>0&&c>hi+a*BreakoutBufferATR)return 1;
         if(trend<0&&c<lo-a*BreakoutBufferATR)return -1;
      }
   }
   if(Mode!=MODE_TREND_ONLY)
   {
      if(FailedBreakout(-1,a))return -1;
      if(FailedBreakout(1,a))return 1;
   }
   return 0;
}

bool HasPosition(ulong &ticket)
{
   ticket=0;
   for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t>0&&PositionSelectByTicket(t)&&PositionGetString(POSITION_SYMBOL)==Sym&&PositionGetInteger(POSITION_MAGIC)==MagicNumber){ticket=t;return true;}}
   return false;
}

void ResetState()
{
   ulong t; if(!HasPosition(t)){StateTicket=0;StateEntry=0;StateRisk=0;StatePeak=0;PartialDone=false;return;}
   if(!PositionSelectByTicket(t))return;
   if(t!=StateTicket){StateTicket=t;StateEntry=PositionGetDouble(POSITION_PRICE_OPEN);double sl=PositionGetDouble(POSITION_SL);StateRisk=MathAbs(StateEntry-sl);StatePeak=StateEntry;PartialDone=false;}
}

double LossMoney(ENUM_ORDER_TYPE type,double lots,double dist)
{
   double e=(type==ORDER_TYPE_BUY)?SymbolInfoDouble(Sym,SYMBOL_ASK):SymbolInfoDouble(Sym,SYMBOL_BID);double s=(type==ORDER_TYPE_BUY)?e-dist:e+dist,p=0;
   if(!OrderCalcProfit(type,Sym,lots,e,s,p))return 0;return MathAbs(p);
}

double Lots(ENUM_ORDER_TYPE type,double dist)
{
   double riskMoney=AccountInfoDouble(ACCOUNT_EQUITY)*MathMin(RiskPercent,MaxRiskPercent)/100.0;if(riskMoney<=0)return 0;
   double minLot=SymbolInfoDouble(Sym,SYMBOL_VOLUME_MIN);if(RejectMinLotIfRiskExceeded&&LossMoney(type,minLot,dist)>riskMoney*1.02)return 0;
   double ts=SymbolInfoDouble(Sym,SYMBOL_TRADE_TICK_SIZE),tv=SymbolInfoDouble(Sym,SYMBOL_TRADE_TICK_VALUE);if(ts<=0||tv<=0)return 0;
   double perLot=(dist/ts)*tv;if(perLot<=0)return 0;double lot=riskMoney/perLot;
   double maxv=MathMin(MaxLotSize,SymbolInfoDouble(Sym,SYMBOL_VOLUME_MAX));double step=SymbolInfoDouble(Sym,SYMBOL_VOLUME_STEP);lot=MathMin(lot,maxv);
   if(step>0)lot=MathFloor(lot/step)*step;
   if(lot<minLot)return 0;return NormalizeDouble(lot,2);
}

bool OpenTrade(int dir,double a)
{
   ulong t;if(HasPosition(t)||DailyBlocked()||!InSession())return false;
   int digits=(int)SymbolInfoInteger(Sym,SYMBOL_DIGITS);double bid=SymbolInfoDouble(Sym,SYMBOL_BID),ask=SymbolInfoDouble(Sym,SYMBOL_ASK);
   double entry=dir>0?ask:bid;
   double swing=dir>0?Lowest(StructureLookback,1):Highest(StructureLookback,1);
   double rawDist=dir>0?(entry-(swing-a*StopATRBuffer)):((swing+a*StopATRBuffer)-entry);
   double dist=MathMax(rawDist,a*MinStopATR);dist=MathMin(dist,a*MaxStopATR);
   ENUM_ORDER_TYPE type=dir>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL;double lot=Lots(type,dist);if(lot<=0)return false;
   double sl=dir>0?entry-dist:entry+dist;
   trade.SetExpertMagicNumber(MagicNumber);trade.SetDeviationInPoints(DeviationPoints);
   bool ok=dir>0?trade.Buy(lot,Sym,entry,NormalizeDouble(sl,digits),0,TradeComment):trade.Sell(lot,Sym,entry,NormalizeDouble(sl,digits),0,TradeComment);
   if(ok){LastEntry=TimeCurrent();TradesToday++;ResetState();}return ok;
}

void ManagePosition()
{
   ulong t;if(!HasPosition(t)||!PositionSelectByTicket(t))return;ResetState();
   ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);double open=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL),vol=PositionGetDouble(POSITION_VOLUME);
   double price=type==POSITION_TYPE_BUY?SymbolInfoDouble(Sym,SYMBOL_BID):SymbolInfoDouble(Sym,SYMBOL_ASK);double risk=StateRisk;if(risk<=0)risk=MathAbs(open-sl);if(risk<=0)return;
   if(type==POSITION_TYPE_BUY)StatePeak=MathMax(StatePeak,price);else StatePeak=(StatePeak==0?price:MathMin(StatePeak,price));
   double r=type==POSITION_TYPE_BUY?(price-open)/risk:(open-price)/risk;
   datetime ot=(datetime)PositionGetInteger(POSITION_TIME);int age=(int)((TimeCurrent()-ot)/60);
   if(age>=MaxTradeMinutes){if(trade.PositionClose(t))LastExit=TimeCurrent();return;}
   int digits=(int)SymbolInfoInteger(Sym,SYMBOL_DIGITS);double a=ATR(1),newSL=sl;
   if(r>=PartialTP_R&&!PartialDone&&vol>SymbolInfoDouble(Sym,SYMBOL_VOLUME_MIN))
   {
      double closeVol=vol*PartialClosePercent/100.0;double step=SymbolInfoDouble(Sym,SYMBOL_VOLUME_STEP),minLot=SymbolInfoDouble(Sym,SYMBOL_VOLUME_MIN);
      if(step>0)closeVol=MathFloor(closeVol/step)*step;
      if(closeVol>=minLot&&closeVol<vol&&trade.PositionClosePartial(t,closeVol))PartialDone=true;
   }
   if(r>=BreakEven_R)
   {
      double lock=type==POSITION_TYPE_BUY?open+risk*BreakEvenLock_R:open-risk*BreakEvenLock_R;
      if(type==POSITION_TYPE_BUY)newSL=MathMax(newSL,lock);else newSL=(newSL==0?lock:MathMin(newSL,lock));
   }
   if(r>=RunnerStart_R&&a>0)
   {
      bool strong=StrongTrend(type==POSITION_TYPE_BUY?1:-1);double mult=strong?StrongTrailATR:TrailATR;double trail=type==POSITION_TYPE_BUY?StatePeak-mult*a:StatePeak+mult*a;
      if(type==POSITION_TYPE_BUY)newSL=MathMax(newSL,trail);else newSL=(newSL==0?trail:MathMin(newSL,trail));
   }
   double pt=SymbolInfoDouble(Sym,SYMBOL_POINT);
   if(type==POSITION_TYPE_BUY&&newSL>sl+pt)trade.PositionModify(t,NormalizeDouble(newSL,digits),0);
   if(type==POSITION_TYPE_SELL&&newSL>0&&(sl==0||newSL<sl-pt))trade.PositionModify(t,NormalizeDouble(newSL,digits),0);
}

void Stats()
{
   static datetime scan=0;datetime from=scan>0?scan:DayStart;if(!HistorySelect(from,TimeCurrent()))return;int n=HistoryDealsTotal();
   for(int i=n-1;i>=0;i--){ulong d=HistoryDealGetTicket(i);if(d==0)continue;if(HistoryDealGetInteger(d,DEAL_MAGIC)!=MagicNumber||HistoryDealGetString(d,DEAL_SYMBOL)!=Sym)continue;datetime tm=(datetime)HistoryDealGetInteger(d,DEAL_TIME);if(tm<=scan)break;long en=HistoryDealGetInteger(d,DEAL_ENTRY);if(en==DEAL_ENTRY_OUT||en==DEAL_ENTRY_OUT_BY){double p=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_SWAP)+HistoryDealGetDouble(d,DEAL_COMMISSION);if(p<0)LossStreak++;else if(p>0)LossStreak=0;LastExit=tm;}if(tm>scan)scan=tm;}
}

int OnInit()
{
   Sym=_Symbol;trade.SetExpertMagicNumber(MagicNumber);
   H4Fast=iMA(Sym,RegimeTF,FastMAPeriod,0,MODE_EMA,PRICE_CLOSE);H4Slow=iMA(Sym,RegimeTF,SlowMAPeriod,0,MODE_EMA,PRICE_CLOSE);H4ADX=iADX(Sym,RegimeTF,ADXPeriod);
   H1Fast=iMA(Sym,BiasTF,FastMAPeriod,0,MODE_EMA,PRICE_CLOSE);H1Slow=iMA(Sym,BiasTF,SlowMAPeriod,0,MODE_EMA,PRICE_CLOSE);H1ADX=iADX(Sym,BiasTF,ADXPeriod);ATRHandle=iATR(Sym,EntryTF,ATRPeriod);
   if(H4Fast<0||H4Slow<0||H4ADX<0||H1Fast<0||H1Slow<0||H1ADX<0||ATRHandle<0)return INIT_FAILED;ResetDay();return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(H4Fast>=0)IndicatorRelease(H4Fast);if(H4Slow>=0)IndicatorRelease(H4Slow);if(H4ADX>=0)IndicatorRelease(H4ADX);if(H1Fast>=0)IndicatorRelease(H1Fast);if(H1Slow>=0)IndicatorRelease(H1Slow);if(H1ADX>=0)IndicatorRelease(H1ADX);if(ATRHandle>=0)IndicatorRelease(ATRHandle);Comment("");
}

void OnTick()
{
   ResetDay();Stats();ManagePosition();
   if(HasPosition(*(new ulong)))return;
   if(!NewBar()||DailyBlocked()||!InSession())return;
   double a=ATR(1);if(a<=0||!SpreadOK(a))return;
   int sig=Signal(a);if(sig!=0)OpenTrade(sig,a);
   Comment("XAU ADAPTIVE V10\n","Equity: ",DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2),"\n","Day PnL: ",DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY)-DayStartEquity,2),"\n","Trades: ",TradesToday," LossStreak: ",LossStreak,"\n","ATR ratio: ",DoubleToString(ATRRatio(a),2)," Signal: ",sig);
}

//+------------------------------------------------------------------+
//| SLP_Confluence_EA_v6.mq5                                         |
//| Trades any pair with USD, JPY or a metal as base or quote, plus |
//| the USD index and US stock indices (US30, US500, US100).         |
//| A trade needs:                                                   |
//|  1) D1 directional bias (HH/HL or LH/LL)                         |
//|  2) MSS or DBS on EntryTF in the bias direction                  |
//|  3) Valid inducement (first pullback that returns to the extreme)|
//|  4) POI = order block OR breaker block, unmitigated, closest to  |
//|     the inducement (mitigated only by a BODY touch, not a wick)  |
//|  5) EA's own recent statistics show a positive edge              |
//| Lots = risk USD / (unit x SL pips); fixed $ risk per trade.      |
//| TP = nearest liquidity target that pays at least MinRR.          |
//| UNTESTED CODE: compile, backtest and demo-forward-test first.    |
//+------------------------------------------------------------------+
#property copyright "SLP confluence EA v6"
#property version   "6.00"
#include <Trade/Trade.mqh>

enum LOT_MODE { LOT_SLP_FORMULA=0, LOT_BROKER_EXACT=1, LOT_SAFEST=2 };

input group "Universe"
input string          TradeCcy         = "USD,JPY,XAU,XAG,XPT,XPD";   // a pair qualifies if EITHER leg is one of these
input string          CoveredCcy       = "USD,JPY,EUR,GBP,AUD,NZD,CAD,CHF,XAU,XAG,XPT,XPD";   // BOTH legs must be in this list to qualify
input bool            MultiSymbol      = true;        // scan every qualifying symbol in Market Watch from one chart
input int             MaxSymbols       = 30;
input int             MaxOpenPositions = 3;           // account-wide: open positions + pending orders
input int             MaxSameCcyExposure = 2;         // max trades leaning the same way on one currency
input string          IndexKeys        = "DXY,USDX,USDIDX,USDOLLAR";   // USD index names
input string          StockIndexKeys   = "US30,US500,US100,DJ30,WS30,SPX500,SP500,NAS100,USTEC,NDX100";   // stock indices to trade; matched at the START of the symbol name (US30.cash, #US500 also match). Must be in Market Watch
input group "SLP structure"
input ENUM_TIMEFRAMES BiasTF           = PERIOD_D1;
input ENUM_TIMEFRAMES ConfirmTF        = PERIOD_H4;
input ENUM_TIMEFRAMES EntryTF          = PERIOD_M30;
input int             SwingLR          = 3;
input int             ScanBars         = 400;
input int             MinPushes        = 2;
input int             BiasMinPushes    = 1;
input int             LevelAge         = 150;
input int             OriginLookback   = 40;
input int             BBBack           = 20;          // bars before the impulse origin searched for failed order blocks (breakers)
input double          IDMTolATR        = 0.15;
input int             MaxSetupBars     = 60;
input double          SLBufferATR      = 0.15;
input bool            UseLTFRefine     = true;        // wide POI / long candle: look for a tighter OB on a lower timeframe
input ENUM_TIMEFRAMES RefineTF         = PERIOD_M5;
input double          RefineIfSLATR    = 1.5;         // refine when the stop is wider than this many ATR
input int             MinScore         = 4;         // max possible score is now 4 (base) + 1 (ConfirmTF agrees); was 6 with fundamentals bonus
input group "Take profit (liquidity)"
input double          MinRR            = 2.0;
input double          EqTolATR         = 0.10;
input int             RangeBars        = 60;
input double          RangeATR         = 6.0;
input int             WickBars         = 120;         // long-wick liquidity search window
input double          WickATR          = 0.8;         // wick must be at least this many ATR
input double          WickBodyRatio    = 2.0;         // and at least this many times the body
input group "Lot size and risk"
input double          RiskUSD          = 5.0;         // fixed risk per trade
input LOT_MODE        LotMode          = LOT_SAFEST;  // SAFEST = smaller of video formula and broker-exact
input double          JPYUnit          = 6.62;        // $ per pip per 1.00 lot on JPY pairs (video value, drifts with USDJPY)
input double          CommodityUnit    = 10.0;
input double          USDUnit          = 10.0;        // $ per pip per 1.00 lot on USD-quoted pairs (EURUSD, GBPUSD, ...)        // gold: displayed price move x10 = pips
input double          MaxSpreadFracSL  = 0.15;
input double          MaxDailyLossUSD  = 15.0;
input int             MaxTradesPerDay  = 3;           // account-wide
input group "Statistical gate"
input int             StatLookback     = 50;
input int             MinSample        = 30;
input double          MinProfitFactor  = 1.3;
input double          MinWinRate       = 40.0;
input double          WarmupRiskMult   = 1.0;         // keep 1.0 to stay at the fixed $ risk
input group "Session"
input int             StartHour        = 7;
input int             EndHour          = 20;
input int             FridayCutoffHour = 17;
input long            MagicNumber      = 550033;

//--- structure engine ------------------------------------------------
struct Pivot { int bar; double px; int type; bool broken; };   // type +1 swing high, -1 swing low
struct Evt   { int kind; int dir; int bar; };                  // kind 1 = MSS, 2 = DBS
struct Setup { int dir; int kind; datetime id; double entry; double sl; double tp; double idm; string why; string poi; };

class CStruct
{
public:
   MqlRates r[];
   int      n;
   Pivot    pv[];
   int      npv;
   Evt      ev[];
   int      nev;
   int      trend;
   int      pushes;

   void AddPivot(int bar,double px,int type)
   {
      ArrayResize(pv,npv+1,64);
      pv[npv].bar=bar; pv[npv].px=px; pv[npv].type=type; pv[npv].broken=false;
      npv++;
   }
   void AddEvt(int kind,int dir,int bar)
   {
      ArrayResize(ev,nev+1,16);
      ev[nev].kind=kind; ev[nev].dir=dir; ev[nev].bar=bar;
      nev++;
   }
   int LastPivot(int type)
   {
      for(int k=npv-1;k>=0;k--) if(pv[k].type==type) return k;
      return -1;
   }

   bool Run(const string sym,ENUM_TIMEFRAMES tf,int bars,int lr,int minPushes)
   {
      ArraySetAsSeries(r,false);
      n=CopyRates(sym,tf,0,bars,r);
      if(n<lr*2+20) return false;
      ArrayResize(pv,0); npv=0;
      ArrayResize(ev,0); nev=0;
      trend=0; pushes=0;
      double thPx=0, plPx=0, pbPx=0;
      bool   havePb=false;
      int    last=n-2;

      for(int i=lr;i<=last;i++)
      {
         int p=i-lr;
         if(p>=lr)
         {
            bool ph=true, pl=true;
            for(int k=1;k<=lr;k++)
            {
               if(r[p].high<=r[p-k].high || r[p].high<r[p+k].high) ph=false;
               if(r[p].low >=r[p-k].low  || r[p].low >r[p+k].low ) pl=false;
            }
            if(ph) AddPivot(p,r[p].high,1);
            if(pl) AddPivot(p,r[p].low,-1);
            if(trend!=0)
            {
               int pt = ph ? 1 : (pl ? -1 : 0);
               if(pt==-trend)
               {
                  double tp=trend*((pt==1)?r[p].high:r[p].low);
                  if(!havePb || tp<pbPx){ pbPx=tp; havePb=true; }
               }
            }
         }

         double c=r[i].close;
         if(trend==0)
         {
            int kh=LastPivot(1), kl=LastPivot(-1);
            if(kh>=0 && kl>=0)
            {
               if(c>pv[kh].px){ trend=1;  thPx=r[i].high;  plPx=pv[kl].px;  havePb=false; pushes=0; }
               else if(c<pv[kl].px){ trend=-1; thPx=-r[i].low; plPx=-pv[kh].px; havePb=false; pushes=0; }
            }
         }
         else
         {
            double cs=trend*c;
            if(cs<plPx)
            {
               if(pushes>=minPushes) AddEvt(1,-trend,i);        // Market Structure Shift
               int ns=-trend;
               double oldTh=thPx;
               trend=ns;
               thPx=(ns>0)? r[i].high : -r[i].low;
               plPx=-oldTh;
               havePb=false; pushes=0;
            }
            else
            {
               int cnt=0;                                        // Double Break of Structure
               for(int k=0;k<npv;k++)
                  if(pv[k].type==trend && !pv[k].broken && (i-pv[k].bar)<=LevelAge && cs>trend*pv[k].px) cnt++;
               if(cnt>=2) AddEvt(2,trend,i);
               double th=(trend>0)? r[i].high : -r[i].low;
               if(th>thPx)
               {
                  if(havePb){ plPx=pbPx; havePb=false; pushes++; }
                  thPx=th;
               }
            }
         }
         for(int k=0;k<npv;k++)
         {
            if(pv[k].broken) continue;
            if(pv[k].type==1 && c>pv[k].px) pv[k].broken=true;
            else if(pv[k].type==-1 && c<pv[k].px) pv[k].broken=true;
         }
      }
      return true;
   }
};

CStruct g_D, g_H, g_E;

double Hs(const MqlRates &x,int d){ return d>0 ? x.high : -x.low;  }
double Ls(const MqlRates &x,int d){ return d>0 ? x.low  : -x.high; }
double Os(const MqlRates &x,int d){ return d*x.open;  }
double Cs(const MqlRates &x,int d){ return d*x.close; }

//--- globals ----------------------------------------------------------
CTrade   trade;
string   g_syms[];                // symbols this EA trades
int      g_hATR[];
datetime g_lastBar[];
datetime g_pend[];                // working pending-order setup id, per symbol
string   g_stat[];                // dashboard line, per symbol
int      g_ns=0;
int      g_idx=0;
string   g_sym="";               // symbol currently being evaluated
datetime g_day=0;
double   g_dayEquity=0;

//+------------------------------------------------------------------+
// Returns the StockIndexKeys entry the symbol starts with (after any broker prefix such as # or .), else "".
string StockIdxKey(const string symIn)
{
   string s=symIn; StringToUpper(s);
   while(StringLen(s)>0)
   {
      ushort ch=StringGetCharacter(s,0);
      if((ch>='A' && ch<='Z') || (ch>='0' && ch<='9')) break;
      s=StringSubstr(s,1);
   }
   string keys[]; int n=StringSplit(StockIndexKeys,',',keys);
   for(int i=0;i<n;i++)
   {
      string k=keys[i]; StringTrimLeft(k); StringTrimRight(k); StringToUpper(k);
      if(StringLen(k)>0 && StringFind(s,k)==0) return k;
   }
   return "";
}
// Split a symbol into its two legs. Handles broker prefixes/suffixes (EURUSD.m, #EURUSD),
// GOLD/SILVER aliases, USD-index names and US stock indices.
// Stock indices come back as isIndex=true with base "EQ" (one shared equity leg, so US30 + US500 + US100
// count as the same lean in the exposure cap) and no quote leg.
void ParseSymbolS(const string symIn,string &base,string &quote,bool &isIndex)
{
   string s=symIn; StringToUpper(s);
   isIndex=false; base=""; quote="";
   string keys[]; int n=StringSplit(IndexKeys,',',keys);
   for(int i=0;i<n;i++)
   {
      string k=keys[i]; StringTrimLeft(k); StringTrimRight(k); StringToUpper(k);
      if(StringLen(k)>0 && StringFind(s,k)>=0){ isIndex=true; base="USD"; return; }
   }
   if(StockIdxKey(s)!=""){ isIndex=true; base="EQ"; quote=""; return; }
   while(StringLen(s)>0){ ushort ch=StringGetCharacter(s,0); if(ch>='A' && ch<='Z') break; s=StringSubstr(s,1); }
   if(StringFind(s,"GOLD")==0){ base="XAU"; quote="USD"; return; }
   if(StringFind(s,"SILVER")==0){ base="XAG"; quote="USD"; return; }
   if(StringLen(s)>=6){ base=StringSubstr(s,0,3); quote=StringSubstr(s,3,3); }
}
void ParseSymbol(string &base,string &quote,bool &isIndex){ ParseSymbolS(g_sym,base,quote,isIndex); }

bool InList(const string list,const string code)
{
   string keys[]; int n=StringSplit(list,',',keys);
   for(int i=0;i<n;i++)
   {
      string k=keys[i]; StringTrimLeft(k); StringTrimRight(k); StringToUpper(k);
      if(k==code) return true;
   }
   return false;
}
bool IsMetal(const string c){ return c=="XAU" || c=="XAG" || c=="XPT" || c=="XPD"; }

// A symbol qualifies when one leg is in TradeCcy (USD / JPY / a metal) and BOTH legs are in CoveredCcy.
// Crypto and exotic pairs are left out on purpose.
bool AllowedSymbolS(const string sym)
{
   string b,q; bool idx;
   ParseSymbolS(sym,b,q,idx);
   if(StockIdxKey(sym)!="") return SymbolInfoInteger(sym,SYMBOL_TRADE_MODE)!=SYMBOL_TRADE_MODE_DISABLED;
   if(idx) return true;
   if(b=="" || q=="") return false;
   if(!InList(CoveredCcy,b) || !InList(CoveredCcy,q)) return false;
   if(!(InList(TradeCcy,b) || InList(TradeCcy,q))) return false;
   return SymbolInfoInteger(sym,SYMBOL_TRADE_MODE)!=SYMBOL_TRADE_MODE_DISABLED;
}
bool SamePair(const string a,const string c)
{
   string b1,q1,b2,q2; bool i1,i2;
   ParseSymbolS(a,b1,q1,i1); ParseSymbolS(c,b2,q2,i2);
   return (b1==b2 && q1==q2 && i1==i2 && StockIdxKey(a)==StockIdxKey(c));   // US30 and US500 share base "EQ", so compare the index key too
}
void AddSym(const string sym)
{
   for(int i=0;i<g_ns;i++) if(SamePair(g_syms[i],sym)) return;     // skip broker-suffix duplicates
   ArrayResize(g_syms,g_ns+1); g_syms[g_ns]=sym; g_ns++;
}
void BuildSymbolList()
{
   g_ns=0; ArrayResize(g_syms,0);
   if(AllowedSymbolS(_Symbol)) AddSym(_Symbol);                     // chart symbol first
   if(!MultiSymbol) return;
   int tot=SymbolsTotal(true);                                      // Market Watch
   for(int i=0;i<tot && g_ns<MaxSymbols;i++)
   {
      string sym=SymbolName(i,true);
      if(AllowedSymbolS(sym)) AddSym(sym);
   }
}

int OnInit()
{
   BuildSymbolList();
   if(g_ns==0){ Print("No qualifying symbols. Put USD / JPY / metal pairs or US30 / US500 style indices in Market Watch (or attach the EA to one)."); return INIT_FAILED; }
   ArrayResize(g_hATR,g_ns); ArrayResize(g_lastBar,g_ns); ArrayResize(g_pend,g_ns); ArrayResize(g_stat,g_ns);
   string list="";
   for(int i=0;i<g_ns;i++)
   {
      SymbolSelect(g_syms[i],true);
      g_hATR[i]=iATR(g_syms[i],EntryTF,14);
      g_lastBar[i]=0; g_pend[i]=0; g_stat[i]="";
      list+=g_syms[i]+" ";
   }
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   EventSetTimer(15);
   PrintFormat("SLP v6 ready | %d symbols: %s",g_ns,list);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i=0;i<g_ns;i++) if(g_hATR[i]!=INVALID_HANDLE) IndicatorRelease(g_hATR[i]);
   Comment("");
}

//+------------------------------------------------------------------+
//| TARGETS AND SETUP                                                |
//+------------------------------------------------------------------+
void Consider(double lvl,double need,const string lbl,double &best,string &bw)
{
   if(lvl>=need && lvl<best){ best=lvl; bw=lbl; }
}

// Liquidity targets from the TP video: trend-line liquidity (origin of the pullback into the POI),
// equal highs/lows, long-wick liquidity, range opposite side, last swing. Nearest one that pays MinRR.
bool PickTarget(CStruct &S,int d,double eTS,double risk,double atr,int last,int jBar,double &tpTS,string &why)
{
   double need=eTS+MinRR*risk;
   double buf=0.1*atr;
   double best=DBL_MAX; string bw="";

   // trend-line liquidity: was the approach into the POI a trend (2+ descending swings after the apex)?
   int apex=jBar; double apexHi=-DBL_MAX;
   for(int i=jBar;i<=last;i++){ double h=Hs(S.r[i],d); if(h>apexHi){ apexHi=h; apex=i; } }
   int cntDesc=0; double prevPx=DBL_MAX;
   for(int k=0;k<S.npv;k++)
   {
      if(S.pv[k].type!=d || S.pv[k].bar<=apex) continue;
      double px=d*S.pv[k].px;
      if(px<prevPx){ cntDesc++; prevPx=px; } else { cntDesc=0; prevPx=px; }
   }
   bool trendLike=(cntDesc>=2);
   if(trendLike) Consider(apexHi-buf,need,"trend-line liquidity",best,bw);

   // equal highs / lows (unbroken pairs)
   double tol=EqTolATR*atr;
   for(int a=0;a<S.npv;a++)
   {
      if(S.pv[a].type!=d || S.pv[a].broken) continue;
      double pa=d*S.pv[a].px; if(pa<=eTS) continue;
      for(int b=a+1;b<S.npv;b++)
      {
         if(S.pv[b].type!=d || S.pv[b].broken) continue;
         double pb=d*S.pv[b].px;
         if(MathAbs(pa-pb)<=tol) Consider(MathMax(pa,pb)-buf,need,"equal highs/lows",best,bw);
      }
   }

   // long-wick liquidity (not yet swept by later price)
   int w0=MathMax(0,last-WickBars);
   for(int i=w0;i<=last;i++)
   {
      double top=Hs(S.r[i],d);
      if(top<=eTS) continue;
      double bodyTop=MathMax(Os(S.r[i],d),Cs(S.r[i],d));
      double bodyLen=MathAbs(Cs(S.r[i],d)-Os(S.r[i],d));
      double wick=top-bodyTop;
      if(wick<WickATR*atr || wick<WickBodyRatio*MathMax(bodyLen,0.05*atr)) continue;
      bool swept=false;
      for(int b=i+1;b<=last;b++) if(Hs(S.r[b],d)>=top){ swept=true; break; }
      if(!swept) Consider(top-buf,need,"long-wick liquidity",best,bw);
   }

   // ranging liquidity: opposite side of the current range
   int from=MathMax(0,last-RangeBars+1);
   double hh=-DBL_MAX, ll=DBL_MAX;
   for(int i=from;i<=last;i++){ hh=MathMax(hh,Hs(S.r[i],d)); ll=MathMin(ll,Ls(S.r[i],d)); }
   if(hh-ll<=RangeATR*atr) Consider(hh-buf,need,"range opposite side",best,bw);

   // fallback: last swing formed before the POI is tapped (skipped when the approach was a trend line)
   if(!trendLike)
   {
      for(int k=S.npv-1;k>=0;k--)
      {
         if(S.pv[k].type==d && d*S.pv[k].px>eTS){ Consider(d*S.pv[k].px-buf,need,"last swing before POI",best,bw); break; }
      }
   }
   if(best<DBL_MAX){ tpTS=best; why=bw; return true; }
   return false;
}

// Lower-timeframe refinement: inside a wide POI, look for an unmitigated order block on RefineTF.
// Body-touch rule: a wick tap does not mitigate it. Mitigation only counts after the impulse candle (t2).
bool RefineZone(int d,datetime t0,datetime t2,datetime t1,double zoneBot,double zoneTop,double &eOut,double &botOut)
{
   MqlRates x[];
   ArraySetAsSeries(x,false);
   int m=CopyRates(g_sym,RefineTF,t0,t1,x);
   if(m<6) return false;
   double best=-DBL_MAX, bBot=0; bool ok=false;
   for(int k=0;k<m-1;k++)
   {
      if(!(Cs(x[k],d)<Os(x[k],d) && Cs(x[k+1],d)>Os(x[k+1],d))) continue;
      if(!(Cs(x[k+1],d)>=Os(x[k],d) && Os(x[k+1],d)<=Cs(x[k],d))) continue;
      double body=Os(x[k],d)-Cs(x[k],d);
      double wick=Hs(x[k],d)-Os(x[k],d);
      double e=(wick<=body) ? Hs(x[k],d) : Os(x[k],d);
      double bot=MathMin(Ls(x[k],d),Ls(x[k+1],d));
      if(e>zoneTop || bot<zoneBot) continue;
      bool mit=false;
      for(int b=k+2;b<m;b++)
         if(x[b].time>=t2 && Ls(x[b],d)<=Os(x[k],d)){ mit=true; break; }
      if(mit) continue;
      if(e>best){ best=e; bBot=bot; ok=true; }
   }
   if(!ok) return false;
   eOut=best; botOut=bBot;
   return true;
}

bool FindSetup(CStruct &S,int biasDir,double atr,Setup &o)
{
   int last=S.n-2;
   if(S.nev==0 || last<50) return false;
   Evt e=S.ev[S.nev-1];
   if(e.dir!=biasDir) return false;
   int d=e.dir;

   int o0=MathMax(0,e.bar-OriginLookback);
   int origin=o0; double mn=DBL_MAX;
   for(int i=o0;i<=e.bar;i++){ double v=Ls(S.r[i],d); if(v<mn){ mn=v; origin=i; } }

   int kImp=-1;
   for(int k=0;k<S.npv;k++) if(S.pv[k].type==d && S.pv[k].bar>=e.bar){ kImp=k; break; }
   if(kImp<0) return false;
   int impBar=S.pv[kImp].bar; double impHi=d*S.pv[kImp].px;

   int kIdm=-1;
   for(int k=kImp+1;k<S.npv;k++) if(S.pv[k].type==-d && S.pv[k].bar>impBar){ kIdm=k; break; }
   if(kIdm<0) return false;
   int idmBar=S.pv[kIdm].bar; double idmPx=d*S.pv[kIdm].px;

   double tol=IDMTolATR*atr;
   int j=-1;
   for(int b=idmBar+1;b<=last;b++) if(Hs(S.r[b],d)>=impHi-tol){ j=b; break; }
   if(j<0) return false;
   if(last-j>MaxSetupBars) return false;

   double bestE=-DBL_MAX, bestBot=0, bestTop=0; int bestType=0, bestC1=-1, bestC2=-1;

   // Every OB and BB is a candidate. Mitigated ones are dropped, and the unmitigated one closest to the
   // inducement (highest entry below it) wins - i.e. work outward from the inducement and take the first
   // block that has not been tapped. A block is mitigated only when price trades INTO its BODY;
   // a wick tap leaves it valid.

   // (a) ORDER BLOCKS: opposing candle engulfed by an impulse candle
   for(int c1=origin;c1<e.bar;c1++)
   {
      int c2=c1+1;
      if(!(Cs(S.r[c1],d)<Os(S.r[c1],d) && Cs(S.r[c2],d)>Os(S.r[c2],d))) continue;
      if(!(Cs(S.r[c2],d)>=Os(S.r[c1],d) && Os(S.r[c2],d)<=Cs(S.r[c1],d))) continue;
      double bodyTop=Os(S.r[c1],d);
      double body=bodyTop-Cs(S.r[c1],d);
      double wick=Hs(S.r[c1],d)-bodyTop;
      double eTS=(wick<=body) ? Hs(S.r[c1],d) : bodyTop;     // small wick: from the wick, long wick: from the body
      if(eTS>=idmPx){ if(bodyTop<idmPx) eTS=bodyTop; else continue; }
      bool mit=false;
      for(int b=c2+1;b<=j;b++) if(Ls(S.r[b],d)<=bodyTop){ mit=true; break; }
      if(mit) continue;
      if(eTS>bestE){ bestE=eTS; bestBot=MathMin(Ls(S.r[c1],d),Ls(S.r[c2],d)); bestTop=Hs(S.r[c1],d); bestType=1; bestC1=c1; bestC2=c2; }
   }

   // (b) BREAKER BLOCKS: an order block of the opposite side that price then closed through
   for(int c1=MathMax(0,origin-BBBack);c1<e.bar;c1++)
   {
      int c2=c1+1;
      if(!(Cs(S.r[c1],d)>Os(S.r[c1],d) && Cs(S.r[c2],d)<Os(S.r[c2],d))) continue;
      if(!(Os(S.r[c2],d)>=Cs(S.r[c1],d) && Cs(S.r[c2],d)<=Os(S.r[c1],d))) continue;
      double zoneTop=Hs(S.r[c1],d);
      int bb=-1;
      for(int b=c2+1;b<=e.bar;b++) if(Cs(S.r[b],d)>zoneTop){ bb=b; break; }
      if(bb<0) continue;
      double bodyTop=Cs(S.r[c1],d);
      double body=bodyTop-Os(S.r[c1],d);
      double wick=zoneTop-bodyTop;
      double eTS=(wick<=body) ? zoneTop : bodyTop;
      if(eTS>=idmPx){ if(bodyTop<idmPx) eTS=bodyTop; else continue; }
      bool mit=false;
      for(int b=bb+1;b<=j;b++) if(Ls(S.r[b],d)<=bodyTop){ mit=true; break; }
      if(mit) continue;
      if(eTS>bestE){ bestE=eTS; bestBot=MathMin(Ls(S.r[c1],d),Ls(S.r[c2],d)); bestTop=zoneTop; bestType=2; bestC1=c1; bestC2=c2; }
   }
   if(bestType==0) return false;

   // stop covers the whole block (wick and body); lot size then absorbs the wider stop
   double spread=SymbolInfoDouble(g_sym,SYMBOL_ASK)-SymbolInfoDouble(g_sym,SYMBOL_BID);
   double eFin=bestE;
   double slTS=bestBot-SLBufferATR*atr-spread;
   double risk=eFin-slTS;
   bool refined=false;
   if(UseLTFRefine && risk>RefineIfSLATR*atr && PeriodSeconds(RefineTF)<PeriodSeconds(EntryTF))
   {
      datetime t0=S.r[bestC1].time;
      datetime t2=S.r[bestC2].time+PeriodSeconds(EntryTF);
      datetime t1=S.r[j].time+PeriodSeconds(EntryTF);
      double e2=0, b2=0;
      if(RefineZone(d,t0,t2,t1,bestBot,bestTop,e2,b2))
      {
         double sl2=b2-SLBufferATR*atr-spread;
         if(e2-sl2>0 && (e2-sl2)<risk){ eFin=e2; slTS=sl2; risk=e2-sl2; refined=true; }
      }
   }
   if(risk<=0) return false;

   // POI already tapped after the inducement completed -> that entry is gone
   for(int b=j+1;b<=last;b++) if(Ls(S.r[b],d)<=eFin) return false;

   double tpTS=0; string why="";
   if(!PickTarget(S,d,eFin,risk,atr,last,j,tpTS,why)) return false;

   o.dir=d; o.kind=e.kind; o.id=S.r[e.bar].time;
   o.entry=d*eFin; o.sl=d*slTS; o.tp=d*tpTS; o.idm=d*idmPx; o.why=why;
   o.poi=(bestType==1) ? "OB" : "BB";
   if(refined) o.poi+="(LTF)";
   return true;
}

//+------------------------------------------------------------------+
//| STATISTICS, LOTS, ORDERS                                         |
//+------------------------------------------------------------------+
bool EdgeOK(double &riskMult,string &why)
{
   riskMult=1.0;
   if(!HistorySelect(0,TimeCurrent())){ riskMult=WarmupRiskMult; why="no history"; return true; }
   int total=HistoryDealsTotal();
   int n=0, wins=0; double gw=0, gl=0;
   for(int i=total-1;i>=0 && n<StatLookback;i--)
   {
      ulong tk=HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(tk,DEAL_MAGIC)!=MagicNumber) continue;
      if(HistoryDealGetInteger(tk,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      double p=HistoryDealGetDouble(tk,DEAL_PROFIT)+HistoryDealGetDouble(tk,DEAL_SWAP)+HistoryDealGetDouble(tk,DEAL_COMMISSION);
      n++;
      if(p>0){ wins++; gw+=p; } else gl+=MathAbs(p);
   }
   if(n<MinSample){ riskMult=WarmupRiskMult; why=StringFormat("warm-up %d/%d trades",n,MinSample); return true; }
   double wr=100.0*wins/n;
   double pf=(gl>0)? gw/gl : 99.0;
   why=StringFormat("n=%d WR=%.1f%% PF=%.2f",n,wr,pf);
   return (wr>=MinWinRate && pf>=MinProfitFactor);
}

// Video formula: Lot = Risk USD / (unit x SL pips). JPY pairs: pip 0.01, unit 6.62.
// Gold: displayed move x10 = pips, unit 10. Returns 0 where the video gives no formula
// (stock indices included: they use the broker-exact lot calculation).
double LotsFormula(double dist,double riskUSD)
{
   string b,q; bool idx; ParseSymbol(b,q,idx);
   double pip=0, unit=0;
   if(!idx && q=="JPY" && !IsMetal(b)){ pip=0.01; unit=JPYUnit; }                    // JPY pairs
   else if(!idx && q=="USD" && !IsMetal(b)){ pip=0.0001; unit=USDUnit; }              // EURUSD, GBPUSD, AUDUSD ...
   else if(!idx && b=="XAU" && q=="USD"){ pip=0.10; unit=CommodityUnit; }             // gold
   else return 0;                                                                     // all others: broker-exact lots
   double pips=dist/pip;
   if(pips<=0) return 0;
   return riskUSD/(unit*pips);
}
// exact value from the broker's own contract specification (account currency)
double LotsExact(double entry,double sl,bool buy,double riskUSD)
{
   double profit=0;
   if(!OrderCalcProfit(buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,g_sym,1.0,entry,sl,profit)) return 0;
   double perLot=MathAbs(profit);
   if(perLot<=0) return 0;
   return riskUSD/perLot;
}
double CalcLots(double entry,double sl,bool buy,double riskUSD,string &how)
{
   double fo=LotsFormula(MathAbs(entry-sl),riskUSD);
   double ex=LotsExact(entry,sl,buy,riskUSD);
   double raw;
   if(LotMode==LOT_BROKER_EXACT)      raw=ex;
   else if(LotMode==LOT_SLP_FORMULA)  raw=(fo>0)? fo : ex;
   else                               raw=(fo>0 && ex>0)? MathMin(fo,ex) : (ex>0? ex : fo);
   how=StringFormat("formula %.3f / broker %.3f",fo,ex);
   if(raw<=0) return 0;
   double step=SymbolInfoDouble(g_sym,SYMBOL_VOLUME_STEP);
   double mn=SymbolInfoDouble(g_sym,SYMBOL_VOLUME_MIN), mx=SymbolInfoDouble(g_sym,SYMBOL_VOLUME_MAX);
   double lots=MathFloor(raw/step+1e-9)*step;
   if(lots<mn) return 0;                              // never round UP: the fixed $ risk must hold
   lots=MathMin(lots,mx);
   int dg=(int)MathMax(0,MathRound(-MathLog10(step)));
   return NormalizeDouble(lots,dg);
}

int CountMineAll()
{
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(PositionGetSymbol(i)!="" && PositionGetInteger(POSITION_MAGIC)==MagicNumber) c++;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i); if(t==0) continue;
      if(OrderGetInteger(ORDER_MAGIC)==MagicNumber) c++;
   }
   return c;
}
int LegHit(const string sym,int dir,const string ccy,int sign)    // 1 if this trade leans `sign` on `ccy`
{
   string b,q; bool idx; ParseSymbolS(sym,b,q,idx);
   int r=0;
   if(b==ccy && dir==sign) r=1;
   if(q==ccy && -dir==sign) r=1;
   return r;
}
int ExposureCount(const string ccy,int sign)
{
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      string ps=PositionGetSymbol(i);
      if(ps=="" || ps==g_sym || PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      int pd=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?1:-1;
      c+=LegHit(ps,pd,ccy,sign);
   }
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i); if(t==0) continue;
      string os=OrderGetString(ORDER_SYMBOL);
      if(os==g_sym || OrderGetInteger(ORDER_MAGIC)!=MagicNumber) continue;
      long ot=OrderGetInteger(ORDER_TYPE);
      int od=(ot==ORDER_TYPE_BUY_LIMIT || ot==ORDER_TYPE_BUY_STOP || ot==ORDER_TYPE_BUY)?1:-1;
      c+=LegHit(os,od,ccy,sign);
   }
   return c;
}
// buying EURUSD leans long EUR and short USD; avoid stacking the same lean across many pairs
bool ExposureBlocked(int dir)
{
   string b,q; bool idx; ParseSymbol(b,q,idx);
   if(ExposureCount(b,dir)>=MaxSameCcyExposure) return true;
   if(q!="" && ExposureCount(q,-dir)>=MaxSameCcyExposure) return true;
   return false;
}

bool HavePosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(PositionGetSymbol(i)==g_sym && PositionGetInteger(POSITION_MAGIC)==MagicNumber) return true;
   return false;
}
bool HavePending()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i); if(t==0) continue;
      if(OrderGetString(ORDER_SYMBOL)==g_sym && OrderGetInteger(ORDER_MAGIC)==MagicNumber) return true;
   }
   return false;
}
void DeletePending()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i); if(t==0) continue;
      if(OrderGetString(ORDER_SYMBOL)==g_sym && OrderGetInteger(ORDER_MAGIC)==MagicNumber) trade.OrderDelete(t);
   }
   g_pend[g_idx]=0;
}

void RollDay()
{
   datetime d=StringToTime(TimeToString(TimeCurrent(),TIME_DATE));
   if(d!=g_day){ g_day=d; g_dayEquity=AccountInfoDouble(ACCOUNT_EQUITY); }
}
int TodayEntries()
{
   if(!HistorySelect(g_day,TimeCurrent())) return 0;
   int c=0;
   for(int i=HistoryDealsTotal()-1;i>=0;i--)
   {
      ulong tk=HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(tk,DEAL_MAGIC)==MagicNumber && HistoryDealGetInteger(tk,DEAL_ENTRY)==DEAL_ENTRY_IN) c++;
   }
   return c;
}
bool SessionOK()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(dt.day_of_week==0 || dt.day_of_week==6) return false;
   if(dt.hour<StartHour || dt.hour>=EndHour) return false;
   if(dt.day_of_week==5 && dt.hour>=FridayCutoffHour) return false;
   return true;
}
bool DailyOK()
{
   if(g_dayEquity>0 && (AccountInfoDouble(ACCOUNT_EQUITY)-g_dayEquity)<=-MaxDailyLossUSD) return false;
   return TodayEntries()<MaxTradesPerDay;
}

void Status(const string msg)
{
   if(g_idx>=0 && g_idx<g_ns) g_stat[g_idx]=g_sym+": "+msg;
   string all="SLP v6\n";
   for(int i=0;i<g_ns;i++) if(g_stat[i]!="") all+=g_stat[i]+"\n";
   Comment(all);
}

//+------------------------------------------------------------------+
void Evaluate()
{
   if(HavePosition()){ DeletePending(); Status("Position open - managed by SL/TP (no early exit)"); return; }

   double a[1];
   if(CopyBuffer(g_hATR[g_idx],0,1,1,a)!=1 || a[0]<=0) return;
   double atr=a[0];

   // 1) directional bias
   if(!g_D.Run(g_sym,BiasTF,300,SwingLR,MinPushes)){ DeletePending(); Status("Bias data not ready"); return; }
   int bias=g_D.trend;
   if(bias==0 || g_D.pushes<BiasMinPushes){ DeletePending(); Status("No clear D1 bias (range / unclear) - standing aside"); return; }

   // 2-4) structure event, inducement, POI (OB or BB)
   if(!g_E.Run(g_sym,EntryTF,ScanBars,SwingLR,MinPushes)){ DeletePending(); return; }
   Setup s;
   bool haveSetup=FindSetup(g_E,bias,atr,s);
   if(!haveSetup){ DeletePending(); Status(StringFormat("D1 bias %s | waiting for MSS/DBS + inducement + unmitigated OB/BB + liquidity target",bias>0?"BUY":"SELL")); return; }
   if(!SessionOK() || !DailyOK()){ DeletePending(); Status("Setup found but session / daily limits block it"); return; }

   int score=4;
   if(g_H.Run(g_sym,ConfirmTF,300,SwingLR,MinPushes) && g_H.trend==bias) score++;
   if(score<MinScore){ DeletePending(); Status(StringFormat("Score %d < %d",score,MinScore)); return; }

   // 5) statistical gate
   double mult; string ew;
   if(!EdgeOK(mult,ew)){ DeletePending(); Status("Edge gate blocked: "+ew); PrintFormat("%s blocked by edge gate (%s)",g_sym,ew); return; }

   if(HavePending())
   {
      if(g_pend[g_idx]==s.id){ Status(StringFormat("Limit order working (%s %s, score %d)",s.kind==1?"MSS":"DBS",s.poi,score)); return; }
      DeletePending();
   }

   if(CountMineAll()>=MaxOpenPositions){ Status("Open-trade cap reached"); return; }
   if(ExposureBlocked(s.dir)){ Status("Skipped: too many trades already leaning the same way on one currency"); return; }

   bool buy=(s.dir>0);
   int dg=(int)SymbolInfoInteger(g_sym,SYMBOL_DIGITS);
   double px=NormalizeDouble(s.entry,dg), sl=NormalizeDouble(s.sl,dg), tp=NormalizeDouble(s.tp,dg);
   double dist=MathAbs(px-sl);
   double spread=SymbolInfoDouble(g_sym,SYMBOL_ASK)-SymbolInfoDouble(g_sym,SYMBOL_BID);
   if(dist<=0 || spread>MaxSpreadFracSL*dist) return;
   double minDist=SymbolInfoInteger(g_sym,SYMBOL_TRADE_STOPS_LEVEL)*SymbolInfoDouble(g_sym,SYMBOL_POINT);
   double ask=SymbolInfoDouble(g_sym,SYMBOL_ASK), bid=SymbolInfoDouble(g_sym,SYMBOL_BID);
   if(buy && px>ask-minDist) return;
   if(!buy && px<bid+minDist) return;

   string lw;
   double lots=CalcLots(px,sl,buy,RiskUSD*mult,lw);
   if(lots<=0)
   {
      Status(StringFormat("Skipped: $%.2f risk is below the minimum lot at this stop (%s)",RiskUSD*mult,lw));
      PrintFormat("%s skipped - stop too wide for $%.2f risk at minimum lot (%s)",g_sym,RiskUSD*mult,lw);
      return;
   }
   string cmt="SLP v6";
   datetime exp=TimeCurrent()+(datetime)(MaxSetupBars*PeriodSeconds(EntryTF));
   trade.SetTypeFillingBySymbol(g_sym);
   bool ok=buy ? trade.BuyLimit (lots,px,g_sym,sl,tp,ORDER_TIME_SPECIFIED,exp,cmt)
               : trade.SellLimit(lots,px,g_sym,sl,tp,ORDER_TIME_SPECIFIED,exp,cmt);
   if(ok)
   {
      g_pend[g_idx]=s.id;
      PrintFormat("%s %s LIMIT %.2f lots @ %s | %s %s | TP: %s | score %d | lots: %s | %s",g_sym,buy?"BUY":"SELL",lots,DoubleToString(px,dg),
                  s.kind==1?"MSS":"DBS",s.poi,s.why,score,lw,ew);
      Status(StringFormat("Placed %s limit (%s %s, TP: %s)",buy?"BUY":"SELL",s.kind==1?"MSS":"DBS",s.poi,s.why));
   }
}

void ScanAll()
{
   RollDay();
   for(int i=0;i<g_ns;i++)
   {
      if(g_hATR[i]==INVALID_HANDLE) continue;
      datetime t=iTime(g_syms[i],EntryTF,0);
      if(t==0 || t==g_lastBar[i]) continue;          // one evaluation per new entry bar, per symbol
      g_lastBar[i]=t;
      g_idx=i; g_sym=g_syms[i];
      Evaluate();
   }
}
void OnTick(){ ScanAll(); }
void OnTimer(){ ScanAll(); }                        // keeps the other symbols moving when the chart symbol is quiet
//+------------------------------------------------------------------+

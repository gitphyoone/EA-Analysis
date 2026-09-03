//+------------------------------------------------------------------+
//| V19 FX Prop Desk — MT5 Trade Executor v1.12                     |
//| Ported from MT4 TradeExecutor v2.10                             |
//|                                                                  |
//| MQL4→MQL5 key changes:                                          |
//|  - OrdersTotal/OrderSelect → PositionsTotal/PositionGetTicket   |
//|  - OrderSend (old) → MqlTradeRequest + OrderSend                |
//|  - MarketInfo → SymbolInfoDouble/Integer                        |
//|  - AccountBalance/Equity → AccountInfoDouble                    |
//|  - iATR(…,bar) → iATR handle + CopyBuffer                      |
//|  - OrdersHistoryTotal → HistorySelect + HistoryDealsTotal       |
//|  - Partial close: same ticket survives (no remainder ticket)    |
//|  - DEAL_REASON_SL/TP for exit reason (cleaner than price cmp)  |
//|  - ulong tickets (64-bit)                                       |
//| v1.10 — synced with MT4 v2.10:                                  |
//|  - ManageOpenTrades moved OnTimer → OnTick (real-time reaction) |
//|  - SL_ATR_Mult input; TP/partial-trigger R defaults raised      |
//|  - ADX/EMA10-20 trend-weakening exit: tighten to ATR×0.5, or   |
//|    full "runner" close when ADX<20 + EMA cross-back at ≥3R    |
//|  - SLD global-var tracks original ATR-based sl_dist (needed    |
//|    because BE/partial close moves the position's actual SL,    |
//|    which would otherwise corrupt R and step-trail math)        |
//| v1.11 — MT4/MT5 logic-parity fixes:                             |
//|  - FIX A: ServerToGMT() header comment corrected — it wrongly   |
//|    claimed MT4 (v2.10) already converts closed_at to GMT.       |
//|    It does NOT; MT4 sends raw broker-server time. This is a     |
//|    separate, still-open bug to fix on the MT4 side — do not     |
//|    assume it's handled there. MT5's ServerToGMT() conversion    |
//|    itself is correct and unchanged.                             |
//|  - FIX B: CloseAllPositions() ATR shift corrected from the      |
//|    GetATR() default (shift=1, previous closed bar) to an        |
//|    explicit shift=0 (current/live bar), matching MT4's          |
//|    iATR(sym,60,14,0) in the same function.                      |
//|  - NOTE (not fixed here, unconfirmed): Symbol_List uses plain   |
//|    "USDJPY" while MT4 uses "USDJPY.y" (broker suffix). Verify   |
//|    against this MT5 account's actual Market Watch symbol name   |
//|    before relying on USDJPY signals/trades.                     |
//| CONFIRMED (chat): switching SL_ATR_Mult 2.0→1.5 and             |
//|    Partial_Close_At_R 4.0→2.0 fixed step-trail on H1 — but the  |
//|    underlying data source was still hardcoded to H1 regardless  |
//|    of these input labels. v1.12 fixes that.                     |
//| v1.13 — V19.1 Exit Improvement Memo (RED list, exit side):        |
//|  - Max_Open_Positions default 5 → 3           (memo §13)          |
//|  - Break-even trigger is now an input (BE_Trigger_R, default 1.0) |
//|    and the BE buffer optionally adds the live spread so BE really |
//|    covers trading cost, not just 1 pip        (memo §5 / §18)     |
//|  - Single 30%-@-4R partial REPLACED by a 3-stage scale-out:       |
//|      Stage 1  +TP1_R (1.0R) → close TP1_Close_Pct (30%), SL→BE   |
//|      Stage 2  +TP2_R (2.0R) → close TP2_Close_Pct (30%), SL→+1R  |
//|      Runner   remaining ~40% → ATR trail (Runner_Trail_ATR_Mult) |
//|    All R levels / percentages are inputs      (memo §3 / §4 / §6) |
//|  - Exit stage tracked as an int GV (PCSTAGE_) instead of the old  |
//|    boolean PC_ flag; original entry lot saved in LOT_ GV so the   |
//|    stage-2 close is a % of the ORIGINAL size, not the remainder.  |
//|  - Re-entry cooldown / same-dir wait-candle / daily -2% stop are  |
//|    enforced BACKEND-side (routers/signals.py) and arrive here as  |
//|    a normal NO_TRADE + reject_reason — nothing to do in the EA.   |
//| v1.12 — H1/H4 dual-instance support:                             |
//|  - FIX E: Signal_Timeframe input added. Previously PERIOD_H1    |
//|    was hardcoded in OnInit()'s indicator handle creation, in    |
//|    FetchSignal()'s URL query string, and in LogRejectReason()'s |
//|    JSON body — meaning the SL_ATR_Mult/Partial_Close_At_R       |
//|    "H1=.../H4=..." input comments were cosmetic only; the       |
//|    actual candle/indicator data was always H1 no matter what.   |
//|    Now Signal_Timeframe drives all three, so this same file can |
//|    run as a second, independent H4 instance (with its own      |
//|    Magic_Number) alongside the existing H1 instance.            |
//|  - To run H4 alongside H1: attach this EA to a second chart     |
//|    with Signal_Timeframe=PERIOD_H4, Magic_Number=<different     |
//|    value, e.g. 19002>, SL_ATR_Mult=2.0, Partial_Close_At_R=4.0. |
//|    Different Magic_Number is required — GV keys (GV_PC, GV_SLD) |
//|    and position/history filtering are all keyed by symbol+magic,|
//|    so the two instances won't interfere with each other even    |
//|    when trading the same symbols.                                |
//|  - NOT verified here: whether the backend's /signals/evaluate    |
//|    endpoint and market_data table actually distinguish H1 vs    |
//|    H4 rows. DataCollector must also be run as a second H4       |
//|    instance (see DataCollector.mq5 v1.02) for this to work end-  |
//|    to-end — check backend routers/signals.py if H4 signals      |
//|    come back empty or identical to H1.                          |
//+------------------------------------------------------------------+
#property copyright "V19 FX Prop Desk"
#property version   "1.13"

// ── Inputs ──────────────────────────────────────────────────────────
input string           FastAPI_Base         = "http://127.0.0.1";
input string           API_Key              = "f9e369ad5592a0dcd33c78c4e33bd382";
input string            Symbol_List          = "EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD,GBPJPY";
input ENUM_TIMEFRAMES   Signal_Timeframe     = PERIOD_H1;  // FIX E (v1.12): drives indicators + signal URL + reject-log
input int               Poll_Seconds         = 10;
input long              Magic_Number         = 19001;      // MUST differ between the H1 and H4 instances
input int                Slippage             = 3;
input bool                Enable_Trading       = true;
input double               BE_Buffer_Pips       = 1.0;
input int                    Friday_Close_Hour    = 20;
input string                  Telegram_Token       = "";
input string                   Telegram_Chat_ID     = "";
input bool                      Debug                = true;

input int    Max_Open_Positions     = 3;     // V19.1 §13 — was 5
input double Portfolio_Max_Risk_Pct = 6.0;
input double Risk_Per_Trade_Pct     = 1.0;
input bool   Enable_Session_Filter  = false;
input bool   Log_Reject_Reasons     = true;

input double TP_R_Multiple          = 8.0;   // wide safety TP for the runner (SL_dist x R)
input double SL_ATR_Mult            = 2.0;   // SL = ATR x mult (H1=1.5, H4=2.0)

// ── V19.1 staged exit (memo §3 / §4 / §5 / §6 / §18) ───────────────
input double BE_Trigger_R           = 1.0;   // move SL to break-even at +this R — memo §5:
                                             // NEVER before +0.8R (Option A) / +1.0R (Option B)
input bool   BE_Cost_Buffer         = true;  // add live spread to the BE buffer (cover cost)
input double TP1_R                  = 1.0;   // stage 1: trigger R
input double TP1_Close_Pct          = 30.0;  // stage 1: % of ORIGINAL lot to close
input double TP2_R                  = 2.0;   // stage 2: trigger R
input double TP2_Close_Pct          = 30.0;  // stage 2: % of ORIGINAL lot to close
input double Runner_Trail_Start_R   = 1.0;   // runner: ATR trail active from +this R
input double Runner_Trail_ATR_Mult  = 1.5;   // runner: trail distance = ATR x this (test 1.5 / 2.0)

input double CB_Level1_DD_Pct       = 3.0;
input double CB_Level2_DD_Pct       = 5.0;
input double CB_Level3_DD_Pct       = 8.0;
input double CB_Reset_Ratio         = 0.5;

// ── State ────────────────────────────────────────────────────────────
int    cb_level = 0;
string cb_date  = "";

ulong  reported_closed_tickets[500];
int    n_reported_closed = 0;

string g_opened_symbols[50];
int    g_opened_count = 0;

string symbols[];
int    num_symbols = 0;
int    atr_handles[];   // one per symbol, created in OnInit
int    adx_handles[];   // ADX(14) main line, one per symbol
int    ma10_handles[];  // EMA(10) close, one per symbol
int    ma20_handles[];  // EMA(20) close, one per symbol

// ── Utility helpers ──────────────────────────────────────────────────
// FIX E (v1.12): maps ENUM_TIMEFRAMES to the string the backend expects
// (used so "H1" is no longer hardcoded in the signal URL / reject-log body).
string TFToString(ENUM_TIMEFRAMES tf) {
    switch (tf) {
        case PERIOD_M1:  return "M1";
        case PERIOD_M5:  return "M5";
        case PERIOD_M15: return "M15";
        case PERIOD_M30: return "M30";
        case PERIOD_H1:  return "H1";
        case PERIOD_H4:  return "H4";
        case PERIOD_D1:  return "D1";
        case PERIOD_W1:  return "W1";
        case PERIOD_MN1: return "MN1";
        default:         return "H1";
    }
}

bool IsOpenedSymbol(string sym) {
    for (int i = 0; i < g_opened_count; i++)
        if (g_opened_symbols[i] == sym) return true;
    return false;
}
void MarkOpenedSymbol(string sym) {
    if (!IsOpenedSymbol(sym) && g_opened_count < 50)
        g_opened_symbols[g_opened_count++] = sym;
}
void ClearOpenedSymbol(string sym) {
    for (int i = 0; i < g_opened_count; i++) {
        if (g_opened_symbols[i] == sym) {
            for (int j = i; j < g_opened_count - 1; j++)
                g_opened_symbols[j] = g_opened_symbols[j+1];
            g_opened_symbols[--g_opened_count] = "";
            return;
        }
    }
}

// V19.1: exit stage per symbol (0 = full position / no scale-out yet,
// 1 = stage-1 partial done, 2 = stage-2 partial done → runner).
// Keyed by symbol+magic so H1 and H4 instances never collide.
string GV_STAGE(string sym) { return "PCSTAGE_" + sym + "_" + IntegerToString(Magic_Number); }
int  GetExitStage(string sym) {
    string gv = GV_STAGE(sym);
    return GlobalVariableCheck(gv) ? (int)GlobalVariableGet(gv) : 0;
}
void SetExitStage(string sym, int stage) { GlobalVariableSet(GV_STAGE(sym), (double)stage); }
void ClearExitStage(string sym) {
    if (GlobalVariableCheck(GV_STAGE(sym))) GlobalVariableDel(GV_STAGE(sym));
    // also clear any legacy v1.12 boolean flag left over from before the upgrade
    string legacy = "PC_" + sym + "_" + IntegerToString(Magic_Number);
    if (GlobalVariableCheck(legacy)) GlobalVariableDel(legacy);
}

// V19.1: original entry lot size — stage-1/stage-2 closes are a % of THIS,
// not of the shrinking remainder, so the runner ends up at the intended ~40%.
string GV_LOT(string sym) { return "LOT_" + sym + "_" + IntegerToString(Magic_Number); }
void   SaveOrigLot(string sym, double lots) { GlobalVariableSet(GV_LOT(sym), lots); }
double LoadOrigLot(string sym, double fallback) {
    string gv = GV_LOT(sym);
    if (GlobalVariableCheck(gv)) { double v = GlobalVariableGet(gv); if (v > 0) return v; }
    return fallback;
}
void ClearOrigLot(string sym) {
    if (GlobalVariableCheck(GV_LOT(sym))) GlobalVariableDel(GV_LOT(sym));
}

// Original ATR-based SL distance at entry (see header note — required so
// r/step-trail math stays correct after BE or partial close moves the SL).
string GV_SLD(string sym) { return "SLD_" + sym + "_" + IntegerToString(Magic_Number); }
void SaveSlDist(string sym, double sl_dist) { GlobalVariableSet(GV_SLD(sym), sl_dist); }
double LoadSlDist(string sym, double fallback) {
    string gv = GV_SLD(sym);
    if (GlobalVariableCheck(gv)) {
        double val = GlobalVariableGet(gv);
        if (val > 0) return val;
    }
    return fallback;
}
void ClearSlDist(string sym) {
    string gv = GV_SLD(sym);
    if (GlobalVariableCheck(gv)) GlobalVariableDel(gv);
}

// ── Indicator helpers ─────────────────────────────────────────────────
int SymbolIndex(string sym) {
    for (int i = 0; i < num_symbols; i++)
        if (symbols[i] == sym) return i;
    return -1;
}
double GetATR(string sym, int shift = 1) {
    int idx = SymbolIndex(sym);
    if (idx < 0 || atr_handles[idx] == INVALID_HANDLE) return 0.0;
    double buf[1];
    if (CopyBuffer(atr_handles[idx], 0, shift, 1, buf) != 1) return 0.0;
    return buf[0];
}
double GetADX(string sym, int shift) {
    int idx = SymbolIndex(sym);
    if (idx < 0 || adx_handles[idx] == INVALID_HANDLE) return 0.0;
    double buf[1];
    if (CopyBuffer(adx_handles[idx], 0, shift, 1, buf) != 1) return 0.0;
    return buf[0];
}
double GetMA(int &handles[], string sym, int shift) {
    int idx = SymbolIndex(sym);
    if (idx < 0 || handles[idx] == INVALID_HANDLE) return 0.0;
    double buf[1];
    if (CopyBuffer(handles[idx], 0, shift, 1, buf) != 1) return 0.0;
    return buf[0];
}

// ── JSON helpers ──────────────────────────────────────────────────────
double JsonDouble(string body, string key) {
    string search = "\"" + key + "\":";
    int pos = StringFind(body, search);
    if (pos < 0) return 0.0;
    pos += StringLen(search);
    if (StringSubstr(body, pos, 4) == "null") return 0.0;
    int end  = StringFind(body, ",", pos);
    int end2 = StringFind(body, "}", pos);
    if (end < 0 || (end2 >= 0 && end2 < end)) end = end2;
    if (end < 0) return 0.0;
    return StringToDouble(StringSubstr(body, pos, end - pos));
}
string JsonString(string body, string key) {
    string search = "\"" + key + "\":\"";
    int pos = StringFind(body, search);
    if (pos < 0) return "";
    pos += StringLen(search);
    int end = StringFind(body, "\"", pos);
    if (end < 0) return "";
    return StringSubstr(body, pos, end - pos);
}
int JsonInt(string body, string key) { return (int)JsonDouble(body, key); }

// ── Time / session helpers ────────────────────────────────────────────
string FormatTimestamp(datetime dt) {
    string s = TimeToString(dt, TIME_DATE|TIME_SECONDS);
    StringReplace(s, ".", "-");
    StringReplace(s, ".", "-");
    StringReplace(s, " ", "T");
    return s;
}
string FormatISO8601(datetime dt) { return FormatTimestamp(dt); }
// Broker server time != UTC — convert before reporting closed_at.
// NOTE (v1.11): MT4 executor (v2.10) does NOT do this conversion yet — that's
// a separate, still-open bug on the MT4 side. Do not assume it's handled
// there; this MT5 conversion is correct and should NOT be removed to
// "match" MT4 — fix MT4 to match this instead.
datetime ServerToGMT(datetime server_time) {
    return server_time + (TimeGMT() - TimeCurrent());
}

string TodayString() {
    MqlDateTime tm;
    TimeToStruct(TimeGMT(), tm);
    return StringFormat("%04d%02d%02d", tm.year, tm.mon, tm.day);
}
string GetSession() {
    MqlDateTime tm;
    TimeToStruct(TimeGMT(), tm);
    int h = tm.hour;
    bool lo = (h >= 8 && h < 17), ny = (h >= 13 && h < 22);
    if (lo && ny) return "OVERLAP";
    if (lo)       return "LONDON";
    if (ny)       return "NEW_YORK";
    return "OFF_SESSION";
}
bool IsFridayClose() {
    MqlDateTime tm;
    TimeToStruct(TimeGMT(), tm);
    return (tm.day_of_week == 5 && tm.hour >= Friday_Close_Hour);
}

// ── HTTP helpers ──────────────────────────────────────────────────────
string GETUrl(string ep) {
    if (StringLen(API_Key) > 0)
        return FastAPI_Base + ep +
               (StringFind(ep, "?") >= 0 ? "&" : "?") + "api_key=" + API_Key;
    return FastAPI_Base + ep;
}
string POSTHeaders() {
    string h = "Content-Type: application/json\r\n";
    if (StringLen(API_Key) > 0) h += "X-API-Key: " + API_Key + "\r\n";
    return h;
}

// ── Account / position helpers ────────────────────────────────────────
int GetOpenCount() {
    int n = 0;
    for (int i = 0; i < PositionsTotal(); i++) {
        if (PositionGetTicket(i) > 0 &&
            PositionGetInteger(POSITION_MAGIC) == Magic_Number) n++;
    }
    return n;
}
bool HasOpenPosition(string sym) {
    for (int i = 0; i < PositionsTotal(); i++) {
        if (PositionGetTicket(i) == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) == sym &&
            PositionGetInteger(POSITION_MAGIC) == Magic_Number) return true;
    }
    return false;
}
double GetTotalOpenRiskPct() {
    double total = 0, bal = AccountInfoDouble(ACCOUNT_BALANCE);
    if (bal <= 0) return 0;
    for (int i = 0; i < PositionsTotal(); i++) {
        if (PositionGetTicket(i) == 0) continue;
        if (PositionGetInteger(POSITION_MAGIC) != Magic_Number) continue;
        double sl = PositionGetDouble(POSITION_SL);
        if (sl == 0) continue;
        string sym    = PositionGetString(POSITION_SYMBOL);
        double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
        double sd     = MathAbs(entry - sl);
        double ps     = (StringFind(sym, "JPY") >= 0) ? 0.01 : 0.0001;
        double tv     = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
        double ts     = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
        double pv     = (ts > 0) ? tv / ts * ps : 0.0;
        double lots   = PositionGetDouble(POSITION_VOLUME);
        total += (sd / ps) * pv * lots;
    }
    return total / bal * 100.0;
}

// ── History helpers ───────────────────────────────────────────────────
bool IsReportedClosed(ulong ticket) {
    for (int i = 0; i < n_reported_closed; i++)
        if (reported_closed_tickets[i] == ticket) return true;
    return false;
}
void MarkReportedClosed(ulong ticket) {
    if (n_reported_closed < 500) reported_closed_tickets[n_reported_closed++] = ticket;
}

// ── Trade execution helpers ───────────────────────────────────────────
ENUM_ORDER_TYPE_FILLING GetFilling(string sym) {
    int modes = (int)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
    if ((modes & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
    if ((modes & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
    return ORDER_FILLING_RETURN;
}
bool ModifySLTP(ulong ticket, string sym, double sl, double tp) {
    MqlTradeRequest req = {}; MqlTradeResult res = {};
    req.action   = TRADE_ACTION_SLTP;
    req.position = ticket;
    req.symbol   = sym;
    req.sl       = sl;
    req.tp       = tp;
    return OrderSend(req, res) && (res.retcode == TRADE_RETCODE_DONE ||
                                   res.retcode == TRADE_RETCODE_PLACED);
}

// ── OnInit / OnDeinit ─────────────────────────────────────────────────
int OnInit() {
    string raw = Symbol_List;
    StringReplace(raw, " ", "");
    string tmp[];
    int n = StringSplit(raw, ',', tmp);
    ArrayResize(symbols, n);
    for (int i = 0; i < n; i++) symbols[i] = tmp[i];
    num_symbols = n;
    g_opened_count = 0;
    for (int j = 0; j < ArraySize(g_opened_symbols); j++) g_opened_symbols[j] = "";

    // Create indicator handles for each symbol
    // FIX E (v1.12): uses Signal_Timeframe instead of hardcoded PERIOD_H1,
    // so this same file can be attached a second time as an H4 instance.
    ArrayResize(atr_handles, num_symbols);
    ArrayResize(adx_handles, num_symbols);
    ArrayResize(ma10_handles, num_symbols);
    ArrayResize(ma20_handles, num_symbols);
    for (int i = 0; i < num_symbols; i++) {
        atr_handles[i]  = iATR(symbols[i], Signal_Timeframe, 14);
        adx_handles[i]  = iADX(symbols[i], Signal_Timeframe, 14);
        ma10_handles[i] = iMA(symbols[i], Signal_Timeframe, 10, 0, MODE_EMA, PRICE_CLOSE);
        ma20_handles[i] = iMA(symbols[i], Signal_Timeframe, 20, 0, MODE_EMA, PRICE_CLOSE);
        if (atr_handles[i] == INVALID_HANDLE || adx_handles[i] == INVALID_HANDLE ||
            ma10_handles[i] == INVALID_HANDLE || ma20_handles[i] == INVALID_HANDLE)
            Print("[Executor] WARNING: indicator handle failed for ", symbols[i]);
    }

    EventSetTimer(Poll_Seconds);
    Print("[Executor MT5 v1.13] Initialized"
          " | symbols=", Symbol_List, " | timeframe=", TFToString(Signal_Timeframe),
          " | magic=", Magic_Number,
          " | max_pos=", Max_Open_Positions, " | portfolio=", Portfolio_Max_Risk_Pct, "%"
          " | risk=", Risk_Per_Trade_Pct, "% | SL_mult=", SL_ATR_Mult,
          " | BE@", BE_Trigger_R, "R(buf ", BE_Buffer_Pips, "p", (BE_Cost_Buffer ? "+spread" : ""), ")",
          " | stage1 ", TP1_Close_Pct, "%@", TP1_R, "R",
          " | stage2 ", TP2_Close_Pct, "%@", TP2_R, "R",
          " | runner trail ATRx", Runner_Trail_ATR_Mult, " from ", Runner_Trail_Start_R, "R",
          " | CB_reset=", CB_Reset_Ratio);
    return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) {
    EventKillTimer();
    for (int i = 0; i < num_symbols; i++) {
        if (atr_handles[i]  != INVALID_HANDLE) IndicatorRelease(atr_handles[i]);
        if (adx_handles[i]  != INVALID_HANDLE) IndicatorRelease(adx_handles[i]);
        if (ma10_handles[i] != INVALID_HANDLE) IndicatorRelease(ma10_handles[i]);
        if (ma20_handles[i] != INVALID_HANDLE) IndicatorRelease(ma20_handles[i]);
    }
}

// ManageOpenTrades() runs on every tick for real-time price reaction — BE,
// partial close, and trailing stop must not wait for the Poll_Seconds timer.
// OnTimer() still handles the poll-cadence work: closed-trade reporting,
// circuit breaker, and signal evaluation.
void OnTick() {
    if (!Enable_Trading) return;
    if (cb_level == 3) return;
    ManageOpenTrades();
    if (cb_level == 2) Level2ProtectTrades();
}

// ── OnTimer (main loop) ───────────────────────────────────────────────
void OnTimer() {
    string today = TodayString();
    if (cb_date != today) { cb_level = 0; cb_date = today; }
    DetectAndReportClosedTrades();
    if (!Enable_Trading) return;
    if (IsFridayClose()) { CloseAllPositions("FRIDAY_CLOSE"); return; }
    CheckCircuitBreaker();
    if (cb_level >= 1) return;
    EvaluateSignals();
}

// ── Circuit breaker ───────────────────────────────────────────────────
double FetchRealizedDailyLoss() {
    string url = GETUrl("/analytics/drawdown");
    uchar dummy[], result[]; string rh;
    int res = WebRequest("GET", url, "", 5000, dummy, result, rh);
    if (res != 200) { if (Debug) Print("[Executor] drawdown HTTP=", res); return 0.0; }
    string body = CharArrayToString(result);
    int pos = StringFind(body, "\"daily_loss\":"); if (pos < 0) return 0.0;
    pos += 13;
    int end = StringFind(body, ",", pos); if (end < 0) end = StringFind(body, "}", pos);
    if (end < 0) return 0.0;
    return -MathAbs(StringToDouble(StringSubstr(body, pos, end - pos)));
}
void CheckCircuitBreaker() {
    double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    if (equity <= 0 || balance <= 0) return;

    double realized   = FetchRealizedDailyLoss();
    double total_loss = realized + MathMin(0, equity - balance);
    double dd_pct     = MathAbs(total_loss) / balance * 100.0;

    int new_level = 0;
    if      (dd_pct >= CB_Level3_DD_Pct) new_level = 3;
    else if (dd_pct >= CB_Level2_DD_Pct) new_level = 2;
    else if (dd_pct >= CB_Level1_DD_Pct) new_level = 1;

    if (cb_level == 2 && dd_pct < CB_Level2_DD_Pct * CB_Reset_Ratio) new_level = 1;
    if (cb_level == 1 && dd_pct < CB_Level1_DD_Pct * CB_Reset_Ratio) new_level = 0;
    if (cb_level == 3) new_level = 3;

    if (new_level != cb_level) {
        string msg = StringFormat("[CB] LEVEL %d -> %d | DD=%.2f%%", cb_level, new_level, dd_pct);
        cb_level = new_level;
        Print(msg); SendTelegram(msg);
        if (cb_level == 3) CloseAllPositions("CB_L3");
    }
}

// ── Signal evaluation ─────────────────────────────────────────────────
void EvaluateSignals() {
    for (int i = 0; i < num_symbols; i++) {
        string sym = symbols[i];
        if (HasOpenPosition(sym)) continue;
        if (IsOpenedSymbol(sym)) {
            if (!HasOpenPosition(sym)) ClearOpenedSymbol(sym); else continue;
        }
        if (GetOpenCount() >= Max_Open_Positions) {
            if (Debug) Print("[Executor] Max pos (", Max_Open_Positions, ") — stop"); break;
        }
        double cr = GetTotalOpenRiskPct();
        if (cr + Risk_Per_Trade_Pct > Portfolio_Max_Risk_Pct) {
            if (Debug) Print("[Executor] Portfolio cap — stop"); break;
        }
        int sc = 0; double rsi = 0, adx = 0, dip = 0, dim = 0, e50 = 0, e200 = 0;
        string rej = "";
        string dir = FetchSignal(sym, sc, rsi, adx, dip, dim, e50, e200, rej);
        if (dir == "NO_TRADE" || dir == "") {
            if (Log_Reject_Reasons && dir == "NO_TRADE") LogRejectReason(sym, sc, rej);
            continue;
        }
        if (Enable_Session_Filter && GetSession() == "OFF_SESSION") {
            if (Log_Reject_Reasons) LogRejectReason(sym, sc, "OFF_SESSION");
            continue;
        }
        OpenTrade(sym, dir, sc, rsi, adx, dip, dim, e50, e200);
    }
}
string FetchSignal(string sym, int &sc, double &rsi, double &adx,
                   double &dip, double &dim, double &e50, double &e200, string &rej) {
    double ps = (StringFind(sym, "JPY") >= 0) ? 0.01 : 0.0001;
    double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
    double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
    double pv = (ts > 0) ? tv / ts * ps : 0.0;
    // FIX E (v1.12): timeframe query param now driven by Signal_Timeframe
    // instead of a hardcoded "H1" literal.
    string url = GETUrl(StringFormat("/signals/evaluate/%s?timeframe=%s&pip_value=%.6f",
                                     sym, TFToString(Signal_Timeframe), pv));
    uchar dummy[], result[]; string rh;
    int res = WebRequest("GET", url, "", 5000, dummy, result, rh);
    if (res != 200) { if (Debug) Print("[Executor] Signal HTTP=", res, " ", sym); return ""; }
    string body = CharArrayToString(result);
    int pos = StringFind(body, "\"direction\":\""); if (pos < 0) return "";
    pos += 13; int end = StringFind(body, "\"", pos); if (end < 0) return "";
    string dir = StringSubstr(body, pos, end - pos);
    sc  = JsonInt(body, "score");    rsi = JsonDouble(body, "rsi");
    adx = JsonDouble(body, "adx");   dip = JsonDouble(body, "di_plus");
    dim = JsonDouble(body, "di_minus"); e50  = JsonDouble(body, "ema50");
    e200 = JsonDouble(body, "ema200");  rej  = JsonString(body, "reject_reason");
    if (Debug) Print("[Executor] Signal ", sym, " → ", dir, " score=", sc, " reject=", rej);
    return dir;
}
void LogRejectReason(string sym, int score, string reason) {
    // FIX E (v1.12): timeframe field now driven by Signal_Timeframe
    // instead of a hardcoded "H1" literal.
    string body = StringFormat(
        "{\"symbol\":\"%s\",\"timeframe\":\"%s\",\"direction\":\"NO_TRADE\","
        "\"score\":%d,\"reject_reason\":\"%s\",\"timestamp\":\"%s\"}",
        sym, TFToString(Signal_Timeframe), score, reason, FormatTimestamp(TimeCurrent()));
    string url = FastAPI_Base + "/signals/log";
    uchar post_data[], result[]; string rh;
    StringToCharArray(body, post_data, 0, StringLen(body));
    int res = WebRequest("POST", url, POSTHeaders(), 5000, post_data, result, rh);
    if (Debug && res != 200 && res != 201 && res != 404)
        Print("[Executor] LogReject HTTP=", res, " ", sym);
}

// ── Open trade ────────────────────────────────────────────────────────
void OpenTrade(string sym, string dir, int sc, double rsi, double adx,
               double dip, double dim, double e50, double e200) {
    double atr = GetATR(sym);
    double atr_min = (StringFind(sym, "JPY") >= 0) ? 0.050 : 0.0005;
    double atr_max = (StringFind(sym, "JPY") >= 0) ? 0.500 : 0.0050;
    if (atr <= 0 || atr < atr_min || atr > atr_max) {
        Print("[Executor] ATR abnormal ", sym, " atr=", DoubleToString(atr, 6),
              " valid=", DoubleToString(atr_min, 6), "-", DoubleToString(atr_max, 6), " — skip");
        return;
    }

    double price;
    ENUM_ORDER_TYPE cmd;
    if (dir == "BUY") { price = SymbolInfoDouble(sym, SYMBOL_ASK); cmd = ORDER_TYPE_BUY; }
    else              { price = SymbolInfoDouble(sym, SYMBOL_BID);  cmd = ORDER_TYPE_SELL; }

    double sl_dist = atr * SL_ATR_Mult;
    double sl = (cmd == ORDER_TYPE_BUY) ? price - sl_dist : price + sl_dist;
    double tp = (cmd == ORDER_TYPE_BUY) ? price + sl_dist * TP_R_Multiple
                                        : price - sl_dist * TP_R_Multiple;

    double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
    double risk_amt = equity * (Risk_Per_Trade_Pct / 100.0);
    double ps       = (StringFind(sym, "JPY") >= 0) ? 0.01 : 0.0001;
    double tv       = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
    double ts_val   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
    double pv       = (ts_val > 0) ? tv / ts_val * ps : 0.0;
    double sl_pips  = sl_dist / ps;
    double lots     = 0.01;
    if (pv > 0 && sl_pips > 0) lots = MathFloor((risk_amt / (sl_pips * pv)) * 100) / 100.0;
    double min_lot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
    double max_lot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
    lots = MathMax(min_lot, MathMin(lots, max_lot));

    double spread = SymbolInfoInteger(sym, SYMBOL_SPREAD) * SymbolInfoDouble(sym, SYMBOL_POINT);
    if (spread > ps * 4) { if (Debug) Print("[Executor] Spread wide ", sym); return; }

    MqlTradeRequest req = {}; MqlTradeResult res = {};
    req.action       = TRADE_ACTION_DEAL;
    req.symbol       = sym;
    req.volume       = lots;
    req.type         = cmd;
    req.price        = price;
    req.sl           = sl;
    req.tp           = tp;
    req.deviation    = Slippage;
    req.magic        = Magic_Number;
    req.comment      = "V19_" + dir;
    req.type_filling = GetFilling(sym);

    if (!OrderSend(req, res)) {
        Print("[Executor] OrderSend failed ", sym, " err=", GetLastError(),
              " retcode=", res.retcode);
        return;
    }

    ulong ticket = res.order; // position ticket = opening order ticket
    MarkOpenedSymbol(sym);
    SaveSlDist(sym, sl_dist);
    SaveOrigLot(sym, lots);       // V19.1: stage-1/2 closes are a % of this
    ClearExitStage(sym);          // fresh position → stage 0

    string msg = StringFormat("[Trade OPEN] %s %s | lots=%.2f price=%.5f SL=%.5f TP=%.5f"
                              " (%.1fR) atr=%.5f risk=%.1f%% ticket=%lld",
                              dir, sym, lots, price, sl, tp, TP_R_Multiple, atr,
                              Risk_Per_Trade_Pct, (long)ticket);
    if (Debug) Print(msg); SendTelegram(msg);
    NotifyBackend(ticket, sym, dir, price, sl, tp, lots, equity, risk_amt, atr,
                  sc, rsi, adx, dip, dim, e50, e200);
}

// ── Trade management ──────────────────────────────────────────────────
// Close `close_lot` of an open position at market. Returns true on send OK.
bool ClosePartOfPosition(ulong ticket, string sym, ENUM_POSITION_TYPE pos_type,
                         double cur, double close_lot) {
    MqlTradeRequest req = {}; MqlTradeResult res = {};
    req.action       = TRADE_ACTION_DEAL;
    req.position     = ticket;
    req.symbol       = sym;
    req.volume       = close_lot;
    req.type         = (pos_type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
    req.price        = cur;
    req.deviation    = Slippage;
    req.magic        = Magic_Number;
    req.type_filling = GetFilling(sym);
    return OrderSend(req, res);
}

// V19.1 staged exit ladder (memo §3–§6):
//   r >= BE_Trigger_R  → SL to break-even (+ BE_Buffer_Pips, + live spread if BE_Cost_Buffer)
//   stage 0, r >= TP1_R → close TP1_Close_Pct% of ORIGINAL lot, SL→BE,  stage=1
//   stage 1, r >= TP2_R → close TP2_Close_Pct% of ORIGINAL lot, SL→+1R, stage=2
//   stage 2 (runner)    → ATR trail (Runner_Trail_ATR_Mult) blended with step-SL,
//                         plus the ADX/EMA10-20 trend-weakening tighten / full close
//                         and TP-extend (all carried over from v1.12).
void ManageOpenTrades() {
    for (int i = PositionsTotal()-1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetInteger(POSITION_MAGIC) != Magic_Number) continue;

        string sym  = PositionGetString(POSITION_SYMBOL);
        ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        bool   is_buy = (pos_type == POSITION_TYPE_BUY);
        double entry = PositionGetDouble(POSITION_PRICE_OPEN);
        double sl    = PositionGetDouble(POSITION_SL);
        double tp    = PositionGetDouble(POSITION_TP);
        double lots  = PositionGetDouble(POSITION_VOLUME);
        double cur   = is_buy ? SymbolInfoDouble(sym, SYMBOL_BID)
                              : SymbolInfoDouble(sym, SYMBOL_ASK);

        double sl_dist_cur = MathAbs(entry - sl);
        if (sl_dist_cur == 0) continue;
        double sl_dist = LoadSlDist(sym, sl_dist_cur);
        double r  = is_buy ? (cur - entry) / sl_dist : (entry - cur) / sl_dist;
        double ps = (StringFind(sym, "JPY") >= 0) ? 0.01 : 0.0001;
        double min_lot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
        double lot_step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
        if (lot_step <= 0) lot_step = 0.01;
        double orig_lot = LoadOrigLot(sym, lots);
        int    stage    = GetExitStage(sym);

        // ── Break-even (memo §5 / §18) ─────────────────────────────
        double spread_px = SymbolInfoInteger(sym, SYMBOL_SPREAD) * SymbolInfoDouble(sym, SYMBOL_POINT);
        double be_buffer = ps * BE_Buffer_Pips + (BE_Cost_Buffer ? spread_px : 0.0);
        double be_sl = is_buy ? entry + be_buffer : entry - be_buffer;
        bool be_set  = is_buy ? (sl >= be_sl - ps * 0.1) : (sl <= be_sl + ps * 0.1);
        // guard: only (re)set BE when it actually improves SL by > 0.3 pip — avoids
        // per-tick SL churn as the live spread wobbles the buffer.
        bool be_improves = is_buy ? (be_sl > sl + ps * 0.3) : (be_sl < sl - ps * 0.3);
        if (r >= BE_Trigger_R && !be_set && be_improves) {
            if (ModifySLTP(ticket, sym, be_sl, tp)) {
                sl = be_sl; be_set = true;
                if (Debug) Print("[Mgr] BE ticket=", ticket, " SL=", DoubleToString(be_sl, 5));
            }
        }

        // ── Stage 1 — scale out TP1% at +TP1_R, lock SL at BE ──────
        if (stage == 0 && r >= TP1_R) {
            double want = MathFloor(orig_lot * (TP1_Close_Pct / 100.0) / lot_step) * lot_step;
            want = MathMin(want, lots - min_lot);            // keep a tradeable remainder
            if (want >= min_lot && ClosePartOfPosition(ticket, sym, pos_type, cur, want)) {
                SetExitStage(sym, 1); stage = 1;
                if (PositionSelectByTicket(ticket)) {
                    sl = PositionGetDouble(POSITION_SL); tp = PositionGetDouble(POSITION_TP);
                    lots = PositionGetDouble(POSITION_VOLUME);
                }
                if (!be_set && ModifySLTP(ticket, sym, be_sl, tp)) sl = be_sl;
                string m = StringFormat("[Trade PARTIAL 1/2] %s ticket=%lld -%.2f @%.5f (+%.2fR) SL->BE",
                                        sym, (long)ticket, want, cur, r);
                if (Debug) Print(m); SendTelegram(m);
            } else {
                SetExitStage(sym, 1); stage = 1;            // lot too small to split — just advance
                if (want < min_lot && Debug) Print("[Mgr] Stage1 skip close (lot too small) ", sym);
                else if (Debug) Print("[Mgr] Stage1 partial failed ", sym, " err=", GetLastError());
            }
        }

        // ── Stage 2 — scale out TP2% at +TP2_R, SL → +1R ───────────
        if (stage == 1 && r >= TP2_R) {
            double want  = MathFloor(orig_lot * (TP2_Close_Pct / 100.0) / lot_step) * lot_step;
            want = MathMin(want, lots - min_lot);
            double sl_1r = is_buy ? entry + sl_dist : entry - sl_dist;
            bool closed = (want >= min_lot && ClosePartOfPosition(ticket, sym, pos_type, cur, want));
            if (closed || want < min_lot) {
                SetExitStage(sym, 2); stage = 2;
                if (PositionSelectByTicket(ticket)) {
                    sl = PositionGetDouble(POSITION_SL); tp = PositionGetDouble(POSITION_TP);
                    lots = PositionGetDouble(POSITION_VOLUME);
                }
                bool sl_ok = is_buy ? (sl_1r > sl) : (sl_1r < sl || sl == 0);
                if (sl_ok && ModifySLTP(ticket, sym, sl_1r, tp)) sl = sl_1r;
                if (closed) {
                    string m = StringFormat("[Trade PARTIAL 2/2] %s ticket=%lld -%.2f @%.5f (+%.2fR) SL->+1R runner=%.2f",
                                            sym, (long)ticket, want, cur, r, lots);
                    if (Debug) Print(m); SendTelegram(m);
                } else if (Debug) Print("[Mgr] Stage2 skip close (lot too small), SL->+1R ", sym);
            } else if (Debug) {
                Print("[Mgr] Stage2 partial failed ", sym, " err=", GetLastError());
            }
        }

        // ── Runner (stage 2) — ATR trail + trend-weakening exit ────
        if (stage == 2 && r >= Runner_Trail_Start_R) {
            if (PositionSelectByTicket(ticket)) {
                sl = PositionGetDouble(POSITION_SL); tp = PositionGetDouble(POSITION_TP);
                lots = PositionGetDouble(POSITION_VOLUME);
            }
            double atr_cur = GetATR(sym, 0);

            double adx_cur    = GetADX(sym, 0);
            double ema10_cur  = GetMA(ma10_handles, sym, 0);
            double ema20_cur  = GetMA(ma20_handles, sym, 0);
            double ema10_prev = GetMA(ma10_handles, sym, 1);
            double ema20_prev = GetMA(ma20_handles, sym, 1);

            bool ema_cross_back = is_buy
                ? (ema10_prev >= ema20_prev) && (ema10_cur < ema20_cur)
                : (ema10_prev <= ema20_prev) && (ema10_cur > ema20_cur);
            bool adx_weak  = adx_cur < 25.0;
            bool adx_dying = adx_cur < 20.0;

            // Case 1: ADX<20 AND EMA cross-back at >=3R → close the runner
            if (adx_dying && ema_cross_back && r >= 3.0) {
                if (ClosePartOfPosition(ticket, sym, pos_type, cur, lots)) {
                    string m = StringFormat("[Mgr] RUNNER CLOSE %s ticket=%lld r=%.2f ADX=%.1f EMA-crossback",
                                            sym, (long)ticket, r, adx_cur);
                    if (Debug) Print(m); SendTelegram(m);
                }
                continue;
            }

            // Case 2: ADX<25 OR EMA cross-back → tighten the trail to ATR×0.5
            double trail_mult = Runner_Trail_ATR_Mult;
            if (adx_weak || ema_cross_back) {
                trail_mult = 0.5;
                if (Debug) Print("[Mgr] Tighten trail ATR x0.5 ticket=", ticket,
                                 " ADX=", DoubleToString(adx_cur, 1), " xback=", ema_cross_back);
            }

            int r_floor = (int)MathFloor(r);
            int r_min   = (int)MathCeil(TP2_R);
            if (r_floor < r_min) r_floor = r_min;
            double step_sl = is_buy ? entry + (r_floor - 1) * sl_dist
                                    : entry - (r_floor - 1) * sl_dist;
            double atr_sl  = (atr_cur > 0)
                              ? (is_buy ? cur - atr_cur * trail_mult : cur + atr_cur * trail_mult)
                              : step_sl;
            double target_sl = is_buy ? MathMax(step_sl, atr_sl) : MathMin(step_sl, atr_sl);

            bool should_move = is_buy ? (target_sl > sl) : (target_sl < sl || sl == 0);
            if (should_move && ModifySLTP(ticket, sym, target_sl, tp)) {
                sl = target_sl;
                if (Debug) Print("[Mgr] Trail ticket=", ticket, " r=", DoubleToString(r, 2),
                                 " -> SL=", DoubleToString(target_sl, 5),
                                 " (mult=", DoubleToString(trail_mult, 1), ")");
            }

            // TP extend — keep the runner's TP ahead of price
            double new_tp = is_buy ? entry + (r_floor + 1) * sl_dist
                                   : entry - (r_floor + 1) * sl_dist;
            bool tp_behind = is_buy ? (cur >= tp - ps) : (cur <= tp + ps);
            if (tp_behind && MathAbs(new_tp - tp) > ps && ModifySLTP(ticket, sym, sl, new_tp)) {
                if (Debug) Print("[Mgr] TP extended ticket=", ticket, " new_tp=", DoubleToString(new_tp, 5));
            }
        }
    }
}

// ── Circuit breaker protection ────────────────────────────────────────
void Level2ProtectTrades() {
    for (int i = PositionsTotal()-1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetInteger(POSITION_MAGIC) != Magic_Number) continue;

        string sym   = PositionGetString(POSITION_SYMBOL);
        ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double entry = PositionGetDouble(POSITION_PRICE_OPEN);
        double sl    = PositionGetDouble(POSITION_SL);
        double tp    = PositionGetDouble(POSITION_TP);
        double lots  = PositionGetDouble(POSITION_VOLUME);
        double pnl   = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        double cur   = (pos_type == POSITION_TYPE_BUY) ?
                       SymbolInfoDouble(sym, SYMBOL_BID) :
                       SymbolInfoDouble(sym, SYMBOL_ASK);

        if (pnl < 0) {
            MqlTradeRequest req = {}; MqlTradeResult res = {};
            req.action       = TRADE_ACTION_DEAL;
            req.position     = ticket;
            req.symbol       = sym;
            req.volume       = lots;
            req.type         = (pos_type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
            req.price        = cur;
            req.deviation    = Slippage;
            req.magic        = Magic_Number;
            req.type_filling = GetFilling(sym);
            if (OrderSend(req, res)) {
                string msg = StringFormat("[CB-L2] Closed loser ticket=%lld %s pnl=%.2f",
                                          (long)ticket, sym, pnl);
                Print(msg); SendTelegram(msg);
            }
            continue;
        }
        // memo §5: do NOT move to BE before +BE_Trigger_R even in defensive mode —
        // an early BE just gets stopped out on a normal retracement while the trend
        // continues without us. Winners below that R keep their original SL; the L3
        // circuit breaker still closes everything if the drawdown deepens.
        double ps = (StringFind(sym, "JPY") >= 0) ? 0.01 : 0.0001;
        double sl_dist = LoadSlDist(sym, MathAbs(entry - sl));
        double r = (sl_dist > 0)
                   ? ((pos_type == POSITION_TYPE_BUY) ? (cur - entry) / sl_dist
                                                       : (entry - cur) / sl_dist)
                   : 0.0;
        if (r < BE_Trigger_R) continue;

        double spread_px = SymbolInfoInteger(sym, SYMBOL_SPREAD) * SymbolInfoDouble(sym, SYMBOL_POINT);
        double be_buffer = ps * BE_Buffer_Pips + (BE_Cost_Buffer ? spread_px : 0.0);
        double be_sl = (pos_type == POSITION_TYPE_BUY) ? entry + be_buffer : entry - be_buffer;
        bool be_set = (pos_type == POSITION_TYPE_BUY) ?
                      (sl >= be_sl - ps * 0.1) : (sl <= be_sl + ps * 0.1);
        if (!be_set)
            if (ModifySLTP(ticket, sym, be_sl, tp) && Debug)
                Print("[CB-L2] BE set ticket=", ticket, " r=", DoubleToString(r, 2));
    }
}

void CloseAllPositions(string reason) {
    for (int i = PositionsTotal()-1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetInteger(POSITION_MAGIC) != Magic_Number) continue;

        string sym   = PositionGetString(POSITION_SYMBOL);
        ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double entry = PositionGetDouble(POSITION_PRICE_OPEN);
        double sl    = PositionGetDouble(POSITION_SL);
        double tp    = PositionGetDouble(POSITION_TP);
        double lots  = PositionGetDouble(POSITION_VOLUME);
        double pnl   = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        double cur   = (pos_type == POSITION_TYPE_BUY) ?
                       SymbolInfoDouble(sym, SYMBOL_BID) :
                       SymbolInfoDouble(sym, SYMBOL_ASK);

        if (pnl < 0) {
            MqlTradeRequest req = {}; MqlTradeResult res = {};
            req.action       = TRADE_ACTION_DEAL;
            req.position     = ticket;
            req.symbol       = sym;
            req.volume       = lots;
            req.type         = (pos_type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
            req.price        = cur;
            req.deviation    = Slippage;
            req.magic        = Magic_Number;
            req.type_filling = GetFilling(sym);
            if (OrderSend(req, res)) {
                string msg = StringFormat("[Trade CLOSE] ticket=%lld %s reason=%s (loss=%.2f)",
                                          (long)ticket, sym, reason, pnl);
                if (Debug) Print(msg); SendTelegram(msg);
            } else if (Debug)
                Print("[Trade CLOSE] failed ticket=", ticket, " err=", GetLastError());
        } else {
            double sl_dist = MathAbs(entry - sl);
            // FIX B (v1.11): explicit shift=0 (current/live bar) — matches MT4's
            // iATR(sym,60,14,0) in the same function.
            double atr = GetATR(sym, 0);
            double buf = MathMax(sl_dist * 0.20, atr * 0.3);
            buf = MathMin(buf, atr * 2.0);
            double new_sl = (pos_type == POSITION_TYPE_BUY) ? cur - buf : cur + buf;
            if (ModifySLTP(ticket, sym, new_sl, tp)) {
                double pct = sl_dist > 0 ? (sl_dist - buf) / sl_dist * 100 : 0;
                string msg = StringFormat("[Trade LOCK] ticket=%lld %s SL=%.5f (~%.0f%% locked) reason=%s",
                                          (long)ticket, sym, new_sl, pct, reason);
                if (Debug) Print(msg); SendTelegram(msg);
            }
        }
    }
}

// ── Detect and report closed trades ──────────────────────────────────
// In MT5, partial closes do NOT create a new ticket (unlike MT4).
// So we wait until the position is fully gone before reporting to backend.
// We aggregate P&L from ALL DEAL_ENTRY_OUT deals for the position.
void DetectAndReportClosedTrades() {
    datetime from = TimeCurrent() - 604800; // 1 week look-back
    HistorySelect(from, TimeCurrent());
    int total = HistoryDealsTotal();

    for (int i = total - 1; i >= 0; i--) {
        ulong deal_ticket = HistoryDealGetTicket(i);
        if (deal_ticket == 0) continue;
        if (HistoryDealGetInteger(deal_ticket, DEAL_MAGIC) != Magic_Number) continue;
        if (HistoryDealGetInteger(deal_ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

        ulong pos_id = (ulong)HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
        if (IsReportedClosed(pos_id)) continue;

        datetime close_time = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);
        if (close_time == 0) continue;
        if (TimeCurrent() - close_time > 604800) { MarkReportedClosed(pos_id); continue; }

        // Skip if position still open (partial close scenario — wait for full close)
        if (PositionSelectByTicket(pos_id)) continue;

        string sym = HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
        if (!HasOpenPosition(sym)) {
            ClearExitStage(sym); ClearOrigLot(sym); ClearOpenedSymbol(sym); ClearSlDist(sym);
        }

        // Aggregate ALL out-deals for this position (handles partial closes)
        double total_profit = 0, total_commission = 0, total_swap = 0;
        double last_price = 0;
        datetime last_time = 0;
        long last_reason = DEAL_REASON_CLIENT;

        for (int j = 0; j < total; j++) {
            ulong d = HistoryDealGetTicket(j);
            if ((ulong)HistoryDealGetInteger(d, DEAL_POSITION_ID) != pos_id) continue;
            if (HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
            total_profit     += HistoryDealGetDouble(d, DEAL_PROFIT);
            total_commission += HistoryDealGetDouble(d, DEAL_COMMISSION);
            total_swap       += HistoryDealGetDouble(d, DEAL_SWAP);
            datetime dt = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
            if (dt >= last_time) {
                last_time   = dt;
                last_price  = HistoryDealGetDouble(d, DEAL_PRICE);
                last_reason = HistoryDealGetInteger(d, DEAL_REASON);
            }
        }

        string reason = "MANUAL";
        if (last_reason == DEAL_REASON_SL) reason = "SL";
        else if (last_reason == DEAL_REASON_TP) reason = "TP";

        string body = StringFormat(
            "{\"exit_price\":%.6f,\"commission\":%.2f,\"swap\":%.2f,\"profit\":%.2f,"
            "\"exit_reason\":\"%s\",\"closed_at\":\"%s\",\"account_equity\":%.2f}",
            last_price, total_commission, total_swap, total_profit,
            reason, FormatISO8601(ServerToGMT(last_time)), AccountInfoDouble(ACCOUNT_EQUITY));

        string url = FastAPI_Base + "/trades/close/by-ticket/" + IntegerToString((long)pos_id);
        uchar post_data[], result[]; string rh;
        StringToCharArray(body, post_data, 0, StringLen(body));
        int res = WebRequest("POST", url, POSTHeaders(), 5000, post_data, result, rh);

        if (res == 200 || res == 404) {
            MarkReportedClosed(pos_id);
            if (Debug) Print("[Executor] Close reported ticket=", pos_id,
                             " reason=", reason, " HTTP=", res);
        } else {
            if (Debug) Print("[Executor] Close report failed ticket=", pos_id, " HTTP=", res);
        }
    }
}

// ── Notify backend of new open trade ─────────────────────────────────
void NotifyBackend(ulong ticket, string sym, string dir,
                   double price, double sl, double tp, double lots,
                   double equity, double risk_amt, double atr,
                   int sc, double rsi, double adx, double dip, double dim,
                   double e50, double e200) {
    string body = StringFormat(
        "{\"ticket\":%lld,\"symbol\":\"%s\",\"direction\":\"%s\","
        "\"entry_price\":%.6f,\"stop_loss\":%.6f,\"take_profit\":%.6f,"
        "\"lot_size\":%.2f,\"account_equity\":%.2f,\"risk_amount\":%.2f,"
        "\"atr_at_entry\":%.6f,\"session\":\"%s\","
        "\"signal_score\":%d,\"signal_rsi\":%.4f,\"signal_adx\":%.4f,"
        "\"signal_di_plus\":%.4f,\"signal_di_minus\":%.4f,"
        "\"signal_ema50\":%.6f,\"signal_ema200\":%.6f}",
        (long)ticket, sym, dir, price, sl, tp, lots, equity, risk_amt, atr, GetSession(),
        sc, rsi, adx, dip, dim, e50, e200);
    string url = FastAPI_Base + "/trades/open";
    uchar post_data[], result[]; string rh;
    StringToCharArray(body, post_data, 0, StringLen(body));
    int res = WebRequest("POST", url, POSTHeaders(), 5000, post_data, result, rh);
    if (Debug) Print("[Executor] NotifyBackend HTTP=", res);
}

// ── Telegram ──────────────────────────────────────────────────────────
void SendTelegram(string message) {
    if (StringLen(Telegram_Token) == 0 || StringLen(Telegram_Chat_ID) == 0) return;
    string url = "https://api.telegram.org/bot" + Telegram_Token +
                 "/sendMessage?chat_id=" + Telegram_Chat_ID + "&text=" + message;
    uchar dummy[], result[]; string rh;
    WebRequest("GET", url, "", 5000, dummy, result, rh);
}
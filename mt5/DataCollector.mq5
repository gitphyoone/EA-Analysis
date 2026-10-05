//+------------------------------------------------------------------+
//| V19 FX Prop Desk — MT5 Data Collector v1.02                     |
//| Ported from MT4 DataCollector v1.00                             |
//| Collects H1 OHLCV + EMA10/20/50/200, RSI14, ADX14, ATR14       |
//| Sends to FastAPI via WebRequest                                  |
//|                                                                  |
//| MQL4→MQL5 changes:                                              |
//|  - iMA/iRSI/iADX/iATR → handles created in OnInit + CopyBuffer |
//|  - iOpen/iHigh/etc → CopyOpen/High/Low/Close                    |
//|  - iVolume → CopyTickVolume                                      |
//|  - AccountEquity/Balance → AccountInfoDouble                    |
//|  - char[] → uchar[] for WebRequest                              |
//|  - %I64d → %lld for long                                        |
//| v1.01 — MT4/MT5 logic-parity fixes:                             |
//|  - FIX C: ema50_prev/ema200_prev fields added. MT4's collector  |
//|    sends these (shift=2 EMA reads) specifically so the backend  |
//|    SignalEngine's ema_slope filter can score EMA50/200          |
//|    rising/falling. Without them, SignalEngine.evaluate() treats |
//|    ema50_prev/ema200_prev as missing and silently skips the     |
//|    slope filter (no penalty) for every MT5-sourced symbol —     |
//|    no new indicator handle needed, ema50/ema200 handles already |
//|    created in OnInit are just read at shift=2 instead of 1.     |
//|  - FIX D: CollectOnTick input added to match MT4's on/off       |
//|    toggle. MT5's OnTick() previously called CollectAll()        |
//|    unconditionally with no way to disable it.                   |
//|  - RESOLVED (v1.02): Symbol_List "USDJPY" vs MT4 "USDJPY.y" —   |
//|    confirmed this broker's Market Watch symbol is plain         |
//|    "USDJPY" (no suffix), so no mismatch. USDJPY removed from    |
//|    Symbol_List anyway — backtest (chat, 2026-10) showed it's a  |
//|    net-negative pair for V19's signal engine regardless of      |
//|    symbol-name correctness (score=9 USDJPY trades were the      |
//|    worst-performing bucket, not just low-score ones).           |
//| v1.02 — H1/H4 logic-parity fix:                                  |
//|  - FIX F: market_data.timeframe was hardcoded to the literal     |
//|    "H1" in CollectAndSend()'s JSON body, ignoring the Timeframe  |
//|    input entirely. A second instance of this EA attached with   |
//|    Timeframe=PERIOD_H4 (for the TradeExecutor H4 instance) was   |
//|    silently mislabeling its candles as "H1" in the backend —     |
//|    routers/signals.py's evaluate_signal() queries               |
//|    MarketData.timeframe=="H4" for the H4 TradeExecutor instance, |
//|    which would find nothing (404) or, worse, find H1 rows if a   |
//|    naive query omitted the filter. Added TFToString() (ported    |
//|    from TradeExecutor.mq5) and now send TFToString(Timeframe)    |
//|    instead of the "H1" literal. To run an H4 collector instance  |
//|    alongside H1: attach this EA to a second chart with           |
//|    Timeframe=PERIOD_H4 — Symbol_List can stay the same.          |
//+------------------------------------------------------------------+
#property copyright "V19 FX Prop Desk"
#property version   "1.02"

// ── Inputs ──────────────────────────────────────────────────────────
input string             FastAPI_URL        = "http://127.0.0.1/data/candle";
input string             FastAPI_AccountURL = "http://127.0.0.1/data/account";
input string             API_Key            = "f9e369ad5592a0dcd33c78c4e33bd382";
input string              Symbol_List        = "EURUSD,GBPUSD,AUDUSD,USDCAD,GBPJPY,NZDUSD,USDCHF,EURGBP";  // FIX (chat, 2026-10): USDJPY removed — net-negative pair
input ENUM_TIMEFRAMES    Timeframe          = PERIOD_H1;
input bool               CollectOnTick      = true;   // FIX D (v1.01): matches MT4's toggle
input bool               Debug              = true;

// ── State ────────────────────────────────────────────────────────────
string   symbols[];
int      num_symbols = 0;
datetime last_bar_time[];

// Indicator handles — one per symbol
int h_ema10[];
int h_ema20[];
int h_ema50[];
int h_ema200[];
int h_rsi[];
int h_adx[];   // buffers: 0=ADX, 1=+DI, 2=-DI
int h_atr[];

// ── Helpers ───────────────────────────────────────────────────────────
string FormatTimestamp(datetime dt) {
    string s = TimeToString(dt, TIME_DATE|TIME_SECONDS);
    StringReplace(s, ".", "-");
    StringReplace(s, ".", "-");
    StringReplace(s, " ", "T");
    return s;
}
double GetBuf(int handle, int buf_idx, int shift) {
    if (handle == INVALID_HANDLE) return 0.0;
    double buf[1];
    if (CopyBuffer(handle, buf_idx, shift, 1, buf) != 1) return 0.0;
    return buf[0];
}
// FIX F (v1.02): ported from TradeExecutor.mq5 — maps Timeframe input to the
// string the backend's market_data.timeframe column expects, so an H4
// collector instance no longer mislabels its candles as "H1".
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

// ── OnInit ────────────────────────────────────────────────────────────
int OnInit() {
    string raw = Symbol_List;
    StringReplace(raw, " ", "");
    string tmp[];
    int n = StringSplit(raw, ',', tmp);
    ArrayResize(symbols,       n);
    ArrayResize(last_bar_time, n);
    ArrayResize(h_ema10,       n);
    ArrayResize(h_ema20,       n);
    ArrayResize(h_ema50,       n);
    ArrayResize(h_ema200,      n);
    ArrayResize(h_rsi,         n);
    ArrayResize(h_adx,         n);
    ArrayResize(h_atr,         n);

    for (int i = 0; i < n; i++) {
        symbols[i]       = tmp[i];
        last_bar_time[i] = 0;
        h_ema10[i]  = iMA(symbols[i],  Timeframe, 10,  0, MODE_EMA, PRICE_CLOSE);
        h_ema20[i]  = iMA(symbols[i],  Timeframe, 20,  0, MODE_EMA, PRICE_CLOSE);
        h_ema50[i]  = iMA(symbols[i],  Timeframe, 50,  0, MODE_EMA, PRICE_CLOSE);
        h_ema200[i] = iMA(symbols[i],  Timeframe, 200, 0, MODE_EMA, PRICE_CLOSE);
        h_rsi[i]    = iRSI(symbols[i], Timeframe, 14, PRICE_CLOSE);
        h_adx[i]    = iADX(symbols[i], Timeframe, 14);
        h_atr[i]    = iATR(symbols[i], Timeframe, 14);

        if (h_ema10[i]  == INVALID_HANDLE || h_ema20[i]  == INVALID_HANDLE ||
            h_ema50[i]  == INVALID_HANDLE || h_ema200[i] == INVALID_HANDLE ||
            h_rsi[i]    == INVALID_HANDLE || h_adx[i]    == INVALID_HANDLE ||
            h_atr[i]    == INVALID_HANDLE)
            Print("[DataCollector] WARNING: handle creation failed for ", symbols[i]);
    }
    num_symbols = n;
    EventSetTimer(60);
    Print("[DataCollector MT5 v1.02] Initialized | symbols=", Symbol_List,
          " | timeframe=", TFToString(Timeframe),
          " | CollectOnTick=", CollectOnTick);
    return INIT_SUCCEEDED;
}

// ── OnDeinit ──────────────────────────────────────────────────────────
void OnDeinit(const int reason) {
    EventKillTimer();
    for (int i = 0; i < num_symbols; i++) {
        if (h_ema10[i]  != INVALID_HANDLE) IndicatorRelease(h_ema10[i]);
        if (h_ema20[i]  != INVALID_HANDLE) IndicatorRelease(h_ema20[i]);
        if (h_ema50[i]  != INVALID_HANDLE) IndicatorRelease(h_ema50[i]);
        if (h_ema200[i] != INVALID_HANDLE) IndicatorRelease(h_ema200[i]);
        if (h_rsi[i]    != INVALID_HANDLE) IndicatorRelease(h_rsi[i]);
        if (h_adx[i]    != INVALID_HANDLE) IndicatorRelease(h_adx[i]);
        if (h_atr[i]    != INVALID_HANDLE) IndicatorRelease(h_atr[i]);
    }
}

// ── Timer and tick ────────────────────────────────────────────────────
void OnTimer() {
    CollectAll();
    SendAccountSnapshot();
}

// FIX D (v1.01): CollectOnTick toggle now respected, matching MT4's
// "input int CollectOnTick" behavior (previously always collected).
void OnTick() {
    if (CollectOnTick) CollectAll();
}

// ── Main collection ───────────────────────────────────────────────────
void CollectAll() {
    for (int i = 0; i < num_symbols; i++) {
        string sym = symbols[i];
        datetime bar0 = iTime(sym, Timeframe, 0);
        if (bar0 <= last_bar_time[i]) continue;  // same bar, skip
        last_bar_time[i] = bar0;
        CollectAndSend(i, sym);
    }
}

void CollectAndSend(int idx, string sym) {
    // OHLCV for bar 1 (last fully closed bar — no repaint)
    double open_buf[1], high_buf[1], low_buf[1], close_buf[1];
    long   vol_buf[1];
    datetime time_buf[1];

    if (CopyOpen (sym, Timeframe, 1, 1, open_buf)  != 1) { Print("[DC] CopyOpen fail ", sym);  return; }
    if (CopyHigh (sym, Timeframe, 1, 1, high_buf)  != 1) { Print("[DC] CopyHigh fail ", sym);  return; }
    if (CopyLow  (sym, Timeframe, 1, 1, low_buf)   != 1) { Print("[DC] CopyLow fail ", sym);   return; }
    if (CopyClose(sym, Timeframe, 1, 1, close_buf) != 1) { Print("[DC] CopyClose fail ", sym); return; }
    if (CopyTickVolume(sym, Timeframe, 1, 1, vol_buf) != 1) vol_buf[0] = 0;
    if (CopyTime(sym, Timeframe, 1, 1, time_buf) != 1) { Print("[DC] CopyTime fail ", sym); return; }

    // Indicators at bar 1 (last closed bar)
    double ema10  = GetBuf(h_ema10[idx],  0, 1);
    double ema20  = GetBuf(h_ema20[idx],  0, 1);
    double ema50  = GetBuf(h_ema50[idx],  0, 1);
    double ema200 = GetBuf(h_ema200[idx], 0, 1);
    // FIX C (v1.01): ema50_prev/ema200_prev at bar 2 — required by backend
    // SignalEngine's ema_slope filter (rising/falling check). Reuses the
    // existing h_ema50/h_ema200 handles at shift=2, no new handle needed.
    double ema50_prev  = GetBuf(h_ema50[idx],  0, 2);
    double ema200_prev = GetBuf(h_ema200[idx], 0, 2);
    double rsi    = GetBuf(h_rsi[idx],    0, 1);
    double adx    = GetBuf(h_adx[idx],    0, 1);  // buffer 0 = ADX main
    double di_p   = GetBuf(h_adx[idx],    1, 1);  // buffer 1 = +DI
    double di_m   = GetBuf(h_adx[idx],    2, 1);  // buffer 2 = -DI
    double atr    = GetBuf(h_atr[idx],    0, 1);

    string body = StringFormat(
        "{"
        "\"symbol\":\"%s\","
        "\"timeframe\":\"%s\","                                 // FIX F (v1.02): was hardcoded "H1"
        "\"timestamp\":\"%s\","
        "\"open\":%.6f,"
        "\"high\":%.6f,"
        "\"low\":%.6f,"
        "\"close\":%.6f,"
        "\"volume\":%lld,"
        "\"ema10\":%.6f,"
        "\"ema20\":%.6f,"
        "\"ema50\":%.6f,"
        "\"ema200\":%.6f,"
        "\"ema50_prev\":%.6f,"
        "\"ema200_prev\":%.6f,"
        "\"rsi14\":%.4f,"
        "\"adx14\":%.4f,"
        "\"di_plus\":%.4f,"
        "\"di_minus\":%.4f,"
        "\"atr14\":%.6f"
        "}",
        sym,
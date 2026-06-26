//+------------------------------------------------------------------+
//| V19 FX Prop Desk — MT4 Data Collector                           |
//| Collects H1 OHLCV + EMA50/200, RSI14, ADX14 (DI+/DI-), ATR14  |
//| and sends to FastAPI via WebRequest()                            |
//+------------------------------------------------------------------+
#property copyright "V19 FX Prop Desk"
#property version   "1.00"
#property strict

// ── Inputs ──────────────────────────────────────────────────────────
input string   FastAPI_URL      = "http://127.0.0.1/data/candle";
input string   FastAPI_AccountURL = "http://127.0.0.1/data/account";
input string   API_Key          = "f9e369ad5592a0dcd33c78c4e33bd382";
input string   Symbol_List      = "EURUSD,GBPUSD,USDJPY.y,AUDUSD,USDCAD,GBPJPY";
input int      Timeframe        = 60;          // 60 = H1
input int      CollectOnTick    = 1;           // send on every new bar
input bool     Debug            = true;

// ── State ────────────────────────────────────────────────────────────
datetime last_bar_time[];
string   symbols[];
int      num_symbols = 0;

// ── Timestamp formatter ──────────────────────────────────────────────
// Converts "2026.06.11 07:00:00" → "2026-06-11T07:00:00"
// Backend requires ISO 8601 format with dash separators
string FormatTimestamp(datetime dt) {
    string s = TimeToString(dt, TIME_DATE|TIME_SECONDS);
    StringReplace(s, ".", "-");   // 2026.06.11 → 2026-06-11 (first dot)
    StringReplace(s, ".", "-");   // second dot
    StringReplace(s, " ", "T");   // space → T
    return s;
}

int OnInit() {
    string raw = Symbol_List;
    StringReplace(raw, " ", "");
    string tmp[];
    int n = StringSplit(raw, ',', tmp);
    ArrayResize(symbols, n);
    ArrayResize(last_bar_time, n);
    for (int i = 0; i < n; i++) {
        symbols[i] = tmp[i];
        last_bar_time[i] = 0;
    }
    num_symbols = n;
    EventSetTimer(60);
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer() {
    CollectAll();
    SendAccountSnapshot();
}

void OnTick() {
    if (CollectOnTick == 1)
        CollectAll();
}

void SendAccountSnapshot() {
    string body = StringFormat(
        "{\"equity\":%.2f,\"balance\":%.2f}",
        AccountEquity(),
        AccountBalance()
    );

    string headers = "Content-Type: application/json\r\n";
    if (StringLen(API_Key) > 0)
        headers += "X-API-Key: " + API_Key + "\r\n";

    char post_data[], result[];
    string result_headers;
    StringToCharArray(body, post_data, 0, StringLen(body));

    int res = WebRequest("POST", FastAPI_AccountURL, headers, 5000, post_data, result, result_headers);

    if (Debug) {
        if (res == 200)
            Print("[DataCollector] AccountSnapshot OK equity=", AccountEquity());
        else
            Print("[DataCollector] AccountSnapshot FAIL HTTP=", res, " body=", CharArrayToString(result));
    }
}

void CollectAll() {
    for (int i = 0; i < num_symbols; i++) {
        string sym = symbols[i];
        datetime bar0 = iTime(sym, Timeframe, 0);
        if (bar0 <= last_bar_time[i]) continue;    // same bar, skip
        last_bar_time[i] = bar0;
        CollectAndSend(sym, bar0);
    }
}

void CollectAndSend(string sym, datetime ts) {
    // OHLCV
    double o  = iOpen (sym, Timeframe, 1);
    double h  = iHigh (sym, Timeframe, 1);
    double l  = iLow  (sym, Timeframe, 1);
    double c  = iClose(sym, Timeframe, 1);
    long   v  = iVolume(sym, Timeframe, 1);

    // Indicators (bar 1 = closed bar — confirmed, no repaint)
    double ema10  = iMA(sym, Timeframe, 10,  0, MODE_EMA, PRICE_CLOSE, 1);
    double ema20  = iMA(sym, Timeframe, 20,  0, MODE_EMA, PRICE_CLOSE, 1);
    double ema50  = iMA(sym, Timeframe, 50,  0, MODE_EMA, PRICE_CLOSE, 1);
    double ema200 = iMA(sym, Timeframe, 200, 0, MODE_EMA, PRICE_CLOSE, 1);
    double rsi    = iRSI(sym, Timeframe, 14, PRICE_CLOSE, 1);
    double adx    = iADX(sym, Timeframe, 14, PRICE_CLOSE, MODE_MAIN,    1);
    double di_p   = iADX(sym, Timeframe, 14, PRICE_CLOSE, MODE_PLUSDI,  1);
    double di_m   = iADX(sym, Timeframe, 14, PRICE_CLOSE, MODE_MINUSDI, 1);
    double atr    = iATR(sym, Timeframe, 14, 1);

    // Build JSON
    // FIX: FormatTimestamp() used instead of TimeToString()
    // TimeToString() returns "2026.06.11 07:00:00" (dot separator)
    // Backend expects "2026-06-11T07:00:00" (ISO 8601)
    string body = StringFormat(
        "{"
        "\"symbol\":\"%s\","
        "\"timeframe\":\"H1\","
        "\"timestamp\":\"%s\","
        "\"open\":%.6f,"
        "\"high\":%.6f,"
        "\"low\":%.6f,"
        "\"close\":%.6f,"
        "\"volume\":%I64d,"
        "\"ema10\":%.6f,"
        "\"ema20\":%.6f,"
        "\"ema50\":%.6f,"
        "\"ema200\":%.6f,"
        "\"rsi14\":%.4f,"
        "\"adx14\":%.4f,"
        "\"di_plus\":%.4f,"
        "\"di_minus\":%.4f,"
        "\"atr14\":%.6f"
        "}",
        sym,
        FormatTimestamp(iTime(sym, Timeframe, 1)),   // FIX: was TimeToString()
        o, h, l, c, v,
        ema10, ema20, ema50, ema200, rsi, adx, di_p, di_m, atr
    );

    string headers = "Content-Type: application/json\r\n";
    if (StringLen(API_Key) > 0)
        headers += "X-API-Key: " + API_Key + "\r\n";

    char   post_data[];
    char   result[];
    string result_headers;

    StringToCharArray(body, post_data, 0, StringLen(body));

    int res = WebRequest("POST", FastAPI_URL, headers, 5000, post_data, result, result_headers);

    if (Debug) {
        string resp = CharArrayToString(result);
        if (res == 201)
            Print("[DataCollector] OK ", sym, " | ", FormatTimestamp(iTime(sym, Timeframe, 1)));
        else
            Print("[DataCollector] FAIL ", sym, " HTTP=", res, " body=", resp);
    }
}
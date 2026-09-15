--------------------------------------------------------------------------------
-- Provider: Yahoo Finance (unofficial chart endpoint)
--
-- No API key, no registration. This endpoint is undocumented and Yahoo can
-- change it without notice -- their v7/quote endpoint started returning 401 in
-- 2025 -- so treat it as best-effort. For a supported contract use finnhub.lua.
--
-- One request per symbol: v7/quote used to allow batching, but now requires a
-- session crumb.
--------------------------------------------------------------------------------

-- Derive the package root from our own module name so the widget works
-- regardless of what the containing directory is called.
local ROOT = (...):match("^(.-)%.providers%.") or "awesomewm-stock-ticker"
local json = require(ROOT .. ".json")
local url  = require(ROOT .. ".url")

local P = { name = "yahoo", needs_key = false,
              quote_url = "https://finance.yahoo.com/quote/%s" }

--- Build the HTTP request for one symbol.
-- @tparam string symbol  e.g. "AAPL"
-- @tparam table opts     provider_options from the user config
-- @treturn table         { url = string, headers = { [name] = value } }
function P.request(symbol, opts)
    opts = opts or {}
    local host = opts.host or "https://query1.finance.yahoo.com"
    return {
        url = string.format("%s/v8/finance/chart/%s?interval=1d&range=1d",
                            host, url.encode(symbol)),
        -- Yahoo rejects requests without a browser-ish UA.
        headers = { ["User-Agent"] = opts.user_agent or "Mozilla/5.0" },
    }
end

local function num(v)
    if type(v) == "number" then return v end
    return nil
end

-- json.null is a table sentinel, so a plain truthiness check is not enough.
local function str(v)
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

--- Parse a response body into the standardised quote table.
-- @treturn table|nil quote, @treturn string|nil error
function P.parse(body, symbol)
    local d, err = json.decode(body)
    if not d then return nil, "json: " .. tostring(err) end

    -- Yahoo reports its own errors inside a 200 body. Note json.null is a
    -- table sentinel, so "error": null must be excluded explicitly.
    local cerr = type(d.chart) == "table" and d.chart.error or nil
    if type(cerr) == "table" and cerr ~= json.null then
        return nil, tostring(cerr.description or cerr.code or "provider error")
    end

    local res = d.chart and d.chart.result and d.chart.result[1]
    if res == json.null then res = nil end
    local m = res and res.meta
    if m == json.null then m = nil end
    if not m then return nil, "unexpected response shape" end

    local price = num(m.regularMarketPrice)
    if not price then return nil, "no price in response" end

    local prev = num(m.chartPreviousClose) or num(m.previousClose)
    local chg_pct = num(m.regularMarketChangePercent)
    local chg
    if prev then
        chg = price - prev
        if not chg_pct and prev ~= 0 then chg_pct = (chg / prev) * 100 end
    end

    -- Derive market state from the trading periods; this endpoint's meta does
    -- not reliably carry marketState.
    local state, trading = "UNKNOWN", nil
    local tp = m.currentTradingPeriod
    if type(tp) == "table" then
        trading = {}
        for _, k in ipairs({ "pre", "regular", "post" }) do
            local p = tp[k]
            if type(p) == "table" and num(p.start) and num(p["end"]) then
                trading[k] = { start = p.start, stop = p["end"] }
            end
        end
        local now = os.time()
        if trading.regular and now >= trading.regular.start and now < trading.regular.stop then
            state = "REGULAR"
        elseif trading.pre and now >= trading.pre.start and now < trading.pre.stop then
            state = "PRE"
        elseif trading.post and now >= trading.post.start and now < trading.post.stop then
            state = "POST"
        else
            state = "CLOSED"
        end
    end

    return {
        symbol         = str(m.symbol) or symbol,
        name           = str(m.longName) or str(m.shortName),
        price          = price,
        previous_close = prev,
        change         = chg,
        change_percent = chg_pct,
        currency       = str(m.currency),
        exchange       = str(m.fullExchangeName) or str(m.exchangeName),
        timezone       = str(m.exchangeTimezoneName),
        day_high       = num(m.regularMarketDayHigh),
        day_low        = num(m.regularMarketDayLow),
        week52_high    = num(m.fiftyTwoWeekHigh),
        week52_low     = num(m.fiftyTwoWeekLow),
        market_state   = state,
        trading        = trading,
        timestamp      = num(m.regularMarketTime) or os.time(),
    }
end

return P

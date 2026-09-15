--------------------------------------------------------------------------------
-- stocks -- a pluggable stock ticker widget for awesome 4.x
--
--   local stocks = require("awesomewm-stock-ticker")
--   ...
--   stocks({ symbols = { "AAPL", "META" } })
--
-- The module resolves its own name at load time, so the directory it lives in
-- can be called anything -- require() it by whatever name you cloned it as.
--
-- All configuration is passed in by the caller; nothing about your setup is
-- baked into this module. Data sources are plugins: see providers/ and the
-- PROVIDER CONTRACT below.
--
-- Dependencies: curl. Nothing else -- JSON decoding is vendored in json.lua.
--
-- PROVIDER CONTRACT ----------------------------------------------------------
-- A provider is a table with:
--   name       string
--   needs_key  boolean            -- widget warns if no key was configured
--   request(symbol, opts)         -> { url = string, headers = { [k] = v } }
--   parse(body, symbol)           -> quote | nil, errmsg
--
-- `opts` is provider_options from the config, plus `api_key` resolved by the
-- widget (from api_key or api_key_cmd).
--
-- A quote is this standardised table. Only symbol and price are required;
-- everything else is optional and the widget degrades gracefully.
--   symbol, name, price, previous_close, change, change_percent, currency,
--   exchange, timezone, day_high, day_low, week52_high, week52_low,
--   market_state ("REGULAR"|"PRE"|"POST"|"CLOSED"|"UNKNOWN"),
--   trading = { regular = { start = epoch, stop = epoch }, pre = ..., post = ... },
--   timestamp
--------------------------------------------------------------------------------

-- Our own module name, e.g. "awesomewm-stock-ticker". Lua passes it to the
-- chunk as the first vararg, so nothing here depends on the directory name.
local MODULE = ...

local awful     = require("awful")
local wibox     = require("wibox")
local gears     = require("gears")
local beautiful = require("beautiful")

local M = {}

-- Defaults. Every one can be overridden per-instance from rc.lua.
local defaults = {
    symbols          = {},
    provider         = "yahoo",
    provider_options = {},
    api_key          = nil,
    api_key_cmd      = nil,          -- shell command printing the key on stdout

    -- Polling, in seconds, chosen by market state. The provider tells us
    -- whether the market is open, so there is no hardcoded schedule or
    -- holiday calendar and DST is handled upstream.
    refresh_open     = 60,
    refresh_extended = 300,          -- pre / post market
    refresh_closed   = 900,
    timeout          = 10,           -- curl timeout

    -- Display
    color_up         = "#8CC63F",
    color_down       = "#D05050",
    color_flat       = nil,          -- nil -> beautiful.fg_normal
    color_error      = "#E0A030",
    show_name        = false,        -- prefix each quote with its symbol
    show_percent     = true,
    show_price       = true,
    price_format     = "%.2f",
    percent_format   = "%+.2f%%",
    separator        = "  ",
    font             = nil,

    -- Full control over the rendered text. When nil, the layout is built from
    -- the show_* flags above. Either:
    --   a string template with ${placeholders}, or
    --   a function(fields) returning pango markup.
    -- See the "Custom formatting" section of the README for the field list.
    text_format      = nil,
    -- Colour applied to the symbol when text_format is in use. nil leaves it
    -- the theme's foreground colour.
    color_symbol     = nil,
    -- Colour applied to the price when text_format is in use. nil leaves it
    -- the theme's foreground colour; set to "change" to colour it by the move.
    color_price      = nil,
    -- Left click on a ticker. Called with (symbol, quote).
    -- Defaults to opening the provider's quote page via xdg-open; set to
    -- false to disable, or supply your own function.
    on_click         = nil,
    -- URL template used by the default on_click. %s is replaced with the
    -- symbol. Providers may override via provider.quote_url.
    quote_url        = nil,
}

-- Shell-quote a string for safe interpolation into a /bin/sh command line.
local function shquote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function build_curl(req, timeout)
    local parts = { "curl", "-sS", "--max-time", tostring(timeout) }
    for name, value in pairs(req.headers or {}) do
        parts[#parts + 1] = "-H"
        parts[#parts + 1] = shquote(name .. ": " .. value)
    end
    parts[#parts + 1] = shquote(req.url)
    return table.concat(parts, " ")
end

local function load_provider(p)
    if type(p) == "table" then return p end          -- inline provider
    local ok, mod = pcall(require, MODULE .. ".providers." .. tostring(p))
    if ok and type(mod) == "table" then return mod end
    return nil, ("provider '%s' not found (%s)"):format(tostring(p), tostring(mod))
end

--- Default left-click action: open the quote page in the user's browser.
local function default_on_click(cfg, provider)
    local tmpl = cfg.quote_url or (provider and provider.quote_url)
    if not tmpl then return nil end
    return function(symbol)
        awful.spawn.with_shell("xdg-open " .. shquote(tmpl:format(symbol)))
    end
end

local function markup(cfg, text, color)
    local t = gears.string.xml_escape and gears.string.xml_escape(text) or text
    if not color then return t end
    return string.format("<span foreground='%s'>%s</span>", color, t)
end

--- Colour implied by a quote's move: up, down, or flat/unknown.
local function change_color(cfg, q)
    if q and q.change_percent then
        if q.change_percent > 0 then return cfg.color_up end
        if q.change_percent < 0 then return cfg.color_down end
    end
    return cfg.color_flat or beautiful.fg_normal or "#ffffff"
end

--- Substitute ${placeholders} in a template.
-- Template may instead be a function, which is called with the field table and
-- must return markup -- that escape hatch means any layout is reachable without
-- growing the option list.
-- Unknown placeholders render empty rather than raising, so a typo degrades to
-- a gap instead of breaking the wibar.
local function substitute(template, fields)
    if type(template) == "function" then
        return tostring(template(fields) or "")
    end
    return (template:gsub("%${([%w_]+)}", function(key)
        local v = fields[key]
        return v ~= nil and tostring(v) or ""
    end))
end

--- Build the ${placeholder} table for one quote.
local function template_fields(cfg, symbol, q)
    local chg = change_color(cfg, q)
    local function on(c) return c and string.format("<span foreground='%s'>", c) or "" end
    local function off(c) return c and "</span>" or "" end

    -- color_price = "change" means "colour the price by the day's move".
    local price_color = cfg.color_price
    if price_color == "change" then price_color = chg end

    local f = {
        symbol         = q and q.symbol or symbol,
        name           = q and q.name or "",
        price          = q and string.format(cfg.price_format, q.price) or "",
        change         = q and q.change and string.format("%+.2f", q.change) or "",
        change_percent = q and q.change_percent
                         and string.format(cfg.percent_format, q.change_percent) or "",
        previous_close = q and q.previous_close
                         and string.format(cfg.price_format, q.previous_close) or "",
        currency       = q and q.currency or "",
        market_state   = q and q.market_state or "",
        -- Arrow reflecting direction; empty when flat or unknown.
        arrow          = (q and q.change_percent and q.change_percent > 0 and "\u{25B2}")
                         or (q and q.change_percent and q.change_percent < 0 and "\u{25BC}")
                         or "",
    }
    f.change_color_on,  f.change_color_off  = on(chg), off(chg)
    f.symbol_color_on,  f.symbol_color_off  = on(cfg.color_symbol), off(cfg.color_symbol)
    f.price_color_on,   f.price_color_off   = on(price_color), off(price_color)
    return f
end

--- Render one quote (or its error) as pango markup.
local function format_quote(cfg, symbol, q, err)
    if err or not q then
        return markup(cfg, symbol .. " ?", cfg.color_error)
    end

    -- Custom layout: the template owns the colouring entirely.
    if cfg.text_format then
        local ok, out = pcall(substitute, cfg.text_format, template_fields(cfg, symbol, q))
        if ok then return out end
        return markup(cfg, symbol .. " !", cfg.color_error)
    end

    -- Default layout, built from the show_* flags.
    local bits = {}
    if cfg.show_name then bits[#bits + 1] = q.symbol or symbol end
    if cfg.show_price then bits[#bits + 1] = string.format(cfg.price_format, q.price) end
    if cfg.show_percent and q.change_percent then
        bits[#bits + 1] = string.format(cfg.percent_format, q.change_percent)
    end
    return markup(cfg, table.concat(bits, " "), change_color(cfg, q))
end

local function format_tooltip(cfg, symbol, q, err)
    if err or not q then
        return string.format("%s\n  error: %s", symbol, tostring(err or "no data"))
    end
    local L = {}
    L[#L + 1] = string.format("%s%s", q.symbol or symbol, q.name and ("  —  " .. q.name) or "")
    L[#L + 1] = string.format("  price      %s %s", string.format(cfg.price_format, q.price), q.currency or "")
    if q.change and q.change_percent then
        L[#L + 1] = string.format("  change     %+.2f (%+.2f%%)", q.change, q.change_percent)
    end
    if q.previous_close then
        L[#L + 1] = string.format("  prev close %s", string.format(cfg.price_format, q.previous_close))
    end
    if q.day_low and q.day_high then
        L[#L + 1] = string.format("  day range  %s – %s",
            string.format(cfg.price_format, q.day_low), string.format(cfg.price_format, q.day_high))
    end
    if q.week52_low and q.week52_high then
        L[#L + 1] = string.format("  52w range  %s – %s",
            string.format(cfg.price_format, q.week52_low), string.format(cfg.price_format, q.week52_high))
    end
    if q.market_state and q.market_state ~= "UNKNOWN" then
        L[#L + 1] = string.format("  market     %s", q.market_state)
    end
    if q.exchange then L[#L + 1] = string.format("  exchange   %s", q.exchange) end
    if q.timestamp then
        L[#L + 1] = string.format("  updated    %s", os.date("%H:%M:%S", q.timestamp))
    end
    return table.concat(L, "\n")
end

--------------------------------------------------------------------------------

--- Create a stocks widget.
-- @tparam table user_args see `defaults` above; `symbols` is required.
-- @treturn wibox.widget
function M.new(user_args)
    user_args = user_args or {}

    -- Precedence: caller's args override the defaults below.
    local cfg = {}
    for k, v in pairs(defaults) do cfg[k] = v end
    for k, v in pairs(user_args) do cfg[k] = v end

    local container = wibox.widget {
        layout  = wibox.layout.fixed.horizontal,
        spacing = 0,
    }

    local provider, perr = load_provider(cfg.provider)

    -- on_click: false disables, a function is used as-is, nil falls back to
    -- opening the provider's quote page.
    local click_handler
    if cfg.on_click == false then click_handler = nil
    elseif type(cfg.on_click) == "function" then click_handler = cfg.on_click
    else click_handler = default_on_click(cfg, provider) end

    local boxes, quotes = {}, {}
    -- One tooltip per ticker: hovering a symbol shows only that symbol.
    local tooltips = {}

    --- Refresh the tooltip for one symbol, or for all of them when sym is nil.
    local function refresh_tooltip(sym)
        if sym == nil then
            for _, s2 in ipairs(cfg.symbols) do refresh_tooltip(s2) end
            return
        end
        local tt = tooltips[sym]
        if not tt then return end
        local e = quotes[sym]
        local text = format_tooltip(cfg, sym, e and e.quote, e and e.err)
        if provider then
            text = text .. string.format("\n\nsource: %s", provider.name or tostring(cfg.provider))
        end
        tt.text = text
    end

    -- Build one textbox per symbol, with separators between.
    for i, sym in ipairs(cfg.symbols) do
        if i > 1 then
            local sep = wibox.widget { widget = wibox.widget.textbox, text = cfg.separator }
            container:add(sep)
        end
        local tb = wibox.widget { widget = wibox.widget.textbox, font = cfg.font }
        tb.markup = markup(cfg, sym .. " …", cfg.color_error)
        boxes[sym] = tb
        container:add(tb)
        tooltips[sym] = awful.tooltip { objects = { tb }, mode = "outside" }
        if click_handler then
            tb:buttons(gears.table.join(awful.button({}, 1, function()
                local e = quotes[sym]
                click_handler(sym, e and e.quote)
            end)))
        end
    end

    if not provider then
        for _, sym in ipairs(cfg.symbols) do
            quotes[sym] = { err = perr }
            boxes[sym].markup = markup(cfg, sym .. " !", cfg.color_error)
        end
        refresh_tooltip()
        return container
    end

    -- Resolve the API key once (api_key_cmd is read at runtime so tokens need
    -- not be written into rc.lua), then start polling.
    local opts = {}
    for k, v in pairs(cfg.provider_options or {}) do opts[k] = v end
    opts.api_key = cfg.api_key

    local timer
    local pending = 0

    local function interval_for_state()
        local state
        for _, sym in ipairs(cfg.symbols) do
            local e = quotes[sym]
            local s = e and e.quote and e.quote.market_state
            if s == "REGULAR" then state = "REGULAR" break
            elseif s == "PRE" or s == "POST" then state = "EXTENDED"
            elseif not state and s then state = s end
        end
        if state == "REGULAR" then return cfg.refresh_open end
        if state == "EXTENDED" then return cfg.refresh_extended end
        if state == "CLOSED" then return cfg.refresh_closed end
        return cfg.refresh_open   -- UNKNOWN: provider has no calendar, poll normally
    end

    local function fetch_all()
        for _, sym in ipairs(cfg.symbols) do
            local ok, req = pcall(provider.request, sym, opts)
            if not ok or type(req) ~= "table" or not req.url then
                quotes[sym] = { err = "provider.request failed" }
                boxes[sym].markup = format_quote(cfg, sym, nil, quotes[sym].err)
                refresh_tooltip(sym)
            else
                pending = pending + 1
                awful.spawn.easy_async_with_shell(build_curl(req, cfg.timeout),
                    function(stdout, stderr, _, exitcode)
                        pending = pending - 1
                        local q, err
                        if exitcode ~= 0 then
                            err = "curl exit " .. tostring(exitcode)
                                  .. ((stderr and stderr ~= "") and (": " .. stderr:gsub("%s+$", "")) or "")
                        else
                            local pok, res, perr2 = pcall(provider.parse, stdout, sym)
                            if not pok then err = "parse error: " .. tostring(res)
                            elseif not res then err = perr2 or "no data"
                            else q = res end
                        end
                        quotes[sym] = { quote = q, err = err }
                        boxes[sym].markup = format_quote(cfg, sym, q, err)
                        refresh_tooltip(sym)

                        -- Re-arm on the interval the market state implies.
                        if pending == 0 and timer then
                            local want = interval_for_state()
                            if timer.timeout ~= want then
                                timer.timeout = want
                                timer:again()
                            end
                        end
                    end)
            end
        end
    end

    local function start()
        timer = gears.timer {
            timeout   = cfg.refresh_open,
            autostart = true,
            call_now  = true,
            callback  = fetch_all,
        }
    end

    if cfg.api_key_cmd and not opts.api_key then
        awful.spawn.easy_async_with_shell(cfg.api_key_cmd, function(stdout, _, _, code)
            if code == 0 and stdout then opts.api_key = stdout:gsub("%s+$", "") end
            if provider.needs_key and (not opts.api_key or opts.api_key == "") then
                for _, sym in ipairs(cfg.symbols) do
                    quotes[sym] = { err = "api_key_cmd produced no key" }
                    boxes[sym].markup = format_quote(cfg, sym, nil, quotes[sym].err)
                end
                refresh_tooltip()
                return
            end
            start()
        end)
    else
        if provider.needs_key and (not opts.api_key or opts.api_key == "") then
            for _, sym in ipairs(cfg.symbols) do
                quotes[sym] = { err = "provider '" .. tostring(provider.name) .. "' requires api_key or api_key_cmd" }
                boxes[sym].markup = format_quote(cfg, sym, nil, quotes[sym].err)
            end
            refresh_tooltip()
            return container
        end
        start()
    end

    -- Middle click anywhere: force refresh.
    container:buttons(gears.table.join(awful.button({}, 2, function() fetch_all() end)))

    return container
end

return setmetatable(M, { __call = function(_, ...) return M.new(...) end })

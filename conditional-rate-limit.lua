local core = require("apisix.core")
local plugin = require("apisix.plugin")
local ngx = ngx
local ngx_time = ngx.time
local string = string

local plugin_name = "conditional-rate-limit"

local schema = {
    type = "object",
    properties = {
        anonymous_count = {
            type = "integer",
            minimum = 0,
            default = 5000,
            description = "Rate limit count for anonymous users per time window"
        },
        anonymous_time_window = {
            type = "integer",
            minimum = 1,
            default = 3600,
            description = "Time window in seconds for anonymous users"
        },
        polite_count = {
            type = "integer",
            minimum = 0,
            default = 15000,
            description = "Rate limit count for polite users per time window"
        },
        polite_time_window = {
            type = "integer",
            minimum = 1,
            default = 3600,
            description = "Time window in seconds for polite users"
        },
        api_key_count = {
            type = "integer",
            minimum = 0,
            default = 50000,
            description = "Rate limit count for API key users per time window"
        },
        api_key_time_window = {
            type = "integer",
            minimum = 1,
            default = 3600,
            description = "Time window in seconds for API key users"
        },
        key_header = {
            type = "string",
            default = "X-API-Key",
            description = "Header to check for API key"
        },
        key_query_param = {
            type = "string",
            default = "apikey",
            description = "Query parameter to check for API key"
        },
        email_pattern = {
            type = "string",
            default = "%S+@%S+%.%S+",
            description = "Lua pattern to match emails in User-Agent"
        },
        mailto_query_param = {
            type = "string",
            default = "mailto",
            description = "Query parameter to check for email address"
        },
        rejected_code = {
            type = "integer",
            minimum = 200,
            maximum = 599,
            default = 429,
            description = "HTTP status code returned when rate limit exceeded"
        },
        rejected_msg = {
            type = "string",
            default = "Rate limit exceeded. See https://ecosyste.ms/api for details.",
            description = "Response body when rate limit exceeded"
        },
        policy = {
            type = "string",
            enum = {"local", "redis"},
            default = "local",
            description = "Storage policy for rate limit counters"
        }
    }
}

local _M = {
    version = 0.1,
    priority = 1001,
    name = plugin_name,
    schema = schema
}

-- In-memory storage for rate limiting counters
local counters = {}

local function get_identifier(conf, ctx)
    -- Get real client IP, checking Cloudflare headers first, then X-Forwarded-For, then remote_addr
    local remote_addr = core.request.header(ctx, "CF-Connecting-IP") or
                       core.request.header(ctx, "X-Real-IP") or
                       core.request.header(ctx, "X-Forwarded-For") or
                       ctx.var.remote_addr or
                       "unknown"

    -- If X-Forwarded-For contains multiple IPs, get the first one (original client)
    if remote_addr and remote_addr:find(",") then
        remote_addr = remote_addr:match("^([^,]+)")
        if remote_addr then
            remote_addr = remote_addr:gsub("^%s*(.-)%s*$", "%1") -- trim whitespace
        end
    end

    -- Check for API key in header or query param
    local api_key = core.request.header(ctx, conf.key_header)
    if not api_key and conf.key_query_param then
        local args = core.request.get_uri_args(ctx) or {}
        api_key = args[conf.key_query_param]
    end

    if api_key then
        -- Use API key as identifier for per-key rate limiting
        local identifier = "apikey:" .. api_key
        return identifier, "api_key", true, api_key, nil
    end

    -- Check for email in mailto query parameter first
    local is_polite = false
    local email_source = nil
    if conf.mailto_query_param then
        local args = core.request.get_uri_args(ctx) or {}
        local mailto = args[conf.mailto_query_param]
        if mailto then
            -- Check if the mailto parameter contains a valid email
            is_polite = string.match(mailto, conf.email_pattern) ~= nil
            if is_polite then
                email_source = "query_param"
            end
        end
    end

    -- If not found in mailto param, check User-Agent
    if not is_polite then
        local user_agent = core.request.header(ctx, "User-Agent") or ""
        is_polite = string.match(user_agent, conf.email_pattern) ~= nil
        if is_polite then
            email_source = "user_agent"
        end
    end

    local tier = is_polite and "polite" or "anonymous"
    local identifier = remote_addr .. ":" .. tier

    return identifier, tier, is_polite, nil, email_source
end

local function get_rate_limit_config(conf, tier)
    if tier == "api_key" then
        return conf.api_key_count, conf.api_key_time_window
    elseif tier == "polite" then
        return conf.polite_count, conf.polite_time_window
    else
        return conf.anonymous_count, conf.anonymous_time_window
    end
end

local function check_rate_limit(conf, identifier, count_limit, time_window)
    local now = ngx_time()
    local window_start = now - (now % time_window)
    local key = identifier .. ":" .. window_start

    if not counters[key] then
        counters[key] = {
            count = 0,
            window_start = window_start,
            expires = window_start + time_window + 60
        }
    end

    -- Cleanup old entries
    for k, v in pairs(counters) do
        if v.expires < now then
            counters[k] = nil
        end
    end

    local counter = counters[key]

    if counter.count >= count_limit then
        return false, count_limit, 0, window_start + time_window
    end

    counter.count = counter.count + 1
    local remaining = count_limit - counter.count
    return true, count_limit, remaining, window_start + time_window
end

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    local identifier, tier, has_special_access, api_key, email_source = get_identifier(conf, ctx)
    local count_limit, time_window = get_rate_limit_config(conf, tier)
    local allowed, limit, remaining, reset_time = check_rate_limit(conf, identifier, count_limit, time_window)

    -- Add rate limit headers
    core.response.set_header("x-ratelimit-limit", tostring(limit))
    core.response.set_header("x-ratelimit-remaining", tostring(remaining))
    core.response.set_header("x-ratelimit-reset", tostring(reset_time))
    core.response.set_header("x-ratelimit-tier", tier)

    -- Add API key identifier if present
    if api_key then
        core.response.set_header("x-ratelimit-key", string.sub(api_key, 1, 8) .. "...")
    end

    if not allowed then
        return conf.rejected_code, {error_msg = conf.rejected_msg}
    end
end

return _M
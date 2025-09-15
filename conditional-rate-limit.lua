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
        email_pattern = {
            type = "string",
            default = "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+%.[A-Za-z][A-Za-z]+",
            description = "Lua pattern to match emails in User-Agent"
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
            default = "Rate limit exceeded",
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
    priority = 1001, -- Execute before other rate limiting plugins
    name = plugin_name,
    schema = schema
}

-- In-memory storage for rate limiting counters
local counters = {}

local function get_identifier(conf, ctx)
    local user_agent = core.request.header(ctx, "User-Agent") or ""
    local remote_addr = ctx.var.remote_addr or "unknown"
    
    -- Check if User-Agent contains email pattern
    local is_polite = string.match(user_agent, conf.email_pattern) ~= nil
    
    local tier = is_polite and "polite" or "anonymous"
    local identifier = remote_addr .. ":" .. tier
    
    return identifier, tier, is_polite
end

local function get_rate_limit_config(conf, tier)
    if tier == "polite" then
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
            expires = window_start + time_window + 60 -- Add buffer for cleanup
        }
    end
    
    -- Cleanup old entries (basic cleanup)
    for k, v in pairs(counters) do
        if v.expires < now then
            counters[k] = nil
        end
    end
    
    local counter = counters[key]
    
    if counter.count >= count_limit then
        return false, count_limit, counter.count, window_start + time_window
    end
    
    counter.count = counter.count + 1
    return true, count_limit, count_limit - counter.count, window_start + time_window
end

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    local identifier, tier, has_special_access, api_key = get_identifier(conf, ctx)
    local count_limit, time_window = get_rate_limit_config(conf, tier)
    
    local allowed, limit, remaining, reset_time = check_rate_limit(conf, identifier, count_limit, time_window)
    
    -- Add rate limit headers (lowercase for compatibility)
    core.response.set_header("x-ratelimit-limit", limit)
    core.response.set_header("x-ratelimit-remaining", remaining)  
    core.response.set_header("x-ratelimit-reset", reset_time)
    core.response.set_header("x-ratelimit-tier", tier)
    
    -- Add API key identifier if present (for debugging/logging)
    if api_key then
        core.response.set_header("x-ratelimit-key", string.sub(api_key, 1, 8) .. "...")
    end
    
    if not allowed then
        core.log.warn("Rate limit exceeded for ", identifier, " (", tier, " tier)")
        return conf.rejected_code, {error_msg = conf.rejected_msg}
    end
    
    core.log.info("Rate limit check passed for ", identifier, " (", tier, " tier), remaining: ", remaining)
end

return _M

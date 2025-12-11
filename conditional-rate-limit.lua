local core = require("apisix.core")
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
            default = 100000,
            description = "Rate limit count for API key users per time window"
        },
        api_key_time_window = {
            type = "integer",
            minimum = 1,
            default = 3600,
            description = "Time window in seconds for API key users"
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
        },
        exempt_hosts = {
            type = "array",
            items = {
                type = "string"
            },
            default = {"grafana.ecosyste.ms", "prometheus.ecosyste.ms", "apisix.ecosyste.ms"},
            description = "List of host domains to bypass rate limiting completely"
        },
        exempt_ips = {
            type = "array",
            items = {
                type = "string"
            },
            default = {},
            description = "List of IP addresses to bypass rate limiting completely"
        }
    }
}

local _M = {
    version = 0.1,
    priority = 1001,
    name = plugin_name,
    schema = schema
}

-- Use APISIX's plugin-limit-count shared dictionary for rate limiting
-- This allows counters to be shared across all nginx workers
local shared_dict = ngx.shared["plugin-limit-count"]
if not shared_dict then
    -- Fallback to internal-status if plugin-limit-count is not available
    shared_dict = ngx.shared["internal-status"]
    if not shared_dict then
        core.log.error("No shared dictionary found for rate limiting!")
    end
end

local function get_identifier(conf, ctx)
    -- Get consumer name from ctx (may be set by key-auth or other auth plugins)
    -- Try ctx.consumer_name first, fall back to ctx.consumer.username
    local consumer_name = ctx.consumer_name
    if not consumer_name and ctx.consumer then
        consumer_name = ctx.consumer.username
    end

    -- Check if this request is from an authenticated consumer (not anonymous)
    if consumer_name and consumer_name ~= "anonymous" then
        local identifier = "consumer:" .. consumer_name
        return identifier, "api_key", true, consumer_name, nil
    end

    -- No authenticated consumer, continue with IP-based identification

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

local function get_rate_limit_config(conf, ctx, tier)
    if tier == "api_key" then
        -- Try to get rate limit from consumer's limit-count plugin
        if ctx.consumer and ctx.consumer.plugins and ctx.consumer.plugins["limit-count"] then
            local limit_count = ctx.consumer.plugins["limit-count"]
            local count = limit_count.count or conf.api_key_count
            local time_window = limit_count.time_window or conf.api_key_time_window
            return count, time_window
        end
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
    local key = "conditional_rate_limit:" .. identifier .. ":" .. window_start

    -- Use shared dictionary if available
    if shared_dict then
        -- Use incr method which is atomic and works across workers
        local count, err = shared_dict:incr(key, 1, 0, time_window + 60)

        if not count then
            core.log.error("failed to increment counter for key ", key, ": ", err)
            -- Allow the request on error
            return true, count_limit, count_limit, window_start + time_window
        end

        -- Check if over limit
        if count > count_limit then
            return false, count_limit, 0, window_start + time_window
        end

        local remaining = count_limit - count
        return true, count_limit, remaining, window_start + time_window
    else
        -- Fallback - no shared dict (shouldn't happen in APISIX)
        core.log.error("No shared dictionary available, rate limiting will not work correctly")
        return true, count_limit, count_limit, window_start + time_window
    end
end

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    -- Check if request is TO an exempt host domain - bypass all rate limiting
    if conf.exempt_hosts then
        local host = ctx.var.host or core.request.header(ctx, "Host") or ""
        for _, exempt_host in ipairs(conf.exempt_hosts) do
            if host == exempt_host then
                core.log.info("Request to exempt host: ", host)
                return -- Bypass rate limiting completely
            end
        end
    end

    -- Check if request is FROM an exempt IP address - bypass all rate limiting
    if conf.exempt_ips and #conf.exempt_ips > 0 then
        local remote_addr = core.request.header(ctx, "CF-Connecting-IP") or
                           core.request.header(ctx, "X-Real-IP") or
                           core.request.header(ctx, "X-Forwarded-For") or
                           ctx.var.remote_addr or
                           "unknown"

        -- If X-Forwarded-For contains multiple IPs, get the first one
        if remote_addr and remote_addr:find(",") then
            remote_addr = remote_addr:match("^([^,]+)")
            if remote_addr then
                remote_addr = remote_addr:gsub("^%s*(.-)%s*$", "%1")
            end
        end

        for _, exempt_ip in ipairs(conf.exempt_ips) do
            if remote_addr == exempt_ip then
                core.log.info("Request from exempt IP: ", remote_addr)
                return -- Bypass rate limiting completely
            end
        end
    end

    local identifier, tier, has_special_access, api_key, email_source = get_identifier(conf, ctx)

    local count_limit, time_window = get_rate_limit_config(conf, ctx, tier)
    local allowed, limit, remaining, reset_time = check_rate_limit(conf, identifier, count_limit, time_window)

    -- Add rate limit headers
    core.response.set_header("x-ratelimit-limit", tostring(limit))
    core.response.set_header("x-ratelimit-remaining", tostring(remaining))
    core.response.set_header("x-ratelimit-reset", tostring(reset_time))
    core.response.set_header("x-ratelimit-tier", tier)

    -- Add consumer identifier if present
    if ctx.consumer_name then
        core.response.set_header("x-ratelimit-consumer", ctx.consumer_name)
    end

    if not allowed then
        return conf.rejected_code, {error_msg = conf.rejected_msg}
    end
end

return _M
-- Run from the repo root: lua test/conditional_rate_limit_test.lua

local counters = {}
local response_headers = {}

_G.ngx = {
    time = function() return 7200 end,
    shared = {
        ["plugin-limit-count"] = {
            incr = function(_, key, value, init)
                counters[key] = (counters[key] or init) + value
                return counters[key]
            end
        }
    }
}

package.loaded["apisix.core"] = {
    log = { info = function() end, error = function() end },
    schema = { check = function() return true end },
    request = {
        header = function(ctx, name) return ctx.headers[string.lower(name)] end,
        get_uri_args = function(ctx) return ctx.args or {} end
    },
    response = {
        set_header = function(name, value) response_headers[name] = value end
    }
}

local plugin = dofile("conditional-rate-limit.lua")

local conf = {
    anonymous_count = 2, anonymous_time_window = 3600,
    polite_count = 3, polite_time_window = 3600,
    api_key_count = 10, api_key_time_window = 3600,
    email_pattern = "[^@]+@[^@]+",
    mailto_query_param = "mailto",
    rejected_code = 429,
    rejected_msg = "Rate limit exceeded.",
    exempt_hosts = {},
    exempt_ips = {},
    ua_tiers = {
        { name = "parlay", ua_pattern = "^parlay %(", hosts = {"packages.ecosyste.ms"}, count = 4, time_window = 3600 }
    }
}

local function request(ip, host, ua)
    response_headers = {}
    local ctx = {
        var = { host = host, remote_addr = ip },
        headers = { ["cf-connecting-ip"] = ip, ["user-agent"] = ua }
    }
    local code = plugin.access(conf, ctx)
    return code, response_headers
end

local failures = 0
local function check(name, got, want)
    if got ~= want then
        failures = failures + 1
        print("FAIL " .. name .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    else
        print("ok   " .. name)
    end
end

local _, h = request("1.1.1.1", "packages.ecosyste.ms", "parlay (0.11.0)")
check("parlay on packages gets parlay tier", h["x-ratelimit-tier"], "parlay")
check("parlay tier limit", h["x-ratelimit-limit"], "4")

for _ = 2, 4 do request("1.1.1.1", "packages.ecosyste.ms", "parlay (dev)") end
local code = request("1.1.1.1", "packages.ecosyste.ms", "parlay (0.9.0)")
check("parlay rejected after its own limit", code, 429)

_, h = request("1.1.1.1", "packages.ecosyste.ms", "curl/8.0")
check("same IP without parlay UA uses separate anonymous bucket", h["x-ratelimit-tier"], "anonymous")
check("anonymous bucket untouched by parlay requests", h["x-ratelimit-remaining"], "1")

_, h = request("2.2.2.2", "repos.ecosyste.ms", "parlay (0.11.0)")
check("parlay on other host stays anonymous", h["x-ratelimit-tier"], "anonymous")

_, h = request("3.3.3.3", "packages.ecosyste.ms", "myparlay (1.0)")
check("pattern is anchored", h["x-ratelimit-tier"], "anonymous")

_, h = request("4.4.4.4", "packages.ecosyste.ms", "parlay (v0.10.0-surepath; mailto:ops@surepath.ai)")
check("parlay with email gets parlay tier", h["x-ratelimit-tier"], "parlay")

_, h = request("5.5.5.5", "packages.ecosyste.ms", "tool mailto:a@b.com")
check("polite tier unchanged", h["x-ratelimit-tier"], "polite")

if failures > 0 then
    os.exit(1)
end

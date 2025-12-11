# conditional-rate-limit

Apache APISIX plugin for three-tier rate limiting used by [Ecosyste.ms](https://ecosyste.ms).

## Overview

This plugin categorizes requests into three tiers with different rate limits:

1. **API Key (Consumer)** - Authenticated APISIX consumers get the highest limits
2. **Polite** - Users who include an email in their User-Agent or use the `mailto` parameter get moderate limits
3. **Anonymous** - Everyone else gets the most restrictive limits

### How Request Identification Works

The plugin identifies and tracks requests differently based on the tier:

- **API Key Tier**: When a request is authenticated by an APISIX consumer (using plugins like `key-auth`, `jwt-auth`, etc.), the rate limit is tracked **per consumer**. Each unique consumer has its own quota, regardless of the IP address making the request. This provides proper authentication and centralized credential management through APISIX.

- **Polite Tier**: When an email address is detected (in the User-Agent header or `mailto` query parameter), the request is classified as "polite" but is still tracked **by IP address**. The email only determines which tier's limits apply - it does not become the identifier. Each unique IP address gets its own polite tier quota.

- **Anonymous Tier**: All other requests are tracked **by IP address** with the anonymous tier limits.

### Examples

- Same IP with email → Gets polite tier limits, tracked by that IP
- Authenticated consumer → Gets API key tier limits, tracked by consumer name
- Different IPs with same email → Each IP gets their own separate polite tier quota
- Different IPs with same consumer credentials → Share the same consumer quota

### Exemptions

Requests can bypass rate limiting entirely based on:

- **exempt_hosts**: Requests to specific host domains (e.g., `grafana.ecosyste.ms`)
- **exempt_ips**: Requests from specific IP addresses

By default, `grafana.ecosyste.ms`, `prometheus.ecosyste.ms`, and `apisix.ecosyste.ms` are exempt hosts. Exempt requests bypass rate limiting completely and don't receive rate limit headers.


## Installation

1. Clone the repository and copy the plugin to your APISIX container:

```bash
git clone https://github.com/ecosyste-ms/conditional-rate-limit.lua
docker cp ~/conditional-rate-limit.lua/conditional-rate-limit.lua apisix-quickstart:/usr/local/apisix/apisix/plugins
```

2. Restart APISIX to load the new plugin:

```bash
docker restart apisix-quickstart
```

## Setting Up Consumers for API Key Tier

To use the API Key tier, you need to create APISIX consumers with authentication credentials:

1. Create a consumer with `key-auth` and optionally a custom rate limit via `limit-count`:

```bash
curl -X PUT \
  http://YOUR_APISIX_IP:9180/apisix/admin/consumers \
  -H 'Content-Type: application/json' \
  -H "X-API-KEY: YOUR_ADMIN_API_KEY" \
  -d '{
    "username": "my-api-user",
    "plugins": {
      "key-auth": {
        "key": "your-secure-api-key-here"
      },
      "limit-count": {
        "count": 500000,
        "time_window": 3600
      }
    }
  }'
```

The plugin reads `count` and `time_window` from the consumer's `limit-count` plugin if present, allowing custom rate limits per consumer. If not specified, the plugin's default `api_key_count` and `api_key_time_window` are used.

2. Enable `key-auth` in the **same global rule** as the rate limiting plugin:

```bash
curl -X PUT \
  http://YOUR_APISIX_IP:9180/apisix/admin/global_rules/1 \
  -H 'Content-Type: application/json' \
  -H "X-API-KEY: YOUR_ADMIN_API_KEY" \
  -d '{
    "plugins": {
      "key-auth": {
        "hide_credentials": true,
        "header": "apikey",
        "query": "apikey",
        "anonymous_consumer": "anonymous"
      },
      "conditional-rate-limit": {
        "anonymous_count": 5000,
        "polite_count": 15000,
        "api_key_count": 100000
      }
    }
  }'
```

**Important**: Both plugins must be in the same global rule. Due to [a bug in APISIX](https://github.com/apache/apisix/issues/12704), plugins in separate global rules execute by creation timestamp rather than by plugin phase/priority. If key-auth is in a different global rule, `ctx.consumer_name` won't be set when the rate limiting plugin runs.

3. Create an anonymous consumer for unauthenticated requests:

```bash
curl -X PUT \
  http://YOUR_APISIX_IP:9180/apisix/admin/consumers \
  -H 'Content-Type: application/json' \
  -H "X-API-KEY: YOUR_ADMIN_API_KEY" \
  -d '{
    "username": "anonymous",
    "desc": "Fallback for unauthenticated requests"
  }'
```

**Note**: You can use other authentication plugins (`jwt-auth`, `basic-auth`, etc.) instead of `key-auth`. The rate limiting plugin works with any auth plugin that sets `ctx.consumer_name`

## Configuration

```yaml
plugins:
  conditional-rate-limit:
    enable: true
    config:
      # API Key tier (for authenticated consumers)
      api_key_count: 100000
      api_key_time_window: 3600

      # Polite tier
      polite_count: 15000
      polite_time_window: 3600

      # Anonymous tier
      anonymous_count: 5000
      anonymous_time_window: 3600

      # Email detection for polite tier
      mailto_query_param: "mailto"
      email_pattern: "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}"

      # Response
      rejected_code: 429
      rejected_msg: "Rate limit exceeded. See https://ecosyste.ms/api for details."

      # Exemptions (optional)
      exempt_hosts:           # Defaults to ["grafana.ecosyste.ms", "prometheus.ecosyste.ms", "apisix.ecosyste.ms"]
        - "grafana.ecosyste.ms"
        - "prometheus.ecosyste.ms"
        - "apisix.ecosyste.ms"
      exempt_ips:             # IP addresses to bypass rate limiting (defaults to [])
        - "192.168.1.100"
        - "10.0.0.50"
```

## Examples

```bash
# Authenticated consumer - 100,000 req/hour
# (Assumes consumer created with key-auth plugin)
curl -H "apikey: your-secure-api-key-here" https://api.ecosyste.ms/endpoint

# Polite - 15,000 req/hour (via User-Agent)
curl -H "User-Agent: MyApp/1.0 (contact: user@example.com)" https://api.ecosyste.ms/endpoint

# Polite - 15,000 req/hour (via mailto parameter)
curl "https://api.ecosyste.ms/endpoint?mailto=you@example.com"

# Anonymous - 5,000 req/hour
curl https://api.ecosyste.ms/endpoint
```

Response headers will include:
- `x-ratelimit-limit`: Maximum requests allowed in the time window
- `x-ratelimit-remaining`: Requests remaining in current window
- `x-ratelimit-reset`: Unix timestamp when the rate limit resets
- `x-ratelimit-tier`: The tier applied (`api_key`, `polite`, or `anonymous`)
- `x-ratelimit-consumer`: Consumer username (only for authenticated requests)

## License

GNU Affero General Public License v3.0 - see [LICENSE](LICENSE) file.
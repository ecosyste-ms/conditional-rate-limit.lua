# conditional-rate-limit

Apache APISIX plugin for three-tier rate limiting used by [Ecosyste.ms](https://ecosyste.ms).

## Overview

This plugin categorizes requests into three tiers with different rate limits:

1. **API Key** - Users with API keys get the highest limits
2. **Polite** - Users who include an email in their User-Agent or use the `mailto` parameter get moderate limits
3. **Anonymous** - Everyone else gets the most restrictive limits


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

3. Configure as a global rule via the APISIX Admin API:

```bash
curl -X PUT \
  http://YOUR_APISIX_IP:9180/apisix/admin/global_rules/1 \
  -H 'Content-Type: application/json' \
  -H "X-API-KEY: YOUR_ADMIN_API_KEY" \
  -d '{
    "plugins": {
      "conditional-rate-limit": {
        "api_key_count": 50000,
        "api_key_time_window": 3600,
        "polite_count": 15000,
        "polite_time_window": 3600,
        "anonymous_count": 5000,
        "anonymous_time_window": 3600,
        "key_header": "X-API-Key",
        "key_query_param": "apikey",
        "mailto_query_param": "mailto",
        "email_pattern": "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}"
      }
    }
  }'
```

## Configuration

```yaml
plugins:
  conditional-rate-limit:
    enable: true
    config:
      # API Key tier
      api_key_count: 1000
      api_key_time_window: 60

      # Polite tier
      polite_count: 100
      polite_time_window: 60

      # Anonymous tier
      anon_count: 10
      anon_time_window: 60

      # API key detection
      key_header: "X-API-Key"
      key_query_param: "apikey"

      # Email detection for polite tier
      mailto_query_param: "mailto"
      email_pattern: "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}"

      # Response
      rejected_code: 429
      rejected_msg: "Too many requests"
```

## Examples

```bash
# API key - 1000 req/min
curl -H "X-API-Key: your-key" https://api.ecosyste.ms/endpoint

# Polite - 100 req/min (via User-Agent)
curl -H "User-Agent: MyApp/1.0 (contact: user@example.com)" https://api.ecosyste.ms/endpoint

# Polite - 100 req/min (via mailto parameter)
curl "https://api.ecosyste.ms/endpoint?mailto=you@example.com"

# Anonymous - 10 req/min
curl https://api.ecosyste.ms/endpoint
```

## License

GNU Affero General Public License v3.0 - see [LICENSE](LICENSE) file.
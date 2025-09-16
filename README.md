# conditional-rate-limit

Apache APISIX plugin for three-tier rate limiting used by [Ecosyste.ms](https://ecosyste.ms).

## Overview

This plugin categorizes requests into three tiers with different rate limits:

1. **API Key** - Users with API keys get the highest limits
2. **Polite** - Users who include an email in their User-Agent get moderate limits
3. **Anonymous** - Everyone else gets the most restrictive limits

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

      # Email pattern for polite tier
      email_pattern: "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}"

      # Response
      rejected_code: 429
      rejected_msg: "Too many requests"
```

## Examples

```bash
# API key - 1000 req/min
curl -H "X-API-Key: your-key" https://api.ecosyste.ms/endpoint

# Polite - 100 req/min
curl -H "User-Agent: MyApp/1.0 (contact: user@example.com)" https://api.ecosyste.ms/endpoint

# Anonymous - 10 req/min
curl https://api.ecosyste.ms/endpoint
```

## License

GNU Affero General Public License v3.0 - see [LICENSE](LICENSE) file.
# AGENTS.md

## Project Overview
* Bash CLI for interacting with the GridPane API
* Performs operations such as creating, updating, and deleting resources on GridPane

## Required Behaviors (MUST follow)
* Immediately after ANY code change, provide a single-line git commit message using conventional commit format: `feat:`, `fix:`, `docs:`, `style:`, `refactor:`, `perf:`, `test:`, `chore:`
* Use Git Kraken to manage commits and branches

## Code Patterns

### Cache System
* Cache files are stored at `${CACHE_DIR}/${GPBC_TOKEN_NAME}_<endpoint>.json`
* When adding a new cache type (e.g., "domains"), update the case statements in `_check_cache_with_options()` in `inc/gp-inc.sh`
* Use `_check_cache_with_options "$CACHE_FILE" "<type>"` for consistent cache prompting behavior
* Default pagination is `GPBC_DEFAULT_PER_PAGE=500` for all cache operations

### API Responses
* Some cache files may contain nested arrays (from paginated API responses) - use jq `flatten` to handle both flat and nested arrays: `flatten | .[]`
* The `gp_api` function handles 429 rate limiting with 15-second backoff and 1 retry

### Adding New Commands
1. Add cache function `_gp_api_cache_<type>()` in `inc/gp-inc-api.sh`
2. Add list/get functions in `inc/gp-inc-api.sh`
3. Add cache type to case statements in `_check_cache_with_options()` in `inc/gp-inc.sh`
4. Add command handlers in `gp-api.sh`
5. Add usage help text in `_usage()` in `gp-api.sh`

### Output Formatting
* For long table outputs, repeat headers every 10 rows for readability
* Use `printf` with fixed widths for aligned columns

### Debugging
* `-df` flag logs to `~/tmp/gpbc-debug.log` by default
* API requests/responses are logged via `_debugf` in `gp_api()`

## API Reference
* Domain fields: `id`, `url`, `route`, `type`, `dns_management_id`, `is_ssl`, `site_id`, `is_wildcard`, `user_dns.integration_name`, `user_dns.provider.name`

## Reference
* GridPane API documentation: `doc/gridpane-api.json`
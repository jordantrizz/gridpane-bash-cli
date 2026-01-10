# TODO.md

## ✅ 1 - Fix Issue with Stale Cache for Servers

**COMPLETED** - Updated `_gp_api_list_servers`, `_gp_api_list_servers_csv`, and `_gp_api_list_servers_sites` to use `_check_cache_with_options`. Now when server cache is stale:
* User sees a warning that cache is old
* User can choose to refresh the cache or use the existing stale cache
* Consistent behavior with sites cache handling

## ✅ 2 - Mask Token When Debugging

**COMPLETED** - Added `_mask_token()` helper function that masks API tokens in debug output.
* Shows first 15 characters of token only
* Appends "... (truncated)" to indicate masked content  
* Example output: `sk-1234567890abcdefg... (truncated)`
* Applied to all debug statements that reference `$GPBC_TOKEN`

## Completed

1. ✅ Cache domain to API key name, so no need to select which key to use each time if previously used. Prompt user to proceed with lookup of domain on API key name.
2. ✅ Add in stripping domain of white space and https:// or http:// or www. before sending to API, make sure to notify user of the strip.
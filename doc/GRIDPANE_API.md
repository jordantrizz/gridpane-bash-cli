# GridPane API Integration

This document describes how the FaithMade Site Creation plugin integrates with the GridPane API.

## Overview

The plugin uses the GridPane API to:
- Fetch available servers for site deployment
- Test API connectivity
- Manage server inventory for site creation

## API Configuration

### Setting Up API Credentials

1. Navigate to **FaithMade Site Creation → GridPane** in WordPress admin
2. Configure the following settings:
   - **API Host**: GridPane API endpoint (default: `https://my.gridpane.com`)
   - **API Key**: Your GridPane API bearer token
   - **Requests Per Hour Limit**: Rate limit for API calls (default: 100)

### Testing the Connection

Click the **Test Connection** button to verify:
- API credentials are valid
- API endpoint is accessible
- Authentication is working correctly

## API Endpoints Used

### 1. Test Connection
- **Endpoint**: `/oauth/api/v1/user`
- **Method**: GET
- **Purpose**: Verify API credentials and connectivity
- **Response**: User information if successful

### 2. Get Servers
- **Endpoint**: `/oauth/api/v1/server` (note: singular "server", not "servers")
- **Method**: GET
- **Purpose**: Retrieve list of all available servers
- **Response**: Array of server objects with ID and name

### 3. Run WP-CLI Command
- **Endpoint**: `/oauth/api/v1/site/run-wp-cli/{site_id}`
- **Method**: PUT
- **Purpose**: Execute WP-CLI commands on a client site
- **Request Body**: 
  ```json
  {
    "wp": {
      "command_name": ["subcommand and arguments"]
    }
  }
  ```
- **Response**: Command output and status
- **Important Note**: GridPane automatically adds `--path` parameter with the site's document root when executing the command

#### WP-CLI Command Execution Details

When executing WP-CLI commands via GridPane API:

1. **Command Format**: Commands sent to the API should not include the `--path` parameter
   - Send: `user get site-admin --field=ID 2>&1 || true`
   - GridPane Executes: `/usr/local/bin/wp user get site-admin --field=ID 2>&1 || true --path=/var/www/site-domain.com/htdocs 2>&1`

2. **Path Handling**: GridPane automatically prepends the correct WordPress document root path based on the site configuration

3. **Examples**:
   - Create user: `user create site-admin email@example.com --role=administrator`
   - Update option: `option update admin_email 'new@email.com'`
   - Flush cache: `cache flush`

## Rate Limiting

The plugin implements client-side rate limiting to prevent exceeding GridPane's API limits:

- **Default Limit**: 100 requests per hour
- **Tracking**: Per-hour request counting
- **Storage**: WordPress options table
- **Reset**: Automatically at the start of each hour
- **Status**: View current usage in GridPane settings page

### Rate Limit Status

The GridPane settings page displays:
- Requests used this hour
- Requests remaining
- Reset time (next hour)

## API Response Structures

### Server List Response

```json
{
  "data": [
    {
      "id": "server-id-123",
      "name": "Production Server 01"
    },
    {
      "id": "server-id-456",
      "name": "Production Server 02"
    }
  ]
}
```

**Alternative Structure** (also supported):
```json
[
  {
    "id": "server-id-123",
    "name": "Production Server 01"
  }
]
```

The plugin handles both response structures automatically.

## Error Handling

### Common Errors

#### Rate Limit Exceeded
- **Error Code**: 429
- **Message**: "API rate limit exceeded. Please try again in the next hour."
- **Resolution**: Wait until the next hour or increase the rate limit

#### Authentication Failed
- **Error Code**: 401
- **Message**: "Unauthorized"
- **Resolution**: Verify API key is correct and has proper permissions

#### Server Not Found
- **Error Code**: 404
- **Message**: "Not Found"
- **Resolution**: Verify API host URL is correct

#### Network Timeout
- **Error**: WP_Error with timeout message
- **Resolution**: Check network connectivity, firewall rules, or increase timeout

### Error Logging

All API errors are logged to the plugin log file at:
`wp-content/uploads/faithmade-site-creation.log`

View logs: **FaithMade Site Creation → Logs**

## Debugging API Calls

### Enable Full API Response Logging

To debug API issues, enable detailed logging by adding this constant to `wp-config.php`:

```php
define('GRIDPANE_API_DEBUG', true);
```

When enabled, the plugin will log:
- Full request details (endpoint, method, headers)
- Complete response headers
- Full response body
- HTTP status codes
- JSON parsing errors

**Example Debug Log Output:**
```
[2025-10-31 20:00:00] [DEBUG] GridPane API Response Code: 200
[2025-10-31 20:00:00] [DEBUG] GridPane API Response Headers: {"content-type":"application/json","x-ratelimit-remaining":"95"}
[2025-10-31 20:00:00] [DEBUG] GridPane API Response Body: {"data":[{"id":"srv-123","name":"Server 01"}]}
```

### Debug Workflow

1. Enable debug logging in `wp-config.php`
2. Perform the action (sync servers, test connection)
3. Check logs: **FaithMade Site Creation → Logs**
4. Filter by log level: "Debug"
5. Review full API request/response details
6. Disable debug logging when done

**Security Note**: Debug logging exposes API responses which may contain sensitive data. Only enable temporarily for troubleshooting and disable when finished.

### Viewing Debug Logs

Via Admin Interface:
1. Go to **FaithMade Site Creation → Logs**
2. Set **Log Level** to "Debug"
3. Click **Filter Logs**

Via REST API:
```bash
curl -X GET "https://yourdomain.com/wp-json/faithmade/v1/logs?level=DEBUG&lines=100" \
  -H "Authorization: Bearer YOUR_WP_AUTH_TOKEN"
```

## Code Examples

### Fetching Servers

```php
$api = new GridPane_API();
$result = $api->get_servers();

if (is_wp_error($result)) {
    // Handle error
    $error_message = $result->get_error_message();
    error_log('GridPane API Error: ' . $error_message);
} else {
    // Process servers
    $servers = $result['data'];
    foreach ($servers as $server) {
        $server_id = $server['id'];
        $server_name = $server['name'];
        // Use server data...
    }
}
```

### Testing Connection

```php
$api = new GridPane_API();
$test_result = $api->test_connection();

if ($test_result['success']) {
    echo 'API connection successful!';
} else {
    echo 'API connection failed: ' . $test_result['message'];
}
```

### Checking Rate Limit Status

```php
$api = new GridPane_API();
$status = $api->get_rate_limit_status();

echo 'Requests used: ' . $status['used'] . '/' . $status['limit'];
echo 'Requests remaining: ' . $status['remaining'];
echo 'Resets at: ' . date('Y-m-d H:i:s', $status['reset']);
```

### Running WP-CLI Commands

```php
$api = new GridPane_API();

// Example 1: Check if user exists
$result = $api->run_wp_cli_command(12345, 'user get site-admin --field=ID 2>&1 || true');

if (is_wp_error($result)) {
    error_log('WP-CLI Error: ' . $result->get_error_message());
} else {
    // Result contains command output
    $output = isset($result['data']) ? $result['data'] : $result;
    echo 'User ID: ' . $output;
}

// Example 2: Create WordPress user
$result = $api->run_wp_cli_command(12345, 'user create site-admin email@example.com --role=administrator');

if (is_wp_error($result)) {
    error_log('Failed to create user: ' . $result->get_error_message());
} else {
    echo 'User created successfully!';
}

// Example 3: Update WordPress option
$result = $api->run_wp_cli_command(12345, 'option update admin_email \'new@email.com\'');

if (!is_wp_error($result)) {
    echo 'Email updated successfully!';
}
```

**Important**: GridPane automatically adds the `--path` parameter pointing to the site's document root. Do not include `--path` in your commands.

## Security Considerations

### API Key Storage

- API keys are stored in WordPress options table
- Keys are only accessible to users with `manage_options` capability
- Consider using environment variables for additional security:

```php
// In wp-config.php (recommended for production)
define('GRIDPANE_API_KEY', 'your-api-key-here');
```

Then update the plugin to read from the constant instead of options.

### Request Signatures

GridPane API uses Bearer token authentication:
```
Authorization: Bearer YOUR_API_KEY
```

All requests include this header automatically via the `GridPane_API` class.

### SSL/TLS

- Always use HTTPS endpoints (default: `https://my.gridpane.com`)
- Never disable SSL verification in production
- Ensure WordPress installation has up-to-date CA certificates

## Troubleshooting

### Issue: "Connection failed" Error

**Possible Causes:**
1. Invalid API key
2. Incorrect API host URL
3. Network connectivity issues
4. Firewall blocking outbound requests
5. SSL certificate issues

**Solutions:**
1. Verify API key in GridPane dashboard
2. Ensure API host is `https://my.gridpane.com` (not http)
3. Test network: `curl -I https://my.gridpane.com`
4. Check firewall rules for outbound HTTPS
5. Update CA certificates on server

### Issue: Servers Not Syncing

**Troubleshooting Steps:**
1. Enable debug logging: `define('GRIDPANE_API_DEBUG', true);`
2. Click "Refresh Servers from GridPane API"
3. Check logs for full API response
4. Verify response structure matches expected format
5. Check database: `SELECT * FROM wp_fm_servers;`

**Common Solutions:**
- API returning empty array: No servers in GridPane account
- JSON parse error: Response format changed
- Database error: Check table exists and has proper permissions

### Issue: Rate Limit Exceeded

**Solutions:**
1. Wait until next hour (automatic reset)
2. Increase rate limit in GridPane settings
3. Reduce frequency of sync operations
4. Implement caching for server lists

### Issue: Timeout Errors

**Solutions:**
1. Increase PHP max_execution_time
2. Increase WordPress HTTP timeout:
```php
add_filter('http_request_timeout', function() { return 30; });
```
3. Check server resources (CPU, memory)
4. Contact hosting provider about network latency

## API Response Caching

The plugin currently makes real-time API calls. For better performance, consider implementing caching:

```php
// Example: Cache server list for 1 hour
$cache_key = 'gridpane_servers_list';
$cached_servers = get_transient($cache_key);

if ($cached_servers === false) {
    $api = new GridPane_API();
    $result = $api->get_servers();
    
    if (!is_wp_error($result)) {
        set_transient($cache_key, $result['data'], HOUR_IN_SECONDS);
        return $result['data'];
    }
} else {
    return $cached_servers;
}
```

## Best Practices

### 1. Rate Limit Management
- Monitor rate limit status regularly
- Implement exponential backoff for retries
- Cache responses when possible

### 2. Error Handling
- Always check for `WP_Error` returns
- Log errors for debugging
- Provide user-friendly error messages

### 3. Security
- Store API keys securely (environment variables preferred)
- Use HTTPS endpoints only
- Validate API responses before processing

### 4. Performance
- Cache server lists when possible
- Avoid unnecessary API calls
- Use async requests for non-critical operations

### 5. Debugging
- Enable debug logging only when needed
- Review logs regularly for issues
- Disable debug mode in production

## Configuration Constants

Add these to `wp-config.php` for advanced configuration:

```php
// Enable full API response logging (temporary debugging only)
define('GRIDPANE_API_DEBUG', true);

// Custom API endpoint (if using different GridPane instance)
// Note: This would require modifying the plugin to read from constant
// Currently uses option: get_option('gridpane_api_host')
define('GRIDPANE_API_HOST', 'https://custom.gridpane.instance');

// Store API key in constant instead of database (recommended)
// Note: This would require modifying the plugin to read from constant
// Currently uses option: get_option('gridpane_api_key')
define('GRIDPANE_API_KEY', 'your-api-key-here');
```

## Future Enhancements

Potential improvements:
- Response caching with configurable TTL
- Webhook support for real-time server updates
- Batch operations for multiple servers
- Retry logic with exponential backoff
- Support for additional GridPane API endpoints
- API key storage in constants/environment variables

## Support Resources

- **GridPane API Documentation**: https://gridpane.com/kb/gridpane-api-introduction-and-postman-documentation/
- **Postman Collection**: https://documenter.getpostman.com/view/13664964/TVssjU7Z
- **Plugin Logs**: FaithMade Site Creation → Logs
- **WordPress Debug**: Enable `WP_DEBUG` and `WP_DEBUG_LOG` in wp-config.php

## Reference Files

- **API Class**: `includes/class-gridpane-api.php`
- **Admin Interface**: `includes/faithmade-site-creation-admin.php`
- **Database Schema**: `doc/DATABASE_SCHEMA.md`
- **Webhook Debugging**: `doc/WEBHOOK_DEBUGGING.md`

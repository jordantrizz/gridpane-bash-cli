## gp-site-mig.sh
* Create a new command called gp-site-mig.sh that operates similar to gp-api.sh
* Goal: Migrate a site from one GridPane server/account to another GridPane server/account

### CLI Arguments
* `-s <site>` - Site domain to migrate
* `-sp <source-profile>` - Source account profile name (from ~/.gridpane)
* `-dp <destination-profile>` - Destination account profile name (from ~/.gridpane)
* `-n` - Dry-run mode (show what would be done without executing)
* `-v` - Verbose mode (show detailed output)
* `--step <step>` - Run a specific step only (e.g., `--step 3` or `--step 2.1`)
* `--dns-integration <id>` - Specify destination DNS integration ID (required if multiple integrations exist)

### Infrastructure
* **Logs folder**: `logs/` - Contains timestamped log files `gp-site-mig-<site>-<timestamp>.log`
* **State folder**: `state/` - Contains JSON state files `gp-site-mig-<site>.json`

### State File Format (JSON)
```json
{
  "site": "example.com",
  "source_profile": "account1",
  "dest_profile": "account2",
  "source_site_id": "12345",
  "dest_site_id": "67890",
  "source_server_ip": "1.2.3.4",
  "dest_server_ip": "5.6.7.8",
  "source_system_user": "user1",
  "dest_system_user": "user2",
  "source_site_path": "/home/user1/sites/example.com",
  "dest_site_path": "/home/user2/sites/example.com",
  "db_name": "example_db",
  "completed_steps": ["1", "2.1", "2.2"],
  "last_updated": "2026-01-29T12:00:00Z"
}
```

### Resume/Restart Logic
* No state file + no `--step`: Run all steps from beginning
* State file exists + no `--step`: Prompt "Resume previous migration? (y/n)"
  * If "y": Skip completed steps, continue from where left off
  * If "n": Delete state file, start fresh
* `--step N`: Run only that step (requires state file with prerequisite data, will error if missing)

### Migration Steps

#### Step 1 - Validate Input
* **1.0** - Confirm site exists on source and destination profiles (via API) ✅
  * Store to state: source_site_id, dest_site_id, source_server_id, dest_server_id
* **1.1** - Get system user for source and destination
  * Query system-user API endpoint using system_user_id from site data
  * Store to state: source_system_user (username), dest_system_user (username)
* **1.2** - Get domain routing for source and destination
  * Get primary domain for source site from domains cache
  * Read route field (`none`, `www`, `root`) for both source and destination
  * Store to state: source_domain_id, source_route, dest_domain_id, dest_route
* **1.3** - Get SSL status and DNS integration for source
  * Read from source primary domain: is_ssl, ssl_status, is_wildcard
  * Read source DNS integration: user_dns.integration_name, user_dns.provider.name, dns_management_id
  * Query destination DNS integrations via GET `/user/integration`
  * If destination has multiple DNS integrations and `--dns-integration <id>` not provided, list available integrations and exit with error
  * If destination has exactly one integration, use it automatically
  * Store to state: source_is_ssl, source_ssl_status, source_is_wildcard, source_dns_provider, source_dns_integration_id, dest_dns_integration_id
* If anything fails, exit with error

#### Step 2 - Server Discovery and SSH Validation
* **2.1** - Get server IPs from API and store to state
* **2.2** - Test SSH connectivity to source and destination servers
* **2.3** - Get database name from wp-config.php via SSH, store to state
* **2.4** - Confirm database exists on both servers via SSH
* **2.5** - Confirm site directory exists (check both paths), store site_path to state:
  * `$HOME/sites/<site>`
  * `$HOME/home/<system-user>/sites/<site>`
* If anything fails, exit with error

#### Step 3 - Test Rsync and Migrate Files
* **3.1** - Confirm rsync installed on source server
* **3.2** - Confirm rsync installed on destination server, confirm htdocs access
* **3.3** - Ensure destination server can SSH to the source server (required for remote rsync)
  * Remote rsync runs on the destination server and pulls from the source server over SSH
  * If using root (default), copy destination `/root/.ssh/id_rsa.pub` into source `/root/.ssh/authorized_keys`
  * If using a non-root SSH user (via `GPBC_SSH_USER`), copy that user's public key into the matching user's `~/.ssh/authorized_keys` on the source server
  * Ensure the source server host key is accepted on the destination server (e.g., run `ssh <source_ip> exit` from the destination once)
* **3.4** - Rsync htdocs from source to destination, log output
* If anything fails, exit with error

#### Step 4 - Migrate Database
* Export database from source using mysqldump, pipe to mysql on destination via SSH
* Log the database migration output
* If anything fails, exit with error

#### Step 5 - Migrate Nginx Config
* **5.1** - Check for nginx config files beyond standard ones:
  * `<site>-headers-csp.conf`
  * `<site>-sockfile.conf`
  * Print any additional files found
* **5.2** - If special configs found, run corresponding gp commands on destination:
  * `disable-xmlrpc-main-context.conf` → `gp site {site} -disable-xmlrpc`
  * `disable-wp-trackbacks-main-context.conf` → `gp site {site} -block-wp-trackbacks.php`
  * `disable-wp-links-opml-main-context.conf` → `gp site {site} -block-wp-links-opml.php`
  * `disable-wp-comments-post-main-context.conf` → `gp site {site} -block-wp-comments-post.php`
* **5.3** - Tar and copy nginx files to destination: `nginx-{site}-src-backup.tar.gz`

#### Step 6 - Copy user-config.php
* Check if user-config.php exists on source
* If exists:
  * Backup existing on destination as `user-config-src-backup{timestamp}.php`
  * Copy from source to destination

#### Step 7 - Sync Domain Route
* Compare source_route and dest_route from state (captured in Step 1.2)
* If routes match, log "Routes already match" and skip update
* If routes differ, update destination domain route via PUT `/domain/{dest_domain_id}` with `{"routing": "<source_route>"}`
* Store to state: `route_updated` (boolean)

#### Step 8 - Cloudflare DNS Integration
* Check if Cloudflare intergration is set for destination and if true, enable the DNS intergration.

#### Step 9 - Enable SSL on Destination
* Check if source has SSL enabled (`source_is_ssl` from state, captured in Step 1.3)
* If source_is_ssl is false, skip this step
* If source_is_ssl is true:
  * Enable SSL on destination via PUT `/domain/{dest_domain_id}` with `{"ssl": true}`
  * Wait for SSL provisioning (poll or wait fixed time)
  * Store to state: `ssl_enabled` (boolean)

#### Step 10 - Final Steps
* Create `cyber.html` file in destination htdocs with content `vm7` (used to confirm DNS propagation)
* Clear cache on destination server via gp command
* Print summary of migration including any errors that occurred

---

### Implementation Phases

Sample data for testing: ./gp-site-mig.sh -d -s aroconsulting.ca -sp BOLDLAYOUT -dp CYBER

#### Phase 1 - Script Skeleton and CLI Parsing ✅
**Goal:** Create basic script structure with argument parsing and help text
* [x] Create `gp-site-mig.sh` with shebang and source includes
* [x] Implement argument parsing: `-s`, `-sp`, `-dp`, `-n`, `-v`, `-d`, `--step`, `-h`
* [x] Implement `_usage()` function with help text
* [x] Implement `_pre_flight_mig()` to check dependencies (jq, curl, ssh, rsync)
* [x] Add global variables: `DRY_RUN`, `VERBOSE`, `DEBUG`, `SITE`, `SOURCE_PROFILE`, `DEST_PROFILE`, `RUN_STEP`

**Test:** Run `./gp-site-mig.sh -h` and verify help output; test invalid args

#### Phase 2 - Logging and State Management ✅
**Goal:** Implement logging system and state file read/write
* [x] Implement `_log()` function - writes timestamped entries to log file
* [x] Implement `_verbose()` function - prints only when VERBOSE=1
* [x] Implement `_dry_run_msg()` function - prints "[DRY-RUN]" prefix when DRY_RUN=1
* [x] Implement `_debug()` function - prints "[DEBUG]" prefix when DEBUG=1
* [x] Implement `_state_init()` - create new state file with initial data
* [x] Implement `_state_read()` - read state file into variables
* [x] Implement `_state_write()` - update state file (preserving existing data)
* [x] Implement `_state_add_completed_step()` - append step to completed_steps array
* [x] Implement `_state_is_step_completed()` - check if step already done
* [x] Implement resume/restart prompt logic (`_check_resume()`)

**Test:** Create/read/update state file; verify log file creation; test resume prompt

#### Phase 3 - Step 1 Implementation (Validate Input)
**Goal:** Validate site exists on both profiles via API and gather initial metadata
* [x] Implement `_step_1_0()` function - Validate site exists on both profiles
* [x] Switch to source profile, query API for site by domain (uses cache)
* [x] Extract and store: source_site_id, source_server_id, source_system_user_id
* [x] Switch to destination profile, query API for site by domain (uses cache)
* [x] Extract and store: dest_site_id, dest_server_id, dest_system_user_id
* [x] Update state file with extracted data
* [x] Mark step 1.0 complete in state
* [x] Implement `_run_step()` helper to handle step execution and resume logic
* [x] Implement `_step_1_1()` - Get system user usernames from system-user API
* [x] Implement `_step_1_2()` - Get domain routing for source and destination from domains cache
* [x] Implement `_step_1_3()` - Get SSL status and DNS integration for source primary domain
* [ ] Implement wrapper `_step_1()` that calls all sub-steps

**Test:** Run with valid site on both profiles; run with missing site (expect error)
**Note:** Until Phase 4+ is implemented, the script should stop cleanly after Step 1.

#### Phase 4 - Step 2 Implementation (Server Discovery & SSH) ✅
**Goal:** Get server IPs and validate SSH connectivity
* [x] Implement `_step_2_1()` - Resolve server IPs from server cache, store to state
* [x] Implement `_step_2_2()` - Test SSH to both servers (`ssh -o ConnectTimeout=5 -o BatchMode=yes`)
* [x] Implement `_step_2_3()` - SSH to both servers, extract DB_NAME from wp-config.php, store to state
* [x] Implement `_step_2_4()` - SSH to both servers, verify database exists (`mysql -e "SHOW DATABASES LIKE 'dbname'"`)
* [x] Implement `_step_2_5()` - SSH to both servers, find wp-config.php and store site/htdocs paths to state
* [x] Implement wrapper `_step_2()` that calls all sub-steps

**Test:** Run each sub-step individually with `--step 2.1`, etc.; verify state updates
**Note:** Until Step 3+ is implemented, the script should stop cleanly after Step 2.

#### Phase 5 - Step 3 Implementation (Rsync) ✅
**Goal:** Validate rsync and migrate files
* [x] Implement `_step_3_1()` - SSH to source, verify `which rsync`
* [x] Implement `_step_3_2()` - SSH to destination, verify rsync and htdocs writable
* [x] Implement `_step_3_3()` - Copy destination SSH public key to source authorized_keys (required for remote rsync)
* [x] Implement `_step_3_4()` - Execute rsync with progress, log output
  * Use: `rsync -avz --progress -e ssh source:path/ dest:path/`
  * Respect DRY_RUN flag (add `--dry-run` to rsync)
* [x] Implement wrapper `_step_3()` that calls all sub-steps

**Test:** Run rsync in dry-run mode first; verify file transfer on test site

#### Phase 6 - Step 4 Implementation (Database Migration)
**Goal:** Export and import database
* [ ] Implement `_step_4()` function
* [ ] Build mysqldump command with proper credentials
* [ ] Pipe over SSH: `ssh source "mysqldump db" | ssh dest "mysql db"`
* [ ] Log output and any errors
* [ ] Respect DRY_RUN flag (print command without executing)

**Test:** Run in dry-run mode; test on non-production site first

#### Phase 7 - Step 5 Implementation (Nginx Config)
**Goal:** Check and migrate nginx configurations
* [ ] Implement `_step_5_1()` - SSH to source, list nginx configs, filter standard ones
* [ ] Implement `_step_5_2()` - For each special config, run corresponding gp command on dest
* [ ] Implement `_step_5_3()` - Tar nginx configs, scp to destination
* [ ] Implement wrapper `_step_5()` that calls all sub-steps

**Test:** Run on site with custom nginx configs; verify gp commands execute

#### Phase 8 - Steps 6-7 Implementation (user-config & Domain Route Sync)
**Goal:** Copy user-config.php and sync domain routing to destination
* [ ] Implement `_step_6()` - Check for user-config.php, backup and copy if exists
* [ ] Implement `_step_7()` - Compare routes from state, update destination via PUT `/domain/{id}` if different

#### Phase 9 - Steps 8-9 Implementation (DNS Check & Final Steps)
**Goal:** Check Cloudflare DNS and finalize migration
* [ ] Implement `_step_8()` - Check if source/dest have Cloudflare DNS integration, log warnings
* [ ] Implement `_step_9()` - Clear cache, print summary
* [ ] Implement `_print_summary()` - Show all completed steps, any errors, timing

**Test:** Full end-to-end migration on test site

#### Phase 10 - Polish and Error Handling
# TODO.md

## error_log() Enhancements
* Go back and find any error messages and implement utilize new _error_log() function for consistent error handling and logging.

## gp-site-mig-custom.sh

#### Step 0 - Scaffold Script
* **0.0** - Copy gp-site-mig.sh to gp-site-mig-custom.sh; update CLI/help text and rename state/log filenames to use "-custom" suffix

#### Step 1 - Seed Ingest
* **1.0** - Extend rocket CSV/JSON schema with ssh_host, ssh_user, ssh_port, source_webroot, custom_source flag (seed-only)
* **1.1** - Parse new columns in _load_data_from_file and persist to state

#### Step 2 - Source Discovery (Custom Mode)
* **2.0** - When custom_source flag set, skip GridPane cache lookups for source
* **2.1** - Use seed ssh_host/ssh_user/ssh_port; allow seed source_webroot override else find wp-config and normalize docroot
* **2.2** - Parse DB_NAME and DB_HOST from wp-config.php and store to state

#### Step 3 - SSH Plumbing
* **3.0** - Adjust _ssh_run/_ssh_capture/known_hosts to honor per-source host/user/port; leave destination handling unchanged

#### Step 4 - SSH Key Setup
* **4.0** - If /root/.ssh/id_rsa missing on destination, generate passwordless key
* **4.1** - Append destination pubkey to source /root/.ssh/authorized_keys using custom source SSH params; refresh known_hosts entry

#### Step 5 - Rsync
* **5.0** - Reuse existing exclusions/delete behavior; run host-to-host rsync using custom source SSH params; keep --rsync-local fallback

#### Step 6 - Database Migration
* **6.0** - Keep mysqldump/mysql commands unchanged; use DB_HOST from state; retain markers and skip/force flags

#### Step 7 - Docs & Samples
* **7.0** - Update README and rocket-gp-site-mig.* examples with custom-source workflow and seed schema



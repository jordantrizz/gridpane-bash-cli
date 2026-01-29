# TODO.md

## doc commands
* Create a doc section.
* Create a command called doc-api that will list all of the available endpoints categories, such as sites, servers, system users, etc.
* Typing -c doc sites will list all endpoints available for sites with a short description of each endpoint.
* Typing -c doc sites get-sites will show the full documentation for that endpoint including parameters
* Create a gp-inc-doc.sh file.

## gp-site-mig.sh
* Create a new command called gp-site-mig.sh that operates similar to gp-api.sh the goal of it is to migrate a site from one gridpane server on one account to another gridpane server on another account.
* The command will ask for the the following
  * -s <site>
  * -sp <source-site-profile>
  * -ss <source-server-id>
  * -dp <destination-site-profile>
  * -ds <destination-server-id>
* The command will allow you to run in a dry-run mode to see what will be done without actually doing it.
  * -n (dry-run)
* The command will allow you to run in verbose mode to see more details of what is happening
    * -v (verbose)
* The command will automatically log all actions into the logs folder each log item will be time stamped.
* The log file will be named gp-site-mig-<site>-<timestamp>.log
* The command will be broken into the following parts
* Part 1 - Validate Input
  * Confirm that the site exists on the source server
  * Confirm that the site eixts on the destination server
  * Store the following data
    * Source site ID
    * Source server IP
    * Source site system user
    * Destination site ID
    * Destination server IP
    * Destination site system user
    *  If anything fails here, exit the script with an error.
* Part 2 - Get Server IP's and confirm SSH and get Database Info
  * Confirm SSH connectivity to source and destination server
  * Get database name and store to use later, look in $HOME/sites/<site>/wp-config.php for DB_NAME
  * Confirm database exists on both source and destination servers
  * Confirm site directory, check under the two locations and make sure a htdocs is present
    * $HOME/sites/<site>
    * $HOME/home/<system-user>/sites/<site>
  * Store the site directory path to use later, don't include htdocs in the path
  *  If anything fails here, exit the script with an error.
* Part 3 - Test Rsync and Migrate Files
  * Source and destination test.
    * Confirm rsync is installed on server
    * Confirm access to the htdocs directory on the each server, it will be under the site directory
    * If anything fails here, exit the script with an error.
  * Rsync the htdocs folder from the source server to the destination server and log the rsync output.
* Part 4 - Migrate Database
  * Export the database from the source server using mysqldump and pipe it to mysql on the destination server.
  * Log the output of the database migration.
  * If anything fails here, exit the script with an error.
* Part 5 - Migrate Nginx Config
  * Check if there are files other than the following.
    * gspotofmobile.com-headers-csp.conf
    * gspotofmobile.com-sockfile.conf
  * If there are print them out.
  * If you find the following run the following command via the gp command
    * disable-xmlrpc-main-context.conf = gp site {site.url} -disable-xmlrpc
    * disable-wp-trackbacks-main-context.conf = gp site {site.url} -block-wp-trackbacks.php
    * disable-wp-links-opml-main-context.conf = gp site {site.url} -block-wp-links-opml.php
    * disable-wp-comments-post-main-context.conf = gp site {site.url} -block-wp-comments-post.php
  * copy and tar up the nginx files and place them in the site directory on the destination server as nginx-{site}-backup-{timestamp}.tar.gz
* Part 6 - Copy user-config.php if it exists
  * Check if user-config.php exists in the site directory on the source server
  * If it does, copy it to the destination server site directory
  * Backup the same user-config.php on the destination server by copying and naming it user-config-{timestamp}.php
* Part 7 - Final Steps
  * Clear cache on destination server via gp command
  * Print out a summary of the migration including any errors that may have occurred.

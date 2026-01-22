# gridpane-bash-cli
A Bash CLI for GridPane API

# Setup
1. Clone the repository:
2. Create $HOME/.gridpane file
```
GPBC_TOKEN_DEFAULT=<token>
GPBC_TOKEN_CUSTOMER=<token>
```

# Usage

## Reports

### report-server-sites
Generate a report of total sites per server (alphabetically sorted).

**Default output (formatted table):**
```bash
./gp-api.sh -c report-server-sites
```

Output:
```
Server ID  Server Name  Total Sites
==========================================
1          server1      10
2          server2      5
```

**CSV output:**
```bash
./gp-api.sh -c report-server-sites --csv
```

Output:
```
"server_id","server_name","total_sites"
"1","server1","10"
"2","server2","5"
```

You can export to a file:
```bash
./gp-api.sh -c report-server-sites --csv > report.csv
```
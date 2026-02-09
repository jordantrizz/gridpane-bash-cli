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

## Migration examples
- Example seed files for gp-site-mig.sh live in [conf/gp-site-mig.json.example](conf/gp-site-mig.json.example) and [conf/gp-site-mig.csv.example](conf/gp-site-mig.csv.example).
- Rocket.net-to-GridPane samples: [conf/rocket-gp-site-mig.json.example](conf/rocket-gp-site-mig.json.example) and [conf/rocket-gp-site-mig.csv.example](conf/rocket-gp-site-mig.csv.example).
- Run gp-site-mig with `--json conf/rocket-gp-site-mig.json.example` or `--csv conf/rocket-gp-site-mig.csv.example` to seed state; Rocket-style `public_html` docroots are accepted via the normalization logic in [gp-site-mig.sh](gp-site-mig.sh#L1739-L1765).
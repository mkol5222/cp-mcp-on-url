
### Note

based on Killercoda lab https://killercoda.com/94180bda-4838-456f-89db-fb7fef3a6b02/scenario/mcp

# CP MCPs over HTTP with Docker Compose

Same as Step 0, but everything is wired together with Docker Compose: both MCP servers run in HTTP transport mode and Caddy reverse-proxies them. Inside the Compose network the services reach each other by name, so the proxy targets `quantum-management-mcp:3001` and `management-logs-mcp:3000`.

Bring your own S1C demo instance with variables:

```
# replace with valid values for your S1C demo instance
export API_KEY=k9EV3u0cYYlRG7TWukG02Q==
export S1C_URL=https://chkp-internal--m-cdknrbfc.maas.checkpoint.com/66c7a3d2-beab-4426-9714-27a57c304bb0/web_api/
```{{exec}}

Write the Compose file
```
cat > docker-compose.yml <<'EOF'
services:
  quantum-management-mcp:
    image: node:24
    entrypoint: npx
    environment:
      MCP_TRANSPORT_TYPE: http
      MCP_TRANSPORT_PORT: "3001"
      API_KEY: ${API_KEY}
      S1C_URL: ${S1C_URL}
    command: ["--", "npx", "@chkp/quantum-management-mcp"]

  management-logs-mcp:
    image: node:24
    entrypoint: npx
    environment:
      MCP_TRANSPORT_TYPE: http
      MCP_TRANSPORT_PORT: "3000"
      API_KEY: ${API_KEY}
      S1C_URL: ${S1C_URL}
    command: ["--", "npx", "@chkp/management-logs-mcp"]

  caddy:
    image: caddy:2.11-alpine
    ports:
      - "8080:8080"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
    depends_on:
      - quantum-management-mcp
      - management-logs-mcp
EOF
```{{exec}}

Write a Compose-aware Caddyfile (routes to service names instead of IPs)
```
cat > Caddyfile <<'EOF'
:8080 {
        log {
                output stdout
                format console
        }

        @unauthorized not header X-Api-Key vpn123
        handle @unauthorized {
                header Content-Type text/plain
                respond "401 Unauthorized: valid X-Api-Key header required" 401
        }

        handle_path /logs/* {
                reverse_proxy management-logs-mcp:3000 {
                        flush_interval -1
                }
        }

        handle_path /quantum/* {
                reverse_proxy quantum-management-mcp:3001 {
                        flush_interval -1
                }
        }

        handle {
                header Content-Type text/plain
                respond "Check Point MCP proxy. Endpoints: /logs/mcp  /quantum/mcp" 404
        }
}
EOF
```{{exec}}

Bring the whole stack up on port [8080]({{TRAFFIC_HOST1_8080}})
```
docker-compose up
```{{exec}}

Test it (from another terminal)
```
curl localhost:8080 -H 'X-Api-Key: vpn123'; echo

curl localhost:8080/logs/health -v -H 'X-Api-Key: vpn123'; echo

curl localhost:8080/quantum/health -v -H 'X-Api-Key: vpn123'; echo
```{{exec}}

Tear it down
```
docker-compose down
```{{exec}}

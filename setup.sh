#!/bin/bash
set -e

echo ""
echo "========================================"
echo "  OpenClaw + n8n Stack Setup"
echo "  Secure, isolated deployment"
echo "========================================"
echo ""

#######################################
# COLLECT USER INPUT
#######################################

read -p "Enter your Telegram Bot Token: " TELEGRAM_BOT_TOKEN
read -p "Enter your Telegram User ID: " TELEGRAM_USER_ID
read -p "Enter your OpenAI API Key: " OPENAI_API_KEY

# Auto-detect IP
DETECTED_IP=$(curl -s ifconfig.me)
read -p "Enter your Droplet IP [${DETECTED_IP}]: " DROPLET_IP
DROPLET_IP=${DROPLET_IP:-$DETECTED_IP}
DOMAIN_NAME="${DROPLET_IP}.nip.io"

echo ""
echo "Using domain: ${DOMAIN_NAME}"
echo ""

#######################################
# AUTO-GENERATED SECRETS
#######################################
GATEWAY_TOKEN=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 16)
N8N_ENCRYPTION_KEY=$(openssl rand -hex 16)
N8N_WEBHOOK_SECRET=$(openssl rand -hex 32)
N8N_WEBHOOK_PATH=$(cat /proc/sys/kernel/random/uuid)

echo "=== Installing dependencies ==="
apt update && apt install -y docker.io docker-compose-v2 ufw

echo "=== Configuring firewall ==="
ufw allow 22    # SSH
ufw allow 80    # HTTP
ufw allow 443   # HTTPS
ufw --force enable

echo "=== Creating directories ==="
mkdir -p /opt/openclaw
mkdir -p /opt/clawdbot/caddy_config
mkdir -p /opt/clawdbot/local_files
mkdir -p /root/.openclaw/workspace/skills/n8n-webhook

echo "=== Creating OpenClaw config ==="
cat > /root/.openclaw/openclaw.json << EOF
{
  "messages": {"ackReactionScope": "group-mentions"},
  "agents": {
    "defaults": {
      "maxConcurrent": 4,
      "subagents": {"maxConcurrent": 8},
      "compaction": {"mode": "safeguard"},
      "workspace": "/home/node/.openclaw/workspace",
      "model": {"primary": "openai/gpt-4.1-mini"},
      "models": {"openai/gpt-4.1-mini": {}}
    }
  },
  "gateway": {
    "mode": "local",
    "auth": {"mode": "token", "token": "${GATEWAY_TOKEN}"},
    "port": 18789,
    "bind": "lan",
    "tailscale": {"mode": "off", "resetOnExit": false},
    "remote": {"token": "${GATEWAY_TOKEN}"}
  },
  "plugins": {"entries": {"telegram": {"enabled": true}}},
  "channels": {
    "telegram": {
      "enabled": true,
      "botToken": "${TELEGRAM_BOT_TOKEN}",
      "dmPolicy": "allowlist",
      "allowFrom": ["${TELEGRAM_USER_ID}"]
    }
  },
  "hooks": {
    "internal": {
      "enabled": true,
      "entries": {
        "session-memory": {"enabled": true},
        "command-logger": {"enabled": true}
      }
    }
  }
}
EOF

echo "=== Creating n8n webhook skill ==="
cat > /root/.openclaw/workspace/skills/n8n-webhook/SKILL.md << EOF
---
name: n8n-webhook
description: Trigger n8n workflows via webhook. Use this when you need to execute automations, run workflows, or integrate with external services through n8n.
---

# n8n Webhook Integration

## Endpoint
Internal URL: \`http://n8n:5678/webhook/${N8N_WEBHOOK_PATH}\`

## Authentication
All requests MUST include this header:
- Header: \`X-Webhook-Secret\`
- Value: \`${N8N_WEBHOOK_SECRET}\`

## How to use
Use the \`exec\` tool to call the n8n webhook with curl:

\`\`\`bash
curl -X POST "http://n8n:5678/webhook/${N8N_WEBHOOK_PATH}" \\
  -H "Content-Type: application/json" \\
  -H "X-Webhook-Secret: ${N8N_WEBHOOK_SECRET}" \\
  -d '{"task": "description of what to do", "data": {}}'
\`\`\`

## Notes
- Always include the X-Webhook-Secret header or the request will fail
- Send JSON payload describing the task or data
- n8n will process the workflow and return a response
EOF

echo "=== Creating Caddyfile ==="
cat > /opt/clawdbot/caddy_config/Caddyfile << EOF
n8n.${DOMAIN_NAME} {
    reverse_proxy n8n:5678
}
EOF

echo "=== Creating .env file ==="
cat > /opt/openclaw/.env << EOF
OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}
N8N_SUBDOMAIN=n8n
DOMAIN_NAME=${DOMAIN_NAME}
POSTGRES_USER=n8n
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=n8n
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
OPENAI_API_KEY=${OPENAI_API_KEY}
EOF

echo "=== Creating docker-compose.yml ==="
cat > /opt/openclaw/docker-compose.yml << 'COMPOSEFILE'
networks:
  frontend:
  backend:
    internal: true
  egress:

volumes:
  caddy_data:
  n8n_data:
  postgres_data:

services:
  openclaw-gateway:
    image: ghcr.io/openclaw/openclaw:latest
    container_name: openclaw-gateway
    restart: unless-stopped
    user: "1000:1000"
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    environment:
      - OPENAI_API_KEY=${OPENAI_API_KEY}
    volumes:
      - /root/.openclaw:/home/node/.openclaw
    networks:
      - egress

  caddy:
    image: caddy:2-alpine
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /opt/clawdbot/caddy_config/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - /opt/clawdbot/local_files:/srv
    networks:
      - frontend

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB}
      - DB_POSTGRESDB_USER=${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - N8N_HOST=n8n.${DOMAIN_NAME}
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://n8n.${DOMAIN_NAME}/
    volumes:
      - n8n_data:/home/node/.n8n
    depends_on:
      - postgres
      - redis
    networks:
      - frontend
      - backend
      - egress

  n8n-worker:
    image: n8nio/n8n:latest
    container_name: n8n-worker
    restart: unless-stopped
    command: worker
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB}
      - DB_POSTGRESDB_USER=${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
    volumes:
      - n8n_data:/home/node/.n8n
    depends_on:
      - postgres
      - redis
      - n8n
    networks:
      - backend

  postgres:
    image: postgres:16-alpine
    container_name: postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - backend

  redis:
    image: redis:7-alpine
    container_name: redis
    restart: unless-stopped
    networks:
      - backend
COMPOSEFILE

echo "=== Setting permissions ==="
chown -R 1000:1000 /root/.openclaw

echo "=== Starting services ==="
cd /opt/openclaw
docker compose up -d

echo ""
echo "========================================"
echo "  SETUP COMPLETE!"
echo "========================================"
echo ""
echo "n8n URL: https://n8n.${DOMAIN_NAME}"
echo ""
echo "----------------------------------------"
echo "n8n Webhook Configuration:"
echo "----------------------------------------"
echo "  Webhook Path: ${N8N_WEBHOOK_PATH}"
echo "  Header Auth Name: X-Webhook-Secret"
echo "  Header Auth Value: ${N8N_WEBHOOK_SECRET}"
echo ""
echo "----------------------------------------"
echo "OpenClaw Gateway Token: ${GATEWAY_TOKEN}"
echo "----------------------------------------"
echo ""
echo "To send messages from n8n to OpenClaw/Telegram:"
echo ""
echo "  URL: http://openclaw-gateway:18789/tools/invoke"
echo "  Method: POST"
echo "  Headers:"
echo "    Authorization: Bearer ${GATEWAY_TOKEN}"
echo "    Content-Type: application/json"
echo "  Body:"
echo '    {"tool":"sessions_send","args":{"sessionKey":"agent:main:main","message":"Hello from n8n!","timeoutSeconds":0}}'
echo ""
echo "----------------------------------------"
echo "SAVE THESE VALUES - You will need them!"
echo "----------------------------------------"
echo ""

# OpenClaw + n8n Starter

One-command deployment of OpenClaw AI agent with n8n workflow automation on Digital Ocean.

## What You Get

- **OpenClaw** - AI agent accessible via Telegram
- **n8n** - Workflow automation with web UI
- **Caddy** - Automatic HTTPS
- **PostgreSQL** - Database for n8n
- **Redis** - Queue for n8n workers

## Architecture

```
Internet
    │
    ├─── Telegram ──────────► OpenClaw (internal only)
    │                              │
    │                              ▼
    └─── HTTPS ──► Caddy ──► n8n ◄─┘
                              │
                              ▼
                    PostgreSQL + Redis (internal)
```

**Security:**
- OpenClaw is NOT exposed to the internet (only accessible internally)
- n8n webhooks protected with header authentication
- PostgreSQL/Redis on isolated internal network

## Prerequisites

1. **Digital Ocean Droplet** - Ubuntu 24.04, 2GB+ RAM recommended
2. **Telegram Bot Token** - Get from [@BotFather](https://t.me/botfather)
3. **Telegram User ID** - Get from [@userinfobot](https://t.me/userinfobot)
4. **OpenAI API Key** - Get from [OpenAI](https://platform.openai.com/api-keys)

## Installation

SSH into your droplet and run:

```bash
curl -sL https://raw.githubusercontent.com/Barty-Bart/openclaw-n8n-starter/main/setup.sh -o setup.sh
chmod +x setup.sh
./setup.sh
```

The script will ask for:
- Telegram Bot Token
- Telegram User ID  
- OpenAI API Key
- Droplet IP (auto-detected)

## After Installation

1. **Access n8n**: `https://n8n.YOUR_IP.nip.io`
2. **Message your Telegram bot** to start chatting with OpenClaw
3. **Create workflows** in n8n that OpenClaw can trigger

## Connecting n8n ↔ OpenClaw

### OpenClaw → n8n (trigger workflows)

OpenClaw has an `n8n-webhook` skill. Ask it to trigger your workflow and it will call the webhook.

In n8n, create a Webhook node with:
- **Authentication**: Header Auth
- **Header Name**: `X-Webhook-Secret`
- **Header Value**: (shown after install)

### n8n → OpenClaw (send Telegram messages)

Use HTTP Request node in n8n:

- **URL**: `http://openclaw-gateway:18789/tools/invoke`
- **Method**: POST
- **Headers**:
  - `Authorization`: `Bearer YOUR_GATEWAY_TOKEN`
  - `Content-Type`: `application/json`
- **Body**:
```json
{
  "tool": "sessions_send",
  "args": {
    "sessionKey": "agent:main:main",
    "message": "Hello from n8n!",
    "timeoutSeconds": 0
  }
}
```

## Useful Commands

```bash
# View logs
cd /opt/openclaw
docker compose logs -f

# Restart services
docker compose restart

# Stop everything
docker compose down

# Start everything
docker compose up -d

# Check OpenClaw skills
docker compose run --rm openclaw-cli skills list
```

## Troubleshooting

**Bot not responding?**
```bash
docker compose logs openclaw-gateway
```

**n8n not loading?**
```bash
docker compose logs caddy
docker compose logs n8n
```

**Webhook not working?**
- Check the webhook path matches
- Check the X-Webhook-Secret header is correct
- Use internal URL: `http://n8n:5678/webhook/...`

## ⚠️ Disclaimer

**Use at your own risk.** I've tried to make this secure, but it is NOT 100% perfect.

This is great for **testing and learning**. For **production use**, you'll need to do additional security hardening yourself.

I'm not responsible for any issues, data loss, security breaches, etc.

## Credits

- [OpenClaw](https://github.com/openclaw/openclaw)
- [n8n](https://n8n.io)
- Setup by [Bart S](https://www.youtube.com/@BartSlodyczka)

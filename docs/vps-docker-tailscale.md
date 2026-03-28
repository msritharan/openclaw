# VPS Docker + Tailscale Deployment

Run OpenClaw in a Docker container on a Hetzner VPS with Tailscale for secure VPN access.

## What Gets Deployed

**Containerized services:**
- `openclaw-gateway`: The main AI gateway (port 18789, bound to loopback only)

**Persistent data (on host filesystem):**
- `/opt/openclaw/data/.openclaw/` — config, credentials, sessions, memory, logs
- `/opt/openclaw/data/.openclaw/workspace/` — agent workspace files

**Network:**
- Gateway bound to `127.0.0.1:18789` (loopback only, no direct exposure)
- Access via Tailscale VPN network only

---

## Quick Start

### 1. Provision VPS

Rent a small VPS (1-2 GB RAM minimum, Debian/Ubuntu). Point DNS A record to your VPS IP.

### 2. SSH as root

```bash
ssh root@your-vps-ip
```

### 3. Install Docker

```bash
apt-get update && apt-get install -y git curl ca-certificates
curl -fsSL https://get.docker.com | sh
```

### 4. Clone Repo + Build Image

```bash
git clone https://github.com/openclaw/openclaw.git /opt/openclaw
cd /opt/openclaw
docker build -t openclaw:local .
```

### 5. Create Host Directories

```bash
mkdir -p /opt/openclaw/data/.openclaw/workspace
chown -R 1000:1000 /opt/openclaw/data
```

### 6. Create `.env` File

```bash
cat > /opt/openclaw/.env << 'EOF'
OPENCLAW_IMAGE=openclaw:local
OPENCLAW_GATEWAY_TOKEN=<generate with openssl rand -hex 32>
OPENCLAW_GATEWAY_BIND=loopback
OPENCLAW_CONFIG_DIR=/opt/openclaw/data/.openclaw
OPENCLAW_WORKSPACE_DIR=/opt/openclaw/data/.openclaw/workspace
OPENCLAW_GATEWAY_PORT=18789
TZ=UTC
EOF
```

### 7. Update docker-compose.yml

The existing `docker-compose.yml` needs these minimal changes:

```yaml
services:
  openclaw-gateway:
    image: openclaw:local
    restart: unless-stopped
    env_file:
      - .env
    environment:
      HOME: /home/node
      NODE_ENV: production
    volumes:
      - /opt/openclaw/data/.openclaw:/home/node/.openclaw
    # No ports exposed - only accessible via Tailscale network
    command:
      - node
      - dist/index.js
      - gateway
      - --bind
      - loopback
      - --port
      - "18789"
      - --allow-unconfigured
```

### 8. Install Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --operator=root
```

Copy the **Tailscale IP** (e.g., `100.x.x.x`) shown after login.

### 9. Install Tailscale on Your Devices

Download Tailscale apps for your laptop/phone/tablet and log in with the same auth key.

Devices on your Tailscale network can then access the gateway at `http://100.X.X.X:18789`.

### 10. Start Gateway

```bash
cd /opt/openclaw
docker compose up -d
docker compose logs -f
```

### 11. Enable Services on Boot

```bash
systemctl enable docker
systemctl enable tailscaled
```

### 12. Initial Setup

Open `http://<TAILSCALE_IP>:18789` from your laptop (connected to Tailscale) and enter your gateway token.

---

## Backup Strategy

### Option A: Built-in Backup Command

OpenClaw has a built-in `openclaw backup create` command. Run periodically:

```bash
docker compose exec openclaw-gateway openclaw backup create --output /opt/openclaw/backups
```

### Option B: Simple Cron Backup

```bash
# Add to crontab - backup daily at 3am
0 3 * * * docker compose -f /opt/openclaw/docker-compose.yml exec openclaw-gateway openclaw backup create --output /opt/openclaw/backups >> /var/log/openclaw-backup.log 2>&1
```

### What to Back Up

The backup archive includes:
- `~/.openclaw/openclaw.json` — config
- `~/.openclaw/.env` — secrets
- `~/.openclaw/credentials/` — OAuth tokens, channel credentials
- `~/.openclaw/agents/` — session transcripts
- `~/.openclaw/memory/` — memory SQLite database

### Manual Backup (files)

```bash
tar -czf openclaw-backup-$(date +%Y%m%d).tar.gz \
  -C /opt/openclaw/data .openclaw/openclaw.json \
  -C /opt/openclaw/data .openclaw/.env \
  -C /opt/openclaw/data .openclaw/credentials \
  -C /opt/openclaw/data .openclaw/agents
```

---

## VPS Outage Recovery

### Scenario 1: VPS Goes Down Completely (Hetzner)

1. Hetzner Rescue mode: Boot into rescue, fsck/check disk
2. If unrecoverable, provision new Hetzner VPS
3. Clone repo, rebuild Docker image
4. Restore from backup (see Backup section)
5. Reinstall Tailscale: `tailscale up`
6. Restart container

### Scenario 2: Container Crashes

```bash
docker compose restart openclaw-gateway
docker compose logs --tail=50 openclaw-gateway
```

### Scenario 3: VPS Reboots

Docker Compose with `restart: unless-stopped` auto-restarts the container after reboot. Tailscale also auto-starts on boot (if enabled with `systemctl enable tailscaled`).

### Scenario 4: Data Corruption

1. Stop container: `docker compose stop`
2. Restore from backup archive to `/opt/openclaw/data/.openclaw/`
3. Restart: `docker compose up -d`

### Scenario 5: Backup Files Lost

If `/opt/openclaw/backups/` is lost but VPS is running:
- You still have the data at `/opt/openclaw/data/.openclaw/`
- Create new backup: `docker compose exec openclaw-gateway openclaw backup create --output /opt/openclaw/backups`

---

## Security Checklist

- [ ] Change `OPENCLAW_GATEWAY_TOKEN` from default (generate new with `openssl rand -hex 32`)
- [ ] Gateway bound to `loopback` (only accessible via Tailscale)
- [ ] Tailscale ACL policy restricts access to your devices only
- [ ] No ports exposed on public network
- [ ] `.env` file is not committed to git (add to `.gitignore` if you fork)

---

## Accessing the Gateway

After Tailscale is set up, gateway is accessible at:
```
http://<VPS_TAILSCALE_IP>:18789
```

Example: `http://100.84.123.45:18789`

On your first access, you'll enter the `OPENCLAW_GATEWAY_TOKEN` from your `.env` file.

---

## Adding Channels Later

After initial setup, configure channels (Discord, Telegram, etc.) via:

```bash
docker compose exec openclaw-gateway openclaw channels configure
```

Or use the web UI at `http://YOUR_VPS_IP:18789`

---

## CLI Service (Optional)

The CLI container is optional. Without it, you run commands via:

```bash
docker compose exec openclaw-gateway openclaw <command>
```

CLI commands available:
- `openclaw configure` — initial gateway setup
- `openclaw channels configure` — configure messaging channels
- `openclaw status` — check gateway status
- `openclaw backup create` — create backups
- `openclaw plugins` — manage plugins

**Recommendation:** Skip the CLI service for minimal setup. Use `docker compose exec` when needed.

---

## Files to Create/Modify

1. `/opt/openclaw/.env` — environment variables (create)
2. `/opt/openclaw/docker-compose.yml` — compose config (update existing)
3. `/opt/openclaw/backups/` — backup directory (create)

---

## Verification Steps

1. `docker compose ps` — verify container is running
2. `curl http://127.0.0.1:18789/healthz` — verify gateway health (on VPS)
3. `curl http://<TAILSCALE_IP>:18789/healthz` — verify Tailscale access (from your laptop)
4. Access `http://<TAILSCALE_IP>:18789` in browser — enter gateway token to connect

---

## Provider-Specific Docs (Reference)

- Hetzner: `docs/install/hetzner.md`
- Generic VPS: `docs/vps.md`
- Docker: `docs/install/docker.md`
- Backup CLI: `docs/cli/backup.md`

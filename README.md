# cloudflare-npm

Publish services from any machine — including ones behind CGNAT — with
[Nginx Proxy Manager](https://nginxproxymanager.com/) and a
[Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/),
without ever touching the Cloudflare dashboard after setup.

Add a proxy host in NPM's UI, and within ~30 seconds `https://<that-host>` is live on the internet.

```
 browser ──HTTPS──▶ Cloudflare edge ══ tunnel (outbound only) ══▶ cloudflared ──HTTP──▶ NPM ──▶ your services
                         ▲                                                               │
                         └──── DNS records + tunnel routes ◀──── cf-sync ◀── reads hosts ┘
```

| Container | Image | Role |
|---|---|---|
| `nginx-proxy-manager` | `jc21/nginx-proxy-manager` | Routes each hostname to a service. You manage hosts in its web UI. |
| `cloudflared` | `cloudflare/cloudflared` | Keeps an outbound tunnel to Cloudflare. No open ports or public IP needed. |
| `cf-sync` | `ghcr.io/gauravsuman007/npm-cf-sync` | Watches NPM's hosts and creates/removes the matching Cloudflare DNS records and tunnel routes. |

## How cf-sync works

Every 30 seconds cf-sync reads NPM's database (read-only) and, for each **enabled**
proxy, redirection or 404 host whose domain belongs to one of your Cloudflare zones:

- creates a **proxied CNAME** `<host> → <tunnel-id>.cfargotunnel.com`, and
- adds a **public hostname rule** to the tunnel sending `<host>` to NPM.

When you disable or delete the host in NPM, both are removed again.

It's careful about what it touches:

- DNS records it creates are tagged with the comment `managed-by:npm-cf-sync tunnel:<id>`; only tagged
  records are ever deleted. Existing records are never changed — if a name is already taken by
  another record, cf-sync logs `SKIP` and leaves it.
- Tunnel rules pointing anywhere other than NPM (e.g. ones you added in the dashboard) are kept.
- If NPM's database can't be read, the pass is skipped rather than treated as "no hosts".

## Setup

You need a domain on Cloudflare (the free plan is fine) and Docker with Compose.

### 1. Create the tunnel

1. In the Cloudflare dashboard open **Zero Trust → Networks → Tunnels → Create a tunnel**.
2. Choose **Cloudflared**, name it (e.g. after the machine), and save.
3. On the install step, copy the token — the long string after `--token` in any of the
   install commands. That's your `TUNNEL_TOKEN`. You don't need to run the install command.
4. Skip adding a public hostname; cf-sync does that for you.

### 2. Create an API token

1. Go to **My Profile → API Tokens → Create Token → Create Custom Token**.
2. Permissions:
   - **Account** · Cloudflare Tunnel · **Edit**
   - **Zone** · Zone · **Read**
   - **Zone** · DNS · **Edit**
3. Account resources: the account that owns the tunnel. Zone resources: the domain(s) you'll use.
4. Create it and copy the token. That's your `CF_API_TOKEN`.

### 3. Start it

```bash
git clone https://github.com/gauravsuman007/cloudflare-npm.git
cd cloudflare-npm
cp .env.example .env     # paste TUNNEL_TOKEN and CF_API_TOKEN
docker compose up -d
docker compose logs -f cf-sync
```

You should see a line like
`start: tunnel=… zones=example.com manage_ingress=true interval=30s`.
In the dashboard the tunnel should show as **Healthy**.

> `.env` holds credentials. Keep it out of version control (it's in `.gitignore`).

### 4. Add a site

1. Open NPM at `http://<machine>:81` (first login: `admin@example.com` / `changeme`, you'll be asked to change it).
2. **Hosts → Proxy Hosts → Add Proxy Host**
   - **Domain Names:** `app.example.com`
   - **Scheme / Forward Hostname / Port:** where the service listens, as seen from inside the NPM
     container. For a service on the same machine use the Docker host's address
     (e.g. `172.17.0.1`, or the host's LAN IP); for another container on the same Docker network,
     use its container name.
   - Turn on **Block Common Exploits** and **Websockets Support**.
   - **SSL tab: leave it on "None"**, with Force SSL off. Cloudflare terminates HTTPS at its edge and
     the tunnel speaks plain HTTP to NPM; forcing SSL in NPM causes a redirect loop.
3. Save. Within ~30 s cf-sync logs `dns: created app.example.com` and the site is live at
   `https://app.example.com`.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `TUNNEL_TOKEN` | | Tunnel token. cf-sync reads the tunnel and account IDs from it. |
| `CF_API_TOKEN` | | API token (permissions above). |
| `ZONES` | all zones the token can see | Comma-separated list of zones to manage, e.g. `example.com,example.org`. |
| `INTERVAL` | `30` | Seconds between sync passes. |
| `ORIGIN` | `http://nginx-proxy-manager:80` | Where tunnel routes point. |
| `MANAGE_INGRESS` | `true` with `TUNNEL_TOKEN`, else `false` | Whether to manage the tunnel's public hostname rules. |
| `TUNNEL_ID` | from `TUNNEL_TOKEN` | Tunnel UUID, for locally-managed tunnels (see below). |
| `CF_ACCOUNT_ID` | from `TUNNEL_TOKEN` / cert | Account ID, if it can't be derived. |
| `DB` | `/npm/database.sqlite` | Path to NPM's database inside the container. |
| `CERT` | `/cert.pem` | cloudflared origin certificate, used when `CF_API_TOKEN` is unset. |

### Using an existing locally-managed tunnel

If you already run `cloudflared` on the host with a `config.yml` (created with
`cloudflared tunnel login` / `tunnel create`), point that config's catch-all rule at NPM:

```yaml
ingress:
  - service: http://localhost:80   # NPM, with port 80 published
```

Then drop the `cloudflared` service from the compose file and give cf-sync your tunnel ID and the
login certificate instead of the two tokens. It will manage DNS only:

```yaml
  cf-sync:
    image: ghcr.io/gauravsuman007/npm-cf-sync:latest
    environment:
      TUNNEL_ID: <tunnel uuid>
    volumes:
      - ./data:/npm:ro
      - ~/.cloudflared/cert.pem:/cert.pem:ro
```

The certificate only covers the zone you picked during `cloudflared tunnel login`.

## Limitations

- **Multi-level subdomains** such as `app.home.example.com` aren't covered by Cloudflare's free
  certificate (it covers `example.com` and `*.example.com` only). cf-sync still creates the record
  but logs a warning; you'd need Advanced Certificate Manager for those to work over HTTPS.
  Prefer flat names such as `home-app.example.com`.
- Cloudflare Tunnel carries **HTTP(S) only** for browsers. Raw TCP/UDP services (game servers,
  WireGuard) need another route.
- Cloudflare's free plan limits request bodies to 100 MB and requests to ~100 s.
- **Architectures:** `npm-cf-sync` is built for `amd64`, `arm64` and `armv7`. The whole stack runs
  on any 64-bit machine (x86 servers, 64-bit Raspberry Pi OS, ARM phones/SBCs). On **32-bit ARM**
  (armv7, e.g. older Raspberry Pis or 32-bit Raspberry Pi OS) the upstream
  `cloudflare/cloudflared` and `jc21/nginx-proxy-manager:latest` images currently have no build, so
  there run cloudflared from its [release binaries](https://github.com/cloudflare/cloudflared/releases)
  with the locally-managed setup above, and an armv7-capable NPM tag.

## Images

Built by GitHub Actions on every push to `main` — `amd64` and `arm64` on native runners, `armv7`
under QEMU — and published as one multi-arch image:

- `ghcr.io/gauravsuman007/npm-cf-sync:latest` — latest `main`
- `ghcr.io/gauravsuman007/npm-cf-sync:sha-<commit>` — a specific build
- `ghcr.io/gauravsuman007/npm-cf-sync:<version>` — tagged releases (`v1.2.3` → `1.2.3`, `1.2`)

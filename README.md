# cloudflare-npm

Publish services from any machine — including ones behind CGNAT, with no public IP or open
ports — using [Nginx Proxy Manager](https://nginxproxymanager.com/) and a
[Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/).

Add a proxy host in NPM's UI, and within ~30 seconds `https://<that-host>` is live on the internet.
Everything runs in Docker; nothing is installed on the host.

```
 browser ──HTTPS──▶ Cloudflare edge ══ tunnel (outbound only) ══▶ cloudflared ──HTTP──▶ NPM ──▶ your services
                         ▲                                                               │
                         └──── DNS records (+ tunnel routes) ◀── cf-sync ◀── reads hosts ┘
```

| Container | Image | Role |
|---|---|---|
| `nginx-proxy-manager` | `jc21/nginx-proxy-manager` | Routes each hostname to a service. You manage hosts in its web UI. |
| `cloudflared` | `ghcr.io/gauravsuman007/npm-cf-sync` (`cf-tunnel`) | Logs in to Cloudflare, creates the tunnel if needed, and keeps it connected. |
| `cf-sync` | `ghcr.io/gauravsuman007/npm-cf-sync` | Watches NPM's hosts and creates/removes the matching Cloudflare DNS records. |

## Setup

You need a domain on Cloudflare (the free plan is fine) and Docker with Compose, on an
`amd64` or `arm64` machine.

```bash
git clone https://github.com/gauravsuman007/cloudflare-npm.git
cd cloudflare-npm
```

Then connect it to Cloudflare in one of two ways.

### Option A — click a login link (simplest)

```bash
docker compose up -d
docker compose logs -f cloudflared
```

The log shows a link like

```
cf-tunnel: >>> Open the URL below, sign in, and pick the domain to use. <<<
Please open the following URL and log in with your Cloudflare account:
https://dash.cloudflare.com/argotunnel?aud=&callback=https%3A%2F%2Flogin.cloudflareaccess.org%2F…
```

1. Open it (from any device), sign in to Cloudflare, and click the domain you want to use.
2. Back in the log you'll see `created tunnel …` and `Registered tunnel connection` — you're done.
   `docker compose logs cf-sync` should show `start: … zones=<your domain>`.

The login and tunnel credentials are saved in `./cloudflared/`, so this happens only once.
The tunnel is named `cloudflare-npm`; set `TUNNEL_NAME` in `.env` to use another name
(e.g. one per machine).

This option manages **one domain** — the one you clicked. For several domains, use option B.

### Option B — dashboard tunnel and API token

Use this if you'd rather create the tunnel in the dashboard, or want to serve several domains.

1. **Tunnel:** Cloudflare dashboard → **Zero Trust → Networks → Tunnels → Create a tunnel** →
   **Cloudflared** → name it → save. On the install step copy the token (the long string after
   `--token`). Skip adding public hostnames; cf-sync does that.
2. **API token:** **My Profile → API Tokens → Create Token → Create Custom Token** with
   - Account · Cloudflare Tunnel · **Edit**
   - Zone · Zone · **Read**
   - Zone · DNS · **Edit**

   scoped to your account and the domain(s) you'll use.
3. Put both in `.env`:
   ```bash
   cp .env.example .env    # set TUNNEL_TOKEN and CF_API_TOKEN
   docker compose up -d
   ```

In this mode cf-sync also adds each NPM host as a **public hostname** on the tunnel, so they show
up in the dashboard.

> `.env` and `./cloudflared/` hold credentials. Keep them private (both are git-ignored).

## Add a site

1. Open NPM at `http://<machine>:81` (first login: `admin@example.com` / `changeme`; you'll be asked
   to change it).
2. **Hosts → Proxy Hosts → Add Proxy Host**
   - **Domain Names:** `app.example.com`
   - **Scheme:** `http` (or whatever the service speaks).
   - **Forward Hostname / IP:** `host.docker.internal` — the machine NPM runs on.
   - **Forward Port:** the port the service is published on (the left side of its `ports:` mapping,
     e.g. `8050` for `8050:8000`). Anything reachable on the host works, Docker or not.

     (Containers on the same Docker network as NPM can also be reached by container name and their
     internal port.)
   - Turn on **Block Common Exploits** and **Websockets Support**.
   - **SSL tab: leave it on "None"** with Force SSL off. Cloudflare handles HTTPS at its edge and
     the tunnel speaks plain HTTP to NPM; forcing SSL in NPM causes a redirect loop.
3. Save. Within ~30 s `docker compose logs cf-sync` shows `dns: created app.example.com` and the
   site is live at `https://app.example.com`.

Disable or delete the host in NPM and the record is removed again.

## How cf-sync works

Every `INTERVAL` seconds cf-sync reads NPM's database (read-only). For each **enabled** proxy,
redirection or 404 host whose domain belongs to one of your Cloudflare zones it makes sure there
is a **proxied CNAME** `<host> → <tunnel-id>.cfargotunnel.com` (and, in option B, a public
hostname rule on the tunnel pointing at NPM). Things that are no longer in NPM are removed.

It's careful about what it touches:

- DNS records it creates are tagged with the comment `managed-by:npm-cf-sync tunnel:<id>`, and only
  tagged records are ever deleted. Existing records are never changed — if a name is already taken
  by another record, cf-sync logs `SKIP` and leaves it alone.
- Tunnel rules pointing anywhere other than NPM (e.g. ones you added in the dashboard) are kept.
- If NPM's database can't be read, that pass is skipped rather than treated as "no hosts".

In option A the tunnel itself sends *every* hostname to NPM (a catch-all rule in
`./cloudflared/config.yml`), so only DNS needs managing.

## Configuration

| Variable | Default | Used by | Description |
|---|---|---|---|
| `TUNNEL_NAME` | `cloudflare-npm` | cloudflared | Name of the tunnel created in option A. |
| `TUNNEL_TOKEN` | | both | Option B: token of a dashboard-created tunnel. |
| `CF_API_TOKEN` | | cf-sync | Option B: API token (permissions above). |
| `ZONES` | all visible zones | cf-sync | Comma-separated zones to manage, e.g. `example.com,example.org`. |
| `INTERVAL` | `30` | cf-sync | Seconds between sync passes. |
| `ORIGIN` | `http://nginx-proxy-manager:80` | both | Where the tunnel sends traffic. |
| `MANAGE_INGRESS` | `true` in option B, else `false` | cf-sync | Manage the tunnel's public hostname rules. |
| `TUNNEL_ID` | from token / `config.yml` | cf-sync | Override the tunnel UUID. |
| `CF_ACCOUNT_ID` | from token / cert | cf-sync | Override the account ID. |

### Moving an existing tunnel in

If you already have a tunnel made with `cloudflared tunnel login` / `tunnel create` on the host,
copy `~/.cloudflared/cert.pem` and the tunnel's `<uuid>.json` into `./cloudflared/` before the
first start. `cf-tunnel` adopts that tunnel instead of creating a new one, and writes a
`config.yml` sending everything to NPM. You can then stop and remove the host's `cloudflared`.

To keep a hand-written `config.yml` in `./cloudflared/`, delete its first line (the
`# generated by cf-tunnel` marker) and it won't be overwritten.

## Limitations

- **Multi-level subdomains** such as `app.home.example.com` aren't covered by Cloudflare's free
  certificate (it covers `example.com` and `*.example.com` only). cf-sync still creates the record
  but logs a warning; those need Advanced Certificate Manager. Prefer flat names such as
  `home-app.example.com`.
- Cloudflare Tunnel carries **HTTP(S) only** for browsers. Raw TCP/UDP services (game servers,
  WireGuard) need another route.
- Cloudflare's free plan limits request bodies to 100 MB and requests to ~100 s.
- `amd64` and `arm64` only — Nginx Proxy Manager and cloudflared don't publish 32-bit ARM images.

## Images

Built by GitHub Actions on native `amd64` and `arm64` runners on every push to `main`, and
published as one multi-arch image (which bundles `cloudflared`):

- `ghcr.io/gauravsuman007/npm-cf-sync:latest` — latest `main`
- `ghcr.io/gauravsuman007/npm-cf-sync:sha-<commit>` — a specific build
- `ghcr.io/gauravsuman007/npm-cf-sync:<version>` — tagged releases (`v1.2.3` → `1.2.3`, `1.2`)

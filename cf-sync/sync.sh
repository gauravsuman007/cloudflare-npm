#!/bin/sh
# cf-sync: keeps Cloudflare in step with Nginx Proxy Manager.
#
# Every enabled NPM host (proxy, redirection, 404) whose domain belongs to one
# of your Cloudflare zones gets a proxied CNAME to the tunnel and, when the
# tunnel is managed remotely, a matching public-hostname rule in the tunnel.
# Records created here are tagged and removed again when the host goes away;
# anything not created here is never modified.
set -u

DB=${DB:-/npm/database.sqlite}
CERT=${CERT:-/cert.pem}
INTERVAL=${INTERVAL:-30}
ORIGIN=${ORIGIN:-http://nginx-proxy-manager:80}
ZONES=${ZONES:-}
CF_API_TOKEN=${CF_API_TOKEN:-}
TUNNEL_TOKEN=${TUNNEL_TOKEN:-}
TUNNEL_ID=${TUNNEL_ID:-}
ACCOUNT_ID=${CF_ACCOUNT_ID:-}
API=https://api.cloudflare.com/client/v4

log() { echo "$(date -u +%FT%TZ) $*"; }
die() { log "FATAL $*"; exit 1; }
b64d() { tr -d '\n' | tr '_-' '/+' | base64 -d 2>/dev/null; }

# --- credentials ----------------------------------------------------------
CERT_ZONE=""
if [ -z "$CF_API_TOKEN" ]; then
  [ -r "$CERT" ] || die "set CF_API_TOKEN, or mount cloudflared's cert.pem at $CERT"
  J=$(sed -n '/BEGIN/,/END/p' "$CERT" | grep -v -- ----- | b64d)
  CF_API_TOKEN=$(echo "$J" | jq -r .apiToken)
  CERT_ZONE=$(echo "$J" | jq -r .zoneID)
  [ -n "$ACCOUNT_ID" ] || ACCOUNT_ID=$(echo "$J" | jq -r '.accountID // empty')
fi

if [ -n "$TUNNEL_TOKEN" ]; then
  T=$(printf %s "$TUNNEL_TOKEN" | b64d)
  [ -n "$TUNNEL_ID" ] || TUNNEL_ID=$(echo "$T" | jq -r .t)
  [ -n "$ACCOUNT_ID" ] || ACCOUNT_ID=$(echo "$T" | jq -r .a)
fi
[ -n "$TUNNEL_ID" ] || die "set TUNNEL_TOKEN or TUNNEL_ID"

# Remotely-managed tunnels (created in the dashboard, run with a token) take
# their routing from Cloudflare, so we maintain it. Locally-managed tunnels
# route with their own config.yml and are left alone.
if [ -z "${MANAGE_INGRESS:-}" ]; then
  [ -n "$TUNNEL_TOKEN" ] && MANAGE_INGRESS=true || MANAGE_INGRESS=false
fi
[ "$MANAGE_INGRESS" = false ] || [ -n "$ACCOUNT_ID" ] || die "MANAGE_INGRESS needs CF_ACCOUNT_ID or TUNNEL_TOKEN"

TARGET="$TUNNEL_ID.cfargotunnel.com"
TAG="managed-by:npm-cf-sync tunnel:$TUNNEL_ID"
TUNNEL_API="$API/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations"

cf() { curl -s --max-time 30 -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" "$@"; }
ok() { [ "$(echo "$1" | jq -r .success 2>/dev/null)" = true ]; }
errs() { echo "$1" | jq -c '.errors // .' 2>/dev/null || echo "$1"; }

# --- zones ----------------------------------------------------------------
# "id name" lines, longest name first so the most specific zone wins.
load_zones() {
  if [ -n "$CERT_ZONE" ]; then
    r=$(cf "$API/zones/$CERT_ZONE")
    ok "$r" || return 1
    ZONE_LIST=$(echo "$r" | jq -r '.result | "\(.id) \(.name)"')
  else
    r=$(cf "$API/zones?per_page=50&status=active")
    ok "$r" || return 1
    ZONE_LIST=$(echo "$r" | jq -r '.result[] | "\(.id) \(.name)"')
  fi
  if [ -n "$ZONES" ]; then
    ZONE_LIST=$(echo "$ZONE_LIST" | grep -E " ($(echo "$ZONES" | sed 's/[.]/\\./g; s/ *, */|/g'))\$")
  fi
  ZONE_LIST=$(echo "$ZONE_LIST" | awk 'NF { print length($2), $0 }' | sort -rn | cut -d' ' -f2-)
  [ -n "$ZONE_LIST" ]
}

zone_of() {  # prints "id name" of the zone that owns $1, if any
  echo "$ZONE_LIST" | while read -r id name; do
    case "$1" in "$name"|*."$name") echo "$id $name"; break;; esac
  done
}

# --- NPM ------------------------------------------------------------------
# Prints wanted hostnames. Fails (non-zero) if the DB can't be read, so a
# transient read error never looks like "every host was deleted".
desired() {
  [ -r "$DB" ] || return 1
  rows=$(sqlite3 "file:$DB?immutable=1" "
    select domain_names from proxy_host       where is_deleted=0 and enabled=1
    union all select domain_names from redirection_host where is_deleted=0 and enabled=1
    union all select domain_names from dead_host        where is_deleted=0 and enabled=1;") || return 1
  echo "$rows" | jq -r '.[]?' | tr 'A-Z' 'a-z' | sort -u
}

# --- reconcile ------------------------------------------------------------
sync_dns() {  # $1 = wanted hostnames
  for line in $(echo "$ZONE_LIST" | tr ' ' '|'); do
    zid=${line%%|*}; zname=${line#*|}
    recs=$(cf "$API/zones/$zid/dns_records?per_page=5000")
    ok "$recs" || { log "list $zname failed: $(errs "$recs")"; continue; }

    for name in $1; do
      [ "$(zone_of "$name" | cut -d' ' -f1)" = "$zid" ] || continue
      cur=$(echo "$recs" | jq -c --arg n "$name" '[.result[] | select(.name == $n)]')
      if [ "$cur" = "[]" ]; then
        sub=${name%."$zname"}
        case "$sub" in *.*) log "WARN $name is a multi-level subdomain; Cloudflare's free certificate only covers *.$zname";; esac
        r=$(cf -X POST "$API/zones/$zid/dns_records" -d "$(jq -nc --arg n "$name" --arg c "$TARGET" --arg t "$TAG" \
              '{type:"CNAME", name:$n, content:$c, proxied:true, comment:$t}')")
        ok "$r" && log "dns: created $name" || log "dns: create $name failed: $(errs "$r")"
      elif ! echo "$cur" | jq -e --arg c "$TARGET" '.[] | select(.content == $c)' >/dev/null; then
        [ -n "$(echo "$SKIPPED" | grep -x "$name")" ] || log "dns: SKIP $name, it already has a record that doesn't point at this tunnel"
        SKIPPED=$(printf '%s\n%s' "$SKIPPED" "$name")
      fi
    done

    for rec in $(echo "$recs" | jq -r --arg t "$TAG" '.result[] | select(.comment == $t) | "\(.id)|\(.name)"'); do
      id=${rec%%|*}; name=${rec#*|}
      echo "$1" | grep -qxF "$name" && continue
      r=$(cf -X DELETE "$API/zones/$zid/dns_records/$id")
      ok "$r" && log "dns: deleted $name" || log "dns: delete $name failed: $(errs "$r")"
    done
  done
}

sync_ingress() {  # $1 = wanted hostnames
  r=$(cf "$TUNNEL_API")
  ok "$r" || { log "tunnel: read config failed: $(errs "$r")"; return; }
  cur=$(echo "$r" | jq -c '.result.config // {}')
  want=$(echo "$1" | jq -R . | jq -sc 'map(select(length > 0))')
  # Keep rules that point elsewhere (added by hand), rebuild ours, keep the catch-all.
  new=$(jq -nc --argjson cur "$cur" --argjson want "$want" --arg o "$ORIGIN" '
    ($cur.ingress // []) as $in
    | ($in | map(select(.hostname != null and .service != $o))) as $foreign
    | ($in | map(select(.hostname == null)) | last // {service: "http_status:404"}) as $catch
    | $cur + {ingress: ($foreign + ($want | map({hostname: ., service: $o})) + [$catch])}')
  [ "$(echo "$cur" | jq -Sc .)" = "$(echo "$new" | jq -Sc .)" ] && return
  r=$(cf -X PUT "$TUNNEL_API" -d "$(jq -nc --argjson c "$new" '{config: $c}')")
  ok "$r" && log "tunnel: routes now $(echo "$want" | jq -r 'join(", ")' | sed 's/^$/(none)/')" \
          || log "tunnel: update failed: $(errs "$r")"
}

# --- main -----------------------------------------------------------------
until load_zones; do log "cannot list zones (check token permissions / ZONES), retrying"; sleep "$INTERVAL"; done
log "start: tunnel=$TUNNEL_ID zones=$(echo "$ZONE_LIST" | cut -d' ' -f2 | paste -sd, -) manage_ingress=$MANAGE_INGRESS interval=${INTERVAL}s"

SKIPPED=""
n=0
while :; do
  if all=$(desired); then
    WANT=$(for h in $all; do [ -n "$(zone_of "$h")" ] && echo "$h"; done)
    sync_dns "$WANT"
    [ "$MANAGE_INGRESS" = false ] || sync_ingress "$WANT"
  else
    log "cannot read $DB yet, skipping this pass"
  fi
  n=$((n + 1)); [ $((n % 120)) -eq 0 ] && load_zones  # pick up new zones now and then
  sleep "$INTERVAL"
done

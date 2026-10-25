FROM cloudflare/cloudflared:2026.10.3 AS cloudflared

FROM alpine:3.22
RUN apk add --no-cache sqlite curl jq ca-certificates
COPY --from=cloudflared /usr/local/bin/cloudflared /usr/local/bin/cloudflared
COPY sync.sh /usr/local/bin/cf-sync
COPY cf-tunnel.sh /usr/local/bin/cf-tunnel
RUN chmod +x /usr/local/bin/cf-sync /usr/local/bin/cf-tunnel
# cf-sync by default; the compose file runs `cf-tunnel` for the tunnel container.
CMD ["cf-sync"]

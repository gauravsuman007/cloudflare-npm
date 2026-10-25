FROM alpine:3.22
RUN apk add --no-cache sqlite curl jq ca-certificates
COPY sync.sh /usr/local/bin/cf-sync
RUN chmod +x /usr/local/bin/cf-sync
ENTRYPOINT ["/usr/local/bin/cf-sync"]

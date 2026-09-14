# Deploying the sandssh relay (mode B) — copy-paste guide

The relay is `relay/sandssh-relay.py`: stdlib python, no dependencies, dumb
ciphertext pipe. Both peers dial OUT to it, so it needs no inbound from the
cage — the cage's *egress* to it is what must be allowed.

## 1. Generate a shared key (once)

    openssl rand -hex 32    # this is $SANDSSH_RELAY_KEY

## 2. Run the relay (pick one)

### systemd (VPS)

    sudo useradd -r -s /usr/sbin/nologin sandssh || true
    sudo install -m 755 relay/sandssh-relay.py /usr/local/bin/sandssh-relay
    # /etc/sandssh-relay.env:
    #   SANDSSH_RELAY_KEY=<key from step 1>
    sudo systemctl enable --now sandssh-relay

See `sandssh-relay.service` in this directory. Listens on 127.0.0.1:8443.

### plain process (no root)

    SANDSSH_RELAY_KEY=<key> python3 relay/sandssh-relay.py --listen 127.0.0.1:8443

## 3. TLS in front (required for wss; caddy example)

    # /etc/caddy/Caddyfile
    talaria.qaidvoid.dev {
        reverse_proxy /sandssh/* 127.0.0.1:8443
    }

The relay speaks plain websocket; caddy (or nginx/Cloudflare) terminates
TLS. Any path prefix works: the relay routes on /v1/node/<name> and
/v1/connect/<name>.

## 4. Allowlist one line in the errand daemon's egress config

    talaria.qaidvoid.dev

## 5. Cage side

    ./start.sh serve --relay wss://talaria.qaidvoid.dev/sandssh --name agent1

## 6. Laptop side (once, then it is just ssh)

    curl -fsSL https://raw.githubusercontent.com/talaria0101/sandssh/main/bin/sandssh \
        -o ~/bin/sandssh && chmod +x ~/bin/sandssh
    sandssh config --relay wss://talaria.qaidvoid.dev/sandssh --name agent1 >> ~/.ssh/config
    ssh agent1          # native openssh, interactive, scp/rsync work too

## Security notes

- The relay only ever sees ssh ciphertext; its auth header (step 1 key)
  keeps randoms from consuming slots. ssh pubkey auth is the real gate.
- Run it behind a proxy with per-IP connection limits if exposed publicly.
- The node redials forever; the client retries within one ProxyCommand
  process, so ssh reconnects cleanly after relay restarts.

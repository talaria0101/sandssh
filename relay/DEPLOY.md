# Deploying the sandssh relay (mode B)

The relay is `relay/sandssh-relay.py`: Python standard library only, no
dependencies, and a dumb ciphertext pipe. Both peers dial OUT to it, so it needs
no inbound connection from the cage. What must be allowed is the cage's
*egress* to the relay.

Copy this page; every command is one you can run.

## 1. Generate a shared key (once)

```sh
openssl rand -hex 32
```

That value is the relay's `--key` and the peers' `--auth`. Anyone who has it
can pair, so it is a secret and belongs in an environment file with mode 0600,
not on a command line in a shell history.

## 2. Run the relay

Pick one.

### systemd

```sh
sudo useradd -r -s /usr/sbin/nologin sandssh || true
sudo install -m 755 relay/sandssh-relay.py /usr/local/bin/sandssh-relay
```

Then write `/etc/sandssh-relay.env`:

```
SANDSSH_RELAY_KEY=<the key from step 1>
```

and `chmod 600` it. `sandssh-relay.service` in this directory reads that file
and listens on `127.0.0.1:8443`:

```sh
sudo install -m 644 relay/sandssh-relay.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sandssh-relay
```

### plain process, no root

```sh
SANDSSH_RELAY_KEY=<key> python3 relay/sandssh-relay.py --listen 127.0.0.1:8443
```

### a unix socket, for a cage that cannot bind

```sh
python3 relay/sandssh-relay.py --listen /tmp/relay.sock --key <key>
```

The scheme a peer uses depends on its transport. With the default, raw:
`--relay unix:///tmp/relay.sock` (three slashes, the target is an absolute
path). With `--transport ws`: `--relay ws+unix:///tmp/relay.sock`. This is the
shape to test in, because it needs no port at all. `sandssh` says so in its
error when a scheme is not one of `ws://`, `wss://` or `ws+unix://`.

## 3. TLS

The relay splices raw bytes, so TLS belongs in front of it, on its own port.
caddy, with the layer4 plugin (the plain http module will not do):

```
# /etc/caddy/Caddyfile
{
    layer4 {
        :443 {
            tls
            proxy 127.0.0.1:8443
        }
    }
}
```

nginx, equivalently:

```
stream {
    server {
        listen 443 ssl;
        proxy_pass 127.0.0.1:8443;
    }
}
```

Peers then use `--relay wss://<relay-host>/`. The relay can also terminate TLS
itself, which is one process instead of two and is worth it on a small host:

```sh
python3 relay/sandssh-relay.py --listen :443 --key <key> \
    --tls-cert fullchain.pem --tls-key privkey.pem
```

## 4. Allow the egress

Whatever mediates the cage's egress needs one destination permitted: the relay
host and port. A cage that reaches only a proxy needs the proxy permitted
instead, and the relay reached through it.

## 5. In the cage

```sh
sandssh serve --relay wss://<relay-host>/ --name agent1
```

`--name` is what the relay pairs by, so it must be the same on both ends.
`--dropbear` and `--chroot` point at a dynamically linked server and its chroot
when the defaults do not apply; a statically linked server cannot be reached by
`fakepwd.so` at all.

## 6. On the machine you connect from

```sh
sandssh config --relay wss://<relay-host>/ --name agent1 >> ~/.ssh/config
ssh agent1
```

`sandssh config` writes the `ProxyCommand` line; after that it is ordinary ssh,
so `scp`, `rsync` and every interactive feature work unchanged. `--insecure`
skips certificate verification, which is for a relay under test and not for one
in production.

## Security notes

- The relay only ever sees ssh ciphertext. Its `--key` keeps strangers from
  consuming a slot; the real gate is ssh public-key authentication on the far
  end, so the relay's secret is not the thing protecting the cage.
- Run it behind a proxy with per-IP connection limits if it is publicly
  reachable. A relay with no limits is a free bandwidth relay.
- The node redials forever. The client retries within one `ProxyCommand`
  process, so ssh reconnects cleanly after a relay restart and a user does not
  notice it.
- A public relay is perishable. `research/RELAY-BENCHMARKS.md` has the measured
  behaviour and is stale by construction; re-measure rather than trust it.

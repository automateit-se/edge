# edge

Reverse proxy for `*.automateit.se` services on the office Debian host.

```
browser ──► Cloudflare (*.automateit.se) ──► tunnel ──► cloudflared ──► edge (nginx, 127.0.0.1:80)
                                                                          ├─ dashboard.automateit.se → iotopen-dashboard:8080
                                                                          ├─ appmanagement.automateit.se → appmanagement:8080
                                                                          ├─ <name>.automateit.se    → <app>:<port>
                                                                          └─ any other name          → 404
```

- Cloudflare is set up once: a proxied DNS record `*.automateit.se` pointing at the tunnel, and one tunnel rule `*.automateit.se → http://localhost:80`. Adding a service changes nothing there.
- nginx chooses the service by host name. Only host names with a file in `sites/` are published; everything else answers 404.
- Apps join the Docker network `edge` and are reached by name, so they need no published ports.
- The edge is published on `127.0.0.1` only, so the only client is cloudflared on the same host. The real client address comes from `CF-Connecting-IP`.
- No Docker socket is mounted: publishing a service is an explicit change to this repository.

## Install

```bash
sudo bash install.sh
```

Creates the `edge` network, clones this repository to `/opt/edge`, connects the IoT Open dashboard to the network, starts nginx and checks that `dashboard.automateit.se` answers through the edge. Cloudflare is not changed by the script.

## Add a service

1. Run the app container on the `edge` network with an alias, e.g. in its compose file:

   ```yaml
   services:
     app:
       networks:
         edge:
           aliases: [appmanagement]
   networks:
     edge:
       external: true
   ```

2. Copy `sites/_example.conf.disabled` to `sites/<name>.conf`, set `server_name` and the upstream, and merge it to `main`.
3. On the host: `sudo edge-update`. It fetches `main`, runs `nginx -t` and reloads; a configuration that does not pass is rolled back.

## Updating nginx

`compose.yml` follows a minor version of `nginxinc/nginx-unprivileged` (`1.31-alpine`), so nginx's security fixes arrive as new builds of the same tag. `sudo edge-update` fetches the configuration **and** a newer build of the image every time it runs, so run it after an nginx security advisory even when the configuration has not changed. The new state must pass `nginx -t` and answer on `/healthz` within 20 seconds; otherwise the previous configuration and the previous image (kept locally as `edge-update/previous:latest`) are started again and the command exits with an error. If Docker Hub cannot be reached, the image that is there is kept. `edge-update` also replaces the installed `/usr/local/sbin/edge-update` with the one in the repository when they differ.

## Files

| Path | Purpose |
|---|---|
| `compose.yml` | nginx-unprivileged `1.31-alpine`, read-only root file system, all capabilities dropped, `127.0.0.1:80` |
| `conf.d/edge.conf` | real client IP, Docker DNS, default server (404, `/healthz`) |
| `snippets/proxy.conf` | headers, WebSocket, timeouts, HSTS for every site |
| `sites/*.conf` | one file per published host name |
| `bin/edge-update` | update of the configuration and the nginx image, with `nginx -t` and `/healthz` checks and rollback |

## License

MIT, see [LICENSE](LICENSE).

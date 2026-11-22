# stack-arr

[Sonarr](https://sonarr.tv), [Radarr](https://radarr.video) and
[Prowlarr](https://prowlarr.com) with
[qBittorrent](https://www.qbittorrent.org) behind a WireGuard VPN, as a
stack for [homelab-ngx](https://github.com/homelab-ngx/homelab-ngx). [qui](https://github.com/autobrr/qui) is the web UI for
qBittorrent.

Everything is built from nixpkgs. Sonarr, Radarr and Prowlarr keep their
data in the stack's own PostgreSQL.

## The VPN

qBittorrent runs in a network namespace whose only way out is the WireGuard
tunnel. When the tunnel is down, qBittorrent has no network. The other apps
use the stack's normal network.

The tunnel's settings are the `VPN_*` variables. Copy them from the
WireGuard config your VPN provider gives you.

With `VPN_NATPMP_GATEWAY` set, the stack asks the provider for a forwarded
port every 45 seconds and sets it as qBittorrent's listening port. Four
failed requests in a row rebuild the tunnel and restart qBittorrent. Without
the variable there is no port forwarding.

## Getting started

1. Add the stack: `homelab stacks add github:homelab-ngx/stack-arr`, or Add
   stack on the dashboard's Stacks page.
2. On the stack's page, set `MEDIA_DIR` to your media folder. Every app
   writes to it through the folder's group, so the group needs write access.
3. Fill in the `VPN_*` variables and `QUI_SESSION_SECRET`.
4. Approve the grants and start the stack.
5. Open `https://qui.<your domain>` and create the account. The qBittorrent
   instance is already added.
6. Open Prowlarr, Sonarr and Radarr at their routes and connect them to each
   other and to qBittorrent at `10.200.0.2`, port 8080.

qBittorrent saves to `qbittorrent/` in the media folder. Its web UI answers
only inside the stack, without a login. Sonarr, Radarr and Prowlarr ask for
no login from your private network.

<!-- manifest:start -->
<!-- Made from homelab-stack.json. Change the manifest, not these lines. -->

## Grants

You approve each of these before the stack starts.

- Route: `sonarr.<your domain>` to port 8989 in the stack.
- Route: `radarr.<your domain>` to port 7878 in the stack.
- Route: `prowlarr.<your domain>` to port 9696 in the stack.
- Route: `qui.<your domain>` to port 7476 in the stack.
- Storage: the folder in `MEDIA_DIR`, at `/pool/media` in the stack, read-write.

## Variables

| Name | Kind | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `MEDIA_DIR` | path | yes |  | The media tree: the TV and movie libraries and qBittorrent's downloads (qbittorrent/ in it). Its group becomes the stack's media group, which every app uses. |
| `VPN_PRIVATE_KEY` | secret | yes |  | The WireGuard private key from your VPN provider's config (its PrivateKey line). |
| `VPN_ADDRESS` | env | yes |  | The tunnel address from the provider's config (Address), such as 10.2.0.2/32. |
| `VPN_DNS` | env | yes |  | The DNS server inside the tunnel (DNS in the provider's config), such as 10.2.0.1. |
| `VPN_PEER_PUBLIC_KEY` | env | yes |  | The server's public key (PublicKey under [Peer]). |
| `VPN_ENDPOINT` | env | yes |  | The server's address and port (Endpoint under [Peer]), such as 203.0.113.7:51820. |
| `VPN_NATPMP_GATEWAY` | env | no |  | For a provider with NAT-PMP port forwarding (ProtonVPN: 10.2.0.1): the gateway to ask. The forwarded port is given to qBittorrent. Unset: no port forwarding. |
| `QUI_SESSION_SECRET` | secret | yes |  | Signs qui's sessions. Any random string, such as one from openssl rand -hex 32. |

## Backup

The stack recommends these folders. None is backed up until you add it to a backup.

- Database dumps: `/var/backup/postgresql` in the stack.
- Sonarr settings: `/var/lib/sonarr` in the stack.
  - Without `/MediaCover/**`. Cover images. They download again.
  - Without `/Backups/**`. The app's own backups. The database dumps cover them.
  - Without `/logs/**`. Log files.
  - Without `/logs.db*`. The log database.
  - Without `/.cache/**`. Temporary files.
  - Without `/Sentry/**`. Crash reports.
  - Without `/*.db`. A SQLite database from before Postgres. The database dumps hold the current data.
- Radarr settings: `/var/lib/radarr` in the stack.
  - Without `/MediaCover/**`. Cover images. They download again.
  - Without `/Backups/**`. The app's own backups. The database dumps cover them.
  - Without `/logs/**`. Log files.
  - Without `/logs.db*`. The log database.
  - Without `/.cache/**`. Temporary files.
  - Without `/Sentry/**`. Crash reports.
  - Without `/*.db`. A SQLite database from before Postgres. The database dumps hold the current data.
- Prowlarr settings: `/var/lib/prowlarr` in the stack.
  - Without `/MediaCover/**`. Cover images. They download again.
  - Without `/Backups/**`. The app's own backups. The database dumps cover them.
  - Without `/logs/**`. Log files.
  - Without `/logs.db*`. The log database.
  - Without `/.cache/**`. Temporary files.
  - Without `/Sentry/**`. Crash reports.
  - Without `/*.db`. A SQLite database from before Postgres. The database dumps hold the current data.
  - Without `/Definitions/**`. Indexer definitions. They download again.
- qBittorrent settings: `/var/lib/qbittorrent` in the stack.
  - Without `/qBittorrent/cache/**`. Temporary files.
- qui settings: `/var/lib/qui` in the stack.
  - Without `/tracker-icons/**`. Tracker icons. They download again.

A backup run starts `postgresqlBackup.service` in the stack and waits for it before it copies.

## Health

An update is kept when all of this holds, and rolled back when it does not.

- `sonarr.service` is active.
- `radarr.service` is active.
- `prowlarr.service` is active.
- `postgresql.service` is active.
- `vpn.service` is active.
- `qbittorrent.service` is active.
- `qui.service` is active.

Manifest version 9, built with nixpkgs `nixos-unstable`. Runs on [homelab-ngx](https://github.com/homelab-ngx/homelab-ngx).

<!-- manifest:end -->

## License

MIT, see [LICENSE](LICENSE).

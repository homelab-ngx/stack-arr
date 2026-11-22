{ lib, pkgs, ... }:

# Sonarr, Radarr and Prowlarr on the stack's own Postgres, and qui, the web
# UI for qBittorrent (vpn.nix). Everything under the media folder is the
# media group's: the homelab daemon's host module gives that group the
# folder's gid and opens the routes' ports.

let
  arrs = [
    "sonarr"
    "radarr"
    "prowlarr"
  ];
  # Each app on Postgres through the local socket as its own user (peer
  # authentication, no password). The apps take the client's address from
  # X-Forwarded-For only from a trusted proxy and otherwise ask for a login:
  # Caddy on the homelab host reaches every stack from 10.99.0.0/16. A
  # request from the LAN counts as local and needs no login.
  settings = name: {
    auth.required = "DisabledForLocalAddresses";
    server.trustedNetworks = "10.99.0.0/16";
    postgres = {
      host = "/run/postgresql";
      port = 5432;
      user = name;
      maindb = "${name}-main";
      logdb = "${name}-log";
    };
  };
in
{
  users.groups.media = { };

  services.sonarr = {
    enable = true;
    dataDir = "/var/lib/sonarr";
    settings = settings "sonarr";
  };
  services.radarr = {
    enable = true;
    dataDir = "/var/lib/radarr";
    settings = settings "radarr";
  };
  services.prowlarr = {
    enable = true;
    settings = settings "prowlarr";
  };
  users.users.sonarr.extraGroups = [ "media" ];
  users.users.radarr.extraGroups = [ "media" ];

  # Upstream runs Prowlarr as a DynamicUser; Postgres peer authentication
  # wants a user that exists.
  users.users.prowlarr = {
    isSystemUser = true;
    group = "prowlarr";
    home = "/var/lib/prowlarr";
    extraGroups = [ "media" ];
  };
  users.groups.prowlarr = { };
  systemd.services.prowlarr.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "prowlarr";
    Group = "prowlarr";
  };

  # ── Postgres ────────────────────────────────────────────────────────────
  # Pinned: a new major version needs a dump and restore.
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_17;
    ensureUsers = map (name: { inherit name; }) arrs;
  };
  # Each app's two databases, owned by the app; made once, kept after. The
  # roles come from ensureUsers, which postgresql-setup creates.
  systemd.services.arr-databases = {
    description = "Create the arrs' databases";
    after = [ "postgresql-setup.service" ];
    requires = [ "postgresql-setup.service" ];
    before = map (n: "${n}.service") arrs;
    requiredBy = map (n: "${n}.service") arrs;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    };
    script = lib.concatMapStrings (
      name:
      lib.concatMapStrings (db: ''
        ${pkgs.postgresql_17}/bin/psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${db}'" | grep -q 1 ||
          ${pkgs.postgresql_17}/bin/psql -c 'CREATE DATABASE "${db}" OWNER "${name}"'
      '') [ "${name}-main" "${name}-log" ]
    ) arrs;
  };
  # A dump next to the database: it restores where a copy of a running
  # Postgres data directory may not. The manifest names the dump unit as the
  # backup's prepare step, so a backup run takes a fresh dump first.
  services.postgresqlBackup = {
    enable = true;
    backupAll = true;
    location = "/var/backup/postgresql";
    compression = "zstd";
    startAt = "*-*-* 03:30:00";
  };

  # ── qui, the qBittorrent web UI ─────────────────────────────────────────
  users.users.qui.extraGroups = [ "media" ];
  services.qui = {
    enable = true;
    # The module hands this to qui through LoadCredential, so a file owned
    # by the stack's root is enough.
    secretFile = "/run/secrets/QUI_SESSION_SECRET";
    settings = {
      host = "0.0.0.0";
      port = 7476;
      checkForUpdates = false; # nix manages the version
      logLevel = "INFO";
      # No login of its own: only the stack itself, qBittorrent's namespace
      # and Caddy on the homelab host (10.99.0.0/16) connect.
      authDisabled = true;
      I_ACKNOWLEDGE_THIS_IS_A_BAD_IDEA = true;
      authDisabledAllowedCIDRs = [
        "127.0.0.1/32"
        "10.200.0.0/30"
        "10.99.0.0/16"
      ];
    };
  };
  systemd.services.qui.serviceConfig = {
    BindPaths = [ "/pool/media" ];
    ReadWritePaths = [ "/pool/media" ];
  };
}

{
  config,
  lib,
  pkgs,
  ...
}:

# qBittorrent behind a WireGuard tunnel. The stack builds a network
# namespace `vpn` whose only way out is the tunnel, runs qBittorrent in it,
# and, for a provider with NAT-PMP, keeps a port forwarded and applied to
# qBittorrent. A veth pair joins the namespace to the stack: qui reaches
# qBittorrent's WebUI at 10.200.0.2.
#
# The tunnel's settings are the stack's variables: the private key a secret,
# the rest settings, all read when the tunnel comes up (the base module gives
# every service /run/secrets/env).
#
# Inside the stack's user namespace `ip netns exec` and `ip -n` fail (they
# remount /sys), so commands run in the namespace through nsenter.

let
  ns = "vpn";
  nsPath = "/run/netns/${ns}";
  vethHost = "10.200.0.1/30";
  vethNs = "10.200.0.2";
  webuiPort = 8080;
  # The tunnel's resolv.conf and the forwarded port, kept while vpn.service
  # is up.
  runDir = "/run/vpn";
  portFile = "${runDir}/forwarded-port";
  inNs = "${pkgs.util-linux}/bin/nsenter --net=${nsPath}";
  profileDir = "/var/lib/qbittorrent";

  qbConfigTrigger = pkgs.writeText "qbittorrent-config-trigger" (
    builtins.toJSON config.services.qbittorrent.serverConfig
  );
in
{
  environment.systemPackages = [
    pkgs.wireguard-tools
    pkgs.libnatpmp
  ];

  # The namespace, the tunnel and the veth. Stopping it removes the
  # namespace, which takes wg0 and both veth ends with it.
  systemd.services.vpn = {
    description = "WireGuard namespace for qBittorrent";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.iproute2
      pkgs.wireguard-tools
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = "vpn";
      RuntimeDirectoryPreserve = true;
      ExecStop = "-${pkgs.iproute2}/bin/ip netns del ${ns}";
    };
    script = ''
      set -eu
      : "''${VPN_ADDRESS:?set VPN_ADDRESS on the stack}" "''${VPN_DNS:?set VPN_DNS on the stack}"
      : "''${VPN_PEER_PUBLIC_KEY:?set VPN_PEER_PUBLIC_KEY on the stack}" "''${VPN_ENDPOINT:?set VPN_ENDPOINT on the stack}"
      printf 'nameserver %s\n' "$VPN_DNS" > ${runDir}/resolv.conf
      ip netns del ${ns} 2>/dev/null || true
      ip link del veth-host 2>/dev/null || true
      ip netns add ${ns}
      ip link add wg0 type wireguard
      ip link set wg0 netns ${ns}
      ${inNs} wg set wg0 private-key /run/secrets/VPN_PRIVATE_KEY \
        peer "$VPN_PEER_PUBLIC_KEY" endpoint "$VPN_ENDPOINT" allowed-ips 0.0.0.0/0 persistent-keepalive 25
      ${inNs} ip address add "$VPN_ADDRESS" dev wg0
      ${inNs} ip link set wg0 up
      ${inNs} ip link set lo up
      ${inNs} ip route add default dev wg0
      ip link add veth-host type veth peer name veth-vpn
      ip link set veth-vpn netns ${ns}
      ip address add ${vethHost} dev veth-host
      ip link set veth-host up
      ${inNs} ip address add ${vethNs}/30 dev veth-vpn
      ${inNs} ip link set veth-vpn up
    '';
  };

  # NAT-PMP port forwarding, only when VPN_NATPMP_GATEWAY is set. A mapping
  # lasts 60 s and is renewed every 45 s; the mapped port goes to
  # ${portFile}, which qbittorrent-port-sync applies. Four failed renewals in
  # a row mean the tunnel is gone: the namespace is rebuilt, which restarts
  # qBittorrent with it.
  systemd.services.vpn-port-forward = {
    description = "Keep the VPN's NAT-PMP port forward open";
    after = [ "vpn.service" ];
    bindsTo = [ "vpn.service" ];
    wantedBy = [ "vpn.service" ];
    unitConfig.ConditionPathExists = "/run/secrets/VPN_NATPMP_GATEWAY";
    path = [
      pkgs.libnatpmp
      pkgs.gnugrep
      pkgs.systemd
    ];
    serviceConfig = {
      NetworkNamespacePath = nsPath;
      Restart = "always";
      RestartSec = 10;
    };
    script = ''
      gw=$(cat /run/secrets/VPN_NATPMP_GATEWAY)
      fails=0
      while true; do
        out=$(natpmpc -g "$gw" -a 1 0 udp 60 && natpmpc -g "$gw" -a 1 0 tcp 60) || out=""
        port=$(printf '%s\n' "$out" | grep -o 'Mapped public port [0-9]*' | grep -o '[0-9]*$' | tail -1)
        if [ -n "$port" ]; then
          fails=0
          if [ "$(cat ${portFile} 2>/dev/null)" != "$port" ]; then
            echo "$port" > ${portFile}.tmp && mv ${portFile}.tmp ${portFile}
            echo "forwarded port is $port"
          fi
        else
          fails=$((fails + 1))
          echo "NAT-PMP renewal failed ($fails in a row)"
          if [ "$fails" -ge 4 ]; then
            echo "rebuilding the tunnel"
            systemctl restart --no-block vpn.service
            exit 1
          fi
        fi
        sleep 45
      done
    '';
  };

  # ── qBittorrent ─────────────────────────────────────────────────────────
  users.users.qbittorrent.extraGroups = [ "media" ];

  services.qbittorrent = {
    enable = true;
    inherit profileDir webuiPort;
    openFirewall = false;
    extraArgs = [ "--confirm-legal-notice" ];
    serverConfig = {
      LegalNotice.Accepted = true;
      Preferences = {
        WebUI = {
          Address = vethNs;
          # Only the stack itself reaches the WebUI, over the veth.
          AuthSubnetWhitelistEnabled = true;
          AuthSubnetWhitelist = "10.200.0.0/30";
        };
        Connection = {
          UPnP = false; # a forwarded port comes from NAT-PMP
          Interface = "wg0";
          InterfaceName = "wg0";
        };
        Bittorrent = {
          DHT = false;
          PeX = false;
          LSD = false;
        };
        Downloads = {
          SavePath = "/pool/media/qbittorrent/";
          TempPath = "/pool/media/qbittorrent/.incomplete/";
          TempPathEnabled = true;
        };
        AutoTMM = {
          Enabled = true;
          DefaultSavePath = "/pool/media/qbittorrent/";
        };
        General.Locale = "en";
      };
    };
  };

  systemd.tmpfiles.rules = [ "d ${profileDir} 0750 qbittorrent qbittorrent -" ];

  systemd.services.qbittorrent = {
    after = [ "vpn.service" ];
    bindsTo = [ "vpn.service" ];
    restartTriggers = [ qbConfigTrigger ];
    serviceConfig = {
      NetworkNamespacePath = nsPath;
      BindReadOnlyPaths = [ "${runDir}/resolv.conf:/etc/resolv.conf" ];
      UMask = "0002";
    };
  };

  systemd.paths.qbittorrent-port-sync = {
    description = "Watch the forwarded port";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = portFile;
      Unit = "qbittorrent-port-sync.service";
    };
  };
  systemd.services.qbittorrent-port-sync = {
    description = "Apply the forwarded port to qBittorrent";
    after = [ "qbittorrent.service" ];
    wantedBy = [ "qbittorrent.service" ];
    startLimitBurst = 20;
    startLimitIntervalSec = 60;
    path = [
      pkgs.curl
      pkgs.gnugrep
    ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -eu
      [ -r ${portFile} ] || { echo "no forwarded port yet"; exit 0; }
      PORT=$(cat ${portFile})
      case "$PORT" in "" | *[!0-9]*) echo "invalid port: '$PORT'" >&2; exit 1 ;; esac
      API=http://${vethNs}:${toString webuiPort}
      for attempt in $(seq 1 30); do
        curl -fsS -o /dev/null --max-time 2 "$API/api/v2/app/version" && break
        [ "$attempt" = 30 ] && { echo "qBittorrent WebUI did not come up within 60s" >&2; exit 1; }
        sleep 2
      done
      curl -fsS --data-urlencode "json={\"listen_port\":$PORT}" "$API/api/v2/app/setPreferences" >/dev/null
      APPLIED=$(curl -fsS "$API/api/v2/app/preferences" | grep -o '"listen_port":[0-9]*' | grep -o '[0-9]*$')
      [ "$APPLIED" = "$PORT" ] || { echo "listen_port is $APPLIED after applying $PORT" >&2; exit 1; }
      echo "applied listen_port=$PORT to qBittorrent"
    '';
  };

  # The one qBittorrent instance, put into qui's database on every start.
  systemd.services.qui-instance = {
    description = "Declare the qBittorrent instance in qui";
    after = [ "qui.service" ];
    wantedBy = [ "qui.service" ];
    path = [
      pkgs.curl
      pkgs.jq
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      API=http://127.0.0.1:7476
      body='{"name":"qBittorrent","host":"http://${vethNs}:${toString webuiPort}","tlsSkipVerify":false,"hasLocalFilesystemAccess":true}'
      existing=$(curl -fsS --retry 30 --retry-connrefused --retry-delay 1 "$API/api/instances")
      id=$(jq -r '.[] | select(.name=="qBittorrent") | .id' <<<"$existing")
      if [ -n "$id" ]; then
        curl -fsS -X PUT "$API/api/instances/$id" -H 'content-type: application/json' -d "$body" >/dev/null
      else
        curl -fsS -X POST "$API/api/instances" -H 'content-type: application/json' -d "$body" >/dev/null
      fi
    '';
  };
}

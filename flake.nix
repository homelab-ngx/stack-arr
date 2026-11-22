{
  description = "Sonarr, Radarr, Prowlarr and qBittorrent behind a VPN as a stack for homelab-ngx";

  # The homelab daemon builds nixosModules.default on its base module with
  # the nixpkgs homelab-stack.json recommends (manifest version 9).
  outputs = _: {
    nixosModules.default = {
      imports = [
        ./stack.nix
        ./vpn.nix
      ];
    };
  };
}

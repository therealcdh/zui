{
  description = "zui: ZFS-based Ubuntu Installer Web UI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages.default = pkgs.buildGoModule {
          pname = "zui";
          version = "0.1.0";
          src = ./src;
          vendorHash = null; 
          
          nativeBuildInputs = [ pkgs.makeWrapper ];

          postInstall = ''
            mkdir -p $out/share/zui/frontend
            cp ${./frontend/index.html} $out/share/zui/frontend/index.html
            cp ${./src/install.sh} $out/bin/install-script.sh
            chmod +x $out/bin/install-script.sh
            
            wrapProgram $out/bin/zui \
              --set ZUI_FRONTEND_PATH "$out/share/zui/frontend" \
              --set ZUI_INSTALLER_PATH "$out/bin/install-script.sh" \
              --prefix PATH : ${pkgs.lib.makeBinPath (with pkgs; [ 
                bash coreutils util-linux procps pciutils
                os-prober smartmontools zfs gptfdisk rsync
                parted e2fsprogs
              ])}
          '';
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            go
            nodejs
            nodePackages.npm
            util-linux
            os-prober
            smartmontools
            zfs
            gptfdisk
            rsync
            parted
            e2fsprogs
          ];
        };
      }
    );
}

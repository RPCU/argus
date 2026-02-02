{
  description = "Custom packages for mallow-kids-workspace";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      # Support multiple systems
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          sveltosctl = pkgs.buildGoModule rec {
            pname = "sveltosctl";
            version = "1.4.0";

            src = pkgs.fetchFromGitHub {
              owner = "projectsveltos";
              repo = "sveltosctl";
              rev = "v${version}";
              hash = "sha256-i3XTzzj7UK+GSlFIIbzpu85hmUBuAxJfrXvsVd9H7Pk=";
            };

            vendorHash = "sha256-QXk0SFCXvOPp4U4Li6HfbrbPxX4ELgRGHkcbA1J86d4=";
            subPackages = [ "cmd/sveltosctl" ];
            ldflags = [
              "-s"
              "-w"
              "-X github.com/projectsveltos/sveltosctl/internal/commands/version.version=${version}"
            ];
            meta = with pkgs.lib; {
              homepage = "https://github.com/projectsveltos/sveltosctl";
              description = "Command line client for Sveltos";
              license = licenses.asl20;
              mainProgram = "sveltosctl";
            };
          };
        }
      );
    };
}

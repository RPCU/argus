{ pkgs }:
let
  sources = import ../npins;
in
pkgs.buildGoModule rec {
  pname = "sveltosctl";
  version = "${sources.sveltosctl.version}";

  src = sources.sveltosctl;

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
}

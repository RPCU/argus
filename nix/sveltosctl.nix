{ pkgs }:
let
  sources = import ../npins;
in
pkgs.buildGoModule rec {
  pname = "sveltosctl";
  version = "${sources.sveltosctl.version}";

  src = sources.sveltosctl;

  vendorHash = "sha256-fnhqlhMEDkAsho6118PrksMNkQT1ox3ENzjpW+pTIqY=";
  subPackages = [ "cmd/sveltosctl" ];
  ldflags = [
    "-s"
    "-w"
    "-X github.com/projectsveltos/sveltosctl/internal/commands.gitVersion=${version}"
    "-X github.com/projectsveltos/sveltosctl/internal/commands.gitCommit=${src.revision}"
  ];
  meta = with pkgs.lib; {
    homepage = "https://github.com/projectsveltos/sveltosctl";
    description = "Command line client for Sveltos";
    license = licenses.asl20;
    mainProgram = "sveltosctl";
  };
}

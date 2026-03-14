{ pkgs, ... }:
{
  sveltosctl = import ./sveltosctl.nix { inherit pkgs; };
}

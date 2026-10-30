# nix/exports.nix — flake.lib.mkHermesAgent
#
# Consumers build the package without touching input plumbing:
#   hermes = inputs.hermes.lib.mkHermesAgent { pkgs = nixpkgs.legacyPackages.${system}; };
#   hermes.override { extraPythonPackages = [ pkgs.python3Packages.requests ]; }
# `pkgs.callPackage`'s makeOverridable travels through, so .override keeps
# working on whatever this returns.
{ inputs, ... }:
{
  flake.lib.mkHermesAgent = import ./mkHermesAgent.nix { inherit inputs; };
}

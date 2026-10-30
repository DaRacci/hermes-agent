# nix/overlays.nix — Expose pkgs.hermes-agent for external NixOS configs
#
# Both overlays provide the `full` variant the flake tests: every
# platform-portable optional group, plus `matrix` on Linux.
#
# `default` rebuilds against the consumer's nixpkgs, so a consumer on a
# patched source or a newer revision gets a package that matches its own
# package set. Every flake input follows `nixpkgs` (flake.nix), so the
# consumer's nixpkgs and this flake's input are the same instance and
# rebuilding is correct rather than a second, drifting instantiation.
#
# `locked` is the derivation this flake ships and tests: nothing is
# re-instantiated, so `pkgs.hermes-agent` and the flake's own
# `packages.<system>.default` are the same output path.
#
# The group list lives in `nix/exports.nix`; resolving it against `final`
# keeps the rebuilt variant identical to `packages.<system>.default` instead
# of falling back to the builder's bare variant.
#
# `.override { extraPythonPackages = ...; }` works through either overlay —
# callPackage's makeOverridable travels with the package.
{ inputs, ... }:
{
  flake.overlays.default = final: _: {
    hermes-agent = inputs.self.lib.mkHermesAgent {
      pkgs = final;
      defaultDependencyGroups = inputs.self.lib.defaultDependencyGroups final;
    };
  };

  flake.overlays.locked = final: _: {
    hermes-agent = inputs.self.packages.${final.stdenv.hostPlatform.system}.default;
  };
}

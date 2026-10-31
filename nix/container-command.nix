# nix/container-command.nix — the container's create call and PATH guard
#
# nix/nixosModules.nix interpolates both into the unit and nix/checks.nix
# asserts on them, so the container's command surface can be checked without a
# container daemon.
{
  lib,
  pkgs,
  cfg,
  containerExtraBin ? null,
}:
let
  containerName = "hermes-agent";
  containerDataDir = "/data";
  containerHomeDir = "/home/hermes";

  containerBin =
    if cfg.container.backend == "docker" then
      "${pkgs.docker}/bin/docker"
    else
      "${pkgs.podman}/bin/podman";

  # The mount source is a store path that appears nowhere else, so this
  # argument is what keeps it reachable from the system closure.
  extraBinArgs = lib.optionals (containerExtraBin != null) [
    "--volume ${containerExtraBin}:/opt/hermes-extra-bin:ro"
  ];

  # One element per line of the rendered shell command.
  argv =
    [
      "create"
      "--name ${containerName}"
      "--network=host"
      "--entrypoint ${containerDataDir}/current-entrypoint"
      "--volume /nix/store:/nix/store:ro"
      "--volume ${cfg.stateDir}:${containerDataDir}"
      "--volume ${cfg.stateDir}/home:${containerHomeDir}"
    ]
    ++ map (volume: "--volume ${volume}") cfg.container.extraVolumes
    ++ extraBinArgs
    ++ [
      "--env HERMES_UID=\"$HERMES_UID\""
      "--env HERMES_GID=\"$HERMES_GID\""
      "--env HERMES_HOME=${containerDataDir}/.hermes"
      "--env HERMES_MANAGED=true"
      "--env HOME=${containerHomeDir}"
    ]
    ++ cfg.container.extraOptions
    ++ [
      cfg.container.image
      "${containerDataDir}/current-package/bin/hermes gateway run --replace"
    ]
    ++ cfg.extraArgs;

  # One argument per line, with the shell continuation between them.
  continuation = " \\\n  ";
in
{
  inherit containerName containerDataDir containerHomeDir containerBin argv;

  create = "${containerBin} ${lib.concatMapStringsSep continuation toString argv}";

  # nixosModules.nix puts this in the entrypoint after the venv block. The venv
  # is the only writable interpreter, so a store path must not shadow python or
  # pip, and the extra directory still wins over the image's own tools.
  extraBinPathGuard = ''
    if [ -d /opt/hermes-extra-bin ]; then
      export PATH="/opt/hermes-extra-bin:$PATH"
    fi
  '';
}

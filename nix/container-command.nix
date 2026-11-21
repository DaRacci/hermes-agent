# nix/container-command.nix — the container's create call and PATH setup
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

  # buildEnv links each package's bin/ into its own $out/bin; it does not
  # flatten them into the env root. So the mount point is the env root and the
  # executables are one level down.
  containerExtraBinMount = "/opt/hermes-extra-bin";
  containerExtraBinPath = "${containerExtraBinMount}/bin";

  containerBin =
    if cfg.container.backend == "docker" then
      "${pkgs.docker}/bin/docker"
    else
      "${pkgs.podman}/bin/podman";

  # The mount source is a store path that appears nowhere else, so this
  # argument is what keeps it reachable from the system closure.
  extraBinArgs = lib.optionals (containerExtraBin != null) [
    "--volume ${containerExtraBin}:${containerExtraBinMount}:ro"
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
  inherit containerExtraBinMount containerExtraBinPath;

  create = "${containerBin} ${lib.concatMapStringsSep continuation toString argv}";

  # The entrypoint's whole PATH setup, as one string so that the order is
  # assertable. nixosModules.nix interpolates it immediately before the
  # privilege-drop exec.
  #
  # Every stanza prepends, so the LAST export in this text wins the front slot.
  # The extra-bin prepend therefore comes first here and the venv prepend last,
  # which makes the effective order venv > extra bin > image. The venv has to
  # win: it is the only writable interpreter, so a store path that shadowed
  # python or pip would break the agent's own runtime, and the mount is
  # read-only. The extra directory still outranks the image's tools, which is
  # what extraPackages is for. A container that was not recreated has no mount,
  # so the guard skips the stanza.
  pathSetup = ''
    # Consumer-declared packages, ahead of the image's own tools. Prepended
    # before the venv so that the venv ends up in front of it.
    if [ -d ${containerExtraBinPath} ]; then
      export PATH="${containerExtraBinPath}:$PATH"
    fi

    # The agent venv last, so python/pip resolve to writable copies.
    if [ -d "$TARGET_HOME/.venv/bin" ]; then
      export PATH="$TARGET_HOME/.venv/bin:$PATH"
    fi
  '';
}

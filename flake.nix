# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  description = "zig-wsapi";

  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
    };
  };

  outputs =
    {
      nixpkgs,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      makePackages =
        system:
        import nixpkgs {
          inherit system;
          # nixpkgs marks radicle-node insecure because traffic for *private*
          # repositories is neither encrypted nor authenticated between nodes.
          # This repository is public, and the dev shell carries the node only
          # for its `rad` command. Matched by name rather than by version, so
          # that a nixpkgs bump does not break every `nix develop`.
          config.allowInsecurePredicate = pkg: lib.getName pkg == "radicle-node";
        };

      # Dev shells for every system Nix exposes, not only Linux. This is a Windows
      # library, so the machine that can actually run it is not a Nix machine at
      # all -- but the Linux and macOS side is where `zig build check`, `reuse` and
      # `zig fmt` run, and where CI runs them. A contributor on any of them needs
      # the same Zig and the same tools.
      forAllShells = lib.genAttrs lib.systems.flakeExposed;
    in
    {
      # No `packages` and no `checks`.
      #
      # There is nothing for Nix to build: the library is consumed as source
      # through Zig's package manager, and its test binaries are Windows
      # programs. `zig build check` in CI stands in for a build, and Wine in the
      # dev shell is what runs the tests; both need only the shell.

      devShells = forAllShells (
        system:
        let
          pkgs = makePackages system;
        in
        {
          default = pkgs.mkShell {
            name = "zig-wsapi";
            nativeBuildInputs = [
              pkgs.git-pages-cli
              pkgs.pinact
              pkgs.radicle-node
              pkgs.reuse
              pkgs.typos
              pkgs.zig_0_16
            ]
            # Wine, to run the Windows test binaries on Linux, and PulseAudio
            # for `tools/wine-test.sh` to give it a null sink to play to.
            #
            # The WoW64 build, not plain `wine`: that one is 32-bit only and
            # refuses an x86-64 program with "Bad EXE format". x86-64 only,
            # because the tests are built for x86-64 Windows and a Wine on
            # any other architecture runs that architecture's Windows programs.
            ++ lib.optionals (system == "x86_64-linux") [
              pkgs.pulseaudio
              pkgs.wineWow64Packages.stable
            ];
          };
        }
      );
    };
}

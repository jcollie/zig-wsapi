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
      # through Zig's package manager, and its test binaries only do anything on
      # Windows -- which Nix cannot produce a runnable result for. `zig build
      # check` in CI is what stands in for a build here, and it needs only the dev
      # shell.

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
            ];
          };
        }
      );
    };
}

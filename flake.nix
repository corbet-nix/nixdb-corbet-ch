# SPDX-License-Identifier: MIT OR Apache-2.0
{
  description = "nixdb — the database tier, declared: engines and the operator that manages them as cluster workloads, plus every database client a person installs on a host";

  # The host modules remain options plus catalogues, taking `pkgs`/`config`/`lib` from whichever
  # evaluation composes them. The cluster module closes over nixk3s' consumer factory, while still
  # taking the composing nixidy environment's module arguments. nixidy itself remains checks-only.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The renderer the cluster module defines into. A real input rather than a name in a comment:
    # without it there is no module system to evaluate the cluster side against, and `nix flake
    # check` would pass by checking nothing.
    nixidy = {
      url = "github:arnarg/nixidy";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # THE APP GRAMMAR AND CONSUMER FACTORY THIS REPOSITORY CONSUMES. Checks render through the real
    # grammar, and the exported cluster module is constructed by the matching shared factory.
    nixk3s = {
      url = "git+https://github.com/corbet-nix/nixk3s-corbet-ch";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixidy.follows = "nixidy";
    };
  };

  outputs = { self, nixpkgs, nixidy, nixk3s }:
    let
      lib = nixpkgs.lib;

      # ONLY THE SYSTEMS THESE CHECKS CAN GENUINELY BE EVALUATED ON, which is the narrower claim and
      # the honest one. `cluster-render` builds a real nixidy environment, and nixidy's own
      # `fromYAML` is IMPORT-FROM-DERIVATION: reading a manifest back means BUILDING a derivation
      # during evaluation. A derivation for `aarch64-linux` cannot be built by an x86_64 runner, so
      # declaring aarch64 here does not widen coverage -- it makes `nix flake check --all-systems`
      # fail outright on every ordinary CI machine with "a 'aarch64-linux' ... is required to build
      # ... but I am a 'x86_64-linux'", which is what it did on this repository's first CI run.
      #
      # The alternative -- keeping aarch64 and dropping `--all-systems` -- is the worse trade and
      # the one this family already refuses: a bare `nix flake check` silently omits the systems it
      # cannot evaluate and still exits 0, so CI goes green having tested half of what the flake
      # claims. Narrow the claim instead, and keep the check strict. Same reasoning nixboot's own
      # ci.yml states for why its `systems` list is deliberately short.
      #
      # Nothing else here is x86-specific: the modules are nixidy/NixOS/system-manager modules and
      # the catalogues are plain data, all of which stay available to a consumer on any system.
      forAllSystems = lib.genAttrs [ "x86_64-linux" ];
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      # The cluster plane. Composed into a nixidy environment ALONGSIDE the app grammar, which
      # declares the options this module defines into -- see modules/cluster.nix's own header.
      nixidyModules.nixdb = import ./modules/cluster.nix {
        mkConsumerModule = nixk3s.lib.mkConsumerModule;
      };
      nixidyModules.default = self.nixidyModules.nixdb;

      # The host plane, for the database clients. Here the system is nix, so the backend
      # installs; on Arch there is nothing to install FROM, so the policy module IS that backend and
      # publishes package-name lists for the host's own reconciler. No third file exists to
      # re-export the second one -- see modules/clients.nix's own header.
      nixosModules.nixdb = ./modules/nixos.nix;
      nixosModules.default = ./modules/nixos.nix;

      systemManagerModules.nixdb = ./modules/clients.nix;
      systemManagerModules.default = ./modules/clients.nix;

      # Policy alone, for a consumer that wants the computed lists and will wire them itself, plus
      # the raw catalogues for inspection without re-reading the files.
      lib.clientsPolicy = ./modules/clients.nix;
      lib.cluster = self.nixidyModules.nixdb;
      lib.engines = import ./lib/engines.nix { };
      lib.clients = import ./lib/clients.nix { };

      # `nix flake check` evaluates none of the module outputs on its own, so a green check on this
      # repository without these three files would cover nothing but flake syntax.
      checks = forAllSystems (system:
        let
          pkgs = pkgsFor system;

          # The cluster module, rendered through the real grammar and the real renderer, from the
          # placeholder values in examples/. Building the environment package forces the whole
          # manifest tree.
          env = nixidy.lib.mkEnv {
            inherit pkgs;
            modules = [
              nixk3s.nixidyModules.apps
              nixk3s.nixidyModules.addressing
              self.nixidyModules.nixdb
              ./examples/all/values.nix
            ];
          };
        in
        {
          # 1. The host catalogue, evaluated for real against `lib.evalModules`: which side of the
          # pacman/AUR split a name lands on, what a selection resolves to, and the catalogue's own
          # integrity -- including the cross-reference between the two catalogues.
          clients-eval = import ./checks/clients-eval.nix { inherit pkgs; };

          # 2. The cluster module's own resolution and every guard it makes, in BOTH directions:
          # an empty tier renders nothing at all, a declared tier resolves, and each refusal gets a
          # declaration that must be refused.
          cluster-eval = import ./checks/cluster-eval.nix {
            inherit pkgs lib nixidy;
            appsModule = nixk3s.nixidyModules.apps;
            addressingModule = nixk3s.nixidyModules.addressing;
            clusterModule = self.nixidyModules.nixdb;
          };

          # 3. The manifests the tier actually PRODUCED, parsed and asserted field by field. A
          # module that type-checks can still render an engine whose Service targets a port nothing
          # listens on, or one whose data directory is not mounted where the engine writes -- none
          # of that is an eval error and all of it is an outage.
          cluster-render = import ./checks/cluster-render.nix { inherit pkgs lib env; };
        });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}

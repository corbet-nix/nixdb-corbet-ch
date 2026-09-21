# SPDX-License-Identifier: MIT OR Apache-2.0
#
# nixdb's client policy: the selection surface for ../lib/clients.nix, and the package-name lists a
# host's own reconciler consumes. Installs nothing itself.
#
# THIS MODULE IS ALSO THE ARCH BACKEND, and there is deliberately no second file behind
# `systemManagerModules.default`. Same conclusion the sibling repos reached once their platform-
# specific work moved elsewhere: on Arch there is nothing here to install FROM -- the lists below
# are published and the host's own pacman reconciler consumes them -- so an `arch.nix` whose entire
# body was `imports = [ ./clients.nix ];` would be a file that exists to be an indirection.
#
#   nixarch.packages.pacman = config.nixdb.clients.archPackages;
#   nixarch.packages.aur    = config.nixdb.clients.aurPackages;
#
# PUBLISHED, NOT WIRED, and that is a choice rather than an omission. This module could assign
# `nixarch.packages.*` directly. It does not, for the reason every catalogue repo in this family
# also does not: a host almost always concatenates several catalogues into one reconciler list, and
# a module that assigns into a FOREIGN namespace both hard-depends on that namespace existing and
# takes the concatenation point away from the one file that can see every catalogue at once.
#
# NO `distro` OPTION HERE, unlike some siblings. That option exists in a catalogue where an
# AUR-only name is carried by SOME Arch derivative's own repository, so which of the two lists an
# entry lands on depends on the host. Nothing catalogued here has that property: all four AUR
# entries were checked against a live CachyOS host's own repositories as well as upstream Arch and
# resolve in neither, so `aur = true` is the whole answer everywhere and an option deciding
# nothing would still read as though it did. It is a two-line addition (an `archRepoOn` field and
# this option) the day an entry needs it, and the sibling repositories already have the exact
# shape to copy.
#
# ONE NAMESPACE. Everything declared here lives under `nixdb`, like every repo in this family; the
# client surface is nested at `nixdb.clients` so it cannot collide with the cluster surface
# (`nixdb.operators` / `nixdb.instances` / `nixdb.tools`) that shares the namespace.
{ config, lib, ... }:
let
  cfg = config.nixdb.clients;
  cat = import ../lib/clients.nix { };

  # An EMPTY table is a legitimate state, not a transitional one -- the `operator` group is empty
  # on purpose and says so in the catalogue. `types.enum [ ]` accepts no value at all, so a
  # selection into an empty group is refused at eval rather than silently resolving to nothing.
  mkGroup = what: table: lib.mkOption {
    type = lib.types.listOf (lib.types.enum (lib.attrNames table));
    default = [ ];
    description =
      "Which ${what}. "
      + (if table == { }
      then "NOTHING IS CATALOGUED IN THIS GROUP -- it is declared and empty on purpose (see lib/clients.nix), so any selection here is refused."
      else "Available: ${lib.concatStringsSep ", " (lib.attrNames table)}.");
  };

  # Each resolved entry carries its own catalogue KEY back out as `name` -- without it, everything
  # downstream that needs to say WHICH selection a resolved attrset came from would have to
  # re-derive it by matching on `arch`, which is a different string for every entry in this
  # catalogue.
  resolve = table: k: table.${k} // { name = k; };

  # Groups are hand-listed rather than generated from `lib.attrNames cat`, matching the siblings.
  # The fragility that invites -- a group added to the catalogue and never wired into an option --
  # is closed by a check instead of by cleverness: ../checks/clients-eval.nix asserts that every
  # catalogue group has a matching option on this module.
  selected = lib.flatten [
    (map (resolve cat.wire) cfg.wire)
    (map (resolve cat.universal) cfg.universal)
    (map (resolve cat.file) cfg.file)
    (map (resolve cat.operator) cfg.operator)
  ];

  fromAur = t: t.aur or false;

  # A `null` nixpkgs attribute means NO derivation exists, which is a fact about the package rather
  # than a hole in the entry -- see ../lib/clients.nix. It is filtered out of the NixOS plane here
  # and reported by ../modules/nixos.nix, so a NixOS consumer is told rather than left wondering.
  hasNixpkgs = t: (t.nixpkgs or null) != null;
in
{
  options.nixdb.clients = {
    wire = mkGroup
      "database wire-protocol clients -- a shell for exactly one engine's protocol"
      cat.wire;

    universal = mkGroup
      "multi-engine database clients -- they speak several protocols through drivers, which is why they name none and are not `wire`"
      cat.universal;

    file = mkGroup
      "database FILE clients -- they open an on-disk database directly, with no server, no port and no connection string"
      cat.file;

    operator = mkGroup
      "operator control-plane clients -- these drive an operator, never a database, which is why they are their own group rather than more of `wire`"
      cat.operator;

    # ── Computed, read-only ─────────────────────────────────────────────────────────────────────
    selected = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      internal = true;
      description = ''
        The resolved catalogue entries for every name selected above, in one flat list -- the
        canonical "what did this host actually ask for" that every backend derives from. Backends
        read THIS rather than re-deriving a selection from one platform's own package split: the
        pacman/AUR distinction is meaningless on NixOS, and filtering by it there would silently
        drop an entry.
      '';
    };

    archPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selections that come from an official Arch repository, as pacman names. For the host's own
        reconciler:

          nixarch.packages.pacman = config.nixdb.clients.archPackages;
      '';
    };

    aurPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selections that must be built from the AUR, kept SEPARATE from `archPackages` because
        `pacman -S` cannot resolve an AUR name: it fails the whole transaction with "target not
        found", taking every other package in the same converge with it. Wire to the AUR side of
        the same reconciler:

          nixarch.packages.aur = config.nixdb.clients.aurPackages;

        Non-empty means the host needs a working AUR helper (and, for an unattended reconciler,
        whatever non-root user and sudo rule that helper requires). If it has neither, prefer
        leaving the selection out over declaring something that will be reported as installed and
        will not exist.
      '';
    };

    nixosPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selections as nixpkgs attribute paths (dotted for a nested attribute). Entries whose
        catalogue `nixpkgs` is `null` -- no derivation exists at all -- are absent from this list
        rather than present as an empty string, so a consumer reading it gets names it can
        actually resolve. Published for introspection; ../modules/nixos.nix is what installs them,
        and it force-evaluates each one rather than trusting that the attribute exists.
      '';
    };

    unavailableOnNixos = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Catalogue names selected on this host that have NO nixpkgs derivation at all, so a NixOS
        host cannot satisfy them from the catalogue. Published rather than merely warned about,
        because a consumer that wants the tool anyway needs a machine-readable list to point its
        own packaging at -- and because a silent absence in `nixosPackages` would otherwise be
        indistinguishable from nothing having been selected.
      '';
    };

    binaries = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      description = ''
        catalogue name -> the command actually installed, for every selection. Published because
        the two disagree for most of this catalogue, and because a consumer writing a wrapper, an
        alias or a launcher against the PACKAGE name gets a command that does not exist -- the
        Arch package for the Postgres shell is named for a library, the one for the Mongo shell
        carries a suffix its command does not, and the SQLite entry's package and command differ
        by a digit.
      '';
    };
  };

  config = {
    nixdb.clients.selected = selected;
    nixdb.clients.archPackages = lib.unique (map (t: t.arch) (lib.filter (t: !(fromAur t)) selected));
    nixdb.clients.aurPackages = lib.unique (map (t: t.arch) (lib.filter fromAur selected));
    nixdb.clients.nixosPackages =
      lib.unique (map (t: t.nixpkgs) (lib.filter hasNixpkgs selected));
    nixdb.clients.unavailableOnNixos =
      lib.unique (map (t: t.name) (lib.filter (t: !(hasNixpkgs t)) selected));
    nixdb.clients.binaries =
      lib.listToAttrs (map (t: lib.nameValuePair t.name t.binary) selected);
  };
}

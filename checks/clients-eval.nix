# SPDX-License-Identifier: MIT OR Apache-2.0
# Evaluates modules/clients.nix for real against `lib.evalModules` and asserts what it resolves,
# plus the integrity of both catalogues and the direction of the reference between them.
#
# Here for the reason every sibling states for its own version of this file: `nix flake check` does
# not evaluate `nixosModules`/`systemManagerModules` on its own, so a green check on this repository
# without it would prove nothing but flake syntax.
#
# ── WHAT IT PROVES ─────────────────────────────────────────────────────────────────────────────
#
#   - the whole resolution path terminates in both directions: an empty selection resolves to
#     nothing on every plane a backend reads, and a full selection resolves to every entry exactly
#     once;
#   - THE LOAD-BEARING INVARIANT: `archPackages` and `aurPackages` never intersect. One AUR name
#     reaching a pacman list aborts the entire pacman transaction with "target not found" and
#     takes every unrelated package in the same converge down with it;
#   - the NixOS plane is honest about the one entry no nixpkgs derivation exists for -- it is
#     absent from `nixosPackages` and present, by name, in `unavailableOnNixos`;
#   - each group's own defining field is present and the fields of the other groups are not, which
#     is the mechanical form of the boundary the catalogue's header argues in prose;
#   - the cluster catalogue does not reference the client catalogue at all, in either direction of
#     naming -- the one property that would otherwise break the cluster side every time a package
#     moved between repositories.
#
# Deliberately pkgs-FREE beyond `pkgs.emptyFile` for the derivation shell. Every question here is a
# question about NAMES and LISTS. Whether a name is in a repository today, and whether a nixpkgs
# attribute still forces, are facts about the world that change without this repository changing --
# see ../experiments/verify-package-names.sh.
{ pkgs, lib ? pkgs.lib }:
let
  clients = import ../lib/clients.nix { };
  engines = import ../lib/engines.nix { };

  evalWith = selection: (lib.evalModules {
    modules = [ ../modules/clients.nix { nixdb.clients = selection; } ];
  }).config.nixdb.clients;

  empty = evalWith { };

  groups = lib.attrNames clients;
  entries = lib.concatMap (g: lib.attrValues clients.${g}) groups;

  # Everything the catalogue holds, selected at once. The fixture the invariants quantify over.
  everything = evalWith (lib.genAttrs groups (g: lib.attrNames clients.${g}));

  # `evalModules` is lazy: `tryEval` alone forces only WHNF (the attrset exists), never the
  # type-checked value inside. `deepSeq` forces through, which is what actually runs the
  # listOf-enum merge that rejects a name.
  refuses = selection: group:
    (builtins.tryEval (builtins.deepSeq (evalWith selection).${group} true)).success == false;

  engineEntries = lib.attrValues engines.engines;
  operatorEntries = lib.attrValues engines.operators;
  clusterEntries = engineEntries ++ operatorEntries ++ lib.attrValues engines.tooling;

  has = list: item: lib.elem item list;

  results = {
    # ── The floor: the whole path resolves, in both directions ─────────────────────────────────
    "an empty selection resolves to nothing selected" =
      empty.selected == [ ];

    "an empty selection produces empty lists on EVERY plane, not one populated by default" =
      empty.archPackages == [ ] && empty.aurPackages == [ ]
      && empty.nixosPackages == [ ] && empty.unavailableOnNixos == [ ]
      && empty.binaries == { };

    "every plane a backend reads is actually published" =
      lib.all (o: empty ? ${o})
        [ "selected" "archPackages" "aurPackages" "nixosPackages" "unavailableOnNixos" "binaries" ];

    # The arithmetic is spelled out in the label in the SAME ORDER the catalogue declares its
    # groups (wire, universal, file, operator), so adding an entry means editing both the total and
    # the term it belongs to -- and a label that no longer adds up is itself the signal that one of
    # the two was forgotten.
    "every group contributes to \`selected\`, each entry exactly once (4+2+4+0 = 10)" =
      lib.length everything.selected == 10 && lib.length entries == 10;

    # ── The surface matches the catalogue ─────────────────────────────────────────────────────
    "every catalogue group has a matching selection option on the module" =
      lib.all (g: empty ? ${g}) groups;

    "all four kinds of client have a group, so none has to be invented later" =
      lib.sort (a: b: a < b) groups == [ "file" "operator" "universal" "wire" ];

    # The operator group is empty as an END STATE, not as a stage: a kubectl plugin talks to the
    # Kubernetes API and never to a database, which is the ruling that keeps it with the
    # development tooling. Asserted so that an entry cannot be dropped in without the header being
    # revisited.
    "nothing is selectable in the operator group -- it is declared and claims no package" =
      refuses { operator = [ "anything" ]; } "operator";

    "and the three populated groups do refuse a name they do not hold" =
      refuses { wire = [ "nonesuch" ]; } "wire"
      && refuses { universal = [ "nonesuch" ]; } "universal"
      && refuses { file = [ "nonesuch" ]; } "file";

    # ── THE LOAD-BEARING INVARIANT ────────────────────────────────────────────────────────────
    # One AUR name in a pacman list fails `pacman -S` ATOMICALLY and takes every unrelated package
    # in the same converge with it.
    "archPackages and aurPackages can never intersect, and together account for every entry" =
      lib.intersectLists everything.archPackages everything.aurPackages == [ ]
      && lib.length (everything.archPackages ++ everything.aurPackages) == lib.length entries;

    "the four AUR-only names are on the AUR plane and on no pacman list" =
      lib.sort (a: b: a < b) everything.aurPackages
        == [ "bbolt" "boltbrowser" "mongosh-bin" "usql" ];

    # ── The NixOS plane tells the truth about what it cannot install ──────────────────────────
    "an entry with no nixpkgs derivation is absent from nixosPackages and named in unavailableOnNixos" =
      everything.unavailableOnNixos == [ "bbolt" ]
      && lib.length everything.nixosPackages == 9
      && !(lib.any (a: a == null) everything.nixosPackages);

    "the two nixpkgs attributes that are not the obvious spelling are the ones actually published" =
      has everything.nixosPackages "mariadb.client"
      && !(has everything.nixosPackages "mariadb-client")
      && !(has everything.nixosPackages "mysql-client")
      && has everything.nixosPackages "sqlite-interactive"
      && !(has everything.nixosPackages "sqlite");

    "the Postgres shell's Arch package is the library one, and the package named for the project -- the server -- is nowhere" =
      has everything.archPackages "postgresql-libs"
      && !(has everything.archPackages "postgresql");

    # ── Every entry is complete, and the completeness allows a KNOWN null ─────────────────────
    "every entry names a pacman package and the command it installs" =
      lib.all
        (t: lib.isString (t.arch or null) && t.arch != ""
          && lib.isString (t.binary or null) && t.binary != "")
        entries;

    "every entry names a nixpkgs attribute or an explicit null -- never an empty string, which would read as a name" =
      lib.all
        (t: t ? nixpkgs && (t.nixpkgs == null || (lib.isString t.nixpkgs && t.nixpkgs != "")))
        entries;

    "no two entries resolve to the same pacman name, or to the same nixpkgs attribute" =
      let attrs = lib.filter (a: a != null) (map (t: t.nixpkgs) entries); in
      lib.length (lib.unique (map (t: t.arch) entries)) == lib.length entries
      && lib.length (lib.unique attrs) == lib.length attrs;

    "the published binary map covers every selection, and no command is the empty string" =
      lib.length (lib.attrNames everything.binaries) == lib.length entries
      && lib.all (b: b != "") (lib.attrValues everything.binaries);

    # `binary` exists for these four and is pinned by name rather than by a count, because the
    # count is the uninteresting half: a consumer writing a wrapper, an alias or a launcher against
    # the PACKAGE name gets a command that does not exist for exactly these, and gets away with it
    # everywhere else -- which is what makes the mistake survive review.
    "the entries whose command is not their pacman package name are exactly the four known to be" =
      lib.sort (a: b: a < b) (map (t: t.arch) (lib.filter (t: t.binary != t.arch) entries))
        == [ "mariadb-clients" "mongosh-bin" "postgresql-libs" "sqlite" ];

    # ── Each group's defining field, present here and absent everywhere else ──────────────────
    "a wire client speaks a protocol some engine in the cluster catalogue actually runs" =
      lib.all (c: lib.any (e: e.wire == c.speaks) engineEntries) (lib.attrValues clients.wire);

    "a universal client names NO single protocol -- that is what makes it universal rather than a wire client" =
      lib.all (c: !(c ? speaks) && !(c ? format)) (lib.attrValues clients.universal);

    "a file client names an on-disk format and no protocol, because there is no server in the picture at all" =
      lib.all
        (c: lib.isString (c.format or null) && c.format != "" && !(c ? speaks))
        (lib.attrValues clients.file);

    # The `format` field earns its place by deciding something: two tools that share a format can
    # be pointed at the same file, and the SQLite pair deliberately does NOT share one -- sqlite3
    # reads an encrypted file as corruption, and sqlcipher cannot open a plain one until told
    # there is no key. Pinned because "it is a SQLite fork" reads as interchangeable and is not.
    "the two BoltDB tools share a format; the two SQLite-derived shells do not" =
      clients.file.bbolt.format == clients.file.boltbrowser.format
      && clients.file.sqlite.format != clients.file.sqlcipher.format;

    "only a wire client can carry installsServerOnNixos, and exactly one does" =
      lib.length (lib.filter (t: t.installsServerOnNixos or false) entries) == 1
      && clients.wire.psql.installsServerOnNixos;

    # ── THE DIRECTION OF THE REFERENCE ────────────────────────────────────────────────────────
    # The cluster catalogue names protocols and operator keys; it must never name a PACKAGE. If it
    # did, every reassignment of a package to another repository would break the engines here --
    # and packages get reassigned by somebody who is not reading this file.
    "no cluster catalogue entry names a client package, in any group" =
      lib.all (e: !(e ? client) && !(e ? clientPackage) && !(e ? arch)) clusterEntries;

    "every engine still records the PROTOCOL a client would speak to it, which is the reference that survives a package moving" =
      lib.all (e: lib.isString (e.wire or null) && e.wire != "") engineEntries;

    "and every operator still records what it manages, so an operator client has something to point back at" =
      lib.all (o: lib.isList (o.manages or null) && o.manages != [ ]) operatorEntries;

    # Every protocol the tier speaks has a shell that speaks it. Not a rule the catalogue enforces
    # on new engines -- a tier may well run something no packaged client exists for -- but true
    # today, and worth failing on if a client is removed while its engine stays.
    "every engine in the cluster catalogue has a wire client that speaks to it" =
      lib.all
        (e: lib.any (c: c.speaks == e.wire) (lib.attrValues clients.wire))
        engineEntries;

    # The multi-model engine speaks a protocol that is not its own product. Pinned because it looks
    # like a copy-paste error and is not -- see that entry's own note.
    "two different engines record the same wire protocol, on purpose" =
      engines.engines.arcadedb.wire == engines.engines.postgres.wire;
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
in
if failed == [ ]
then pkgs.emptyFile
else
  throw ''
    nixdb: clients-eval check failed. Failing assertions:
    ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failed}
  ''

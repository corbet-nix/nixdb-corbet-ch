# SPDX-License-Identifier: MIT OR Apache-2.0
#
# The client catalogue: what a PERSON installs on a host in order to work with databases.
#
# THIS REPOSITORY OWNS ALL OF IT. Every database client and command line in this family is
# catalogued here — the shells that speak one engine's wire protocol, the multi-engine command
# lines that speak several, and the inspectors that open a database FILE with no server anywhere.
# Nothing about "it is a terminal program" or "a developer uses it" splits a database tool away
# from the repository whose subject is databases; the universal terminal shelf and the development
# tooling repository catalogue neither.
#
# ── THE FOUR GROUPS, AND WHY THEY ARE FOUR ─────────────────────────────────────────────────────
#
#   `wire`       speaks ONE engine's wire protocol. A shell you point at a running database, and a
#                host with none of that engine has no use for it.
#   `universal`  speaks SEVERAL protocols through drivers. The property that puts a tool here is
#                exactly the one that disqualifies it from `wire`: it is useful on a host running
#                any engine, or none, so it names no single protocol and the catalogue does not
#                pretend otherwise by picking one.
#   `file`       opens a database FILE. No server, no port, no connection string — an on-disk
#                format and a path. What it needs to be correct is the FORMAT, not a protocol,
#                and two tools that read the same format are interchangeable in a way that two
#                tools sharing a protocol are not.
#   `operator`   drives an operator's control plane. Not a database client at all — it asks the
#                operator about the instances it manages, and tells it to do things to them. It
#                never opens a connection to a database, and a host may well want exactly one of
#                the kinds above and this one.
#
# The split is by WHAT A TOOL IS, not by what it touches — the same test the cluster catalogue
# applies to its own groups. `operator` is declared and empty, and that is a state rather than a
# gap: the one plugin this tier would use falls under the standing ruling that cluster-driving
# CLIs belong with the development tooling, so the group exists for a kind that is real and holds
# nothing today.
#
# ── THE BOUNDARY, so the next candidate is decidable without asking ────────────────────────────
#
#   Does the tool exist in order to read, write or inspect a DATABASE — over a protocol or off a
#   disk?
#     yes -> here
#     no  -> whichever repository owns the thing it actually is
#
# "Handles structured data" is NOT the test, and the clause is load-bearing: a JSON processor, a
# YAML query tool and a spreadsheet TUI all read structured data and none of them is a database
# client. They belong to the universal terminal shelf, which is where a tool a host reaches for
# regardless of what it runs already lives. The test is whether the thing addresses a DATABASE.
#
# The near miss on the other side is the spreadsheet TUI that happens to have a SQLite loader
# among two dozen file formats. Opening a database file is not what it is FOR — it is one of the
# formats it can be pointed at — so it stays on the universal shelf. Everything below is a tool
# whose entire purpose is a database.
#
# ONE PACKAGE, ONE CATALOGUE is the family rule: on a NixOS host every catalogue feeds the same
# package list, so a second entry for one package is a collision rather than a redundancy.
#
# ── FIELDS ─────────────────────────────────────────────────────────────────────────────────────
#
# Every one of them exists for a measured reason, and the checks and both backends consume them:
#
# `arch`      the pacman package name.
# `aur`       (default false) the name lives in the AUR rather than an official Arch repository.
#             Load-bearing in one direction only, and fatally: `pacman -S` resolves a transaction
#             ATOMICALLY, so ONE AUR name in a pacman list fails the whole thing with "target not
#             found" and takes every unrelated package in the same converge down with it. The two
#             lists ../modules/clients.nix publishes are separate for exactly this reason, and
#             that they never intersect is asserted.
# `nixpkgs`   the nixpkgs attribute, as a dotted path for a nested one — a dotted path is an
#             expected shape here rather than an exception, see the studies. `null` where NO
#             nixpkgs derivation exists at all. A null is not an oversight and not a to-do: it is
#             this catalogue telling a NixOS consumer that the selection cannot be satisfied
#             there, which is better than silently installing nothing. ../modules/nixos.nix warns
#             and skips.
# `binary`    the command it actually installs. Four entries below install a command that is NOT
#             their pacman package name -- the Postgres shell's package is named for a library, the
#             Mongo shell's carries a suffix its command does not, the MySQL-protocol client's is
#             plural where its command is singular, and the SQLite shell's differs by a digit. The
#             other six agree, which is precisely what makes the field necessary rather than
#             optional: a consumer that writes a wrapper against the package name is right often
#             enough for the habit to survive review, and wrong for the four that matter most.
# `speaks`    (`wire` group) the engine family this client's protocol belongs to, matching the
#             `wire` field of ../lib/engines.nix. THE REFERENCE POINTS THIS WAY ROUND on purpose:
#             an engine names a protocol, never a package, so the cluster catalogue cannot break
#             when a package moves. Absent from `universal` by construction — a tool that speaks
#             several protocols has no single one to record, and recording the subset that happens
#             to match this tier's engines would be inventing data the package does not have.
# `format`    (`file` group) the on-disk database format it opens. The `wire` group's `speaks`
#             with no server in it, and the field that says which of these tools can be pointed at
#             the same file: two entries below share a format and two deliberately do not, even
#             though one is a fork of the other's engine.
# `operates`  (`operator` group) the operator key this plugin drives, from ../lib/engines.nix.
# `installsServerOnNixos`
#             (default false) the nixpkgs attribute additionally installs the ENGINE's server
#             binaries, where the Arch package is client-only. Exactly one entry needs it, it is
#             measured rather than suspected (../studies/psql-is-in-postgresql-libs-not-postgresql.md),
#             and the asymmetry cannot be removed because nixpkgs has no client-only attribute to
#             switch to. ../modules/nixos.nix warns from it.
# `note`      what the entry is, and every trap in getting it installed.
#
# ── THE VERIFICATION CONTRACT EVERY NAME BELOW HAS MET ──────────────────────────────────────────
#
# FOUR SOURCES, because no two of them answer the same question:
#
#   - `pacman -Si <name>` on a live Arch-derivative system. Says what a name resolves to HERE,
#     which is not the same as what upstream Arch ships. NEVER sufficient on its own.
#   - archlinux.org's package search API (`/packages/search/json/?name=<name>`), which IS upstream
#     Arch and knows nothing about a derivative's extra repositories. The only authority for
#     `aur = false`.
#   - the AUR RPC (`https://aur.archlinux.org/rpc/v5/info?arg[]=<name>`). The only authority for
#     `aur = true`.
#   - the nixpkgs attribute FORCED: `builtins.seq p.drvPath`. `hasAttrByPath` cannot distinguish a
#     live attribute from a rename-to-throw, and this subject holds two of those.
#
# Plus two cross-checks a name existing on both platforms cannot pass on its own: `meta.homepage`
# against pacman's `URL`, so a pair that resolves on both platforms while pointing at two DIFFERENT
# projects is caught; and THE COMMAND SURFACE, by listing `bin/` of the realized store path against
# the Arch package's own file list, because two names for the same project at the same version can
# install different commands. Half the entries below carry a finding only that last check produces.
#
# ../experiments/verify-package-names.sh runs all of it, reading the names out of THIS file.
{ ... }:
{
  # ── Wire clients: a shell for one engine's protocol ──────────────────────────────────────────
  wire = {
    psql = {
      arch = "postgresql-libs";
      nixpkgs = "postgresql";
      binary = "psql";
      speaks = "postgres";
      installsServerOnNixos = true;

      note = ''
        PostgreSQL's own interactive terminal. Also the client for anything speaking the Postgres
        wire protocol, which in this catalogue includes the multi-model engine.

        THE ARCH PACKAGE IS `postgresql-libs`, NOT `postgresql`, and getting this wrong is the
        loudest trap in the file. Upstream Arch splits the project the way a distribution does:
        `postgresql` is the SERVER (initdb, postgres, pg_ctl, pg_upgrade -- and no psql at all),
        while `postgresql-libs` carries libpq and the client binaries, psql among them. Installing
        the obvious name on a workstation therefore installs a database server, adds a system user
        and a service, and still leaves the command that was wanted missing. Verified from the
        package file lists rather than assumed -- see
        ../studies/psql-is-in-postgresql-libs-not-postgresql.md.

        NIXPKGS DOES NOT MAKE THAT SPLIT, and the asymmetry is real rather than cosmetic.
        `pkgs.postgresql` is one derivation carrying the client AND the server in the same `out`
        (verified by listing `bin/`: psql sits beside postgres, initdb and pg_ctl), so selecting
        this entry on NixOS puts server binaries on PATH that the Arch host will not have.
        `installsServerOnNixos` records that, and ../modules/nixos.nix warns rather than leaving
        it to be discovered.

        AND THERE IS NO CLIENT-ONLY ALTERNATIVE TO REACH FOR. `pkgs.libpq` exists and is the
        obvious guess -- it is the C library and nothing else: the realized path has no `bin/`
        directory at all. It cannot substitute here.
      '';
    };

    pgcli = {
      arch = "pgcli";
      nixpkgs = "pgcli";
      binary = "pgcli";
      speaks = "postgres";

      note = ''
        A third-party Postgres REPL with auto-completion of table and column names, syntax
        highlighting and multi-line editing. Speaks exactly one protocol, so it is a `wire` client
        by the same test as `psql` above.

        NOT A REPLACEMENT FOR `psql`, AND THE PAIR IS DELIBERATE. Every upstream Postgres document,
        every operator runbook and every recovery procedure assumes the shell the engine itself
        ships; psql's meta-commands, its `\copy`, its script mode and its exit codes are what those
        instructions are written against. This is the interactive-comfort layer on top, for the
        exploratory session where completion actually saves time. A host that installs one has a
        reason to install the other, and neither substitutes.

        NOTHING SURPRISING IN THE NAMES: package, nixpkgs attribute and command are all `pgcli` on
        both platforms, and both are on 4.5.0. Note the Arch package is `any`-architecture rather
        than x86_64 -- it is Python -- which changes nothing for a consumer but does change which
        URL the verification script reads its file list from, and is the one thing about this entry
        that costs a minute if it is not written down.
      '';
    };

    mariadb = {
      arch = "mariadb-clients";
      nixpkgs = "mariadb.client";
      binary = "mariadb";
      speaks = "mysql";

      note = ''
        MariaDB's own client, which is also the client for anything speaking the MySQL protocol.
        Installs BOTH commands: `mariadb` (the current name) and `mysql` (the compatibility name),
        on both platforms -- confirmed by listing `bin/` on the realized nixpkgs path and the Arch
        package's file list, which agree. Scripts written against either name keep working.

        THE NIXPKGS ATTRIBUTE IS NESTED, and both flat guesses are booby-trapped. `mariadb-client`
        and `mysql-client` each exist as attributes and each THROWS when evaluated -- one says it
        was renamed, the other that it was replaced, both pointing at `mariadb.client`. An
        existence check passes on either and the build then fails; only forcing the derivation
        finds it. Written up in
        ../studies/mariadb-client-and-mysql-client-both-throw.md, because it is the exact failure
        mode this catalogue's verification exists to catch.

        The bare `mariadb` attribute is not this: it is the SERVER (its derivation is literally
        named mariadb-server). `mariadb.client` is a separate output of the same source.

        THE TWO PLATFORMS ARE ON DIFFERENT MAJORS, which is a fact about the distributions rather
        than a mistake here, and harmless for a client: the wire protocol is stable across these
        majors in both directions, and a newer client talks to an older server routinely.
      '';
    };

    mongosh = {
      arch = "mongosh-bin";
      aur = true;
      nixpkgs = "mongosh";
      binary = "mongosh";
      speaks = "mongodb";

      note = ''
        MongoDB's current shell -- a JavaScript REPL against a running instance, and the only
        client the engine's own documentation assumes.

        AUR, EVERYWHERE, AND NOT BY OVERSIGHT. Upstream Arch packages nothing MongoDB at all: the
        search API returns zero results for this name and for the database itself, because the
        project's licence took it out of the official repositories years ago and it has not come
        back. `pacman -Si` finds it in no derivative repository either, so unlike an entry that is
        AUR upstream and repository-provided on a derivative, there is nothing to lift here: this
        is the whole answer on every Arch-family host.

        `-bin` IS THE ENTRY, and the choice is deliberate rather than incidental. Two AUR packages
        build this shell: one compiles it and one installs the vendor's own build. The vendor build
        is the far better maintained of the two (about six times the votes) and is what upstream
        ships anyway -- this is a Node application whose from-source build has no advantage to
        offer. The package name carries the `-bin` suffix; the command it installs does not, and
        the PKGBUILD `provides`/`conflicts` the unsuffixed name, so the two can never both land.

        Both platforms are on the same version, and the AUR package's upstream URL and the nixpkgs
        homepage resolve to the same project.
      '';
    };
  };

  # ── Universal clients: several protocols through drivers, so no single one to name ───────────
  universal = {
    usql = {
      arch = "usql";
      aur = true;
      nixpkgs = "usql";
      binary = "usql";

      note = ''
        A single command line for every SQL database, built around psql's own interface: the same
        backslash meta-commands, the same prompt, the same script mode, pointed at a connection
        URL instead of one engine. What it is for is the host that has to reach a Postgres, a
        MySQL and a SQLite file in the same afternoon without three different shells and three
        different dialects of `\d`.

        THE BUILD TAGS ARE THE PACKAGE, not the version, and both platforms agree on them --
        which is the cross-check that matters for a tool whose entire capability is which drivers
        were compiled in. Both are 0.21.4 and both build with `most` plus the SQLite feature tags
        (`sqlite_fts5`, `sqlite_json1`, `sqlite_math_functions`, `sqlite_stat4`, `sqlite_vtable`,
        `sqlite_introspect`, `sqlite_app_armor`) and `no_adodb`. A `usql` built without `most`
        would carry the same name, the same version and a fraction of the drivers.

        THE FROM-SOURCE AUR PACKAGE IS THE ENTRY, which is the opposite call from the Mongo shell
        above and rests on the same measurement rather than a rule: `usql` has about six times the
        votes of `usql-bin`, and a Go program compiled from a PKGBUILD that pins the driver tags
        has nothing to gain from a vendor binary that pins them somewhere a reader cannot see.
        AUR-only on every Arch-family host -- upstream Arch carries no `usql` under any name, and
        `pacman -Si` resolves it in no derivative repository either.
      '';
    };

    rainfrog = {
      arch = "rainfrog";
      nixpkgs = "rainfrog";
      binary = "rainfrog";

      note = ''
        A terminal UI for browsing a database: schema tree on one side, results on the other, a
        query editor with history. Postgres, MySQL/MariaDB and SQLite, which is what puts it here
        rather than in `wire` -- and it opens a SQLite file directly, which is what stops it being
        purely a wire tool at all.

        BESIDE `usql` DELIBERATELY, not instead of it. That is a REPL: you type a statement and
        read the rows back, and it scripts. This is a browser: you navigate a schema you do not
        know yet and look at what is in it. The overlap is real and neither covers the other's
        job.

        THE VERSIONS ARE WORTH CONFIRMING rather than shrugging at, and this is the entry where
        that is true: the project is young and still moving its keybindings and its config file
        around, so a gap here would be one a person actually MEETS rather than a patch-level
        detail. They are in step -- nixpkgs at this repo's own pinned revision forces to 0.4.2 and
        Arch ships 0.4.2, with upstream Arch since tagged 0.4.3, one patch ahead and ordinary
        release-cadence drift. Only a person straddling an Arch host and a NixOS host would ever
        notice such a gap; a script would not, because a schema browser has no scriptable surface
        to notice it with.
      '';
    };
  };

  # ── File clients: open a database on disk. No server, no port, no connection string ──────────
  file = {
    sqlite = {
      arch = "sqlite";
      nixpkgs = "sqlite-interactive";
      binary = "sqlite3";
      format = "sqlite";

      note = ''
        The `sqlite3` shell: open an application's own database file and read it without the
        application, which is how half the services on a host are actually debugged. No server
        exists to connect to -- the file IS the database -- which is the whole reason this group
        is not `wire`.

        `nixpkgs = "sqlite-interactive"`, NOT the bare `sqlite`, and the difference is not what it
        looks like. `pkgs.sqlite` does ship the CLI -- its `bin` output carries `bin/sqlite3` and
        `meta.outputsToInstall` names that output, so it is genuinely installed rather than hidden
        behind a library-only default -- but that build passes `--disable-readline`
        (pkgs/development/libraries/sqlite: `interactive ? false`), leaving a prompt with no line
        editing, no history and no arrow keys. `sqlite-interactive` is the same package with
        `interactive = true`, which adds readline and ncurses. Arch's own `sqlite` links
        `libreadline`/`libncursesw` unconditionally, so the bare pair would have quietly declared
        one capability on Arch and a materially worse one on NixOS -- exactly what this catalogue
        exists to prevent. See ../studies/the-sqlite-entry-is-the-shell-not-the-library.md.

        THE ARCH PACKAGE IS LIBRARY AND SHELL IN ONE, the mirror image of the Postgres entry
        above: `core/sqlite` installs libsqlite3 and thirteen binaries, `sqlite3` among them.
        There is no client-only Arch package to prefer and no server to accidentally install, so
        unlike `psql` this asymmetry costs nothing and needs no flag.
      '';
    };

    sqlcipher = {
      arch = "sqlcipher";
      nixpkgs = "sqlcipher";
      binary = "sqlcipher";
      format = "sqlcipher";

      note = ''
        SQLite with transparent 256-bit AES page encryption, and the shell that goes with it: the
        `sqlcipher` command is the `sqlite3` command plus the `PRAGMA key` that unlocks a file.
        Applications that keep an encrypted local database -- password managers, messengers, note
        stores -- write this format and nothing else opens it.

        `format = "sqlcipher"` AND NOT `"sqlite"`, WHICH IS THE POINT OF THE FIELD. The two are
        one codebase and two formats: `sqlite3` cannot open an encrypted file (it reads the header
        as corruption), and `sqlcipher` cannot open a plain file until it is told there is no key.
        A reader who takes "it is a SQLite fork" as "it can stand in for the entry above" is wrong
        in the direction that looks like data loss.

        NOTHING SURPRISING IN THE NAMES: `sqlcipher` on both platforms, one binary of the same
        name on each, and both homepages resolve to zetetic.net. The versions differ by a couple
        of point releases, which the on-disk format is stable across.
      '';
    };

    bbolt = {
      arch = "bbolt";
      aur = true;
      nixpkgs = null;
      binary = "bbolt";
      format = "boltdb";

      note = ''
        The command line for BoltDB, Go's embedded key/value store: dump a bucket, check a file's
        integrity, print page statistics. Filed by what the tool IS -- a database inspector -- not
        by what happens to be inspected with it today. BoltDB is a general-purpose embedded store
        and the software using it changes; filing this under whichever daemon currently keeps a
        `.db` in that format would age badly.

        NO NIXPKGS DERIVATION EXISTS, and that is the finding rather than a gap in this entry.
        Forced against the pinned revision, `pkgs.bbolt` is not an attribute at all -- not a
        rename-to-throw, genuinely absent, and nothing under any spelling of the name exists in
        the top-level set (the near misses nix offers are `bolt`, the Thunderbolt daemon, and
        `boltbrowser` below). `nixpkgs = null` therefore says the selection cannot be satisfied on
        NixOS; ../modules/nixos.nix warns and skips rather than installing something adjacent.

        AUR-ONLY ON ARCH TOO, so this entry is Arch-and-AUR or nothing: upstream Arch carries no
        `bbolt`, no derivative repository resolves it, and the AUR PKGBUILD builds `cmd/bbolt`
        from the etcd-io source and installs it as `usr/bin/bbolt`.
      '';
    };

    boltbrowser = {
      arch = "boltbrowser";
      aur = true;
      nixpkgs = "boltbrowser";
      binary = "boltbrowser";
      format = "boltdb";

      note = ''
        A terminal browser for the same BoltDB files `bbolt` above inspects -- navigate the bucket
        tree, expand a key, edit a value. The pair is the same division of labour as `usql` and
        `rainfrog` one group up: one prints what you ask for, the other shows you what is there.
        They share a `format`, so either can be pointed at the same file.

        AUR ON ARCH, PLAIN IN NIXPKGS, and the asymmetry is what the `aur` flag exists for.
        Upstream Arch carries no `boltbrowser` and neither does any derivative repository, so on
        an Arch-family host this name must reach the AUR helper and never the pacman list; on
        NixOS `pkgs.boltbrowser` is an ordinary attribute that forces cleanly. Both are 2.2 and
        both point at the same upstream repository.

        THE AUR PACKAGE INSTALLS THE VENDOR'S OWN RELEASE BINARY rather than compiling it, which
        is worth knowing only because it means the AUR side needs no Go toolchain -- unlike
        `bbolt` beside it, which does.
      '';
    };
  };

  # ── Operator clients: drives an operator's control plane, not a database ─────────────────────
  #
  # DECLARED AND EMPTY, and unlike the groups above that is the end state rather than a stage. The
  # plugin this tier's operator ships is a kubectl plugin: it talks to the Kubernetes API and never
  # opens a database connection, which is exactly the standing ruling that puts cluster-driving
  # CLIs with the development tooling rather than with the repository that owns the cluster
  # service. The group stays because the KIND is real and the boundary is worth stating in the
  # place a reader looks for it -- ../modules/clients.nix refuses any selection into it.
  operator = { };
}

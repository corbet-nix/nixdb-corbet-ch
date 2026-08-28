# nixdb

**The database tier, declared: the engines other workloads depend on, the operator that manages
them, and every database client a person installs on a host — with the knowledge that
makes each one actually run.**

It renders no Kubernetes object of its own. Everything expressible as an app is expressed in
[nixk3s](https://github.com/julian-corbet/nixk3s-corbet-ch)'s app grammar; what this repository adds
is the one thing that grammar cannot know — what a database *is*.

## What this is

A catalogue in two halves and one option namespace, `nixdb`, like every repository in this family.

**[`lib/engines.nix`](lib/engines.nix)** — what the tier can run, in three groups because the tier
genuinely contains three kinds of thing: `operators` (software that reconciles instances of an
engine), `engines` (the databases themselves), and `tooling` (something that connects to them
rather than being one). Each entry carries the engine's own knowledge: which port it listens on,
which directories it writes and what is lost when one is not mounted, how long a cold start takes
before a probe means anything, which variable its root credential arrives in, which client speaks
to it.

**[`lib/clients.nix`](lib/clients.nix)** — what a person installs on a **host**, in four groups
because a database tool is one of four things: `wire` clients (a shell for exactly one engine's
protocol), `universal` clients (several protocols through drivers, so they name none),
`file` clients (open a database on disk — no server, no port, no connection string), and `operator`
clients (a plugin that drives an operator's control plane, never a database). Ordinary packages with
`arch`/`nixpkgs` names, resolved by a policy module and installed by two real backends.

**Every database client in this family is catalogued here.** Nothing about "it is a terminal
program" or "a developer uses it" splits a database tool away from the repository whose subject is
databases. The boundary that decides the next candidate is one question — does the tool exist in
order to read, write or inspect a *database*, over a protocol or off a disk? — and "handles
structured data" is deliberately not that question: a JSON processor and a spreadsheet TUI belong
to the universal terminal shelf even though both can be pointed at a database file.

```nix
# Cluster plane — composed into a nixidy environment ALONGSIDE nixk3s's app grammar.
# Every value below is a fleet fact the consumer supplies; this repository ships none of them.
nixdb.clusterPlatform = { namespace = "…"; project = "…"; origin = "nixdb"; };

nixdb.operators.pg-operator = { operator = "cnpg"; slot = N; manifests = [ … ]; };
nixdb.instances = {
  # A ladder: two majors, side by side, permanently. Both above the operator's slot.
  postgres-older = { engine = "postgres"; version = "17"; slot = N + 1; manifests = [ … ]; };
  postgres-newer = { engine = "postgres"; version = "18"; slot = N + 2; manifests = [ … ]; };
  sql = { engine = "mariadb"; version = "11.8"; slot = …;
          state.data.hostPath = "…";                       # where inside the container is ours
          credentials = { secret = "…"; key = "…"; }; };    # by name, never by value
};
nixdb.tools.browser = { tool = "whodb"; version = "…"; exposure = "nb"; … };
nixdb.tools.diagram = { tool = "chartdb"; version = "…"; exposure = "nb";
                        scaling = "scale-to-zero"; wake = "keda";   # whether it idles, and by what
                        probeBudget.readiness.failureThreshold = N; # the timing only, never the question
                      };

# Host plane — the clients. Four groups, ten packages, every name verified against upstream Arch,
# the AUR and a FORCED nixpkgs attribute.
nixdb.clients.wire      = [ "psql" "pgcli" "mariadb" "mongosh" ];
nixdb.clients.universal = [ "usql" "rainfrog" ];
nixdb.clients.file      = [ "sqlite" "sqlcipher" "bbolt" "boltbrowser" ];

# On Arch, publish the two lists to the host's own reconciler — they are separate because ONE AUR
# name in a pacman list aborts the whole transaction.
nixarch.packages.pacman = config.nixdb.clients.archPackages;
nixarch.packages.aur    = config.nixdb.clients.aurPackages;
```

## It consumes the app grammar; it does not reimplement Kubernetes

`modules/cluster.nix` is constructed by nixk3s's shared catalogue-consumer factory. It supplies
three catalogue roots and only nixdb's bounded adapters: operators dispatch to manifests or
references, managed instances dispatch to manifests, and self-managed engines plus tools dispatch
to typed apps. The factory defines those apps into `nixk3s.apps`; the grammar renders the
Application, Namespace, Deployment and Service. Import the grammar alongside this module — it is a
hard requirement, and a version that quietly rendered its own Deployments when the grammar was
absent would be the second implementation this repository exists to avoid.

`nixk3s` is therefore both the source of the exported consumer factory and the real grammar used by
the checks. `nixidy` remains checks-only. A consuming environment still composes nixdb's exported
module beside nixk3s's app grammar and, when `clusterPlatform.origin` is set, its addressing module.

**Two things the grammar cannot express**, and this repository says so rather than working around
it silently. The grammar renders a Deployment for every app, unconditionally, from a required
`image` — so it cannot express an Application carrying only passed-through objects, which is
exactly the shape of an operator's vendor chart output and of an operator-managed instance's custom
resource. Both land on the renderer's own `applications.<name>` with their object text taken as a
**value**, for a second reason beyond that one: a custom resource's schema belongs to the
operator's API version and a chart's object set to its vendor's release, so a copy rendered here
would be a permanently lagging second opinion about somebody else's API. `nixdb.renderedDirectly`
lists every workload that took that route, so the untyped side of the tier is *countable* — a
boundary nobody measures becomes the architecture. Full reasoning:
[`studies/an-operator-managed-instance-is-not-a-deployment.md`](studies/an-operator-managed-instance-is-not-a-deployment.md).

Those two also carry **server-side apply and server-side diff**, and that is not a preference: an
operator's custom resource definitions are large enough that a client-side apply overruns the
262144-byte annotation Kubernetes keeps the last-applied state in, and the apply simply fails.

The workloads the grammar *does* render reach the same two settings through `adopt`, per workload
and defaulting to false — and there it is a **decision** rather than a physical limit. Whether an
object with a workload's identity is already in the cluster is that cluster's **history**, never a
property of the software: the same engine at the same version is taken over where it has been
running for a year and created fresh where the cluster is a week old, so it is a value on the
declaration and could not be a catalogue entry. It matters most on exactly what this repository
declares — a rendered spec is never byte-identical to the YAML it replaces, and durable state
forces `Recreate`, so the diff a client-side apply invents against a live object is a database
going down rather than a rollout nobody notices.

## One engine is not one version

The hardest-won thing here, and the reason **no entry in the catalogue carries a version** and
`version` is required with no default anywhere in this repository.

Real tiers run several majors of one engine **side by side, permanently and on purpose**: existing
applications stay on the major they were qualified against, new ones onboard to the newest, and the
two are separate objects with separate storage that happen to speak the same protocol on the same
port. That is not a migration in progress. It is a **ladder**, and it is the steady state — so a
catalogue entry is a *kind* of engine rather than a copy of one, and nothing here can answer "which
version of Postgres is this cluster on", a question with no answer.

It has a second consequence that surprises people: **a port is not an identity here.** Both rungs
listen on the engine's canonical port in two different Services, and the multi-model engine
additionally speaks the Postgres wire protocol on that same number through a plugin. Three objects,
one port number, no conflict.

## An operator sits below the instances it manages

Where a fleet maps its workloads onto an ordered identity space, an operator takes the position
immediately **below** the group it manages, and its instances follow above it. An operator and its
instances are one subsystem, and a subsystem reads correctly only when the thing that reconciles
comes before the things it reconciles.

This is a **guard over a relationship, never an allocator**: nothing here assigns a number, moves
one, or contains one. The inverted ordering fails eval, naming both workloads and both numbers,
because a slot is a live identity in every space a fleet maps it into and only a person can move one
knowingly. `checks/cluster-eval.nix` asserts the *text* of that refusal, since a guard that fires
without naming what to fix is only half a guard.

Which **range** those numbers may come from is a different question, answered by nixk3s's band
model. `nixdb.clusterPlatform.origin` is the one switch that hands the tier's slots to it when it
is part of the same render.

## What belongs here, and what does not

The placement rule, stated in [`lib/engines.nix`](lib/engines.nix)'s own header so the next
candidate is decidable rather than argued:

> Does the thing **store** the data other software depends on, **manage** something that does, or
> exist only to **inspect** one? Yes → here. No → whichever repository owns the thing it actually
> is.

"Has a database in it" is *not* the test, and that clause matters more than it looks: nearly every
self-hosted application ships or requires a database, and if proximity to one were the test this
catalogue would swallow the whole application layer. A wiki that keeps its pages in Postgres is a
wiki; the Postgres is ours.

**Not the application cookbook's.** [nixapps](https://github.com/julian-corbet/nixapps-corbet-ch)
describes *ordinary* self-hosted applications — things a person opens, sitting at the leaves of the
dependency graph, consuming a database. Everything here sits at the root of that graph. That repo's
own contract says it will never grow "a storage provisioner, a device plugin, a project renderer";
a database operator is the same kind of thing, and has no home there by that repository's own
rules.

**Schema diagramming is explicitly not here.** A diagramming tool reads a schema once and draws it:
it is a design surface for whoever writes the schema, not an operational surface for whoever runs
the engine. Nothing in the tier depends on it, and it depends on the tier only the way a screenshot
depends on a screen. It sits in a different band of the cluster and is not claimed by this
repository in any form.

The one entry closest to that boundary is the **database browser** in `tooling`, and the difference
is not the direction it points — both read a schema — but what it is for: a browser is how the tier
is *operated* (open a live database, run a statement, look at what an application actually wrote),
so it is useless without engines to point at and is deployed alongside them, by whoever runs them.

**On the host side, every database tool is claimed.** The engine shells, the multi-engine command
lines and the file inspectors are all catalogued here — none of them is in
[nixsh](https://github.com/julian-corbet/nixsh-corbet-ch), the universal terminal-tool shelf, or in
the development-tooling repository, because one package belongs to one catalogue: on a NixOS host
they all feed the same package list, so a second entry is a collision rather than a redundancy.

The line against that shelf is worth stating precisely, because it is not "terminal tool" and it is
not "structured data". A JSON processor, a YAML query tool and a spreadsheet TUI all read structured
data and none of them is a database client; the spreadsheet TUI even has a SQLite loader, among two
dozen file formats, and stays where it is because opening a database file is not what it is *for*.
Everything here is a tool whose entire purpose is a database.

Also **not here**: capacity of any kind. Replica counts, heap sizes, resource requests and limits,
storage sizes, node selectors. Those are decisions about one site's hardware, and this repository
supplies what software needs in order to be *correct*, never what it needs in order to be the right
*size*. `env` is where a consumer merges its own tuning in.

## A probe, and idling, split down the same line

Two places where the same term looks like one decision and is really two, and both are refused
rather than merged.

**A probe asks a question, and a cluster pays for it.** *What* it asks — which port, which path,
and whether there is a liveness probe at all — is a property of the software and lives in the
catalogue. A liveness probe is only knowledge when the software has an endpoint that tells a
*wedged* process from a *starting* one: the schema visualiser has one (it serves static files, so
answering the index is the whole health question), and almost nothing else here does, which is why
`liveness` is null on every engine and that is a decision rather than an omission — an engine
mid-recovery answers exactly like a dead one, and restarting it restarts the recovery. The *budget*
— the delay, the period, the timeout, the number of failures — is measured against hardware, so the
catalogue carries the measured default and `probeBudget` overrides the timing, per workload. It can
never reach the port or the path: a cluster that wants a different budget has different disks, and
a cluster that wants a different endpoint has learned something about the software and belongs in
the catalogue. A budget for a probe the catalogue does not define is refused, because every number
in it would reach no object.

**An engine is never idled to zero, and that is about the protocol.** Scale-to-zero works because a
wake front *sees* a request for a workload that is down, holds it, starts the workload and replays
it — and every front that exists does that over HTTP. A client opening 5432 while the pod is asleep
gets a refused connection immediately, with nothing anywhere having noticed that something wanted
the engine; the pod sleeps once and stays asleep. So `idleable` is a catalogue fact (false on every
operator and engine, true on both tooling entries), while *whether* an idleable workload is actually
idled, and by which front, is the deployment's decision and lives in `scaling` and `wake`. Asking
for it on an engine fails eval.

## The verification contract, and what it already found

No name enters `lib/clients.nix` without passing four independent sources, because no two of them
answer the same question: archlinux.org's package search API (upstream Arch — the only authority for
`aur = false`), the AUR RPC (the authority for `aur = true`), the nixpkgs attribute **forced** rather
than looked up, and `pacman -Si` for information only. Plus two cross-checks a name existing on both
platforms cannot pass alone: `meta.homepage` against pacman's `URL`, and the actual contents of
`bin/`. [`experiments/verify-package-names.sh`](experiments/verify-package-names.sh) runs all of it,
reading names out of the catalogue rather than a second hand-kept list.

Every entry has been through it. Four of the ten install a command that is not their pacman package
name — which is exactly what makes the trap survive review, because the other six agree:

| Entry | group | pacman | nixpkgs | command |
|---|---|---|---|---|
| `psql` | wire | `postgresql-libs` (`extra`) | `postgresql` | `psql` |
| `pgcli` | wire | `pgcli` (`extra`, `any`) | `pgcli` | `pgcli` |
| `mariadb` | wire | `mariadb-clients` (`extra`) | `mariadb.client` | `mariadb` (and `mysql`) |
| `mongosh` | wire | `mongosh-bin` (**AUR**) | `mongosh` | `mongosh` |
| `usql` | universal | `usql` (**AUR**) | `usql` | `usql` |
| `rainfrog` | universal | `rainfrog` (`extra`) | `rainfrog` | `rainfrog` |
| `sqlite` | file | `sqlite` (`core`) | `sqlite-interactive` | `sqlite3` |
| `sqlcipher` | file | `sqlcipher` (`extra`) | `sqlcipher` | `sqlcipher` |
| `bbolt` | file | `bbolt` (**AUR**) | *none exists* | `bbolt` |
| `boltbrowser` | file | `boltbrowser` (**AUR**) | `boltbrowser` | `boltbrowser` |

`bbolt`'s `nixpkgs = null` is a verified fact rather than an unfinished row: no attribute of that
name exists in the pinned revision under any spelling. It is filtered out of `nixosPackages`,
published by name in `nixdb.clients.unavailableOnNixos`, and the NixOS backend warns and skips —
which is better than a consumer discovering that a selection silently installed nothing.

Three findings were expensive enough to write up:

- **`psql` is in `postgresql-libs`, not `postgresql`.** The package named for the project is the
  *server* and contains no `psql` at all — so the obvious name installs a database server, a system
  user and a service, and still leaves the wanted command missing. nixpkgs makes no such split
  (`pkgs.postgresql` carries both halves), and `pkgs.libpq` — the obvious client-only guess — has no
  `bin/` directory whatsoever.
  [`studies/psql-is-in-postgresql-libs-not-postgresql.md`](studies/psql-is-in-postgresql-libs-not-postgresql.md)
- **`mariadb-client` and `mysql-client` both exist in nixpkgs and both throw** (renamed and
  replaced, respectively, to `mariadb.client`); `pkgs.mariadb` is the server. An existence check
  passes on all three, and the failure lands at build time.
  [`studies/mariadb-client-and-mysql-client-both-throw.md`](studies/mariadb-client-and-mysql-client-both-throw.md)
- **The SQLite entry is the shell, and `pkgs.sqlite` is the wrong build of it.** That attribute
  really does install `bin/sqlite3` — so every mechanical check passes on it — but it is built
  `--disable-readline`, leaving a prompt with no history and no arrow keys, where Arch's own package
  links readline unconditionally. `sqlite-interactive` is the entry. The one finding nothing
  automated here could have caught, which is why the check pins it by name.
  [`studies/the-sqlite-entry-is-the-shell-not-the-library.md`](studies/the-sqlite-entry-is-the-shell-not-the-library.md)

`pacman -S` resolves a transaction **atomically**, so one AUR name in a pacman list fails the whole
thing with `target not found` and takes every unrelated package in the same converge down with it.
That `archPackages` and `aurPackages` never intersect is the load-bearing invariant of the client
plane — four of the ten entries are AUR-only, and all four were checked against a live CachyOS
host's own repositories as well as upstream Arch, so no `archRepoOn` lift applies to any of them.

## Public mechanism, private layout

**No address, no slot number, no namespace value, no node path and no hostname appears anywhere in
this repository.** Every one of those is a fleet fact and is a parameter the consumer supplies —
exactly the way `namespace` already works. `nixdb.clusterPlatform.namespace` has *no default* and
evaluation fails naming it the moment any workload is declared: what a cluster calls its database
namespace is a value, and a default would be this repository deciding it.

What is public is the mechanism: the catalogue, the knowledge in it, the render, and the guards.

## Repository layout

| Path | Purpose |
|---|---|
| `flake.nix` | `nixidyModules` (cluster), `nixosModules`/`systemManagerModules` (clients), `lib.*`, `checks`. |
| `lib/engines.nix` | The cluster catalogue: operators, engines, tooling — and the knowledge that makes each run. |
| `lib/clients.nix` | The client catalogue: ten packages in four groups, each named on both platforms, plus the verification contract every one of them met. |
| `modules/cluster.nix` | The cluster surface: configures nixk3s's shared consumer factory with the operator/instance/tool roots and nixdb's domain adapters and interlocks. |
| `modules/clients.nix` | Client policy and the published `archPackages`/`aurPackages`/`nixosPackages`/`unavailableOnNixos`/`binaries`. Also *is* the Arch backend — there is nothing platform-specific left for a second file to hold. |
| `modules/nixos.nix` | The NixOS backend: force-evaluates every attribute and installs it; warns separately for a stale mapping and for a package nixpkgs simply does not have. |
| `checks/` | Three checks that really evaluate — see below. |
| `examples/all/values.nix` | Placeholder values that make the render check real. Nothing in it is a real fleet fact. |
| `experiments/verify-package-names.sh` | The verification contract, runnable: every client name against upstream Arch, the AUR, a forced nixpkgs attribute, and `bin/`. |
| `studies/` | Written-up findings that changed a decision here. |

## Checks

`nix flake check` runs three, and none of them is syntax-only.

**`clients-eval`** evaluates `modules/clients.nix` through `lib.evalModules` and asserts what it
resolves in both directions: an empty selection produces empty lists on *every* plane a backend
reads, and selecting the whole catalogue resolves every entry exactly once. Then the invariants that
actually cost something if they break — that `archPackages` and `aurPackages` never intersect and
together account for every entry; that the four AUR names are on the AUR plane and on no pacman
list; that the entry with no nixpkgs derivation is absent from `nixosPackages` and named in
`unavailableOnNixos`; that the three attributes which are *not* the obvious spelling are the ones
published, by name, and the obvious ones are not; that each group carries its own defining field and
none of the others'; and that the cluster catalogue names no client package anywhere, in any group.
That last is the property that would otherwise break the engines here every time a package moved
between repositories, which is why engines record a *protocol* and clients point back at it, never
the other way round.

**`cluster-eval`** renders the cluster module through the real grammar and the real renderer, in
both directions: an empty tier defines no app at all, a declared tier's whole contribution is
exactly the workloads it declares, the engine's own knowledge reaches the grammar, a credential is a
reference, the two rungs of a ladder are two independent objects, the catalogue alone decides
whether a liveness probe exists, and a declared budget moves the timing and nothing else. Then
declarations that must each be **refused** — a managed instance with no operator, a
managed instance with no resource, a self-managed engine passing verbatim objects, an operator
ordered above its instances, an engine with an unbacked directory, storage with neither or both
backings, a credential on an engine that reads none, two workloads on one slot, two workloads
creating one namespace, a namespace anchored by a workload rendered below the grammar, a tool
passing verbatim objects, an operator nothing delivers, an engine idled to zero, an operator idled
to zero, a liveness budget for software with no liveness probe, a probe budget on a workload with no
probes, plus attempts to write factory-only resource, backing and credential terms — against a
control that must render. Central collision and delivery guards are additionally checked to occur
exactly once rather than once in the factory and once in a retired local copy. Two domain refusals
have their *message* asserted by content, because `tryEval` can only say *that* something was
refused.

**`cluster-render`** parses the manifests the tier actually produced and asserts them field by
field, because a module that type-checks can still render an engine whose Service targets a port
nothing listens on, or whose data directory is mounted somewhere the engine does not write. Among
others: the mount path is the *catalogue's* and the backing is the *declaration's*; state forces
`Recreate`, never a rolling update, because a database is a single writer; the root credential is a
`secretKeyRef` and no Secret object is ever rendered; the multi-model engine's three ports and three
directories all land; both rungs of the ladder render exactly one object each and *no* Deployment or
Service; server-side apply and diff are on the two directly-rendered kinds and on neither ordinary
engine; every created Namespace carries the annotation that stops it being cascade-deleted; the
idled tool carries its class and its wake front as labels and renders *no* replica count while the
always-on one beside it does; and no Service carries a pinned address, an external IP or a node
port.

## Status

**Pre-alpha.** The cluster catalogue's knowledge is extracted from a production tier that runs all
of it — an operator, a two-rung Postgres ladder, three self-managed engines and a browser — but this
repository has not yet replaced that tier's own declarations.

The **client plane is complete**: ten packages in four groups, every name verified against upstream
Arch, the AUR and a forced nixpkgs attribute, resolved by a policy module and installed by two real
backends. It is the half of this repository that is ready to be consumed as it stands.

## Related projects

Part of the same independently-usable module family:
[nixk3s](https://github.com/julian-corbet/nixk3s-corbet-ch) (the app grammar this consumes, and the
band model its slots answer to),
[nixapps](https://github.com/julian-corbet/nixapps-corbet-ch) (the ordinary applications that sit at
the other end of the dependency graph and consume these engines), and
[nixsh](https://github.com/julian-corbet/nixsh-corbet-ch) (the universal terminal-tool shelf, which
catalogues the engine-agnostic database tools this repository does not duplicate).

## License

MIT License &copy; 2026 Julian Corbet

# SPDX-License-Identifier: MIT OR Apache-2.0
#
# The cluster catalogue: what the database tier can run. Three groups, because the tier genuinely
# contains three kinds of thing and flattening them would make the model lie:
#
#   `operators`  software that MANAGES instances of an engine. It is a workload itself, and the
#                instances it reconciles are custom resources rather than workloads.
#   `engines`    a database that runs as its own container -- self-managed, one image, one data
#                directory, no controller between the declaration and the process.
#   `tooling`    something that CONNECTS to the engines from inside the cluster rather than being
#                one. It has no wire protocol of its own and nothing depends on it for storage.
#
# THE PLACEMENT RULE, stated as a boundary rather than a list, in the same shape nixsh's
# lib/tools.nix and nixagent's lib/agents.nix state theirs:
#
#   Does the thing STORE the data other software depends on, manage something that does, or exist
#   only to inspect one?
#     yes -> it belongs here
#     no  -> it belongs to whichever repo owns the thing it actually is
#
# "Has a database in it" is NOT the test, and that clause matters more than it looks: nearly every
# self-hosted application ships or requires a database, and if proximity to one were the test this
# catalogue would swallow the whole application layer. The test is whether the thing IS the storage
# tier. A wiki that keeps its pages in Postgres is a wiki; the Postgres is ours.
#
# ── TWO NEIGHBOURS THIS RULE IS DRAWN AGAINST ──────────────────────────────────────────────────
#
#   - the application cookbook (nixapps). That repo describes ORDINARY self-hosted applications:
#     things a person opens, which sit at the leaves of the dependency graph and CONSUME a
#     database. Everything here sits at the root of that graph: an engine is what other workloads
#     depend on, and an operator is what the engine depends on. The cookbook says of itself that
#     it will never grow "a storage provisioner, a device plugin, a project renderer" -- a
#     database operator is the same kind of thing, infrastructure rather than an app, and it has no
#     home there by that repo's own contract.
#
#   - schema DIAGRAMMING was once excluded here, on the reasoning that a diagramming tool reads a
#     schema once and draws it -- a design surface for whoever writes the schema rather than an
#     operational surface for whoever runs the engine. That paragraph was written on 2026-08-07 and
#     the assignment went the other way the next day: a schema visualiser is database TOOLING, it
#     pairs with the browser below rather than with the platform cockpit it had been filed under,
#     and it moved bands to sit with this tier. `chartdb` is therefore in `tooling`, not excluded.
#
#     What the old paragraph got right is still true and is why it is `tooling` and not an engine:
#     nothing in the tier depends on it, and it depends on the tier only in the way a screenshot
#     depends on a screen.
#
# The one entry that sits closest to that boundary is the database BROWSER in `tooling` below, and
# the difference is not the direction it points -- both read a schema -- but what it is for: a
# browser is how the tier is operated (open a live database, run a statement, look at what an
# application actually wrote), so it is useless without engines to point at and is deployed
# alongside them, by whoever runs them. A diagram is authored once and read by people who never
# touch the running system.
#
# ── ONE ENGINE IS NOT ONE VERSION ──────────────────────────────────────────────────────────────
#
# The hardest-won thing in this file, and the reason NO ENTRY BELOW CARRIES A VERSION. Real tiers
# run several majors of one engine SIDE BY SIDE, permanently and on purpose: the existing
# applications stay on the major they were qualified against, new ones onboard to the newest, and
# the two are separate objects with separate storage that happen to speak the same protocol on the
# same port. That is not a migration in progress, it is a LADDER, and it is the steady state.
#
# So `version` is a required, defaultless option on every declared instance (see
# ../modules/cluster.nix), a catalogue entry is a KIND of engine rather than a copy of one, and
# nothing here ever asks "which version of postgres is this cluster on" -- a question with no
# answer.
#
# It has a second consequence worth stating separately, because it surprises people: A PORT IS NOT
# AN IDENTITY HERE. Two rungs of one ladder both listen on the engine's canonical port, in two
# different Services, and a third engine below (the multi-model one) additionally speaks the
# Postgres wire protocol on that same number through a plugin. Three objects, one port number,
# no conflict -- because each is a distinct Service and the number is a property of the software,
# not of the network.
#
# ── AN ENGINE IS NEVER IDLED TO ZERO, AND THAT IS ABOUT THE PROTOCOL ─────────────────────────
#
# Scale-to-zero works because a wake front SEES a request arrive for a workload that is down, holds
# it, starts the workload and replays it. Every front that exists does that over HTTP, because
# holding a request at all requires understanding where one ends.
#
# A database is not reached that way. A client opens a connection over the engine's own wire
# protocol -- 5432, 3306, 27017 -- to an address no HTTP front terminates, and what it gets while
# the pod is down is a refused connection, immediately, with nothing anywhere having noticed that
# something wanted the engine. Nor is it fixable by putting a front in front of it: a database
# connection is long-lived and stateful, so a front would have to hold a session open across a pod
# that does not exist yet, and the cold start it would be hiding is on the query path.
#
# So `idleable` is false on every operator and every engine here, and it is not a policy anybody
# chose -- it is the protocol. It is true on both tooling entries for the mirror-image reason: HTTP
# in, HTTP out, nothing held between requests.
#
# WHETHER an idleable workload is actually idled is still the consumer's decision and lives in the
# declaration (`scaling`, and which front wakes it). This field only says whether that decision is
# available at all.
#
# ── AN OPERATOR SITS BELOW THE INSTANCES IT MANAGES ────────────────────────────────────────────
#
# Where a fleet maps workloads onto an ordered identity space, an operator takes the position
# immediately BELOW the group it manages, and its instances follow above it. The reason is that the
# ordering is read by humans: an operator and its instances are one subsystem, and the subsystem
# reads correctly only when the thing that reconciles comes before the things it reconciles.
#
# This catalogue models the relationship (`operator` on a managed engine, `manages` on an operator)
# and ../modules/cluster.nix REFUSES an inverted ordering rather than merely documenting it. No
# number appears here or there: which positions exist is the shape of somebody's fleet, and only
# the ordering is universal.
#
# ── FIELDS ─────────────────────────────────────────────────────────────────────────────────────
#
# Shared by every group:
#
#   `image`        container image REPOSITORY, with no tag. The tag is the declared instance's
#                  `version`, which is why it is not here -- see the ladder note above. `null` on a
#                  managed engine, whose image is named inside the operator's own resource.
#   `ports`        named container-side ports, `<name> = <number>`. A container port is a property
#                  of the software rather than of any network, which is the one kind of number a
#                  public declaration may carry.
#   `primaryPort`  which of those the readiness probe watches and the client connects to.
#   `state`        the container-internal paths this software writes, `<name> = <mountPath>`. What
#                  BACKS each one is a value the consumer supplies; where it lands inside the
#                  container is knowledge and lives here.
#   `env`          plain environment the software needs in order to run correctly at all. Never
#                  sizing, never credentials, never an address.
#   `args`         entrypoint arguments in the same spirit.
#   `readiness`    probe SHAPE and its measured budget: which endpoint answers "this is serving",
#                  and the timing, in seconds, that a real cold start needed rather than a guess.
#                  The budget is a MEASURED DEFAULT -- a declaration may override the timing for
#                  hardware this was not measured on, and may never override what is asked.
#   `liveness`     the same, for the probe whose verdict is a RESTART, or null. Null is the honest
#                  answer for most software here and is not an omission: a liveness probe is only
#                  knowledge when this software has a cheap endpoint that distinguishes "wedged"
#                  from "still starting", and when it does not, a synthesized one is the classic
#                  way to put a slow engine into a restart loop that looks like the engine's fault.
#   `idleable`     whether this software may be idled to zero and woken on demand by an HTTP wake
#                  front. A property of the software rather than of anybody's cluster: a front can
#                  only hold and replay a request it can SEE, so software reached over its own wire
#                  protocol -- or over no ingress at all -- can never be woken by one. WHETHER a
#                  cluster idles an idleable workload is still that cluster's choice.
#   `note`         what the entry is, and every non-obvious thing about running it.
#
# Group-specific:
#
#   `manages`      (operators) engine keys whose instances this operator reconciles.
#   `chart`        (operators) upstream Helm chart coordinates -- `repo` and `name`, deliberately
#                  WITHOUT a version. See ../modules/cluster.nix for why this repository publishes
#                  the coordinates and renders no chart.
#   `wire`         (engines) which wire protocol a client would speak to it. Not the same as the
#                  product: the multi-model engine below speaks Postgres.
#
#                  A PROTOCOL NAME, NEVER A PACKAGE NAME, and the direction of that reference is
#                  deliberate. This file names no entry of ../lib/clients.nix and must not start
#                  to: a client is a package, packages get assigned to repositories by their
#                  operator, and an engine entry that pointed at one would break here every time a
#                  package moved elsewhere. The reference runs the other way -- a client says which
#                  protocol it speaks -- so this side never has to change.
#   `managed`      (engines) true when instances are custom resources reconciled by an operator
#                  rather than containers. Decides how ../modules/cluster.nix renders an instance,
#                  and it is a hard fork in behaviour rather than a hint.
#   `operator`     (engines) which operator, when `managed`.
#   `rootSecretEnv` (engines) the environment variable that carries the engine's root credential,
#                  or null. The variable's NAME is knowledge; its value is a Secret the consumer
#                  already has, referenced by name and never carried here.
{ ... }:
{
  # ── Operators: software that reconciles instances of an engine ───────────────────────────────
  operators = {
    cnpg = {
      image = null; # delivered by the chart below, not by a single image this repository names
      manages = [ "postgres" ];
      ports = { };
      primaryPort = null;
      state = { };
      env = { };
      args = [ ];
      readiness = null;
      liveness = null;

      # An operator has no ingress at all -- it watches the API server and reconciles. There is no
      # request for a wake front to hold, so idling it to zero is idling the thing that would have
      # to notice, and every instance it manages stops being reconciled while nothing reports it.
      idleable = false;

      chart = {
        repo = "https://cloudnative-pg.github.io/charts";
        name = "cloudnative-pg";
      };

      note = ''
        CloudNativePG: a Kubernetes operator for PostgreSQL. It reconciles a `Cluster` custom
        resource into the pods, Services, Secrets and PVCs that make up one Postgres instance,
        and owns failover, backup and switchover for it.

        THE CHART CARRIES NO VERSION HERE, on purpose. A chart version and its digest change every
        release and are pinned by whoever deploys it; a copy in this catalogue would be a second,
        lagging pin that nothing keeps honest. What does not change is the repository URL and the
        chart name, so those are the parts published.

        WATCH SCOPE IS CLUSTER-WIDE BY DEFAULT. The operator reconciles instances in every
        namespace, not only its own -- so moving the operator between namespaces does not orphan
        the instances it already manages, and equally, one operator is enough for the whole tier.

        ITS CUSTOM RESOURCE DEFINITIONS ARE LARGE. Large enough that a client-side apply overruns
        the 262144-byte annotation the last-applied state is kept in, which is why every workload
        this repository renders for an operator or a managed instance asks for server-side apply
        and server-side diff. See ../modules/cluster.nix.
      '';
    };
  };

  # ── Engines: the databases themselves ────────────────────────────────────────────────────────
  engines = {
    postgres = {
      image = null; # the instance's own resource names it -- see `managed` below
      managed = true;
      operator = "cnpg";
      wire = "postgres";
      ports.postgres = 5432;
      primaryPort = "postgres";
      state = { };
      env = { };
      args = [ ];
      readiness = null;
      liveness = null;
      idleable = false; # see below: an engine is reached over its own wire protocol
      rootSecretEnv = null; # the operator creates and rotates the credential Secret itself

      note = ''
        PostgreSQL, run as instances of the operator above rather than as containers of its own.

        THIS IS THE ENTRY THE LADDER RULE WAS WRITTEN FOR. Several majors run side by side
        indefinitely: applications that were qualified against an older major stay on it, new ones
        onboard to the newest, and both rungs listen on 5432 in two different Services. Declare one
        instance per rung, each with its own `version` and its own storage; nothing in this
        repository has a concept of "the" Postgres.

        AN INSTANCE IS A CUSTOM RESOURCE, NOT A DEPLOYMENT, and that is a fork in how it is
        rendered rather than a detail. The operator owns the pod, the Service, the credential
        Secret and the volume; what is declared is a `Cluster` object describing the desired
        instance. The body of that object is the OPERATOR's API -- versioned with the operator,
        not with this repository -- so it is taken as a value and passed through, exactly the way
        a node path is. See `manifests` in ../modules/cluster.nix.

        STORAGE IS THE OPERATOR'S, hence the empty `state` above: a `Cluster` names its own volume
        size and storage class inside its spec, and a mount declared out here would be a second
        opinion about a directory this repository does not own.
      '';
    };

    mariadb = {
      image = "mariadb";
      managed = false;
      operator = null;
      wire = "mysql";
      ports.mysql = 3306;
      primaryPort = "mysql";
      state.data = "/var/lib/mysql";
      env.MARIADB_ROOT_HOST = "%";
      args = [ ];
      rootSecretEnv = "MARIADB_ROOT_PASSWORD";

      readiness = {
        initialDelaySeconds = 15;
        periodSeconds = 10;
        timeoutSeconds = 5;
        failureThreshold = 3;
      };

      liveness = null; # see the note: what would answer it is an exec probe
      idleable = false;

      note = ''
        MariaDB, the drop-in MySQL-protocol engine. One container, one data directory, single
        writer.

        `MARIADB_ROOT_HOST = "%"` is knowledge, not a loosening anybody chose: the image's default
        confines the root account to connections from localhost, and every consumer inside a
        cluster arrives over TCP from another pod. Without it the engine starts, accepts the
        connection and refuses the login, which reads as a wrong password rather than as a host
        restriction. Reaching it is still governed by the network and by the credential; this only
        stops the account from being useless.

        THE READINESS PROBE HERE IS A TCP CONNECT, and it is weaker than what this engine can
        actually answer. The image ships `healthcheck.sh --connect --innodb_initialized`, which
        distinguishes "the port is open" from "InnoDB finished recovery and will answer queries" --
        a real difference after an unclean stop. That is an exec probe, which the app grammar this
        repository renders through deliberately does not express (its probes are TCP and HTTP), so
        the honest default is the TCP one and the better probe is a typed merge onto the rendered
        Deployment. Said out loud rather than left as a silently weaker default.

        THE INITIAL DELAY IS NOT PADDING. Fifteen seconds is what a cold InnoDB start takes before
        it will answer at all; probing sooner just spends the failure budget on a certainty.
      '';
    };

    mongo = {
      image = "mongo";
      managed = false;
      operator = null;
      wire = "mongodb";
      ports.mongo = 27017;
      primaryPort = "mongo";
      state.data = "/data/db";
      env = { };
      args = [ "--bind_ip_all" ];
      rootSecretEnv = null; # see the note: initial users are created once, not injected per start

      readiness = {
        initialDelaySeconds = 12;
        periodSeconds = 10;
        timeoutSeconds = 5;
        failureThreshold = 3;
      };

      liveness = null;
      idleable = false;

      note = ''
        MongoDB. One container, one data directory, single writer.

        `--bind_ip_all` because the default binds loopback only, which inside a container means the
        pod can reach it and nothing else can.

        NO `rootSecretEnv`. The image's root-user variables only take effect on an EMPTY data
        directory: they are a first-boot bootstrap, not a credential the engine reads on every
        start. Naming one here would suggest a password can be rotated by changing an environment
        variable, which is exactly the belief that produces an engine nobody can log into. Users
        are created once against the running engine and live in its own catalogue afterwards.

        ENABLING AUTHENTICATION COSTS AN INIT CONTAINER, and it is worth knowing before rather
        than after. `--auth` on a replica set additionally requires `--keyFile`, even for a
        single-member set, because members authenticate to each other with it regardless of how
        many there are. The engine then refuses to start unless that file is owned by the user the
        process runs as and is not group-readable -- and a Secret volume is always root-owned, with
        no option anywhere in Kubernetes to change a Secret file's OWNER (only its group, via
        fsGroup, which the engine's own check then rejects as too permissive). The way every
        real-world chart resolves this: copy the file into an emptyDir in an init container, chown
        it there, and mount that instead. This grammar has no term for an init container, so it is
        a typed merge onto the rendered Deployment.

        A REPLICA SET MEMBER NEEDS A STABLE HOSTNAME, which is a pod-DNS arrangement (a hostname, a
        subdomain and a matching headless Service) rather than anything this vocabulary expresses.
        Also a typed merge, and also worth knowing up front: a member reconfigured onto an unstable
        name is a set that cannot elect after a restart.

        THE READINESS PROBE HERE IS A TCP CONNECT, for the same reason as MariaDB above: a probe
        that actually asks the engine to answer needs credentials and a shell, which is an exec
        probe.
      '';
    };

    arcadedb = {
      image = "arcadedata/arcadedb";
      managed = false;
      operator = null;
      wire = "postgres";
      ports = {
        http = 2480;
        postgres = 5432;
        binary = 2424;
      };
      primaryPort = "http";
      state = {
        data = "/arcade_db";
        config = "/home/arcadedb/config";
        backup = "/arcade_backup";
      };
      env = { };
      args = [ ];
      rootSecretEnv = "ROOT_PW";

      readiness = {
        initialDelaySeconds = 20;
        periodSeconds = 10;
        timeoutSeconds = 5;
        failureThreshold = 6;
      };

      liveness = null;
      idleable = false; # HTTP is only one of its three interfaces -- see the note

      note = ''
        ArcadeDB, a multi-model engine (graph, document, key-value, time-series) in one process.

        `wire = "postgres"` IS NOT A TYPO AND NOT THE WHOLE STORY. Its native interfaces are an
        HTTP API on 2480 (which also serves its Studio UI) and a binary protocol on 2424; the
        Postgres wire protocol on 5432 is a PLUGIN, which has to be switched on. It is recorded as
        the `wire` protocol anyway, because it is the interface a person reaches for a shell with --
        this engine and the Postgres ladder are talked to by the same kind of client. `primaryPort`
        is nevertheless the HTTP port rather than the wire port: HTTP is what is always there.

        And it is the third object in a tier that listens on 5432, alongside both rungs of the
        Postgres ladder. Three Services, one port number, no conflict: see this file's header.

        THREE STATE DIRECTORIES, NOT ONE, and they are not interchangeable. `data` holds the
        databases, `config` holds server configuration the process WRITES back (so a read-only
        mount breaks it), and `backup` is where its own backup command lands. A deployment that
        mounts only the first comes up healthy and loses the other two on every restart.

        THE ROOT PASSWORD ARRIVES INDIRECTLY. This engine reads its root password from a JVM system
        property rather than from an environment variable of its own, so the credential is injected
        as `ROOT_PW` from a Secret and then referenced from the JVM options -- which means the JVM
        options string is part of the engine's configuration and not merely tuning. Heap sizing
        belongs in the same string and is deliberately NOT set here: that is capacity, and capacity
        is the consumer's.
      '';
    };
  };

  # ── Tooling: connects to the engines rather than being one ───────────────────────────────────
  tooling = {
    whodb = {
      image = "clidey/whodb";
      ports.http = 8080;
      primaryPort = "http";
      state.data = "/data";
      env = { };
      args = [ ];

      readiness = {
        initialDelaySeconds = 0;
        periodSeconds = 5;
        timeoutSeconds = 1;
        failureThreshold = 30;
      };

      # NO LIVENESS. Its readiness probe is a TCP connect, and a TCP connect whose verdict is a
      # RESTART is the worst of both: it cannot tell a wedged front end from a slow one, and the
      # thing it would kill is holding an editing session in a local file.
      liveness = null;

      idleable = true;

      note = ''
        A database browser and SQL workspace: connects to several engines at once and gives a
        person a schema tree, a table view and a query editor over live data.

        WHY IT IS TIER TOOLING AND NOT AN ORDINARY APPLICATION. It has no domain of its own. It
        stores nothing anybody depends on, it is deployed by whoever runs the engines, and it is
        empty and pointless without them -- every screen it draws is a rendering of some other
        workload's data. That is the same relationship an operator's control-plane plugin has to
        its operator, which is why both are catalogued in this repository and neither is
        catalogued as an app.

        ITS CONNECTIONS ARE CREDENTIALS, so they are not expressible here in any form. Each one is
        a JSON object with a host, a user and a password, supplied as an environment variable named
        for the engine type and an index; all of them belong in a Secret this repository names and
        never carries. Consumed wholesale (`envFrom`) rather than key by key, because the number of
        connections changes without the declaration changing.

        IT KEEPS SESSION STATE IN A LOCAL FILE, hence the single state directory and the single
        writer that comes with it. It also needs a stable encryption key for that store, in the
        same Secret: replace the key and every saved session becomes unreadable.

        THE READINESS BUDGET IS WIDE ON PURPOSE -- five-second periods and thirty failures, so a
        first start has two and a half minutes. It is a front end with nothing to lose by being
        probed patiently, and an impatient probe on a slow first boot is a restart loop that looks
        like a broken image.

        IT IS IDLEABLE EVEN THOUGH IT KEEPS A FILE, which is worth saying because the two facts
        look like they should conflict. Nothing else reads that file: it is this front end's own
        session store, it survives in whatever backs the directory, and the only thing lost by
        idling is the seconds a woken pod spends starting. What decides `idleable` is the PROTOCOL
        somebody arrives on, and everybody arrives here over HTTP.
      '';
    };

    chartdb = {
      image = "ghcr.io/chartdb/chartdb";
      ports.http = 80;
      primaryPort = "http";

      # NOTHING. Stated as an empty set rather than omitted, because the tool assertion compares
      # the directories a declaration backs against the directories the catalogue says are
      # written -- an absent `state` would throw there instead of asserting "backs none".
      state = { };

      env = { };
      args = [ ];

      readiness = {
        path = "/";
        initialDelaySeconds = 0;
        periodSeconds = 5;
        timeoutSeconds = 1;
        failureThreshold = 24;
      };

      # THE ONE ENTRY IN THIS CATALOGUE THAT EARNS A LIVENESS PROBE, and the reason is what it
      # serves rather than how important it is. Both probes ask the same question -- GET the index
      # -- because there is only one question to ask: the whole application is a static bundle, so
      # a server that answers the index is working and one that does not is wedged. There is no
      # third state for a probe to misread, which is exactly what is missing everywhere else here
      # (an engine mid-recovery answers nothing and is fine, and killing it restarts the recovery).
      #
      # THE TWO BUDGETS ARE DELIBERATELY NOT SYMMETRIC. Readiness is patient because it also covers
      # a WOKEN pod (see `idleable`) and must never be the thing that kills a cold start; liveness
      # is impatient by comparison because by the time it is running, the process has already served
      # the index once, so continued silence is a wedge rather than a start.
      liveness = {
        path = "/";
        initialDelaySeconds = 0;
        periodSeconds = 15;
        timeoutSeconds = 1;
        failureThreshold = 6;
      };

      # IT IS THE MOST IDLEABLE THING IN THIS REPOSITORY. HTTP is its only interface, every request
      # is answered from files, and it holds nothing between requests -- so a wake front can accept
      # a request while the pod is down, start it, and replay the request with nobody the wiser.
      # A visualiser nobody opens most days is precisely the workload this is for.
      idleable = true;

      note = ''
        A database-schema visualiser: reads a schema and draws it as a diagram you can move around,
        so a person can see the shape of a database rather than read it a table at a time.

        WHY IT IS TIER TOOLING AND NOT AN ORDINARY APPLICATION -- the same test the browser above
        passes, reached from the other direction. It has no domain of its own and nothing in the
        tier depends on it; it depends on the tier the way a screenshot depends on a screen. That
        is exactly the relationship that makes something tooling, and it is why it pairs with the
        browser rather than with the platform cockpit it was originally filed under.

        IT KEEPS NOTHING. The whole application is a static single-page bundle that runs in the
        browser: what a person lays out lives in that browser's local storage or in a file they
        export, and the container serves assets and holds no copy of any of it. So a restart costs
        unsaved work and never anything durable, there is no directory to back, and the workload is
        genuinely replaceable rather than merely small. Declaring no state is also what keeps it off
        the single-writer handling every stateful workload in this repository gets.

        ITS CONNECTIONS ARE THE READER'S, NOT THE DEPLOYMENT'S, which is the sharpest difference
        from the browser above. That one holds saved connections server-side and needs a Secret and
        an encryption key; this one is handed a schema by whoever is looking at it and stores no
        credential anywhere. There is nothing here for a Secret to carry.

        THE READINESS BUDGET IS WIDE FOR A DIFFERENT REASON than the browser's. Serving static
        files is instant, so a cold process is ready almost immediately -- but this is the kind of
        workload that is idled to zero when nobody is looking, and a probe that runs while a woken
        pod is still starting must not be the thing that kills it. Two minutes of five-second
        periods costs nothing on a fast start and is the difference between a wake and a restart
        loop on a slow one.
      '';
    };
  };
}

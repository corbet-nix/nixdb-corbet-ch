# Proves the cluster module resolves what it claims and REFUSES what it claims to refuse, both
# directions, through the real renderer and the real app grammar.
#
# Both halves matter and neither is enough alone. A guard nobody has watched fire is a comment; a
# guard that fires on everything is a wall. So every case below is a complete, otherwise-valid tier
# with exactly one thing wrong, and the `control` case is the same shape with nothing wrong and MUST
# render -- without it, a typo in the shared base would make every other case "pass" for the wrong
# reason.
#
# Two refusals additionally have their MESSAGE asserted by content, because `tryEval` can only say
# THAT something was refused. For the ordering guard in particular, half of what is being checked is
# whether the refusal names both workloads and both numbers -- a refusal that does not is only half
# a guard, since the whole point is that a person has to move one of them deliberately.
{ pkgs, lib, nixidy, appsModule, addressingModule, clusterModule }:
let
  base = {
    nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
    nixidy.target.branch = "main";
    nixdb.clusterPlatform = {
      namespace = "example-dbs";
      project = "example-data";
    };
  };

  mkEnv = values: nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [ appsModule addressingModule clusterModule base values ];
  };

  renders = values:
    (builtins.tryEval (builtins.seq (mkEnv values).environmentPackage.drvPath true)).success;

  # The assertions themselves rather than the throw they eventually cause.
  failures = values:
    map (a: a.message)
      (lib.filter (a: !a.assertion) (mkEnv values).config.nixidy.assertions);

  # Cross-root invariants now belong to the shared factory. One bad declaration must therefore
  # produce one factory diagnostic, not the same sentence once from the factory and once from the
  # retired translator.
  failsExactlyOnceWith = infix: values:
    let
      result = builtins.tryEval (lib.length (lib.filter
        (assertion: !assertion.assertion && lib.hasInfix infix assertion.message)
        (mkEnv values).config.nixidy.assertions));
    in
    result.success && result.value == 1;

  ## ---------------------------------------------------------------------
  ## The floor: an empty tier renders nothing at all
  ## ---------------------------------------------------------------------

  emptyCfg = (mkEnv { }).config;

  ## ---------------------------------------------------------------------
  ## The control: a complete tier that must resolve
  ## ---------------------------------------------------------------------

  goodTier = {
    nixdb.operators.op = {
      operator = "cnpg";
      slot = 33;
      manifests = [ "apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: op\n  namespace: example-dbs\n" ];
    };
    nixdb.instances = {
      pg-older = {
        engine = "postgres";
        version = "17";
        slot = 34;
        manifests = [ "apiVersion: postgresql.cnpg.io/v1\nkind: Cluster\nmetadata:\n  name: pg-older\n  namespace: example-dbs\nspec:\n  instances: 1\n" ];
      };
      pg-newer = {
        engine = "postgres";
        version = "18";
        slot = 35;
        manifests = [ "apiVersion: postgresql.cnpg.io/v1\nkind: Cluster\nmetadata:\n  name: pg-newer\n  namespace: example-dbs\nspec:\n  instances: 1\n" ];
      };
      sql = {
        engine = "mariadb";
        version = "11.8";
        slot = 36;
        createNamespace = true;
        state.data.hostPath = "/example/data/sql";
        credentials = { secret = "example-sql-root"; key = "rootPassword"; };
      };
    };
    nixdb.tools.browser = {
      tool = "whodb";
      version = "0.0.0";
      namespace = "example-browser";
      createNamespace = true;
      slot = 40;
      state.data.hostPath = "/example/data/browser";
      envFromSecrets = [ "example-browser-connections" ];
      # The OTHER kind the grammar renders, declared as taking over an object this invented cluster
      # already holds. It is in the control rather than in a case of its own because there is
      # nothing to refuse here -- adoption is a plain value with no counterpart in the catalogue to
      # contradict -- so what has to be watched is that it reaches the grammar at all, and that it
      # reaches nothing else.
      adopt = true;
    };
    # The idled tool. Present in the CONTROL rather than only in the failing cases, because both
    # halves of the new split need one: a workload the catalogue says may be woken, actually being
    # woken, with one probe budget overridden and everything else about its probes untouched.
    nixdb.tools.schema = {
      tool = "chartdb";
      version = "0.0.0";
      namespace = "example-schema";
      createNamespace = true;
      slot = 41;
      scaling = "scale-to-zero";
      wake = "keda";
      probeBudget.readiness.failureThreshold = 36;
    };
  };

  goodCfg = (mkEnv goodTier).config;

  # The same tier, with an origin — which is what turns on both halves of the addressing story:
  # `addressingOf` hands the grammar-rendered workloads their slot directly, and everything else
  # has to be RESERVED, because the band model counts occupancy from `nixk3s.apps` and those
  # workloads are not in it. Without the reservations, a fleet's own report calls a live database
  # address free.
  addressedTier = lib.recursiveUpdate goodTier {
    nixdb.clusterPlatform.origin = "example-repo";
  };
  addressedCfg = (mkEnv addressedTier).config;

  # The other direction of the delivery interlock, and the one that keeps it from being a wall: the
  # SAME operator with empty `manifests`, but with the consumer delivering its chart itself as an
  # `applications.<name>` this module does not define. That is precisely what an empty `manifests`
  # promises exists, so it must render.
  emptyManifestsDelivered = lib.recursiveUpdate goodTier {
    nixdb.operators.op.manifests = lib.mkForce [ ];
    applications.op = {
      namespace = "example-dbs";
      createNamespace = false;
      project = "example-data";
      yamls = [ "apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: op\n  namespace: example-dbs\n" ];
    };
  };
  emptyManifestsDeliveredCfg = (mkEnv emptyManifestsDelivered).config;

  # One tier, two renderers, and the split is a property of the ENGINE rather than of the
  # declaration -- which is exactly what makes it worth pinning.
  sorted = lib.sort (a: b: a < b);

  ## ---------------------------------------------------------------------
  ## The failing direction
  ## ---------------------------------------------------------------------

  # Each case is `goodTier` with one thing changed. Written as whole tiers rather than as patches so
  # that a reader can see what is wrong without reconstructing it.
  mustFail = {
    # THE INTERLOCK. An instance of a managed engine with no operator is a custom resource nothing
    # reads: accepted by the API server, reported healthy by the syncing controller, and never a
    # database.
    managed-instance-with-no-operator =
      lib.recursiveUpdate goodTier { nixdb.operators.op.enable = false; };

    # A managed instance IS its custom resource. With none, the Application is empty.
    managed-instance-with-no-resource =
      lib.recursiveUpdate goodTier { nixdb.instances.pg-newer.manifests = lib.mkForce [ ]; };

    # The reverse: a self-managed engine is rendered in full by the grammar, so verbatim objects
    # here would be a second, untyped copy of what is already being rendered.
    self-managed-instance-passing-verbatim-objects =
      lib.recursiveUpdate goodTier { nixdb.instances.sql.manifests = [ "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n" ]; };

    # THE ORDERING GUARD: the operator above the instances it manages.
    operator-ordered-above-its-instances =
      lib.recursiveUpdate goodTier { nixdb.operators.op.slot = lib.mkForce 39; };

    # Every directory the engine writes must be backed by something. The multi-model engine writes
    # three, and an engine that comes up with two of them mounted looks healthy.
    engine-with-an-unbacked-directory =
      lib.recursiveUpdate goodTier {
        nixdb.instances.multimodel = {
          engine = "arcadedb";
          version = "26.5.1";
          slot = 37;
          state.data.hostPath = "/example/data/multimodel";
        };
      };

    engine-with-an-unknown-directory =
      lib.recursiveUpdate goodTier {
        nixdb.instances.sql.state.unknown.hostPath = "/example/data/unknown";
      };

    state-with-no-backing =
      lib.recursiveUpdate goodTier { nixdb.instances.sql.state.data.hostPath = lib.mkForce null; };

    state-with-both-backings =
      lib.recursiveUpdate goodTier { nixdb.instances.sql.state.data.claim = "example-sql-data"; };

    # An engine that establishes its credentials some other way -- naming a Secret for it would
    # render nothing, which is worse than being refused.
    credentials-on-an-engine-that-reads-none =
      lib.recursiveUpdate goodTier {
        nixdb.instances.docs = {
          engine = "mongo";
          version = "8.0";
          slot = 38;
          state.data.hostPath = "/example/data/docs";
          credentials = { secret = "example-docs-root"; key = "password"; };
        };
      };

    two-workloads-on-one-slot =
      lib.recursiveUpdate goodTier { nixdb.tools.browser.slot = lib.mkForce 36; };

    two-workloads-creating-one-namespace =
      lib.recursiveUpdate goodTier { nixdb.tools.browser.namespace = lib.mkForce "example-dbs"; };

    # A Namespace created by a workload rendered below the grammar carries none of the grammar's
    # protection against being pruned -- and everything inside a database namespace is precisely
    # what must survive a manifest slip elsewhere in the tree.
    directly-rendered-workload-anchoring-a-namespace =
      lib.recursiveUpdate goodTier { nixdb.operators.op.createNamespace = true; };

    tool-passing-verbatim-objects =
      lib.recursiveUpdate goodTier { nixdb.tools.browser.manifests = [ "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n" ]; };

    # DECLARED IS NOT DELIVERED. An operator with empty `manifests` renders nothing here, which is
    # the supported shape when its chart comes from an application of the consumer's own -- and it
    # was the one door the interlock did not watch. Drop that application and the tier still
    # evaluated green while every managed instance became a custom resource with no reconciler:
    # the exact failure the interlock exists to prevent, reached through the gap in it.
    operator-declared-with-nothing-delivering-it =
      lib.recursiveUpdate goodTier { nixdb.operators.op.manifests = lib.mkForce [ ]; };

    # AN ENGINE CANNOT BE WOKEN. A wake front holds an HTTP request; a client arriving on 3306
    # while the pod is down gets a refused connection and nothing anywhere notices that anything
    # wanted the engine. The pod sleeps once and stays asleep, which reads as a dead database.
    engine-idled-to-zero =
      lib.recursiveUpdate goodTier { nixdb.instances.sql.scaling = "scale-to-zero"; };

    # Nor can the operator: it has no ingress at all, so idling it idles the only thing that would
    # have noticed, and every instance it manages silently stops being reconciled.
    operator-idled-to-zero =
      lib.recursiveUpdate goodTier { nixdb.operators.op.scaling = "scale-to-zero"; };

    # A budget tunes a probe's timing. For software the catalogue gives no liveness probe -- which
    # here is deliberate rather than missing -- every number in it reaches no object.
    liveness-budget-for-a-probe-the-software-does-not-have =
      lib.recursiveUpdate goodTier { nixdb.tools.browser.probeBudget.liveness.periodSeconds = 20; };

    # The same guard from the other side: an operator is a controller and has no probes at all.
    probe-budget-on-a-workload-with-no-probes =
      lib.recursiveUpdate goodTier { nixdb.operators.op.probeBudget.readiness.timeoutSeconds = 5; };

    # The factory has a wider common vocabulary, but adopting it must not silently widen nixdb's
    # established declaration schema. These are unknown options, not values a later guard ignores.
    factory-only-resource-term =
      lib.recursiveUpdate goodTier { nixdb.tools.browser.resources.cpuRequest = "10m"; };

    factory-only-state-backing =
      lib.recursiveUpdate goodTier { nixdb.instances.sql.state.data.emptyDir = true; };

    factory-variable-shaped-credentials =
      lib.recursiveUpdate goodTier {
        nixdb.instances.sql.credentials.keys.MARIADB_ROOT_PASSWORD = "rootPassword";
      };
  };

  wronglyRendered = lib.attrNames (lib.filterAttrs (_: v: v) (lib.mapAttrs (_: renders) mustFail));

  # The ordering refusal, read as text. It has to name both workloads and both numbers, because
  # nothing here moves either of them and a person has to.
  orderingMessage =
    let msgs = failures mustFail.operator-ordered-above-its-instances; in
    if msgs == [ ] then "" else lib.head msgs;

  orderingMessageNames =
    lib.hasInfix "`op`" orderingMessage
    && (lib.hasInfix "`pg-older`" orderingMessage || lib.hasInfix "`pg-newer`" orderingMessage)
    && lib.hasInfix "39" orderingMessage
    && (lib.hasInfix "34" orderingMessage || lib.hasInfix "35" orderingMessage);

  # The unbacked-directory refusal has to say WHICH directories the engine writes and where, or the
  # reader has to go and find that out from somewhere else -- which is the whole failure this
  # catalogue exists to prevent.
  unbackedMessage =
    let msgs = lib.filter (m: lib.hasInfix "multimodel" m) (failures mustFail.engine-with-an-unbacked-directory); in
    if msgs == [ ] then "" else lib.head msgs;

  unbackedMessageNames =
    lib.hasInfix "/arcade_db" unbackedMessage
    && lib.hasInfix "/home/arcadedb/config" unbackedMessage
    && lib.hasInfix "/arcade_backup" unbackedMessage;

  results = {
    # ── The floor ─────────────────────────────────────────────────────────────────────────────
    "an empty tier defines no app in the grammar at all" =
      emptyCfg.nixk3s.apps == { };

    # The renderer defines applications of its own regardless of what is declared, so "adds
    # nothing" is asserted as a DIFFERENCE against an empty tier rather than against `{ }` -- which
    # also pins the other half in one expression: a declared tier contributes exactly its own
    # workloads to the render, by either route, and not one object more.
    "a declared tier's whole contribution to the render is exactly the workloads it declares" =
      sorted (lib.subtractLists (lib.attrNames emptyCfg.applications) (lib.attrNames goodCfg.applications))
      == sorted (goodCfg.nixdb.renderedByGrammar ++ goodCfg.nixdb.renderedDirectly);

    "an empty tier reports nothing through any factory delivery kind, and claims no slots" =
      emptyCfg.nixdb.renderedByGrammar == [ ]
      && emptyCfg.nixdb.renderedDirectly == [ ]
      && emptyCfg.nixdb.notRendered == [ ]
      && emptyCfg.nixdb.clusterSlots == { }
      && emptyCfg.nixdb.slots == { };

    "an empty tier raises no assertion of its own -- an unused module must be silent" =
      lib.all (a: a.assertion) emptyCfg.nixidy.assertions;

    # ── The control ───────────────────────────────────────────────────────────────────────────
    "a complete tier renders" = renders goodTier;

    # The delivery interlock's accepting direction. Without this, refusing every empty-`manifests`
    # operator would pass the failing case above while making the supported shape unusable.
    "an operator with no manifests renders once something else in the environment delivers it" =
      renders emptyManifestsDelivered;

    "an externally delivered operator is reported as a reference rather than as a direct render" =
      emptyManifestsDeliveredCfg.nixdb.notRendered == [ "op" ]
      && emptyManifestsDeliveredCfg.nixdb.renderedDirectly == [ "pg-newer" "pg-older" ];

    # ── Occupancy: every position this tier holds is visible to the band model ────────────────
    # The grammar-rendered half arrives through `addressingOf`; everything else would be invisible,
    # so it is reserved. Asserted as the EXACT set, because a reservation missing one workload is
    # precisely the bug this exists to prevent — one live address quietly reading as free.
    "every workload the grammar does not render reserves its position" =
      sorted (lib.attrNames addressedCfg.nixk3s.addressing.reservations)
      == [ "op" "pg-newer" "pg-older" ];

    "the grammar-rendered workloads are NOT reserved -- they claim their slot as apps" =
      lib.intersectLists
        (lib.attrNames addressedCfg.nixk3s.addressing.reservations)
        addressedCfg.nixdb.renderedByGrammar == [ ];

    "a reservation carries the tier's origin and the workload's own slot" =
      addressedCfg.nixk3s.addressing.reservations.pg-older.slot == 34
      && addressedCfg.nixk3s.addressing.reservations.pg-older.origin == "example-repo";

    # With no origin there is no band to be counted in, so claiming a position in a space this tier
    # was never bound to would be a lie rather than a reservation.
    "a tier that names no origin reserves nothing" =
      goodCfg.nixk3s.addressing.reservations == { };

    "self-managed engines and tooling go through the app grammar" =
      sorted goodCfg.nixdb.renderedByGrammar == [ "browser" "schema" "sql" ];

    "an operator's delivery and every managed instance go one level below it, countably" =
      sorted goodCfg.nixdb.renderedDirectly == [ "op" "pg-newer" "pg-older" ];

    "the two sides are disjoint and together account for every declared workload" =
      lib.intersectLists goodCfg.nixdb.renderedByGrammar goodCfg.nixdb.renderedDirectly == [ ]
      && goodCfg.nixdb.notRendered == [ ]
      && lib.length (goodCfg.nixdb.renderedByGrammar ++ goodCfg.nixdb.renderedDirectly) == 6;

    "the grammar receives exactly the workloads it renders, with the engine's own knowledge filled in" =
      lib.attrNames goodCfg.nixk3s.apps == [ "browser" "schema" "sql" ]
      && goodCfg.nixk3s.apps.sql.image == "mariadb:11.8"
      && goodCfg.nixk3s.apps.sql.ports.mysql.number == 3306
      && goodCfg.nixk3s.apps.sql.state.data.mountPath == "/var/lib/mysql"
      && goodCfg.nixk3s.apps.sql.state.data.hostPath == "/example/data/sql";

    "the root credential arrives as a reference under the variable the ENGINE names, never as a value" =
      goodCfg.nixk3s.apps.sql.secrets.credentials.secret == "example-sql-root"
      && goodCfg.nixk3s.apps.sql.secrets.credentials.env.MARIADB_ROOT_PASSWORD == "rootPassword";

    "a probe is rendered on the port the catalogue calls primary, with the engine's own timing" =
      goodCfg.nixk3s.apps.sql.probes.readiness.port == "mysql"
      && goodCfg.nixk3s.apps.sql.probes.readiness.initialDelaySeconds == 15;

    # WHETHER there is a liveness probe is the catalogue's answer and nobody else's. Said in both
    # directions in one expression, because the failure mode of getting this wrong is silent: a
    # synthesized liveness probe on an engine that answers nothing during recovery is a restart
    # loop that looks like the engine's fault.
    "the catalogue decides whether a liveness probe exists at all, and what it asks" =
      goodCfg.nixk3s.apps.schema.probes.liveness.path == "/"
      && goodCfg.nixk3s.apps.schema.probes.liveness.port == "http"
      && goodCfg.nixk3s.apps.schema.probes.liveness.periodSeconds == 15
      && goodCfg.nixk3s.apps.browser.probes.liveness == null
      && goodCfg.nixk3s.apps.sql.probes.liveness == null;

    # The other half of the same split: a budget reaches the TIMING and can never become a
    # different question. One number was overridden; the rest of the probe is still the catalogue's.
    "a declared budget overrides the timing it names, and nothing else about the probe" =
      goodCfg.nixk3s.apps.schema.probes.readiness.failureThreshold == 36
      && goodCfg.nixk3s.apps.schema.probes.readiness.periodSeconds == 5
      && goodCfg.nixk3s.apps.schema.probes.readiness.timeoutSeconds == 1
      && goodCfg.nixk3s.apps.schema.probes.readiness.path == "/"
      && goodCfg.nixk3s.apps.schema.probes.readiness.port == "http"
      # and a probe nobody tuned is untouched
      && goodCfg.nixk3s.apps.browser.probes.readiness.failureThreshold == 30;

    # The catalogue says WHETHER a workload may be idled; the declaration says whether it is, and
    # by what. Both reach the grammar, and the engine beside them is left where it has to be.
    "an idleable workload carries the class and the front it was given" =
      goodCfg.nixk3s.apps.schema.scaling == "scale-to-zero"
      && goodCfg.nixk3s.apps.schema.wake == "keda"
      && goodCfg.nixk3s.apps.sql.scaling == "always"
      && goodCfg.nixk3s.apps.sql.wake == null;

    # ADOPTION IS THE RECEIVING CLUSTER'S HISTORY, and it travels to the grammar per workload. Said
    # in both directions in one expression, because a term that leaked onto its neighbours would put
    # a server-side diff on Applications nobody asked to adopt anything with -- and asserted on both
    # kinds the grammar renders, a tool and an engine, since they are two option sets over one
    # translation and only one of them was declared.
    "taking over an existing object reaches the grammar, and only where it was declared" =
      goodCfg.nixk3s.apps.browser.adopt == true
      && goodCfg.nixk3s.apps.sql.adopt == false
      && goodCfg.nixk3s.apps.schema.adopt == false;

    # THE LADDER. Two majors of one engine, side by side, and nothing anywhere decides which is
    # current -- both are ordinary workloads with their own identity.
    "two rungs of one ladder are two independent workloads" =
      goodCfg.nixdb.slots.pg-older == 34
      && goodCfg.nixdb.slots.pg-newer == 35
      && goodCfg.applications.pg-older.namespace == goodCfg.applications.pg-newer.namespace;

    # The renderer normalizes both of these into the strings it will emit, which is why they are
    # compared as strings rather than as the booleans they are set with.
    "both rungs carry server-side apply and server-side diff -- a large custom resource cannot be applied client-side at all" =
      goodCfg.applications.pg-older.syncPolicy.syncOptions.serverSideApply == "ServerSideApply=true"
      && goodCfg.applications.pg-newer.compareOptions.serverSideDiff == "ServerSideDiff=true";

    "the slot report covers every workload that claims one, on both sides of the render split" =
      goodCfg.nixdb.slots == { op = 33; pg-older = 34; pg-newer = 35; sql = 36; browser = 40; schema = 41; }
      && goodCfg.nixdb.clusterSlots == goodCfg.nixdb.slots;

    "the operator's chart coordinates are published WITHOUT a version -- a version here would be a second pin nothing keeps honest" =
      goodCfg.nixdb.operatorCharts.op == {
        repo = "https://cloudnative-pg.github.io/charts";
        name = "cloudnative-pg";
      };

    "the grammar-rendered workloads carry the declaring origin, so the band model governs their slots" =
      (mkEnv (lib.recursiveUpdate goodTier {
        nixdb.clusterPlatform.origin = "nixdb";
        nixk3s.addressing = {
          enable = true;
          bands.example-data = { base = 32; size = 16; };
          bindings.nixdb = "example-data";
        };
      })).config.nixk3s.apps.sql.origin == "nixdb";

    "and without that switch the grammar's apps name no origin at all -- those are the band model's terms, not this module's" =
      goodCfg.nixk3s.apps.sql.origin == null && goodCfg.nixk3s.apps.sql.slot == null;

    # ── The failing direction ─────────────────────────────────────────────────────────────────
    "every guard fires: nothing in the must-fail set renders" =
      wronglyRendered == [ ];

    "the ordering refusal names both workloads and both numbers, because a person has to move one" =
      orderingMessageNames;

    "the unbacked-directory refusal says which directories the engine writes, and where" =
      unbackedMessageNames;

    "the factory is the single cross-root slot-collision authority" =
      failsExactlyOnceWith "slot 36 is claimed by 2 workloads"
        mustFail.two-workloads-on-one-slot;

    "the factory is the single namespace-anchor collision authority" =
      failsExactlyOnceWith "Exactly one workload may create a namespace"
        mustFail.two-workloads-creating-one-namespace;

    "the factory is the single direct-delivery namespace safety authority" =
      failsExactlyOnceWith "non-grammar renderer cannot stamp"
        mustFail.directly-rendered-workload-anchoring-a-namespace;

    "the factory is the single typed-app manifest authority" =
      failsExactlyOnceWith "rendered in full by the app grammar and also carries whole manifests"
        mustFail.self-managed-instance-passing-verbatim-objects
      && failsExactlyOnceWith "rendered in full by the app grammar and also carries whole manifests"
        mustFail.tool-passing-verbatim-objects;
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
in
if failed == [ ]
then
  pkgs.writeText "nixdb-cluster-eval" ''
    control renders, the floor holds, and every guard fires:
    ${lib.concatMapStringsSep "\n" (n: "  refused: ${n}") (lib.attrNames mustFail)}
  ''
else
  throw ''
    nixdb: cluster-eval check failed. Failing assertions:
    ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failed}
    ${lib.optionalString (wronglyRendered != [ ])
      "Declarations that rendered but had to be refused: ${lib.concatStringsSep ", " wronglyRendered}"}
  ''

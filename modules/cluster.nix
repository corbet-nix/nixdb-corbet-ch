# SPDX-License-Identifier: MIT OR Apache-2.0
#
# nixdb's cluster surface: catalogue knowledge translated through nixk3s.
#
# Kubernetes rendering belongs to nixk3s. This module selects one of three catalogue roots,
# classifies each declaration as a typed app, an opaque manifest delivery, or a reference, and
# gives the shared consumer factory only the domain-specific adapters and interlocks it cannot
# derive. The public nixdb declaration vocabulary stays unchanged.
#
# Operators and managed instances are not Deployments. An operator is delivered as its vendor's
# rendered chart, and a managed instance is the custom resource that the operator reconciles.
# Both therefore use the factory's `manifest` delivery (or `reference` for an operator delivered by
# another module). Self-managed engines and tools use the typed app grammar.
{ mkConsumerModule }:
{ lib, ... }:

let
  engines = import ../lib/engines.nix { };

  # The shared factory calls this fact `idleSafe`; nixdb's established catalogue calls it
  # `idleable`. Adapt the private input to the factory without changing the exported catalogue.
  adaptCatalogue = lib.mapAttrs (_: entry: entry // { idleSafe = entry.idleable; });

  operatorCatalogue = adaptCatalogue engines.operators;
  engineCatalogue = adaptCatalogue engines.engines;
  toolCatalogue = adaptCatalogue engines.tooling;

  enabledOf = lib.filterAttrs (_: w: w.enable);

  # ── Legacy public declaration shapes ───────────────────────────────────────────────────────
  #
  # These are deliberately redeclared through root `extraOptions`. State and credentials have
  # narrower, domain-specific shapes than the factory's common records; probeBudget and
  # envFromSecrets are established nixdb names. Image and wake are also retained as replacements
  # so adopting the factory does not add generic diagnostics to nixdb's existing public contract.

  backingType = lib.types.submodule {
    options = {
      claim = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Name of an existing PersistentVolumeClaim backing this directory.";
      };
      hostPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Path on the node backing this directory instead of a claim.";
      };
      hostPathType = lib.mkOption {
        type = lib.types.enum [ "Directory" "DirectoryOrCreate" ];
        default = "Directory";
        description = "Whether a missing node path is an error or is created empty.";
      };
      readOnly = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to mount this directory read-only.";
      };
    };
  };

  probeBudgetType = lib.types.submodule {
    options = {
      initialDelaySeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "Delay before the first probe; null keeps the catalogue's value.";
      };
      periodSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Interval between probes; null keeps the catalogue's value.";
      };
      timeoutSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "How long one probe may take; null keeps the catalogue's value.";
      };
      failureThreshold = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Consecutive failures tolerated; null keeps the catalogue's value.";
      };
    };
  };

  legacyCommonOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to render this workload.";
    };
    createNamespace = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether this workload anchors its namespace.";
    };
    slot = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
      description = "Position this workload holds in the consumer's ordered identity space.";
    };
    exposure = lib.mkOption {
      type = lib.types.enum [ "internal" "nb" "public" ];
      default = "internal";
      description = "Who can reach this workload, as a class rather than an address.";
    };
    scaling = lib.mkOption {
      type = lib.types.enum [ "always" "scale-to-zero" ];
      default = "always";
      description = "Whether this workload is always present or may idle to zero.";
    };
    wake = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "keda" "sablier" ]);
      default = null;
      description = "Which wake front brings an idled workload back.";
    };
    adopt = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether the grammar takes over objects already present in the cluster.";
    };
    probeBudget = lib.mkOption {
      type = lib.types.submodule {
        options = {
          readiness = lib.mkOption {
            type = probeBudgetType;
            default = { };
            description = "Timing override for the readiness probe the catalogue defines.";
          };
          liveness = lib.mkOption {
            type = probeBudgetType;
            default = { };
            description = "Timing override for the liveness probe the catalogue defines.";
          };
        };
      };
      default = { };
      description = "This cluster's timing overrides for catalogue-defined probes.";
    };
    state = lib.mkOption {
      type = lib.types.attrsOf backingType;
      default = { };
      description = "Backing for each directory this catalogue entry writes.";
    };
    envFromSecrets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Existing Secrets loaded wholesale into the workload environment.";
    };
    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra plain environment merged over the catalogue's environment.";
    };
    args = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Arguments appended to the catalogue's entrypoint arguments.";
    };
    image = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Whole image reference replacing the catalogue repository plus version.";
    };
    manifests = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Opaque objects delivered for an operator or managed instance.";
    };
  };

  versionOption = lib.mkOption {
    type = lib.types.str;
    description = "Which version this instance runs; required and defaulted nowhere.";
  };

  credentialsOption = lib.mkOption {
    type = lib.types.nullOr (lib.types.submodule {
      options = {
        secret = lib.mkOption {
          type = lib.types.str;
          description = "Name of an existing Secret holding the engine's root credential.";
        };
        key = lib.mkOption {
          type = lib.types.str;
          description = "Key inside that Secret carrying the credential.";
        };
      };
    });
    default = null;
    description = "The engine's root credential, by Secret and key reference.";
  };

  # Only these factory-common terms existed on nixdb before this migration. Image, wake, and state
  # are intentionally absent here and redeclared above, which transfers their renderer/diagnostic
  # boundary to this adapter. Every other factory-only term remains structurally unwritable.
  operatorEnabledOptions = [
    "namespace"
    "createNamespace"
    "project"
    "slot"
    "exposure"
    "scaling"
    "adopt"
    "env"
    "args"
    "manifests"
  ];

  appEnabledOptions = operatorEnabledOptions ++ [ "version" ];

  # ── Projection into the grammar ─────────────────────────────────────────────────────────────

  stateOf = entry: w:
    lib.mapAttrs
      (key: backing: {
        mountPath = entry.state.${key};
        inherit (backing) claim hostPath hostPathType readOnly;
      })
      # Keep the renderer total while the domain assertion explains an unknown key. Indexing the
      # catalogue first would replace that sentence with a raw missing-attribute exception.
      (lib.filterAttrs (key: _: entry.state ? ${key}) w.state);

  secretsOf = entry: w:
    lib.optionalAttrs (w.credentials != null && (entry.rootSecretEnv or null) != null) {
      credentials = {
        secret = w.credentials.secret;
        env.${entry.rootSecretEnv} = w.credentials.key;
      };
    }
    // lib.listToAttrs
      (map (secret: lib.nameValuePair secret { inherit secret; envFrom = true; }) w.envFromSecrets);

  budgetedProbe = shape: budget:
    shape // lib.filterAttrs (_: value: value != null) {
      inherit (budget) initialDelaySeconds periodSeconds timeoutSeconds failureThreshold;
    };

  probesOf = entry: w:
    lib.optionalAttrs (entry.readiness != null) {
      readiness = { port = entry.primaryPort; } // budgetedProbe entry.readiness w.probeBudget.readiness;
    }
    // lib.optionalAttrs (entry.liveness != null) {
      liveness = { port = entry.primaryPort; } // budgetedProbe entry.liveness w.probeBudget.liveness;
    };

  extendApp = { app, entry, w, ... }:
    app // {
      state = stateOf entry w;
      secrets = secretsOf entry w;
      probes = probesOf entry w;
    };

  operatorKind = { w, ... }: if w.manifests == [ ] then "reference" else "manifest";
  instanceKind = { entry, ... }: if entry.managed then "manifest" else "app";

  # ── Domain interlocks retained below the factory ────────────────────────────────────────────

  showSlot = w: if w.slot == null then "(none)" else toString w.slot;
  budgetIsSet = budget: lib.any (value: value != null) (lib.attrValues budget);
  probeShapes = entry: {
    readiness = entry.readiness != null;
    liveness = entry.liveness != null;
  };

  declaredOperatorKeys = x:
    lib.unique (lib.mapAttrsToList (_: w: w.operator) (enabledOf x.consumer.operators));

  managedInstancesOf = operatorContext:
    lib.filter
      (instance:
        instance.entry.managed
        && lib.elem instance.w.engine operatorContext.entry.manages)
      (lib.mapAttrsToList
        (name: w: { inherit name w; entry = engines.engines.${w.engine}; })
        (enabledOf operatorContext.consumer.instances));

  probeBudgetAssertions = kind: contexts: lib.concatMap
    (x:
      let shapes = probeShapes x.entry; in
      [
        {
          assertion = !(budgetIsSet x.w.probeBudget.readiness) || shapes.readiness;
          message =
            "nixdb: ${kind} `${x.name}` sets a readiness-probe budget, and this software has no "
            + "readiness probe in the catalogue -- so every number in that budget would reach no "
            + "object at all. A budget tunes a probe's TIMING; whether there is a probe to time, "
            + "and what it asks, is a property of the software and lives in the catalogue.";
        }
        {
          assertion = !(budgetIsSet x.w.probeBudget.liveness) || shapes.liveness;
          message =
            "nixdb: ${kind} `${x.name}` sets a liveness-probe budget, and this software has no "
            + "liveness probe in the catalogue -- which for most of what this repository catalogues "
            + "is deliberate rather than missing: a probe whose verdict is a RESTART needs an "
            + "endpoint that tells a wedged process from a slow-starting one, and an engine "
            + "mid-recovery answers exactly like a dead one. The budget would reach no object. If "
            + "this software really does have such an endpoint, that is a catalogue entry, not a "
            + "number here.";
        }
      ])
    contexts;

  # Typed apps use the factory's idle-safety guard through the catalogue adapter above. Manifest
  # and reference deliveries do not pass through that app-only guard, so nixdb keeps the same
  # correctness check for those roots here.
  directIdleAssertions = kind: contexts: map
    (x: {
      assertion = x.w.scaling != "scale-to-zero" || x.entry.idleable;
      message =
        "nixdb: ${kind} `${x.name}` asks to be idled to zero, and the software it runs cannot be "
        + "woken. A wake front sees a request only over HTTP; this is reached over its own wire "
        + "protocol, or over no ingress at all, so a client arriving while the pod is down gets a "
        + "refused connection and nothing starts anything. The pod would go to sleep once and stay "
        + "there. Leave `scaling` at `always`, and idle whatever fronts it instead.";
    })
    (lib.filter (x: x.kind != "app") contexts);

  operatorAssertions = contexts:
    lib.concatMap
      (operatorContext:
        [
          {
            assertion =
              operatorContext.w.manifests != [ ]
              || operatorContext.moduleConfig.applications ? ${operatorContext.name};
            message =
              "nixdb: operator `${operatorContext.name}` is declared with no `manifests`, and "
              + "nothing in this environment delivers it either -- there is no "
              + "`applications.${operatorContext.name}`. An empty `manifests` means \"its chart is "
              + "deployed by an application of my own\", so this declaration currently promises an "
              + "operator that does not exist. Every managed instance depending on it would render "
              + "a custom resource the API server accepts and reports healthy while no database is "
              + "ever created. Deliver the chart from an application of your own, or put its "
              + "rendered objects in `manifests` here.";
          }
        ]
        ++ map
          (instance: {
            assertion =
              operatorContext.w.slot == null
              || instance.w.slot == null
              || operatorContext.w.slot < instance.w.slot;
            message =
              "nixdb: operator `${operatorContext.name}` holds slot ${showSlot operatorContext.w} "
              + "and the instance it manages, `${instance.name}`, holds ${showSlot instance.w}. "
              + "An operator takes the position immediately BELOW the instances it manages: an "
              + "operator and its instances are one subsystem, and the ordering is read by people, "
              + "for whom a subsystem reads correctly only when the thing that reconciles comes "
              + "before the things it reconciles. Nothing here will move either number for you -- "
              + "a slot is a live identity in every space a fleet maps it into. Move them "
              + "deliberately.";
          })
          (managedInstancesOf operatorContext))
      contexts
    ++ probeBudgetAssertions "operator" contexts
    ++ directIdleAssertions "operator" contexts;

  instanceAssertions = contexts:
    lib.concatMap
      (x: [
        {
          assertion = !x.entry.managed || lib.elem x.entry.operator (declaredOperatorKeys x);
          message =
            "nixdb: instance `${x.name}` runs engine `${x.w.engine}`, whose instances are custom "
            + "resources reconciled by the `${toString x.entry.operator}` operator -- and no such "
            + "operator is declared. The resource would be accepted and reported healthy, and no "
            + "database would ever exist. Declare it in `nixdb.operators`, or use an engine that "
            + "runs as its own container.";
        }
        {
          assertion = !x.entry.managed || x.w.manifests != [ ];
          message =
            "nixdb: instance `${x.name}` runs a managed engine, so it IS a custom resource -- and "
            + "`manifests` is empty, which renders an Application with nothing in it. The "
            + "resource's schema belongs to the operator's own API version rather than to this "
            + "repository, so its text is taken as a value: put the object in "
            + "`nixdb.instances.${x.name}.manifests`.";
        }
        {
          assertion = x.entry.managed || lib.attrNames x.w.state == lib.attrNames x.entry.state;
          message =
            "nixdb: instance `${x.name}` (engine `${x.w.engine}`) must back every directory the "
            + "engine writes, and backs "
            + (if x.w.state == { } then "none"
              else lib.concatMapStringsSep ", " (key: "`${key}`") (lib.attrNames x.w.state))
            + ". The engine writes: "
            + lib.concatStringsSep ", "
              (lib.mapAttrsToList (key: path: "`${key}` at ${path}") x.entry.state)
            + ". An unbacked one is not an error at runtime -- the engine starts, uses the "
            + "container's own filesystem, and loses it at the next restart.";
        }
        {
          assertion = lib.all
            (backing: (backing.claim == null) != (backing.hostPath == null))
            (lib.attrValues x.w.state);
          message =
            "nixdb: instance `${x.name}` backs a directory with neither or both of `claim` and "
            + "`hostPath`. Storage needs exactly one backing: an existing claim by name, or a path "
            + "on the node.";
        }
        {
          assertion = (x.entry.rootSecretEnv or null) != null || x.w.credentials == null;
          message =
            "nixdb: instance `${x.name}` names `credentials`, but engine `${x.w.engine}` reads no "
            + "root credential from its environment -- see that entry's own note for how its "
            + "credentials are actually established. The reference would render nothing, which is "
            + "worse than being refused.";
        }
      ])
      contexts
    ++ probeBudgetAssertions "instance" contexts
    ++ directIdleAssertions "instance" contexts;

  toolAssertions = contexts:
    lib.concatMap
      (x: [{
        assertion = lib.attrNames x.w.state == lib.attrNames x.entry.state;
        message =
          "nixdb: tool `${x.name}` must back every directory it writes, and backs "
          + (if x.w.state == { } then "none"
            else lib.concatMapStringsSep ", " (key: "`${key}`") (lib.attrNames x.w.state))
          + ". It writes: "
          + lib.concatStringsSep ", "
            (lib.mapAttrsToList (key: path: "`${key}` at ${path}") x.entry.state)
          + ".";
      }
      {
        assertion = lib.all
          (backing: (backing.claim == null) != (backing.hostPath == null))
          (lib.attrValues x.w.state);
        message =
          "nixdb: tool `${x.name}` backs a directory with neither or both of `claim` and "
          + "`hostPath`. Storage needs exactly one backing.";
      }])
      contexts
    ++ probeBudgetAssertions "tool" contexts;

  operatorWarnings = contexts: map
    (x: {
      when = x.w.manifests == [ ];
      message =
        "nixdb: operator `${x.name}` is declared but delivers nothing here -- `manifests` is empty, "
        + "so no objects are rendered for it. That is correct when its chart is deployed by "
        + "something else in the same cluster, and the declaration still buys the interlocks (an "
        + "instance of a managed engine now knows its operator is present, and the ordering against "
        + "its instances is checked). If it was meant to be delivered from here, it is not.";
    })
    contexts;

  directWarnings = contexts: lib.concatMap
    (x: [
      {
        when = x.w.exposure != "internal";
        message =
          "nixdb: workload `${x.name}` declares exposure `${x.w.exposure}`, which is a term of the "
          + "app grammar -- and this workload is rendered below the grammar, so the class reaches "
          + "no object. Whatever fronts it is selecting on something else.";
      }
      {
        when = x.w.wake != null;
        message =
          "nixdb: workload `${x.name}` names the `${toString x.w.wake}` wake front, which is a term "
          + "of the app grammar -- and this workload is rendered below the grammar, so the name "
          + "reaches no object. Nothing will wake it, and nothing is asleep either.";
      }
      {
        when = x.w.slot != null && x.platform.origin == null;
        message =
          "nixdb: workload `${x.name}` claims slot ${showSlot x.w}, and "
          + "`nixdb.clusterPlatform.origin` is unset -- so the number is checked for order and for "
          + "collisions inside this tier, and by nothing for which RANGE it may come from. Set the "
          + "origin when the band model is part of the same render.";
      }
    ])
    (lib.filter (x: x.kind != "app") contexts);

  slotsOption = lib.mkOption {
    type = lib.types.attrsOf lib.types.ints.unsigned;
    readOnly = true;
    description = "Workload to claimed position for every enabled declaration with a slot.";
  };

  operatorChartsOption = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
    readOnly = true;
    description = "Operator declaration to its upstream Helm chart repository and name.";
  };

  factoryModule = mkConsumerModule {
    namespace = "nixdb";

    roots = {
      operators = {
        catalogue = operatorCatalogue;
        selector = "operator";
        kind = operatorKind;
        enabledOptions = operatorEnabledOptions;
        extraOptions = legacyCommonOptions;
        assertions = operatorAssertions;
        warnings = contexts: operatorWarnings contexts ++ directWarnings contexts;
        description = "Operators present in this cluster, keyed by declaration name.";
      };

      instances = {
        catalogue = engineCatalogue;
        selector = "engine";
        kind = instanceKind;
        enabledOptions = appEnabledOptions;
        extraOptions = legacyCommonOptions // {
          version = versionOption;
          credentials = credentialsOption;
        };
        extend = extendApp;
        assertions = instanceAssertions;
        warnings = directWarnings;
        description = "Database instances, one declaration per running database and version.";
      };

      tools = {
        catalogue = toolCatalogue;
        selector = "tool";
        kind = _: "app";
        enabledOptions = appEnabledOptions;
        extraOptions = legacyCommonOptions // { version = versionOption; };
        extend = extendApp;
        assertions = toolAssertions;
        description = "Tier tooling that connects to the engines rather than storing their data.";
      };
    };

    extraNamespaceOptions = {
      slots = slotsOption;
      operatorCharts = operatorChartsOption;
    };

    extraConfig = contexts:
      let
        operators = lib.filter (x: x.root == "operators") contexts;
        slotted = lib.filter (x: x.w.slot != null) contexts;
      in
      {
        # The factory leaves project unset because it is a cluster value. Preserve nixdb's existing
        # resolved default at option-default priority; an ordinary consumer definition still wins.
        nixdb.clusterPlatform.project = lib.mkOptionDefault "default";
        nixdb.slots = lib.listToAttrs
          (map (x: lib.nameValuePair x.name x.w.slot) slotted);
        nixdb.operatorCharts = lib.listToAttrs
          (map (x: lib.nameValuePair x.name x.entry.chart) operators);
      };
  };
in
{
  imports = [ factoryModule ];
}

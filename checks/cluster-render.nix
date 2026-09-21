# SPDX-License-Identifier: MIT OR Apache-2.0
# Asserts what the tier actually RENDERS, by reading the manifests out of the rendered environment
# with a YAML parser.
#
# Why not just evaluate: a module that type-checks can still render an engine whose Service points
# at a port nothing listens on, whose data directory is mounted somewhere the engine does not write,
# or whose rolling update puts two writers on one volume. None of that is an eval error. All of it
# is either an outage or, worse, a database that comes up empty and reports itself healthy.
#
# The assertions below are the module's PROMISES rather than a transcript of its current output:
# a self-managed engine renders a Deployment and a Service through the app grammar; the engine's own
# knowledge (port, mount path, probe timing, the variable its root credential arrives in) reaches
# the objects; state is backed by what the consumer supplied and mounted where the ENGINE writes;
# a credential is a reference and never a value; the two rungs of a ladder are two independent
# objects in one namespace; whatever cannot be expressed as an app passes through verbatim, with
# server-side apply, and is countable; and a workload declared to take over an object the cluster
# already holds renders the Application that can, while its neighbours do not.
{ pkgs, lib, env }:

pkgs.runCommand "nixdb-cluster-render"
{
  nativeBuildInputs = [ pkgs.yq-go ];
  manifests = env.environmentPackage;
  # Not manifests, so they cannot be asserted from the tree: the two countable reports that say
  # which side of the render split each workload took.
  byGrammar = lib.concatStringsSep " " (lib.sort (a: b: a < b) env.config.nixdb.renderedByGrammar);
  directly = lib.concatStringsSep " " (lib.sort (a: b: a < b) env.config.nixdb.renderedDirectly);
} ''
  set -euo pipefail
  fail=0

  check() {
    if [ "$2" = "$3" ]; then
      echo "  ok   $1: $3"
    else
      echo "  FAIL $1: expected '$2', got '$3'"
      fail=1
    fi
  }

  present() {
    if [ -e "$2" ]; then echo "  ok   $1: rendered"; else echo "  FAIL $1: not rendered ($2)"; fail=1; fi
  }

  absent() {
    if [ -e "$2" ]; then echo "  FAIL $1: rendered but should not be ($2)"; fail=1; else echo "  ok   $1: correctly not rendered"; fi
  }

  y() { yq -r "$1" "$2"; }

  SQL_D=$manifests/example-mysql/Deployment-example-mysql.yaml
  SQL_S=$manifests/example-mysql/Service-example-mysql.yaml
  SQL_A=$manifests/apps/Application-example-mysql.yaml
  SQL_NS=$manifests/example-mysql/Namespace-example-dbs.yaml
  MM_D=$manifests/example-multimodel/Deployment-example-multimodel.yaml
  MM_S=$manifests/example-multimodel/Service-example-multimodel.yaml
  MM_A=$manifests/apps/Application-example-multimodel.yaml
  BR_D=$manifests/example-browser/Deployment-example-browser.yaml
  BR_S=$manifests/example-browser/Service-example-browser.yaml
  BR_NS=$manifests/example-browser/Namespace-example-browser.yaml
  BR_A=$manifests/apps/Application-example-browser.yaml
  SCH_D=$manifests/example-schema/Deployment-example-schema.yaml
  SCH_A=$manifests/apps/Application-example-schema.yaml
  PG_OLD=$manifests/example-pg-older/Cluster-example-pg-older.yaml
  PG_NEW=$manifests/example-pg-newer/Cluster-example-pg-newer.yaml
  PG_OLD_A=$manifests/apps/Application-example-pg-older.yaml
  PG_NEW_A=$manifests/apps/Application-example-pg-newer.yaml
  OP_D=$manifests/example-pg-operator/Deployment-example-pg-operator.yaml
  OP_SA=$manifests/example-pg-operator/ServiceAccount-example-pg-operator.yaml

  echo "== the whole rendered Deployment of a self-managed engine =="
  cat $SQL_D

  echo "== a self-managed engine is rendered by the app grammar, in full =="
  present "Deployment" "$SQL_D"
  present "Service"    "$SQL_S"
  check "Deployment kind"      "Deployment" "$(y '.kind' $SQL_D)"
  check "Service kind"         "Service"    "$(y '.kind' $SQL_S)"
  check "namespace"            "example-dbs" "$(y '.metadata.namespace' $SQL_D)"
  check "managed-by is the grammar's" "nixk3s" "$(y '.metadata.labels."app.kubernetes.io/managed-by"' $SQL_D)"

  echo "== the image is the catalogue repository plus THIS instance's version =="
  check "image" "mariadb:11.8" "$(y '.spec.template.spec.containers[0].image' $SQL_D)"

  echo "== the engine's own port, and a Service that targets the port the container declares =="
  check "container port"     "3306"  "$(y '.spec.template.spec.containers[0].ports[0].containerPort' $SQL_D)"
  check "container port name" "mysql" "$(y '.spec.template.spec.containers[0].ports[0].name' $SQL_D)"
  check "service port"       "3306"  "$(y '.spec.ports[0].port' $SQL_S)"
  check "service targetPort" "mysql" "$(y '.spec.ports[0].targetPort' $SQL_S)"

  echo "== state: mounted where the ENGINE writes, backed by what the consumer supplied =="
  check "mount path is the catalogue's"  "/var/lib/mysql" \
    "$(y '.spec.template.spec.containers[0].volumeMounts[0].mountPath' $SQL_D)"
  check "backing is the declaration's"   "/example/state/mysql" \
    "$(y '.spec.template.spec.volumes[0].hostPath.path' $SQL_D)"
  check "a data directory must already exist" "Directory" \
    "$(y '.spec.template.spec.volumes[0].hostPath.type' $SQL_D)"

  echo "== a database is a single writer: state forces Recreate, never a rolling update =="
  check "strategy" "Recreate" "$(y '.spec.strategy.type' $SQL_D)"
  check "one replica" "1" "$(y '.spec.replicas' $SQL_D)"

  echo "== node-path state pins the pod, and the objects say so =="
  check "node-pinned label" "true" "$(y '.metadata.labels."nixk3s.dev/node-pinned"' $SQL_D)"
  check "nodeSelector"      "example-node" "$(y '.spec.template.spec.nodeSelector."kubernetes.io/hostname"' $SQL_D)"

  echo "== the root credential is a REFERENCE, under the variable the engine itself names =="
  check "secretKeyRef name" "example-mysql-root" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "MARIADB_ROOT_PASSWORD") | .valueFrom.secretKeyRef.name' $SQL_D)"
  check "secretKeyRef key"  "rootPassword" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "MARIADB_ROOT_PASSWORD") | .valueFrom.secretKeyRef.key' $SQL_D)"
  check "no literal value"  "null" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "MARIADB_ROOT_PASSWORD") | .value' $SQL_D)"
  absent "a rendered Secret object" "$manifests/example-mysql/Secret-example-mysql-root.yaml"

  echo "== the engine's own correctness environment is there, and is not sizing =="
  check "root host" "%" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "MARIADB_ROOT_HOST") | .value' $SQL_D)"
  check "no resource sizing invented for it" "null" \
    "$(y '.spec.template.spec.containers[0].resources' $SQL_D)"

  echo "== the probe watches the port the catalogue calls primary, with the engine's own timing =="
  check "probe is a TCP connect" "3306" "$(y '.spec.template.spec.containers[0].readinessProbe.tcpSocket.port' $SQL_D)"
  check "cold-start delay"       "15"   "$(y '.spec.template.spec.containers[0].readinessProbe.initialDelaySeconds' $SQL_D)"
  check "no liveness probe was synthesized" "null" "$(y '.spec.template.spec.containers[0].livenessProbe' $SQL_D)"

  echo "== an engine whose wire protocol is not its own product: three ports, three directories =="
  check "http port"     "2480" "$(y '.spec.ports[] | select(.name == "http")     | .port' $MM_S)"
  check "postgres port" "5432" "$(y '.spec.ports[] | select(.name == "postgres") | .port' $MM_S)"
  check "binary port"   "2424" "$(y '.spec.ports[] | select(.name == "binary")   | .port' $MM_S)"
  check "data directory"   "/arcade_db" \
    "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "data")   | .mountPath' $MM_D)"
  check "config directory" "/home/arcadedb/config" \
    "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "config") | .mountPath' $MM_D)"
  check "backup directory" "/arcade_backup" \
    "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "backup") | .mountPath' $MM_D)"
  check "a directory the engine merely writes into may be created" "DirectoryOrCreate" \
    "$(y '.spec.template.spec.volumes[] | select(.name == "backup") | .hostPath.type' $MM_D)"

  echo "== THE LADDER: two majors of one engine, two objects, one namespace =="
  present "older rung" "$PG_OLD"
  present "newer rung" "$PG_NEW"
  check "older kind"       "Cluster" "$(y '.kind' $PG_OLD)"
  check "newer kind"       "Cluster" "$(y '.kind' $PG_NEW)"
  check "older namespace"  "example-dbs" "$(y '.metadata.namespace' $PG_OLD)"
  check "newer namespace"  "example-dbs" "$(y '.metadata.namespace' $PG_NEW)"
  check "they are different objects" "example-pg-newer" "$(y '.metadata.name' $PG_NEW)"
  # Neither rung renders a Deployment or a Service: the operator creates those from the resource.
  # This is the reason a managed instance cannot go through the app grammar at all.
  absent "older rung Deployment" "$manifests/example-pg-older/Deployment-example-pg-older.yaml"
  absent "newer rung Deployment" "$manifests/example-pg-newer/Deployment-example-pg-newer.yaml"
  absent "older rung Service"    "$manifests/example-pg-older/Service-example-pg-older.yaml"

  echo "== a custom resource cannot be applied client-side: server-side apply and diff, on both =="
  check "older: SSA" "ServerSideApply=true" "$(y '.spec.syncPolicy.syncOptions[0]' $PG_OLD_A)"
  check "older: SSD" "ServerSideDiff=true"  "$(y '.metadata.annotations."argocd.argoproj.io/compare-options"' $PG_OLD_A)"
  check "newer: SSA" "ServerSideApply=true" "$(y '.spec.syncPolicy.syncOptions[0]' $PG_NEW_A)"
  check "newer: SSD" "ServerSideDiff=true"  "$(y '.metadata.annotations."argocd.argoproj.io/compare-options"' $PG_NEW_A)"
  check "and NOT on an ordinary rendered engine" "null" "$(y '.spec.syncPolicy.syncOptions' $SQL_A)"
  check "nor its compare options"                "null" "$(y '.metadata.annotations' $SQL_A)"

  echo "== ADOPTION: a grammar-rendered engine taking over an object the cluster already runs =="
  # The other route to the same two settings, and the one that is a DECISION rather than a physical
  # limit: this engine is rendered in full by the app grammar, and the declaration says the cluster
  # already has one. Client-side apply would diff a spec it did not render against a live object,
  # and this engine's state forces `Recreate` -- so that diff is downtime rather than a rollout.
  check "adopting: SSA" "ServerSideApply=true" "$(y '.spec.syncPolicy.syncOptions[0]' $MM_A)"
  check "adopting: SSD" "ServerSideDiff=true"  "$(y '.metadata.annotations."argocd.argoproj.io/compare-options"' $MM_A)"
  # And the workloads that did NOT ask reach neither, on either kind the grammar renders -- an
  # engine ($SQL_A, above) and a tool. A term that leaked onto its neighbours would put a
  # server-side diff on every Application in the tier and nothing would ever say so.
  check "a tool that adopts nothing: no sync options" "null" "$(y '.spec.syncPolicy.syncOptions' $BR_A)"
  check "a tool that adopts nothing: no compare options" "null" \
    "$(y '.metadata.annotations."argocd.argoproj.io/compare-options"' $BR_A)"

  echo "== the operator's own chart output passes through verbatim =="
  present "operator Deployment"     "$OP_D"
  present "operator ServiceAccount" "$OP_SA"
  check "verbatim content untouched" "example-pg-operator" "$(y '.spec.template.spec.serviceAccountName' $OP_D)"

  echo "== the namespace anchor is a grammar-rendered workload, so it cannot be cascade-deleted =="
  present "engine namespace"  "$SQL_NS"
  present "browser namespace" "$BR_NS"
  check "engine ns Prune=false"  "Prune=false" "$(y '.metadata.annotations."argocd.argoproj.io/sync-options"' $SQL_NS)"
  check "browser ns Prune=false" "Prune=false" "$(y '.metadata.annotations."argocd.argoproj.io/sync-options"' $BR_NS)"
  # Nothing rendered below the grammar creates a namespace -- refused at eval, absent here.
  absent "operator-created namespace" "$manifests/example-pg-operator/Namespace-example-dbs.yaml"
  absent "rung-created namespace"     "$manifests/example-pg-older/Namespace-example-dbs.yaml"

  echo "== tier tooling: its own namespace, a class rather than an address, a Secret by name =="
  check "browser exposure class" "nb" "$(y '.metadata.labels."nixk3s.dev/exposure"' $BR_D)"
  check "browser namespace"      "example-browser" "$(y '.metadata.namespace' $BR_D)"
  check "connections by reference" "example-browser-connections" \
    "$(y '.spec.template.spec.containers[0].envFrom[0].secretRef.name' $BR_D)"
  check "digest-pinned image" \
    "registry.example.com/example-org/example-browser:0.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000" \
    "$(y '.spec.template.spec.containers[0].image' $BR_D)"
  check "patient first-boot budget" "30" "$(y '.spec.template.spec.containers[0].readinessProbe.failureThreshold' $BR_D)"

  echo "== a probe's SHAPE is the catalogue's and its BUDGET is the declaration's =="
  # The visualiser is the one entry that earns a liveness probe -- it serves static files, so the
  # index answering is the whole health question and there is no third state to misread.
  check "liveness is an HTTP GET, not a TCP connect" "/" \
    "$(y '.spec.template.spec.containers[0].livenessProbe.httpGet.path' $SCH_D)"
  check "liveness watches the primary port" "80" \
    "$(y '.spec.template.spec.containers[0].livenessProbe.httpGet.port' $SCH_D)"
  check "liveness keeps the catalogue's own timing" "15" \
    "$(y '.spec.template.spec.containers[0].livenessProbe.periodSeconds' $SCH_D)"
  check "liveness keeps the catalogue's own budget"  "6" \
    "$(y '.spec.template.spec.containers[0].livenessProbe.failureThreshold' $SCH_D)"
  # The declaration overrode ONE number. Everything else about the probe is still the catalogue's,
  # which is the whole claim of the split: a budget cannot become a different question.
  check "the declaration's budget reaches the readiness probe" "36" \
    "$(y '.spec.template.spec.containers[0].readinessProbe.failureThreshold' $SCH_D)"
  check "and the untouched fields are still the catalogue's" "5" \
    "$(y '.spec.template.spec.containers[0].readinessProbe.periodSeconds' $SCH_D)"
  check "including what the probe ASKS" "/" \
    "$(y '.spec.template.spec.containers[0].readinessProbe.httpGet.path' $SCH_D)"
  # And the software the catalogue gives no liveness probe gets none -- never synthesized.
  check "no liveness probe on the browser" "null" \
    "$(y '.spec.template.spec.containers[0].livenessProbe' $BR_D)"

  echo "== idled to zero: the class and the front reach the objects, the replica count leaves =="
  check "scaling class"  "scale-to-zero" "$(y '.metadata.labels."nixk3s.dev/scaling"' $SCH_D)"
  check "wake front"     "keda"          "$(y '.metadata.labels."nixk3s.dev/wake"' $SCH_D)"
  # A sleeping app's replica count belongs to its wake front: rendering one makes every sync fight
  # the autoscaler over it, which is why the Application ignores that field too.
  check "no replica count is rendered" "null" "$(y '.spec.replicas' $SCH_D)"
  check "and the delivery tool is told to ignore it" "/spec/replicas" \
    "$(y '.spec.ignoreDifferences[0].jsonPointers[0]' $SCH_A)"
  # The workload beside it made the other choice, and nothing about scaling reached it.
  check "the browser is always on"       "always" "$(y '.metadata.labels."nixk3s.dev/scaling"' $BR_D)"
  check "so it names no wake front"      "null"   "$(y '.metadata.labels."nixk3s.dev/wake"' $BR_D)"
  check "and keeps its own replica count" "1"     "$(y '.spec.replicas' $BR_D)"
  check "with nothing ignored"           "null"   "$(y '.spec.ignoreDifferences' $BR_A)"

  echo "== an ENGINE is never idled: no scaling class but the default reaches any of them =="
  for d in "$SQL_D" "$MM_D"; do
    check "$(basename $d): always on" "always" "$(y '.metadata.labels."nixk3s.dev/scaling"' $d)"
    check "$(basename $d): no wake front" "null" "$(y '.metadata.labels."nixk3s.dev/wake"' $d)"
  done

  echo "== NO FLEET ADDRESS REACHES ANY OBJECT: a class is a label, never a number =="
  for svc in "$SQL_S" "$MM_S" "$BR_S"; do
    check "$(basename $svc): type"          "ClusterIP" "$(y '.spec.type' $svc)"
    check "$(basename $svc): no pinned IP"  "null"      "$(y '.spec.clusterIP' $svc)"
    check "$(basename $svc): no LB address" "null"      "$(y '.spec.loadBalancerIP' $svc)"
    check "$(basename $svc): no externalIPs" "null"     "$(y '.spec.externalIPs' $svc)"
    check "$(basename $svc): no nodePort"   "null"      "$(y '.spec.ports[0].nodePort' $svc)"
  done

  echo "== every Application lands in the tier's project, at the workload's own destination =="
  for app in example-mysql example-multimodel example-browser example-schema example-pg-older example-pg-newer example-pg-operator; do
    check "$app project" "example-data" "$(y '.spec.project' $manifests/apps/Application-$app.yaml)"
  done
  check "browser destination" "example-browser" "$(y '.spec.destination.namespace' $manifests/apps/Application-example-browser.yaml)"
  check "schema destination"  "example-schema"  "$(y '.spec.destination.namespace' $manifests/apps/Application-example-schema.yaml)"
  check "engine destination"  "example-dbs"     "$(y '.spec.destination.namespace' $SQL_A)"

  echo "== the render split is countable, and the untyped side is the smaller one =="
  check "rendered by the grammar" "example-browser example-multimodel example-mysql example-schema" "$byGrammar"
  check "rendered below it"       "example-pg-newer example-pg-older example-pg-operator" "$directly"

  if [ "$fail" -ne 0 ]; then
    echo "rendered output does not match the tier's promises" >&2
    exit 1
  fi
  echo "all render assertions hold"
  cp -r $manifests $out
''

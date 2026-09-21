#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# THE VERIFICATION CONTRACT every name in lib/clients.nix has met, runnable. Point it at the
# catalogue and it answers every question that matters before a name reaches a host -- which is why
# adding an entry is a one-line change rather than a research project.
#
# Run it by hand after touching the catalogue. Repository membership and attribute liveness are
# facts about the world: they change without this repository changing, and no eval-time check can
# see either (which is exactly the line checks/clients-eval.nix's own header draws around itself).
#
# FOUR SOURCES, AND NONE OF THEM IS REDUNDANT:
#
#   1. archlinux.org's package search API  -- upstream Arch, the ONLY authority for `aur = false`.
#      `pacman -Si` is not: on an Arch derivative it also resolves that derivative's own
#      repositories, so a name can pass it cleanly and be in no upstream Arch repository at all --
#      which would make `aur = false` correct on the machine running this script and a
#      whole-transaction abort on a plain Arch box ("target not found" fails `pacman -S`
#      ATOMICALLY and takes every unrelated package in the same converge with it).
#   2. the AUR RPC                         -- the authority for `aur = true`.
#   3. the nixpkgs attribute, FORCED       -- `builtins.seq p.drvPath`, never `hasAttrByPath`.
#      nixpkgs implements a rename as `<old> = throw "...";`, which keeps the key present and only
#      fails when the value is demanded. This catalogue found two such attributes in one sitting --
#      see ../studies/mariadb-client-and-mysql-client-both-throw.md.
#   4. `pacman -Si`, if pacman is present  -- informational: what THIS host resolves.
#
# AN ENTRY MAY CARRY `nixpkgs = null`, meaning no derivation exists at all. Those are listed rather
# than checked, and listing them is the point: a null that quietly became checkable (somebody
# packaged the tool) is a catalogue improvement waiting to be made, and a null that was never
# verified in the first place is a guess. Either way the reader sees the name.
#
# Plus the two cross-checks that a name existing on both platforms cannot pass on its own: the
# homepage against pacman's URL (a pair pointing at two different projects), and -- with
# `--surface` -- the actual contents of `bin/`, because two names for one project at one version
# can still install different commands. The Postgres entry is the reason that check exists; see
# ../studies/psql-is-in-postgresql-libs-not-postgresql.md.
#
# NAMES ARE READ OUT OF lib/clients.nix, never hand-maintained in this file -- a duplicated list
# goes stale in both directions, silently skipping entries that were added and still "verifying"
# entries that were removed.
#
# Usage: ./experiments/verify-package-names.sh [--surface]
#   --surface   additionally realize each nixpkgs attribute and list its bin/ directory. Downloads
#               from the binary cache, so it is opt-in rather than the default.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

surface=0
[[ "${1:-}" == "--surface" ]] && surface=1

# Pure builtins on purpose: this only reads an attrset of strings, so it must work on a host with
# no <nixpkgs> channel at all.
catalogue_field() {
  local filter="$1" field="$2"
  nix-instantiate --eval --strict --expr "
    let
      cat = import ./lib/clients.nix { };
      entries = builtins.concatLists (map builtins.attrValues (builtins.attrValues cat));
      want = builtins.filter (t: ${filter}) entries;
    in builtins.concatStringsSep \" \" (map (t: t.${field}) want)
  " | sed 's/^\"//; s/\"$//'
}

read -r -a official_names <<<"$(catalogue_field '!(t.aur or false)' 'arch')"
read -r -a aur_names      <<<"$(catalogue_field '(t.aur or false)'  'arch')"
read -r -a nixpkgs_attrs  <<<"$(catalogue_field 't.nixpkgs != null' 'nixpkgs')"
read -r -a nixpkgs_none   <<<"$(catalogue_field 't.nixpkgs == null' 'arch')"

status=0

echo "== Upstream Arch official repos (archlinux.org package search) -- ${#official_names[@]} name(s) =="
echo "   These carry aur = false, so they MUST exist here or a plain Arch host's pacman transaction aborts."
for pkg in "${official_names[@]}"; do
  json="$(curl -sf "https://archlinux.org/packages/search/json/?name=$pkg" || echo '{"results":[]}')"
  if [[ "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["results"]))' <<<"$json")" -gt 0 ]]; then
    echo "OK   $pkg -- $(python3 -c 'import json,sys; r=json.load(sys.stdin)["results"][0]; print(r["repo"], r["pkgver"]+"-"+str(r["pkgrel"]), r["url"])' <<<"$json")"
  else
    echo "FAIL $pkg -- NOT in any upstream Arch repository. lib/clients.nix must mark it aur = true."
    status=1
  fi
done

echo
echo "== The AUR (aur.archlinux.org RPC v5) -- ${#aur_names[@]} name(s) =="
echo "   These carry aur = true, the safe floor. If a name is ALSO carried by some Arch derivative's"
echo "   own repository, that lift belongs in an archRepoOn field the catalogue does not have yet."
for pkg in "${aur_names[@]}"; do
  json="$(curl -sf "https://aur.archlinux.org/rpc/v5/info?arg[]=$pkg" || echo '{"resultcount":0}')"
  if [[ "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["resultcount"])' <<<"$json")" -gt 0 ]]; then
    echo "OK   $pkg (AUR) -- $(python3 -c 'import json,sys; r=json.load(sys.stdin)["results"][0]; print(r["Version"], "votes="+str(r["NumVotes"]), r.get("URL",""))' <<<"$json")"
  else
    echo "FAIL $pkg -- not in the AUR either. The name in lib/clients.nix is wrong."
    status=1
  fi
done

echo
echo "== nixpkgs attributes, FORCED (never hasAttrByPath) -- ${#nixpkgs_attrs[@]} attribute(s) =="
echo "   A renamed attribute stays present and throws only when its value is demanded."
for attr in "${nixpkgs_attrs[@]}"; do
  out="$(nix eval --raw --impure --expr "
    let
      pkgs = (builtins.getFlake \"nixpkgs\").legacyPackages.\${builtins.currentSystem};
      p = pkgs.$attr;
    in builtins.seq p.drvPath \"\${p.name} | \${p.meta.homepage or \"-\"}\"
  " 2>&1 | tail -1)" || true
  if [[ "$out" == *"|"* ]]; then
    echo "OK   $attr -- $out"
  else
    echo "FAIL $attr -- does not force: $out"
    echo "     Most likely a nixpkgs rename-to-throw. See studies/mariadb-client-and-mysql-client-both-throw.md."
    status=1
  fi
done

if [[ ${#nixpkgs_none[@]} -gt 0 ]]; then
  echo
  echo "== Catalogued as having NO nixpkgs derivation (nixpkgs = null) -- ${#nixpkgs_none[@]} entry(ies) =="
  echo "   Not a failure: modules/nixos.nix warns and skips these. If one of them IS packaged now,"
  echo "   the catalogue should say so -- check by hand before assuming the null is still true."
  for pkg in "${nixpkgs_none[@]}"; do
    echo "     $pkg (pacman name) -- no nixpkgs attribute claimed"
  done
fi

if [[ $surface -eq 1 ]]; then
  echo
  echo "== Command surface: what actually lands in bin/ =="
  echo "   Existence, project identity and command surface are three separate questions."
  for attr in "${nixpkgs_attrs[@]}"; do
    if path="$(nix build --no-link --print-out-paths --impure --expr "
      let pkgs = (builtins.getFlake \"nixpkgs\").legacyPackages.\${builtins.currentSystem}; in pkgs.$attr
    " 2>/dev/null | head -1)"; then
      if [[ -d "$path/bin" ]]; then
        echo "     $attr -> $(ls "$path/bin" | tr '\n' ' ')"
      else
        echo "     $attr -> NO bin/ DIRECTORY (a library, not a client -- see the psql study)"
      fi
    else
      echo "     $attr -> could not be realized"
    fi
  done
fi

echo
if command -v pacman >/dev/null 2>&1; then
  echo "== What THIS host resolves (pacman -Si) -- informational, never the authority for \`aur\` =="
  for pkg in "${official_names[@]}" "${aur_names[@]}"; do
    if line="$(pacman -Si "$pkg" 2>/dev/null | sed -n 's/^Repository *: *//p' | head -1)" && [[ -n "$line" ]]; then
      url="$(pacman -Si "$pkg" 2>/dev/null | sed -n 's/^URL *: *//p' | head -1)"
      echo "     $pkg -> $line   $url"
    else
      echo "     $pkg -> (no repository on this host; expected for an AUR name here)"
    fi
  done
else
  echo "== pacman not present -- skipping the host-local view (the authorities above already ran) =="
fi

echo
if [[ $status -eq 0 ]]; then
  echo "All names verified: upstream Arch, the AUR, and a forced nixpkgs attribute."
else
  echo "One or more names failed verification -- see FAIL lines above." >&2
  exit 1
fi

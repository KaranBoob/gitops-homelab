#!/usr/bin/env bash
# Render everything Argo CD would sync, without a cluster.
# Needs kustomize and helm. Runs kubeconform when it is installed.
# Dirs with a KSOPS generator build only when ksops and SOPS_AGE_KEY_FILE exist.
set -euo pipefail
cd "$(dirname "$0")/.."

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
fail=0

echo "== secrets"
for f in $(grep -rl --include='*.yaml' '^kind: Secret' .); do
  if ! grep -q '^sops:' "$f"; then
    echo "FAIL plaintext Secret: $f"
    fail=1
  fi
done

echo "== kustomize"
for k in $(find . -name kustomization.yaml -not -path './.git/*' | sort); do
  d=$(dirname "$k")
  grep -q '^kind: Component' "$k" && continue
  if grep -q ksops-generator "$k"; then
    if command -v ksops >/dev/null && [ -n "${SOPS_AGE_KEY_FILE:-}" ]; then
      # Decrypted output goes nowhere.
      if kustomize build --enable-alpha-plugins --enable-exec "$d" >/dev/null; then echo "ok   $d"; else echo "FAIL $d"; fail=1; fi
    else
      echo "skip $d (needs ksops and SOPS_AGE_KEY_FILE)"
    fi
    continue
  fi
  name=$(echo "${d#./}" | tr / _)
  if kustomize build "$d" >"$out/k_$name.yaml"; then echo "ok   $d"; else echo "FAIL $d"; fail=1; fi
done

echo "== helm"
# One line per element of the list in infrastructure-helm.yaml.
while read -r name ns repo chart version release values; do
  case $repo in
    http*) src=(--repo "$repo" "$chart") ;;
    *) src=("oci://$repo/$chart") ;;
  esac
  if helm template "$release" "${src[@]}" --version "$version" -n "$ns" -f "$values" \
    >"$out/h_$name.yaml" 2>"$out/h_$name.err"; then
    echo "ok   $name $version"
  else
    echo "FAIL $name $version"
    cat "$out/h_$name.err"
    fail=1
  fi
done < <(awk '
  /^ *- name:/   { n = $3 }
  /^ *namespace:/ { ns = $2 }
  /^ *repoURL:/  { r = $2 }
  /^ *chart:/    { c = $2 }
  /^ *version:/  { v = $2 }
  /^ *release:/  { rel = $2 }
  /^ *values:/   { print n, ns, r, c, v, rel, $2 }
' clusters/homelab/infrastructure-helm.yaml | tr -d '"')

if command -v kubeconform >/dev/null; then
  echo "== kubeconform"
  kubeconform -strict -summary -ignore-missing-schemas \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    "$out"/*.yaml || fail=1
else
  echo "skip kubeconform (not installed)"
fi

exit $fail

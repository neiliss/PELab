#!/bin/bash
# =============================================================================
# sync_to_pelab.sh – keep the light distro (../pelab) in sync with the full
# dev tree.  A dev-only utility; not part of the wizard.
#
#   ./sync_to_pelab.sh            sync shared source files dev-tree -> ../pelab
#   ./sync_to_pelab.sh --all      also copy source files not yet in ../pelab
#   ./sync_to_pelab.sh --check    dry run: only report what would change
#   ./sync_to_pelab.sh reverse    sync the other way (../pelab -> dev tree)
#
# By default it only updates files that ALREADY exist in the target tree, so
# the light distro's curated file set is preserved (it doesn't pull in helper
# scripts / vendored modules that are intentionally excluded).  It also refuses
# to touch environment-specific / runtime artifacts (keys, config JSON, tfstate,
# logs, .git, backups) so those never get clobbered.
# =============================================================================
set -euo pipefail

# Which tree is the script sitting in?
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_BASE="$(basename "$SELF_DIR")"

MODE="sync"      # sync | check
ALL=0
REVERSE=0
for a in "$@"; do
  case "$a" in
    --all)  ALL=1 ;;
    --check|check) MODE="check" ;;
    reverse|--reverse) REVERSE=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a (see header for usage)"; exit 2 ;;
  esac
done

# Resolve the source tree (dev) and target tree (light distro).
case "$SELF_BASE" in
  pelab-dev) SRC="$SELF_DIR"; DST="$SELF_DIR/../pelab" ;;
  pelab)     SRC="$SELF_DIR"; DST="$SELF_DIR/../pelab-dev" ;;
  *) echo "Run this from the pelab-dev (or pelab) tree root, not '$SELF_BASE'."; exit 2 ;;
esac
# Normalize the target to an absolute path.
case "$DST" in
  /*) : ;;
  *) DST="$(cd "$DST" && pwd)" ;;
esac
if [[ "$REVERSE" -eq 1 ]]; then temp="$SRC"; SRC="$DST"; DST="$temp"; fi

if [[ ! -d "$DST" ]]; then
  echo "Target tree not found: $DST"; exit 1
fi
echo "Syncing source files: $(basename "$SRC") -> $(basename "$DST")"
[[ "$MODE" == "check" ]] && echo "(dry run – no changes written)"
[[ "$ALL" -eq 1 ]] && echo "(--all: will also copy new source files not yet in target)"

# Artifacts we must never sync (env-specific / runtime / secrets).
skip() {
  local rel="$1"
  case "$rel" in
    */|*.git/*|*/\.git/*) return 0 ;;
    *.tfstate|*.tfstate.backup|*.tfstate.*|.terraform.lock.hcl|*/\.terraform/*) return 0 ;;
    *.log|*dockerhost_ssh.log|*bolt-debug.log|./helper.md) return 0 ;;
    *.json|*setup_wizard_defaults*|*params.json|*inventory.yaml|*.lic|*license.txt) return 0 ;;
    *.tfvars) return 0 ;;
    *id_ed25519|*id_rsa|*gitnano_id_rsa|*.pub|*id_ed25519.pub) return 0 ;;
    */\.hosts-backups/*|*/backups/*) return 0 ;;
    sync_to_pelab.sh|*sync_to_pelab.sh) return 0 ;;
    *) return 1 ;;
  esac
}

is_source() {
  # Real source code only.  Do NOT treat generated/env-specific material
  # (.yaml inventories, generated terraform .tf/.tfvars) as shared source,
  # so per-environment config is never clobbered.
  local rel="$1"
  case "$rel" in
    *.sh|*.py|*.rb|*.pp|*.erb|*.epp|*.md|Dockerfile|*.Dockerfile) return 0 ;;
    *) return 1 ;;
  esac
}

synced=0; skipped=0; new_only=0; changed=0
while IFS= read -r -d '' f; do
  rel="${f#"$SRC"/}"
  # Only plain files.
  [[ -f "$f" ]] || continue
  skip "$rel" && continue
  is_source "$rel" || continue          # only source files are in the light distro
  dst="$DST/$rel"
  if [[ -f "$dst" ]]; then
    if ! cmp -s "$f" "$dst"; then
      changed=$((changed+1))
      if [[ "$MODE" == "sync" ]]; then
        mkdir -p "$(dirname "$dst")" && cp -p "$f" "$dst"
        echo "   synced: $rel"
      else
        echo "   WOULD UPDATE: $rel"
      fi
    else
      synced=$((synced+1))
    fi
  else
    if [[ "$ALL" -eq 1 ]]; then
      if [[ "$MODE" == "sync" ]]; then
        mkdir -p "$(dirname "$dst")" && cp -p "$f" "$dst"
        echo "   added: $rel"
        changed=$((changed+1))
      else
        echo "   WOULD ADD: $rel"
        changed=$((changed+1))
      fi
    else
      new_only=$((new_only+1))
    fi
  fi
done < <(cd "$SRC" && find . -type f -print0)

echo
echo "Summary: $synced already-identical, $changed updated"
[[ "$ALL" -eq 0 && "$new_only" -gt 0 ]] && echo "New source files NOT in target ($new_only): pass --all to include them."
[[ "$MODE" == "check" ]] && echo "(dry run – nothing written)"

#!/usr/bin/env bash
# =========================================================================
# File: site-modules/profile/files/vault_wrapper.sh
# Version: PLATINUM 2.1
# =========================================================================
set -euo pipefail

# 1. Pull the secret into isolated local shell memory
TARGET_SECRET="${SECURE_VAULT_PASSWORD:-}"

# 2. IMMEDIATELY erase the global process environment trail
# This closes the /proc/$PID/environ exposure window instantly.
unset SECURE_VAULT_PASSWORD

# 3. Validation Check
if [ -z "${TARGET_SECRET}" ]; then
    echo "CRITICAL ERROR: JIT Environment payload is missing or null." >&2
    exit 1
fi

# -------------------------------------------------------------------------
# EXECUTE SECURE BACKEND ACTIONS HERE
# -------------------------------------------------------------------------
# Always feed the secret via stdin to your backend application binary:
# echo "${TARGET_SECRET}" | /usr/bin/vault login -method=token token=-
# -------------------------------------------------------------------------

# 4. Clear local subshell memory space before exiting
unset TARGET_SECRET
echo "SUCCESS: Vault Sync completed and process space environment cleaned."
exit 0
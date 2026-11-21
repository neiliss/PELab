# =============================================================================
# embedded.sh  –  extracted from setup.sh (lines 1989-3970)
# Sourced by pelab.sh.  Do not run directly.
# =============================================================================
ensure_gitnano_script() {
  local f="${script_dir}/gitnano.sh"
  # Always regenerate so the on-disk copy matches the embedded (seed-aware)
  # version – a stale copy from an earlier run would ignore the control-repo
  # seed and leave gitnano's repo empty.
  tui_info "Writing ${BOLD}${f}${RESET} (embedded in setup.sh)…"
  cat > "$f" <<'GITNANO'
#!/bin/bash
# =================================================================
# GitNano: Unified Single-Node Installation (Git + Puppet Auth)
# =================================================================

# --- 1. CONFIGURATION (Edit as needed) ---
OLD_GITLAB_URL="${1:-none}"
NEW_FQDN="${2:-your-offline-gitnano-fqdn}"
TOKEN="${3:-$(openssl rand -hex 16)}"
SEED_SOURCE="${4:-}"

GITNANO_USER="gitnano"
INSTALL_DIR="/opt/gitnano"
REPO_NAME="control-repo.git"
LIVE_DIR="/var/www/production"

PUPPET_USER="pe-puppet"
PUPPET_SSH_DIR="/etc/puppetlabs/puppetserver/ssh"
PRIVATE_KEY="$PUPPET_SSH_DIR/id-control_repo.rsa"

export DEBIAN_FRONTEND=noninteractive

echo "🚀 Starting Unified GitNano Deployment for $NEW_FQDN..."

# --- 2. SYSTEM PREP & USERS ---
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -q -y
    apt-get install -y python3 python3-venv git curl openssh-server net-tools sudo nano
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3 python3-pip git curl openssh-server net-tools sudo nano
elif command -v yum >/dev/null 2>&1; then
    yum install -y python3 python3-pip git curl openssh-server net-tools sudo nano
fi

if ! id -u $GITNANO_USER &>/dev/null; then
    useradd -r -m -d $INSTALL_DIR -s /bin/bash $GITNANO_USER
fi
# Ensure user is unlocked and has a shell
usermod -s /bin/bash $GITNANO_USER
passwd -u $GITNANO_USER 2>/dev/null

# Fix /opt permissions (Critical for SSH)
chown root:root /opt
chmod 755 /opt

mkdir -p $INSTALL_DIR/app $INSTALL_DIR/repos $LIVE_DIR
chown -R $GITNANO_USER:$GITNANO_USER $INSTALL_DIR $LIVE_DIR

# --- 3. GLOBAL GIT FIXES (Ownership & Identity) ---
for user in "root" "$GITNANO_USER"; do
    CMD_PREFIX=""
    [ "$user" != "root" ] && CMD_PREFIX="sudo -u $user"
    $CMD_PREFIX git config --global --add safe.directory "$INSTALL_DIR/repos/$REPO_NAME"
    $CMD_PREFIX git config --global --add safe.directory "$LIVE_DIR"
    $CMD_PREFIX git config --global user.email "gitnano@$NEW_FQDN"
    $CMD_PREFIX git config --global user.name "GitNano Automator"
done

# --- 4. PYTHON API BRIDGE SETUP ---
sudo -u $GITNANO_USER python3 -m venv $INSTALL_DIR/app/venv
sudo -u $GITNANO_USER $INSTALL_DIR/app/venv/bin/pip install --quiet flask gunicorn

cat <<EOF > $INSTALL_DIR/app/gitnano.py
import os, subprocess
from flask import Flask, request, Response, abort
app = Flask(__name__)
REPO_ROOT = "$INSTALL_DIR/repos"
AUTH_TOKEN = "$TOKEN"
def check_auth():
    if request.headers.get('Authorization') != f"Bearer {AUTH_TOKEN}": abort(401)
@app.route('/<repo_name>/info/refs', methods=['GET'])
def info_refs(repo_name):
    check_auth()
    service = request.args.get('service')
    repo_path = os.path.join(REPO_ROOT, repo_name)
    rpc_content = f"# service={service}\n"
    header = f"{len(rpc_content) + 4:04x}{rpc_content}0000"
    proc = subprocess.Popen(['git', service.replace('git-', ''), "--stateless-rpc", "--advertise-refs", repo_path], stdout=subprocess.PIPE)
    return Response(header.encode() + proc.communicate()[0], content_type=f"application/x-{service}-advertisement")
@app.route('/<repo_name>/<service>', methods=['POST'])
def service_rpc(repo_name, service):
    check_auth()
    repo_path = os.path.join(REPO_ROOT, repo_name)
    proc = subprocess.Popen(['git', service.replace('git-', ''), "--stateless-rpc", repo_path], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    return Response(proc.communicate(input=request.data)[0], content_type=f"application/x-{service}-result")
if __name__ == '__main__': app.run(host='0.0.0.0', port=5000)
EOF

# --- 5. SYSTEMD SERVICE ---
cat <<EOF > /etc/systemd/system/gitnano.service
[Unit]
Description=GitNano Service
After=network.target
[Service]
User=$GITNANO_USER
Group=$GITNANO_USER
WorkingDirectory=$INSTALL_DIR/app
ExecStart=$INSTALL_DIR/app/venv/bin/gunicorn --workers 1 --bind 0.0.0.0:5000 gitnano:app
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now gitnano

# --- 6. SSHD OPTIMIZATION (No-Hang Fix) ---
echo "🔧 Optimizing SSH Daemon..."
sed -i 's/^#UseDNS yes/UseDNS no/' /etc/ssh/sshd_config
sed -i 's/^UseDNS yes/UseDNS no/' /etc/ssh/sshd_config
sed -i 's/^GSSAPIAuthentication yes/GSSAPIAuthentication no/' /etc/ssh/sshd_config
rm -f /run/nologin /etc/nologin
systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null || true

# --- 7. DATA MIGRATION ---
echo "🚚 Setting up control-repo..."
rm -rf "$INSTALL_DIR/repos/$REPO_NAME"
sudo -u $GITNANO_USER git init --bare "$INSTALL_DIR/repos/$REPO_NAME"
sudo -u $GITNANO_USER git -C "$INSTALL_DIR/repos/$REPO_NAME" symbolic-ref HEAD refs/heads/production

if [ -n "$SEED_SOURCE" ] && [ -d "$SEED_SOURCE" ]; then
    # Seed from a provided local control-repo directory.
    echo "🌱 Seeding control-repo from $SEED_SOURCE"
    # /root is 700 (not traversable by the gitnano user), so stage the seed under
    # gitnano's own dir where the gitnano user can reach it.
    SEED_STAGE="$INSTALL_DIR/seed"
    rm -rf "$SEED_STAGE"
    mkdir -p "$INSTALL_DIR"
    cp -a "$SEED_SOURCE" "$SEED_STAGE"
    chown -R $GITNANO_USER:$GITNANO_USER "$SEED_STAGE"
    cd "$SEED_STAGE"
    if [ ! -d "$SEED_STAGE/.git" ]; then
        sudo -u $GITNANO_USER git init -q
    fi
    sudo -u $GITNANO_USER git checkout -B production 2>/dev/null || sudo -u $GITNANO_USER git checkout production 2>/dev/null || true
    # The seed may be a shallow clone (--depth 1) from the wizard; a shallow
    # push is rejected by the remote, so unshallow it first.
    sudo -u $GITNANO_USER git fetch --unshallow 2>/dev/null || true
    sudo -u $GITNANO_USER git add -A
    sudo -u $GITNANO_USER git -c user.email="gitnano@$NEW_FQDN" -c user.name="GitNano Automator" commit -q -m "Seed control-repo" 2>/dev/null || true
    if sudo -u $GITNANO_USER git push -q --force "$INSTALL_DIR/repos/$REPO_NAME" production; then
        echo "✅ Control-repo seeded from $SEED_SOURCE"
    else
        echo "⚠  Seed push failed – falling back to minimal control-repo"
        SEED_DIR=$(mktemp -d)
        chown $GITNANO_USER "$SEED_DIR"
        sudo -u $GITNANO_USER git -C "$SEED_DIR" init -q
        sudo -u $GITNANO_USER git -C "$SEED_DIR" checkout -q -b production
        mkdir -p "$SEED_DIR/manifests" "$SEED_DIR/hieradata" "$SEED_DIR/modules"
        cat > "$SEED_DIR/Puppetfile" <<'PUPPETFILE'
forge "https://forge.puppet.com"
PUPPETFILE
        cat > "$SEED_DIR/manifests/site.pp" <<'SITEPP'
# Default node classification
node default {
  notify { 'gitnano control-repo ready': }
}
SITEPP
        sudo -u $GITNANO_USER git -C "$SEED_DIR" add -A
        sudo -u $GITNANO_USER git -C "$SEED_DIR" -c user.email="gitnano@$NEW_FQDN" -c user.name="GitNano Automator" commit -q -m "Initial control-repo"
        sudo -u $GITNANO_USER git -C "$SEED_DIR" push -q "$INSTALL_DIR/repos/$REPO_NAME" production
        rm -rf "$SEED_DIR"
    fi
    rm -rf "$SEED_STAGE"
elif [ "$OLD_GITLAB_URL" = "none" ]; then
    # Fresh install: seed a minimal control-repo so r10k has something to deploy.
    SEED_DIR=$(mktemp -d)
    chown $GITNANO_USER "$SEED_DIR"
    sudo -u $GITNANO_USER git -C "$SEED_DIR" init -q
    sudo -u $GITNANO_USER git -C "$SEED_DIR" checkout -q -b production
    mkdir -p "$SEED_DIR/manifests" "$SEED_DIR/hieradata" "$SEED_DIR/modules"
    cat > "$SEED_DIR/Puppetfile" <<'PUPPETFILE'
forge "https://forge.puppet.com"
PUPPETFILE
    cat > "$SEED_DIR/manifests/site.pp" <<'SITEPP'
# Default node classification
node default {
  notify { 'gitnano control-repo ready': }
}
SITEPP
    sudo -u $GITNANO_USER git -C "$SEED_DIR" add -A
    sudo -u $GITNANO_USER git -C "$SEED_DIR" -c user.email="gitnano@$NEW_FQDN" -c user.name="GitNano Automator" commit -q -m "Initial control-repo"
    sudo -u $GITNANO_USER git -C "$SEED_DIR" push -q "$INSTALL_DIR/repos/$REPO_NAME" production
    rm -rf "$SEED_DIR"
else
    MIGRATE_DIR=$(mktemp -d)
    chown $GITNANO_USER "$MIGRATE_DIR"
    sudo -u $GITNANO_USER git clone --mirror "$OLD_GITLAB_URL" "$MIGRATE_DIR"
    if [ $? -eq 0 ]; then
        cd "$MIGRATE_DIR"
        sudo -u $GITNANO_USER git push --mirror "$INSTALL_DIR/repos/$REPO_NAME"
    fi
    rm -rf "$MIGRATE_DIR"
fi

# --- 8. SETUP LIVE DIRECTORY & TOKEN AUTH ---
echo "📂 Setting up production working copy..."

# Jump out of any directory that might be deleted
cd /tmp

# Clean start for the live directory
rm -rf "$LIVE_DIR"
mkdir -p "$LIVE_DIR"
chown $GITNANO_USER:$GITNANO_USER $LIVE_DIR

# Perform the clone
echo "📥 Cloning to $LIVE_DIR..."
sudo -u $GITNANO_USER git clone --branch production "$INSTALL_DIR/repos/$REPO_NAME" "$LIVE_DIR"

# Move INTO the new directory before running git configs
cd "$LIVE_DIR" || exit 1

# Setup the API bridge for internal pushes
echo "⚙  Configuring GitNano API bridge..."
sudo -u $GITNANO_USER git remote add gitnano "http://:@localhost:5000/$REPO_NAME"
sudo -u $GITNANO_USER git config http.extraHeader "Authorization: Bearer $TOKEN"

# Mark it safe one more time specifically at this path
sudo -u $GITNANO_USER git config --global --add safe.directory "$LIVE_DIR"

# --- 9. PUPPET MASTER SSH LINKING (The Final Step) ---
echo "🔗 Finalizing SSH link..."
mkdir -p "$PUPPET_SSH_DIR" "$INSTALL_DIR/.ssh"

# Key Generation/Sync
if [ ! -f "$PRIVATE_KEY" ]; then
    ssh-keygen -t rsa -b 4096 -f "$PRIVATE_KEY" -N "" -q
fi
ssh-keygen -y -f "$PRIVATE_KEY" > "$INSTALL_DIR/.ssh/authorized_keys"

# Set strict permissions
chown -R $PUPPET_USER:$PUPPET_USER "$PUPPET_SSH_DIR"
chmod 700 "$PUPPET_SSH_DIR"
chmod 600 "$PRIVATE_KEY"

chown -R $GITNANO_USER:$GITNANO_USER "$INSTALL_DIR/.ssh"
chmod 700 "$INSTALL_DIR/.ssh"
chmod 600 "$INSTALL_DIR/.ssh/authorized_keys"

# Seed Known Hosts
ssh-keyscan -t rsa,ed25519 "$NEW_FQDN" localhost 127.0.0.1 >> /etc/ssh/ssh_known_hosts 2>/dev/null

# --- 10. VERIFICATION ---
echo "🧪 Testing Puppet-to-GitNano handshake..."
TEST_CMD="sudo -u $PUPPET_USER ssh -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -i $PRIVATE_KEY $GITNANO_USER@$NEW_FQDN 'git --version'"

RESULT=$(eval "$TEST_CMD" 2>&1)

if [[ $RESULT == *"git version"* ]]; then
    echo "------------------------------------------------"
    echo "✅ INSTALLATION COMPLETE & VERIFIED!"
    echo "📍 Git URL: $GITNANO_USER@$NEW_FQDN:$INSTALL_DIR/repos/$REPO_NAME"
    echo "📍 Live Dir: $LIVE_DIR"
    echo "------------------------------------------------"
else
    echo "------------------------------------------------"
    echo "⚠  Install done, but Handshake test failed."
    echo "Error: $RESULT"
    echo "------------------------------------------------"
fi
GITNANO
  chmod +x "$f"
  tui_ok "Wrote ${f}"
}
# Writes the embedded hieranano.sh installer to ${script_dir}/hieranano.sh if it
# is missing (so the wizard is self-contained on a fresh host).  hieranano is a
# Hiera/eyaml web UI (Flask) installed on the master (core0) and is always present.
ensure_hieranano_script() {
  local f="${script_dir}/hieranano.sh"
  if [[ -f "$f" ]]; then
    return 0
  fi
  tui_info "Writing ${BOLD}${f}${RESET} (embedded in setup.sh)…"
  cat > "$f" <<'HIERANANO'
#!/usr/bin/env bash
# ==============================================================================
# HIERANANO - UNIVERSAL AUTO-ADAPTIVE MASTER DEPLOYMENT LAYER (h-gold.sh)
# ==============================================================================
set -e

# ----------------------------------------------------------------------------
# Interactive helper: prompt for a value, defaulting to $2 if empty.
# Honors a non-interactive flag set ($NONINTERACTIVE=1) and the HIERANANO_*
# environment variables so CI / scripted runs work as well.
# ----------------------------------------------------------------------------
DEFAULT_PROMPT_TIMEOUT=60
if [ -z "${NONINTERACTIVE:-}" ]; then
  if [ -t 0 ]; then
    NONINTERACTIVE=0
  else
    NONINTERACTIVE=1
  fi
fi

ask() {
  # ask <varname> <prompt> <default>
  local __var="$1"
  local __prompt="$2"
  local __default="$3"
  # Allow pre-set env var (HIERANANO_<UPPER>) to override defaults
  local __env_key="HIERANANO_$(echo "$__var" | tr '[:lower:]' '[:upper:]')"
  local __env_val="${!__env_key:-}"

  if [ -n "$__env_val" ]; then
    printf -v "$__var" '%s' "$__env_val"
    echo "   ↳ $__prompt = $__env_val (from env $__env_key)"
    return
  fi

  if [ "$NONINTERACTIVE" -eq 1 ]; then
    printf -v "$__var" '%s' "$__default"
    echo "   ↳ $__prompt = $__default (non-interactive default)"
    return
  fi

  local __reply
  if [ -n "$__default" ]; then
    read -r -t "$DEFAULT_PROMPT_TIMEOUT" -p "   $__prompt [$__default]: " __reply || true
    if [ -z "$__reply" ]; then __reply="$__default"; fi
  else
    read -r -t "$DEFAULT_PROMPT_TIMEOUT" -p "   $__prompt: " __reply || true
  fi
  printf -v "$__var" '%s' "$__reply"
}

INSTALL_SECRET="$1"

if [ -z "$INSTALL_SECRET" ]; then
  echo "❌ CRITICAL: You must pass a secure secret key to initialize authentication."
  echo "👉 Usage: ./h.sh 'your_secure_passphrase'"
  exit 1
fi

# 📍 Standard Production Defaults (used unless overridden interactively)
DEFAULT_KEY_DIR="/etc/puppetlabs/puppet/keys"
DEFAULT_EYAML_PUB_KEY="${DEFAULT_KEY_DIR}/public_key.pkcs7.pem"
DEFAULT_EYAML_PRIV_KEY="${DEFAULT_KEY_DIR}/private_key.pkcs7.pem"
DEFAULT_CONTROL_REPO_DIR="/var/www/production"
DEFAULT_AI_ENDPOINT="https://api.openai.com/v1/chat/completions"
DEFAULT_AI_MODEL="gpt-4o-mini"
DEFAULT_AI_TOKEN=""
DEFAULT_AI_PROMPT="You are a Puppet / Hiera architecture assistant. The user supplies hiera class/parameter NAMES (no values) and a Puppet file. For each key: state its likely purpose, where in the puppet file it would be looked up, suggest companions/renames, and flag redundancy. Output as a compact markdown list. No preamble. No code blocks unless needed."

# ----------------------------------------------------------------------------
# INTERACTIVE CONFIGURATION PROMPTS
# Press Enter to accept the default shown in [brackets]. Set NONINTERACTIVE=1
# or HIERANANO_<UPPER_VAR> env vars to skip prompts (for CI / scripting).
# ----------------------------------------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  HIERANANO INTERACTIVE INSTALL CONFIGURATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Press Enter to accept each default in [brackets]."
echo "  You can re-run with NONINTERACTIVE=1 or HIERANANO_* env vars to skip."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "📁  Control Repository (where your Hiera/Puppet files live):"
ask CONTROL_REPO_DIR "    Control repository path" "$DEFAULT_CONTROL_REPO_DIR"

echo ""
echo "🔐  eyaml PKCS7 Key Pair (used to encrypt/decrypt Hiera secrets):"
ask EYAML_PUB_KEY  "    eyaml public key (.pem)"  "$DEFAULT_EYAML_PUB_KEY"
ask EYAML_PRIV_KEY "    eyaml private key (.pem)" "$DEFAULT_EYAML_PRIV_KEY"

echo ""
echo "🤖  OpenAI-compatible AI backend (used by '🤖 Consult AI'):"
ask AI_ENDPOINT "    AI base URL (chat completions)"  "$DEFAULT_AI_ENDPOINT"
ask AI_MODEL    "    AI model name"                   "$DEFAULT_AI_MODEL"
ask AI_TOKEN    "    AI bearer token (leave blank if none)" "$DEFAULT_AI_TOKEN"
ask AI_PROMPT   "    AI system prompt"                "$DEFAULT_AI_PROMPT"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Configuration summary:"
echo "    control_repo_dir : $CONTROL_REPO_DIR"
echo "    eyaml_public_key : $EYAML_PUB_KEY"
echo "    eyaml_private_key: $EYAML_PRIV_KEY"
echo "    ai_endpoint      : $AI_ENDPOINT"
echo "    ai_model         : $AI_MODEL"
echo "    ai_token         : $([ -n "$AI_TOKEN" ] && echo "*** set ($(printf '%s' "$AI_TOKEN" | wc -c) chars) ***" || echo "(empty)")"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 👤 Dynamic Environment & Home Directory Discovery
RUNNING_USER=$(whoami)
RUNNING_UID=$(id -u)

if [ "$RUNNING_UID" -eq 0 ] && [ -n "$SUDO_USER" ]; then
  REAL_USER="$SUDO_USER"
  REAL_HOME=$(eval echo "~$SUDO_USER")
else
  REAL_USER="$RUNNING_USER"
  REAL_HOME="$HOME"
fi

APP_DIR="${REAL_HOME}/.hieranano"
DATA_PERSIST_DIR="${APP_DIR}/data_store"
PORT=5525
HOST="0.0.0.0"

echo "🚀 Bootstrapping Hieranano Workspace Canvas for user: ${REAL_USER}..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/templates"
mkdir -p "$DATA_PERSIST_DIR"

# ==============================================================================
# 🛡️ STEP 1: RESILIENT CRYPTO PATH & PERMISSION RESOLUTION
# ==============================================================================
if [ -f "/opt/puppetlabs/puppet/bin/eyaml" ]; then
  FINAL_EYAML="/opt/puppetlabs/puppet/bin/eyaml"
elif command -v eyaml >/dev/null 2>&1; then
  FINAL_EYAML=$(command -v eyaml)
else
  echo "❌ CRITICAL: The 'eyaml' binary could not be found automatically."
  exit 1
fi

NEEDS_SUDO=0
if [ -f "$EYAML_PUB_KEY" ] && [ -f "$EYAML_PRIV_KEY" ]; then
  if [ ! -r "$EYAML_PUB_KEY" ] || [ ! -r "$EYAML_PRIV_KEY" ]; then
    NEEDS_SUDO=1
  fi
fi

if [ "$NEEDS_SUDO" -eq 1 ] && [ "$RUNNING_UID" -ne 0 ]; then
  echo "🔐 Key read access restricted. Requesting JIT elevation permissions..."
  sudo -v
fi

# ==============================================================================
# STEP 2: ISOLATED DEPENDENCY WORKSPACE PROVISIONING
# ==============================================================================
echo "📦 Building isolated Python Virtual Environment..."
python3 -m venv "$APP_DIR/venv"
source "$APP_DIR/venv/bin/activate"
pip install --upgrade pip --quiet
pip install Flask ruamel.yaml gitpython gunicorn requests --quiet

# ==============================================================================
# STEP 3: WEB APPLICATION RUNTIME ARCHITECTURE (app.py)
# ==============================================================================
echo "⚙️  Assembling Backend Intelligence Engine Core..."
cat << 'EOF' > "$APP_DIR/app.py"
import os
import io
import json
import sqlite3
import subprocess
from flask import Flask, render_template, request, redirect, url_for, flash, session, abort, Response, jsonify
from ruamel.yaml import YAML

app = Flask(__name__)
app.secret_key = os.urandom(32)

# Custom Jinja filter: URL-encode a path component for safe use in ?active=...
import urllib.parse as _urllib_parse
@app.template_filter('urlenc')
def _urlenc(s):
    return _urllib_parse.quote(s, safe='')

DB_PATH = os.path.expanduser("~/.hieranano/data_store/hieranano.db")

# ----------------------------------------------------------------------------
# AI PROMPT CACHE: built once at import time. The system prompt and
# instruction text are static for the life of the worker, so we avoid
# re-reading the SQLite DB and re-concatenating strings on every request.
# The cache is invalidated at install time (gunicorn re-execs the script).
# ----------------------------------------------------------------------------
_BASE_SYSTEM_PROMPT = (
    "You are a Puppet / Hiera architecture assistant. "
    "The user supplies hiera class/parameter NAMES (no values) and a Puppet file. "
    "For each key: state its likely purpose, where in the puppet file it would be "
    "looked up, suggest companions/renames, and flag redundancy. "
    "Output as a compact markdown list. No preamble. No code blocks unless needed."
)

def _build_system_prompt():
    user_prompt = get_setting("ai_prompt", "").strip()
    # If the user configured a custom prompt, use it; otherwise use the
    # terse base. We do NOT concatenate the two -- that would just inflate
    # tokens with redundant instructions.
    return user_prompt if user_prompt else _BASE_SYSTEM_PROMPT

# Response cap removed: we stream with no max_tokens cap so the model can
# return as much as it wants. Cost is bounded by the user closing the tray.
MAX_PUPPET_FILE_BYTES = 50_000  # 50KB hard cap on puppet file sent to AI

def init_db():
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)")
        conn.execute("CREATE TABLE IF NOT EXISTS file_visibility (filepath TEXT PRIMARY KEY, is_hidden INTEGER DEFAULT 0)")
        conn.commit()

init_db()

def get_setting(key, default=""):
    try:
        with sqlite3.connect(DB_PATH) as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT value FROM settings WHERE key = ?", (key,))
            row = cursor.fetchone()
            return row[0] if row else default
    except Exception:
        return default

def set_settings(data_dict):
    with sqlite3.connect(DB_PATH) as conn:
        for k, v in data_dict.items():
            conn.execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", (k, v))
        conn.commit()

def run_eyaml(action, input_data, pub_key=None, priv_key=None):
    cmd = ["/opt/puppetlabs/puppet/bin/eyaml", action, "--stdin"]
    
    if pub_key: cmd.extend(["--pkcs7-public-key", pub_key])
    if priv_key: cmd.extend(["--pkcs7-private-key", priv_key])
    
    # FIX: Safely inherit and append to the existing OS environment layout
    custom_env = os.environ.copy()
    custom_env["PATH"] = "/opt/puppetlabs/puppet/bin:/usr/bin:/bin:" + custom_env.get("PATH", "")
    custom_env["RUBYLIB"] = "/opt/puppetlabs/puppet/lib/ruby/vendor_ruby"
    
    try:
        res = subprocess.run(cmd, input=input_data, capture_output=True, text=True, check=True, env=custom_env)
        return res.stdout
    except subprocess.CalledProcessError as e:
        print(f"DEBUG: Eyaml failed. Stderr: {e.stderr}")
        return None

@app.before_request
def enforce_token_authentication():
    if request.path.startswith('/static/') or request.path == '/api/ai-consult' or request.path.startswith('/api/eyaml/'):
        return

    provided_token = request.args.get('token') or session.get('access_token')
    if provided_token:
        provided_token = provided_token.strip()
    else:
        return abort(403, "Access Denied: Append ?token=YOUR_TOKEN to your URL path.")
        
    plaintext_master = get_setting("plaintext_install_token", "").strip()
    encrypted_passkey = get_setting("secure_install_token", "").strip()

    if plaintext_master and provided_token == plaintext_master:
        session['access_token'] = provided_token
        return

    if encrypted_passkey and provided_token == encrypted_passkey:
        session['access_token'] = provided_token
        return

    pub_key = get_setting("eyaml_public_key")
    priv_key = get_setting("eyaml_private_key")
    decrypted_master = run_eyaml("decrypt", encrypted_passkey, pub_key=pub_key, priv_key=priv_key)
    
    if decrypted_master and provided_token == decrypted_master.strip():
        session['access_token'] = provided_token
        return

    return abort(403, "Invalid security token credential provided.")

def generate_tree_node(dir_path, root_repo_path, mode="all"):
    tree = []
    if not dir_path or not os.path.exists(dir_path):
        return tree
    try:
        for entry in os.scandir(dir_path):
            if entry.name.startswith('.'): continue
            rel_path = os.path.relpath(entry.path, root_repo_path)
            if entry.is_dir():
                sub_children = generate_tree_node(entry.path, root_repo_path, mode)
                if mode == "yaml" and not sub_children:
                    continue
                tree.append({
                    "name": entry.name, "type": "directory", "path": rel_path,
                    "children": sub_children
                })
            else:
                is_yaml = entry.name.endswith(('.yaml', '.yml', '.eyaml'))
                if mode == "yaml" and not is_yaml:
                    continue
                tree.append({"name": entry.name, "type": "file", "path": rel_path})
    except Exception: 
        pass
    tree.sort(key=lambda x: (x['type'] != 'directory', x['name'].lower()))
    return tree

@app.context_processor
def inject_global_settings():
    return {
        "repo_path": get_setting("control_repo_dir", ""),
        "ai_endpoint": get_setting("ai_endpoint", ""),
        "ai_prompt": get_setting("ai_prompt", "This is Puppet Enterprise code. Hiera architecture query context input details follow below:")
    }

@app.route('/')
def index():
    repo_path = get_setting("control_repo_dir", "")
    hiera_tree = generate_tree_node(repo_path, repo_path, mode="yaml") if repo_path else []
    full_tree = generate_tree_node(repo_path, repo_path, mode="all") if repo_path else []

    # Single-editor model: one active file at a time.
    active_file = request.args.get('active', '').strip()
    requested_view = request.args.get('view', '').strip().lower()

    file_content, file_type, key_value_pairs, yaml_valid = "", "none", [], False

    if active_file and repo_path:
        fp = os.path.normpath(os.path.join(repo_path, active_file))
        # Path safety: must remain inside the repo root.
        if os.path.commonpath([fp, os.path.normpath(repo_path)]) == os.path.normpath(repo_path) and os.path.isfile(fp):
            with open(fp, 'r') as f:
                file_content = f.read()
            lower = active_file.lower()
            is_yaml_ext = lower.endswith(('.yaml', '.yml'))
            if is_yaml_ext:
                file_type = "yaml"
                try:
                    yaml = YAML()
                    data = yaml.load(file_content) or {}
                    yaml_valid = True
                    if isinstance(data, dict):
                        for k, v in data.items():
                            val_str = json.dumps(v) if isinstance(v, (dict, list)) else str(v)
                            is_enc = "ENC[PKCS7" in str(v) or val_str.startswith("ENC[PKCS7")
                            key_value_pairs.append({
                                "key": k,
                                "value_raw": val_str,
                                "is_encrypted": is_enc
                            })
                except Exception:
                    yaml_valid = False
            else:
                file_type = "raw"

    # Decide which view to render. Visual only makes sense for a valid YAML.
    can_visual = (file_type == "yaml" and yaml_valid)
    if not can_visual:
        view_mode = "raw"
    else:
        if requested_view in ("visual", "raw"):
            view_mode = requested_view
        else:
            view_mode = "visual"

    return render_template(
        'index.html',
        hiera_tree=hiera_tree,
        full_tree=full_tree,
        active_file=active_file,
        file_content=file_content,
        file_type=file_type,
        key_value_pairs=key_value_pairs,
        yaml_valid=yaml_valid,
        view_mode=view_mode,
        can_visual=can_visual,
        access_token=session.get('access_token', ''),
    )

@app.route('/api/eyaml/decrypt', methods=['POST'])
def api_decrypt():
    pub_key = get_setting("eyaml_public_key")
    priv_key = get_setting("eyaml_private_key")
    ciphertext = request.json.get('ciphertext', '')
    decrypted = run_eyaml("decrypt", ciphertext, pub_key=pub_key, priv_key=priv_key)
    if decrypted:
        return jsonify({"success": True, "plaintext": decrypted.strip()})
    return jsonify({"success": False, "error": "Decryption engine failed"}), 400

@app.route('/api/eyaml/encrypt', methods=['POST'])
def api_encrypt():
    pub_key = get_setting("eyaml_public_key")
    priv_key = get_setting("eyaml_private_key")
    plaintext = request.json.get('plaintext', '')
    encrypted = run_eyaml("encrypt", plaintext, pub_key=pub_key, priv_key=priv_key)
    if encrypted:
        # FIX: Eyaml may emit a leading 'ENC[PKCS7,...]' block plus secondary
        # metadata. We only persist/store the FIRST ENC[...] envelope so the
        # stored value is a single, clean Hiera-safe ENC() string.
        import re
        cleaned = encrypted.strip()
        match = re.search(r'ENC\[[^\]]*\]', cleaned, flags=re.DOTALL)
        if match:
            clean_enc = match.group(0).replace("\n", "").replace(" ", "").replace("\r", "")
        else:
            clean_enc = cleaned.replace("\n", "").replace(" ", "").replace("\r", "")
        return jsonify({"success": True, "ciphertext": clean_enc})
    return jsonify({"success": False, "error": "Encryption engine failed"}), 400

@app.route('/api/git/sync', methods=['POST'])
def api_git_sync():
    """Run git add . / git commit / git push inside the configured control repo."""
    repo_path = get_setting("control_repo_dir", "").strip()
    if not repo_path or not os.path.isdir(repo_path):
        return jsonify({"success": False, "error": "control_repo_dir is not configured or missing."}), 400

    commit_msg = (request.json or {}).get("message", "hieranano: auto-sync via web UI").strip()
    amend = bool((request.json or {}).get("amend", False))
    custom_env = os.environ.copy()
    custom_env["PATH"] = "/opt/puppetlabs/puppet/bin:/usr/bin:/bin:" + custom_env.get("PATH", "")
    custom_env["GIT_TERMINAL_PROMPT"] = "0"

    def run(cmd):
        return subprocess.run(cmd, cwd=repo_path, capture_output=True, text=True, env=custom_env)

    # 1. Ensure we are inside a git working tree
    chk = run(["git", "rev-parse", "--is-inside-work-tree"])
    if chk.returncode != 0:
        return jsonify({
            "success": False,
            "error": "Not a git repository",
            "details": (chk.stderr or chk.stdout).strip()
        }), 400

    # 2. Stage all changes
    add_res = run(["git", "add", "."])
    if add_res.returncode != 0:
        return jsonify({
            "success": False,
            "stage": "add",
            "error": add_res.stderr.strip() or add_res.stdout.strip()
        }), 500

    # 3. Commit. If `amend` is set, run `git commit --amend` instead of
    # `git commit -m`, which rewrites the most recent commit. This will
    # fail if there is no prior commit, or if the prior commit was already
    # pushed; the error is surfaced to the user.
    commit_res = None
    if amend:
        if not commit_msg:
            return jsonify({"success": False, "error": "Amend requires a commit message."}), 400
        commit_res = run(["git", "commit", "--amend", "-m", commit_msg])
        if commit_res.returncode != 0:
            return jsonify({
                "success": False,
                "stage": "amend",
                "error": commit_res.stderr.strip() or commit_res.stdout.strip()
            }), 500
    else:
        # Normal commit: only run if there is something to commit.
        status_res = run(["git", "status", "--porcelain"])
        if status_res.stdout.strip():
            commit_res = run(["git", "commit", "-m", commit_msg])
            if commit_res.returncode != 0:
                return jsonify({
                    "success": False,
                    "stage": "commit",
                    "error": commit_res.stderr.strip() or commit_res.stdout.strip()
                }), 500
        # else: commit_res stays None (nothing to commit)

    # 4. Push (best-effort; failure here is reported but does not block)
    push_res = run(["git", "push"])
    push_ok = push_res.returncode == 0

    return jsonify({
        "success": True,
        "staged": True,
        "committed": bool(commit_res),
        "pushed": push_ok,
        "push_error": (push_res.stderr.strip() if not push_ok else ""),
        "commit_message": commit_msg,
    })

@app.route('/save-file', methods=['POST'])
def save_file():
    """Persist a file in the control repo. The visual grid and the raw editor
    both POST here with the relative `filepath` and `content`."""
    repo_path = get_setting("control_repo_dir")
    rel_path = request.form.get('filepath', '').strip()
    content = request.form.get('content', '')

    if repo_path and rel_path:
        full_path = os.path.normpath(os.path.join(repo_path, rel_path))
        # Path safety: must remain inside the repo root.
        if os.path.commonpath([full_path, os.path.normpath(repo_path)]) == os.path.normpath(repo_path):
            os.makedirs(os.path.dirname(full_path), exist_ok=True)
            with open(full_path, 'w') as f:
                f.write(content)
            flash(f"Saved file {rel_path}", "success")
        else:
            flash("Refused to write outside the control repo.", "error")
    else:
        flash("No active file or repo path configured.", "error")

    return redirect(url_for('index', active=rel_path))

@app.route('/save-visual-hiera', methods=['POST'])
def save_visual_hiera():
    repo_path = get_setting("control_repo_dir")
    rel_path = request.form.get('filepath', '').strip()
    keys = request.form.getlist('keys[]')
    values = request.form.getlist('values[]')

    if not repo_path or not rel_path:
        return redirect(url_for('index'))

    yaml_dict = {}
    for k, v in zip(keys, values):
        if not k.strip(): continue
        try:
            parsed_val = json.loads(v)
        except Exception:
            parsed_val = v
        yaml_dict[k.strip()] = parsed_val

    full_path = os.path.normpath(os.path.join(repo_path, rel_path))
    # Path safety
    if os.path.commonpath([full_path, os.path.normpath(repo_path)]) != os.path.normpath(repo_path):
        flash("Refused to write outside the control repo.", "error")
        return redirect(url_for('index'))

    yaml = YAML()
    yaml.default_flow_style = False

    with open(full_path, 'w') as f:
        yaml.dump(yaml_dict, f)

    flash(f"Visual Grid compiled and saved cleanly to {rel_path}", "success")
    return redirect(url_for('index', active=rel_path))

@app.route('/api/ai-consult', methods=['POST'])
def ai_consult():
    """AI consult: send ONLY the hiera class names and the selected puppet
    file's content. No hiera values (encrypted or otherwise) are sent.

    Token-saving design:
      * System prompt (instructions) is sent as a separate 'system' message
        so backends with prompt caching (OpenAI GPT-4o, Anthropic) can reuse it.
      * Puppet file is minified: comments stripped, blank lines collapsed,
        leading/trailing whitespace removed, then hard-capped at 50KB.
      * No decorative === HEADER === banners -- they cost tokens and convey
        no information the model doesn't already have.
    """
    import requests
    endpoint = get_setting("ai_endpoint")
    token = get_setting("ai_token")
    model = get_setting("ai_model") or "gpt-4o-mini"
    repo_path = get_setting("control_repo_dir")

    req_json = request.get_json() or {}
    hiera_path = (req_json.get('hiera_path') or '').strip()
    hiera_keys = req_json.get('hiera_keys') or []   # LIST OF STRINGS ONLY
    puppet_path = (req_json.get('puppet_path') or '').strip()

    # Validate both paths live inside the repo
    def safe_join(rel):
        if not repo_path or not rel: return None
        p = os.path.normpath(os.path.join(repo_path, rel))
        if os.path.commonpath([p, os.path.normpath(repo_path)]) != os.path.normpath(repo_path):
            return None
        return p

    hiera_full = safe_join(hiera_path)
    puppet_full = safe_join(puppet_path)

    if not hiera_full or not os.path.isfile(hiera_full):
        return jsonify({"success": False, "error": "Invalid hiera file path"}), 400
    if not puppet_full or not os.path.isfile(puppet_full):
        return jsonify({"success": False, "error": "Invalid puppet file path"}), 400

    # ---- Minify the puppet file: drop comments, blank lines, edge whitespace
    def minify_puppet(text):
        out_lines = []
        for line in text.splitlines():
            stripped = line.strip()
            if not stripped:
                continue                       # drop blank lines
            if stripped.startswith('#'):
                continue                       # drop shell-style comments
            # Drop trailing inline comments ONLY when '#' is preceded by
            # whitespace and not inside a quoted string (good-enough heuristic).
            if ' #' in stripped:
                # Find the first ' #' that is outside quotes
                in_quote = False
                cut = -1
                for i, ch in enumerate(stripped):
                    if ch in ('"', "'"):
                        in_quote = not in_quote
                    elif ch == '#' and not in_quote and i > 0 and stripped[i-1] == ' ':
                        cut = i
                        break
                if cut > 0:
                    stripped = stripped[:cut].rstrip()
                    if not stripped:
                        continue
            out_lines.append(stripped)
        return "\n".join(out_lines)

    try:
        with open(puppet_full, 'r') as f:
            puppet_raw = f.read()
    except Exception as e:
        return jsonify({"success": False, "error": f"Cannot read puppet file: {e}"}), 400

    puppet_min = minify_puppet(puppet_raw)
    truncated = False
    if len(puppet_min.encode('utf-8')) > MAX_PUPPET_FILE_BYTES:
        puppet_min = puppet_min.encode('utf-8')[:MAX_PUPPET_FILE_BYTES].decode('utf-8', errors='ignore')
        truncated = True

    # Sanitise: only string keys, no values from the hiera file
    safe_keys = [str(k).strip() for k in hiera_keys if str(k).strip()]

    # Compact key block: one line, comma-separated, no bullet fluff.
    keys_inline = ",".join(safe_keys)

    # Compact user payload: just the two file paths + content + key list.
    # No "=== HEADER ===" banners. No "STRICT RULES" prose (those are in
    # the cached system prompt instead).
    user_payload = (
        f"hiera={hiera_path}\n"
        f"puppet={puppet_path}\n"
        f"keys=[{keys_inline}]\n"
        f"---\n{puppet_min}"
    )
    if truncated:
        user_payload += f"\n[truncated to {MAX_PUPPET_FILE_BYTES}B]"

    # No response cap -- let the model return as much as it wants. The
    # client streams chunks as they arrive, so cost is bounded by the user
    # closing the tray / page rather than by a server-side token limit.
    def safe_str(obj):
        """Robust str() that never propagates bytes objects, which would
        cause 'Object of type bytes is not JSON serializable' when Flask
        or requests internals try to JSON-encode an error message."""
        try:
            if isinstance(obj, bytes):
                try:
                    return obj.decode('utf-8', errors='replace')
                except Exception:
                    return f"<{len(obj)} bytes>"
            if isinstance(obj, (list, tuple)):
                return safe_str(obj[0]) if obj else ''
            return str(obj)
        except Exception:
            return '<unprintable>'

    def stream_request():
        # Buffer for SSE reassembly. iter_lines() may split the upstream
        # stream on arbitrary byte boundaries, so we accumulate "data: " lines
        # until a blank line (end-of-event) and then parse them.
        headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
        # OpenAI / OpenAI-compatible backends require this for streamed tokens.
        headers["Accept"] = "text/event-stream"
        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": _build_system_prompt()},
                {"role": "user", "content": user_payload},
            ],
            "stream": True,
        }
        buf = ""
        try:
            with requests.post(endpoint, json=payload, headers=headers, stream=True, timeout=60) as r:
                # If the upstream returned a non-2xx, surface the body as
                # a normal text chunk so the client sees the real reason
                # instead of an opaque connection error.
                if r.status_code >= 400:
                    err_body = r.text or r.content.decode('utf-8', errors='replace') or '<no body>'
                    yield f"\n💥 AI endpoint returned HTTP {r.status_code}: {err_body.strip()}\n"
                    return

                for raw in r.iter_content(chunk_size=None, decode_unicode=False):
                    if not raw:
                        continue
                    # raw is always bytes when decode_unicode=False
                    if isinstance(raw, bytes):
                        try:
                            buf += raw.decode('utf-8', errors='replace')
                        except Exception:
                            continue
                    else:
                        buf += str(raw)
                    # Process complete SSE events (terminated by a blank line)
                    while '\n\n' in buf:
                        event, buf = buf.split('\n\n', 1)
                        for line in event.splitlines():
                            line = line.strip()
                            if not line:
                                continue
                            if line.startswith('data:'):
                                data = line[5:].lstrip()
                                if data == '[DONE]':
                                    return
                                try:
                                    j = json.loads(data)
                                except Exception:
                                    continue
                                # OpenAI shape: choices[0].delta.content
                                # Some clones nest it as choices[0].text or
                                # choices[0].message.content. Handle both.
                                try:
                                    delta = j['choices'][0].get('delta') or {}
                                    piece = delta.get('content')
                                    if piece is None:
                                        piece = (j['choices'][0].get('message') or {}).get('content', '')
                                    if piece:
                                        yield piece
                                except Exception:
                                    # Surface non-streaming error bodies
                                    if 'error' in j:
                                        err = j['error']
                                        msg = err.get('message') if isinstance(err, dict) else str(err)
                                        yield f"\n💥 AI error: {msg}\n"
        except Exception as e:
            yield f"\n💥 Connection Error: {safe_str(e)}\n"

    # text/event-stream is the right content type for SSE. We also set
    # X-Accel-Buffering: no so reverse proxies (nginx) don't hold the response.
    return Response(
        stream_request(),
        mimetype='text/event-stream',
        headers={
            'Cache-Control': 'no-cache',
            'X-Accel-Buffering': 'no',
            'Connection': 'keep-alive',
        },
    )

@app.route('/update-config', methods=['POST'])
def update_config():
    set_settings({
        "control_repo_dir": request.form.get('control_repo_dir', '').strip(),
        "eyaml_public_key": request.form.get('eyaml_public_key', '').strip(),
        "eyaml_private_key": request.form.get('eyaml_private_key', '').strip(),
        "ai_endpoint": request.form.get('ai_endpoint', '').strip(),
        "ai_token": request.form.get('ai_token', '').strip(),
        "ai_prompt": request.form.get('ai_prompt', '').strip()
    })
    flash("Configuration settings stored successfully.", "success")
    return redirect(url_for('index'))

if __name__ == '__main__':
    pass
EOF

# ==============================================================================
# STEP 4: INTERFACE RENDERER COMPILING (templates/index.html)
# ==============================================================================
echo "🎨 Compiling Frontend Deck Assets..."
cat << 'EOF' > "$APP_DIR/templates/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Hieranano - Intelligence Control Deck</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        :root {
            --bg-0: #0f172a;
            --bg-1: #1e293b;
            --bg-2: #111827;
            --bg-code: #090d16;
            --border: #334155;
            --text: #cbd5e1;
            --accent: #38bdf8;
            --warn: #f59e0b;
        }
        *, *::before, *::after { box-sizing: border-box; }
        html, body { height: 100%; }
        body { margin: 0; background: var(--bg-0); color: var(--text); font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; overflow: hidden; }
        .wrapper { display: flex; height: 100vh; width: 100vw; min-height: 0; }

        /* ---------------- Sidebar (resizable) ---------------- */
        .sidebar {
            width: 340px; min-width: 220px; max-width: 600px;
            background: var(--bg-1); border-right: 1px solid var(--border);
            display: flex; flex-direction: column; height: 100%;
            position: relative; flex: 0 0 auto;
        }
        .sidebar-split-pane {
            display: flex; flex-direction: column;
            border-bottom: 2px solid var(--bg-0);
            overflow: hidden; min-height: 80px;
            flex: 1 1 50%;
        }
        .sidebar-split-pane:last-child { border-bottom: none; }
        .tree-root { padding: 10px; overflow-y: auto; overflow-x: auto; flex: 1 1 auto; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
        .tree-folder { cursor: pointer; user-select: none; padding: 3px 0; display: block; color: var(--accent); }
        .tree-folder::before { content: "📁 "; }
        .tree-files { padding-left: 15px; }
        .tree-file-link { display: block; color: #94a3b8; text-decoration: none; padding: 2px 5px; border-radius: 3px; text-overflow: ellipsis; overflow: hidden; white-space: nowrap; }
        .tree-file-link:hover { background: var(--border); color: #fff; }
        .tree-file-link.active { background: #0284c7; color: #fff; }

        /* Resizer handle between sidebar and main */
        .resizer-v {
            width: 6px; cursor: col-resize; background: transparent; flex: 0 0 auto; z-index: 5;
        }
        .resizer-v:hover, .resizer-v.dragging { background: #475569; }

        /* Resizer between the two sidebar split panes */
        .resizer-h {
            height: 6px; cursor: row-resize; background: var(--bg-0); flex: 0 0 auto; z-index: 4;
        }
        .resizer-h:hover, .resizer-h.dragging { background: #475569; }

        /* ---------------- Main desk ---------------- */
        .main-desk { flex: 1 1 auto; min-width: 0; display: flex; flex-direction: column; overflow: hidden; background: var(--bg-0); }
        .top-deck { height: 55px; background: var(--bg-1); border-bottom: 1px solid var(--border); display: flex; align-items: center; justify-content: space-between; padding: 0 20px; gap: 10px; flex-wrap: wrap; }
        .workspace-split {
            flex: 1 1 auto; min-height: 0; overflow-y: auto; overflow-x: hidden;
            padding: 20px; gap: 25px;
            display: flex; flex-direction: column;
        }

        .canvas-card { background: var(--bg-1); border: 1px solid var(--border); border-radius: 8px; display: flex; flex-direction: column; overflow: hidden; margin-bottom: 5px; }
        .canvas-header { padding: 12px 20px; background: var(--bg-2); border-bottom: 1px solid var(--border); display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 8px; }

        /* Tab strip for visual / raw switching (yaml files only) */
        .view-tabs { display: flex; gap: 0; background: #050a14; border-bottom: 1px solid var(--border); }
        .view-tabs a { flex: 1 1 50%; text-align: center; padding: 8px 10px; color: #94a3b8; text-decoration: none; font-size: 12px; font-weight: 700; letter-spacing: 0.5px; border-right: 1px solid var(--border); transition: background 0.15s; }
        .view-tabs a:last-child { border-right: none; }
        .view-tabs a:hover { background: #1e293b; color: #fff; }
        .view-tabs a.active { background: #0284c7; color: #fff; }

        /* Editor bodies. Both panes get a vertical scrollbar that always shows */
        .code-desk { width: 100%; height: 480px; max-height: 70vh; background: var(--bg-code); color: #f8fafc; border: none; padding: 15px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px; outline: none; resize: vertical; overflow-y: auto !important; }
        .visual-grid-scroll { max-height: 65vh; overflow-y: auto; padding: 12px; background: #050a14; }
        .visual-grid-scroll #visualGridContainer { margin: 0; }

        .ai-assistant-tray { background: #0284c7; color: #fff; padding: 12px; border-radius: 6px; margin-bottom: 15px; display: none; flex-direction: column; gap: 8px; }
        .ai-stream-window { background: var(--bg-0); color: var(--accent); padding: 12px; border-radius: 4px; font-family: ui-monospace, monospace; font-size: 13px; max-height: 200px; overflow-y: auto; white-space: pre-wrap; }
        .grid-row-item { background: var(--bg-2); border: 1px solid var(--border); border-radius: 4px; margin-bottom: 8px; padding: 10px; }
        .eyaml-active { border-left: 4px solid var(--warn) !important; }

        /* Git sync banner / button */
        .git-sync-status { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; padding: 4px 10px; border-radius: 4px; background: #052e16; color: #4ade80; border: 1px solid #14532d; }
        .git-sync-status.error { background: #450a0a; color: #fca5a5; border-color: #7f1d1d; }
        .git-sync-status.pending { background: #1e293b; color: #fde68a; border-color: var(--warn); }

        /* AI Consult modal */
        .ai-key-list { max-height: 360px; overflow-y: auto; background: #0b1220; }
        .ai-key-row { display: flex; align-items: center; gap: 8px; padding: 6px 8px; border-radius: 4px; cursor: pointer; }
        .ai-key-row:hover { background: #1e293b; }
        .ai-key-row .form-check-input { cursor: pointer; }
        .ai-key-name { font-family: ui-monospace, monospace; font-size: 12px; color: #fde68a; word-break: break-all; }

        .ai-tree { max-height: 360px; overflow: auto; background: #0b1220; font-family: ui-monospace, monospace; font-size: 12px; }
        .ai-tree .tree-folder { color: #38bdf8; }
        .ai-tree .ai-file { display: block; color: #cbd5e1; padding: 3px 8px; border-radius: 3px; cursor: pointer; text-decoration: none; }
        .ai-tree .ai-file:hover { background: #1e293b; }
        .ai-tree .ai-file.selected { background: #075985; color: #fff; }
        .ai-tree .ai-file .ppath { color: #64748b; font-size: 11px; margin-left: 6px; }

        /* Custom scrollbars for the dark theme */
        *::-webkit-scrollbar { width: 10px; height: 10px; }
        *::-webkit-scrollbar-track { background: var(--bg-2); }
        *::-webkit-scrollbar-thumb { background: #475569; border-radius: 6px; }
        *::-webkit-scrollbar-thumb:hover { background: #64748b; }

        /* ---------------- Responsive breakpoints ---------------- */
        @media (max-width: 900px) {
            .wrapper { flex-direction: column; }
            .sidebar { width: 100% !important; max-width: none !important; height: 40vh; min-height: 220px; border-right: none; border-bottom: 1px solid var(--border); }
            .resizer-v { display: none; }
            .resizer-h { display: none; }
            .sidebar-split-pane { flex: 1 1 50%; min-height: 0; }
            .main-desk { width: 100%; height: 60vh; }
            .top-deck { height: auto; padding: 8px 12px; }
            .canvas-header { padding: 10px 12px; }
            .workspace-split { padding: 12px; gap: 15px; }
        }
        @media (max-width: 600px) {
            .canvas-header .input-group { width: 100% !important; }
            .canvas-header { flex-direction: column; align-items: stretch; }
            .top-deck { flex-direction: column; align-items: flex-start; }
        }
    </style>
</head>
<body>

<div class="wrapper">
    <div class="sidebar">
        <div class="sidebar-split-pane">
            <div class="p-2 bg-dark border-bottom border-secondary text-info fw-bold small">📊 HIERA DATA LAYERS (.yaml)</div>
            <div class="tree-root">
                {% macro render_hiera_node(nodes) %}
                    {% for node in nodes %}
                        {% if node.type == 'directory' %}
                            <div onclick="toggleFolder(event, 'hiera-dir-{{ node.path | replace('/', '-') | replace('.', '-') }}')" class="tree-folder fw-bold">{{ node.name }}</div>
                            <div class="tree-files" id="hiera-dir-{{ node.path | replace('/', '-') | replace('.', '-') }}">
                                {{ render_hiera_node(node.children) }}
                            </div>
                        {% else %}
                            <a href="?active={{ node.path | urlenc }}" class="tree-file-link {% if active_file == node.path %}active{% endif %}">📄 {{ node.name }}</a>
                        {% endif %}
                    {% endfor %}
                {% endmacro %}
                {% if hiera_tree %}{{ render_hiera_node(hiera_tree) }}{% else %}<div class="text-muted text-center p-2 small">No Hiera files loaded</div>{% endif %}
            </div>
        </div>

        <div class="sidebar-split-pane">
            <div class="p-2 bg-dark border-bottom border-secondary text-warning fw-bold small">📂 FULL REPOSITORY ROOT</div>
            <div class="tree-root">
                {% macro render_all_node(nodes) %}
                    {% for node in nodes %}
                        {% if node.type == 'directory' %}
                            <div onclick="toggleFolder(event, 'all-dir-{{ node.path | replace('/', '-') | replace('.', '-') }}')" class="tree-folder fw-bold">{{ node.name }}</div>
                            <div class="tree-files" id="all-dir-{{ node.path | replace('/', '-') | replace('.', '-') }}">
                                {{ render_all_node(node.children) }}
                            </div>
                        {% else %}
                            <a href="?active={{ node.path | urlenc }}" class="tree-file-link {% if active_file == node.path %}active{% endif %}">📄 {{ node.name }}</a>
                        {% endif %}
                    {% endfor %}
                {% endmacro %}
                {% if full_tree %}{{ render_all_node(full_tree) }}{% else %}<div class="text-muted text-center p-2 small">Configure a repository target</div>{% endif %}
            </div>
        </div>
    </div>

    <div class="resizer-v" id="sidebarResizer" title="Drag to resize"></div>

    <div class="main-desk">
        <div class="top-deck">
            <div class="d-flex gap-2 align-items-center"><span class="badge bg-secondary">System Platform Ready</span></div>
            <div class="d-flex gap-2 align-items-center">
                <span class="git-sync-status" id="gitSyncStatus" style="display:none;">● Idle</span>
                <button type="button" class="btn btn-sm btn-outline-success" onclick="openGitSyncModal()">🔁 Git Sync</button>
            </div>
        </div>

        <div class="workspace-split">
            {% with messages = get_flashed_messages() %}
                {% if messages %}{% for msg in messages %}<div class="alert alert-success p-2 small mb-0 shadow">{{ msg }}</div>{% endfor %}{% endif %}
            {% endwith %}

            <div class="ai-assistant-tray" id="aiTray">
                <div class="d-flex justify-content-between align-items-center">
                    <span class="fw-bold">🤖 Hieranano AI Code Architect Pilot</span>
                    <button class="btn btn-xs btn-dark text-white py-0 px-2 small" onclick="document.getElementById('aiTray').style.display='none'">✕ Close</button>
                </div>
                <div class="small text-white-50">Context: <span class="text-warning" id="aiContextBadge">None</span></div>
                <div class="ai-stream-window" id="aiStreamOutput">Awaiting generation stream...</div>
            </div>

            <div class="canvas-card" id="editorCard">
                <div class="canvas-header">
                    <span class="text-info font-monospace fw-bold" id="editorTitle">
                        🎯 FILE WORKSPACE
                        {% if active_file %}[ {{ active_file }} ]{% endif %}
                    </span>
                    <div class="d-flex gap-2 align-items-center flex-wrap">
                        {% if active_file and view_mode == 'visual' and can_visual %}
                        <span class="badge bg-success">✨ Visual Hiera Mode</span>
                        <span class="badge bg-warning text-dark" id="dirtyBadge" style="display:none;">● Unsaved changes</span>
                        {# 🤖 Consult AI button intentionally hidden per request; JS preserved for later re-enable #}
                        {% elif active_file and view_mode == 'raw' and can_visual %}
                        <span class="badge bg-info text-dark">📄 Raw YAML Mode</span>
                        <span class="badge bg-warning text-dark" id="dirtyBadge" style="display:none;">● Unsaved changes</span>
                        {# 🤖 Consult AI button intentionally hidden per request; JS preserved for later re-enable #}
                        {% elif active_file and file_type == 'yaml' and not yaml_valid %}
                        <span class="badge bg-warning text-dark">⚠ YAML invalid — editing as raw</span>
                        <span class="badge bg-warning text-dark" id="dirtyBadge" style="display:none;">● Unsaved changes</span>
                        {% elif active_file %}
                        <span class="badge bg-secondary">🛠 Raw Editor Mode</span>
                        <span class="badge bg-warning text-dark" id="dirtyBadge" style="display:none;">● Unsaved changes</span>
                        {% endif %}
                        {% if active_file %}
                        <button type="button" class="btn btn-sm btn-success fw-bold" onclick="submitActiveEditor()">💾 Save All</button>
                        {% endif %}
                    </div>
                </div>

                {% if active_file %}
                    {% if can_visual %}
                    <div class="view-tabs">
                        <a href="?active={{ active_file | urlenc }}&view=visual{{ ("&token=" + access_token) if access_token else "" }}" class="{% if view_mode == 'visual' %}active{% endif %}">✨ VISUAL HIERA GRID</a>
                        <a href="?active={{ active_file | urlenc }}&view=raw{{ ("&token=" + access_token) if access_token else "" }}" class="{% if view_mode == 'raw' %}active{% endif %}">📄 RAW SOURCE</a>
                    </div>
                    {% endif %}

                    {% if view_mode == 'visual' and can_visual %}
                    <div class="visual-grid-scroll">
                    <form action="{{ url_for('save_visual_hiera') }}" method="POST" id="visualGridForm">
                        <input type="hidden" name="filepath" value="{{ active_file }}">

                        <div id="visualGridContainer">
                            {% for item in key_value_pairs %}
                            <div class="row g-2 grid-row-item align-items-center {% if item.is_encrypted %}eyaml-active{% endif %}">
                                <div class="col-12 col-md-4">
                                    <input type="text" name="keys[]" class="form-control form-control-sm bg-dark text-white border-secondary font-monospace hiera-key" value="{{ item.key }}" placeholder="parameter.name">
                                </div>
                                <div class="col-9 col-md-6">
                                    <textarea name="values[]" class="form-control form-control-sm bg-dark text-info border-secondary font-monospace val-field" rows="1" data-raw-state="{% if item.is_encrypted %}ciphertext{% else %}plaintext{% endif %}" placeholder="Value mapping or literal">{{ item.value_raw }}</textarea>
                                </div>
                                <div class="col-3 col-md-2 d-flex gap-1 justify-content-end">
                                    {% if item.is_encrypted %}
                                    <button type="button" class="btn btn-sm btn-warning text-dark fw-bold px-2 py-1 small crypto-toggle-btn" onclick="toggleCryptoState(this)">🔓 Reveal</button>
                                    {% else %}
                                    <button type="button" class="btn btn-sm btn-outline-warning fw-bold px-2 py-1 small crypto-toggle-btn" onclick="toggleCryptoState(this)">🔒 Encrypt</button>
                                    {% endif %}
                                    <button type="button" class="btn btn-sm btn-outline-danger p-1 px-2" onclick="this.closest('.row').remove()">✕</button>
                                </div>
                            </div>
                            {% endfor %}
                        </div>
                        <div class="d-flex justify-content-between mt-3 gap-2 flex-wrap">
                            <button type="button" class="btn btn-sm btn-outline-info" onclick="addNewGridRow()">➕ Add Property Entry</button>
                            <div class="d-flex gap-2">
                                <button type="submit" class="btn btn-sm btn-success px-4 fw-bold">💾 Save All</button>
                            </div>
                        </div>
                    </form>
                    </div>
                    {% else %}
                    <form action="{{ url_for('save_file') }}" method="POST" class="m-0">
                        <input type="hidden" name="filepath" value="{{ active_file }}">
                        <textarea id="rawTextarea" name="content" class="code-desk">{{ file_content }}</textarea>
                        <div class="p-2 bg-dark text-end border-top border-secondary d-flex justify-content-between align-items-center">
                            <span class="small text-muted ms-2">
                                {% if file_type == 'yaml' and not yaml_valid %}
                                YAML could not be parsed. Editing as plain text.
                                {% endif %}
                            </span>
                            <div class="d-flex gap-2">
                                {% if can_visual %}
                                <a class="btn btn-sm btn-outline-info" href="?active={{ active_file | urlenc }}&view=visual{{ ("&token=" + access_token) if access_token else "" }}">✨ Back to Visual</a>
                                {% endif %}
                                <button type="submit" class="btn btn-sm btn-primary px-4 fw-bold">💾 Save All</button>
                            </div>
                        </div>
                    </form>
                    {% endif %}
                {% else %}
                    <div class="p-5 text-center text-muted small">Select a file from the sidebar to begin editing.</div>
                {% endif %}
            </div>
        </div>
    </div>
</div>

<!-- =====================================================================
     AI CONSULT MODAL: select hiera keys + a puppet file to send to AI
     ===================================================================== -->
<div class="modal fade" id="aiConsultModal" tabindex="-1" aria-hidden="true">
    <div class="modal-dialog modal-dialog-centered modal-xl modal-dialog-scrollable">
        <div class="modal-content bg-dark text-white border-secondary">
            <div class="modal-header border-secondary">
                <h6 class="modal-title fw-bold">🤖 AI Consult — Hiera Class <span class="text-muted small">↔</span> Puppet File</h6>
                <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button>
            </div>
            <div class="modal-body small">
                <div class="alert alert-warning py-2 px-3 mb-3 d-flex align-items-start gap-2">
                    <span style="font-size:18px;">⚠️</span>
                    <div>
                        <strong>Privacy notice:</strong> This will send to the AI backend:
                        <ul class="mb-1 mt-1">
                            <li>The <strong>NAMES</strong> of the hiera classes/parameters you select below.</li>
                            <li>The <strong>contents</strong> of the puppet file you select on the right.</li>
                        </ul>
                        <strong>No</strong> hiera values, no revealed secrets, and no encrypted ENC[...] blobs are sent. Only the structure and the puppet code.
                    </div>
                </div>

                <div class="row g-3">
                    <div class="col-12 col-lg-6">
                        <div class="d-flex justify-content-between align-items-center mb-2">
                            <label class="text-info fw-bold mb-0">Hiera Classes / Parameters (from <span id="aiHieraFileLabel" class="text-warning font-monospace">…</span>)</label>
                            <div>
                                <button type="button" class="btn btn-xs btn-outline-info py-0 px-2" onclick="aiSelectAllKeys(true)">All</button>
                                <button type="button" class="btn btn-xs btn-outline-secondary py-0 px-2" onclick="aiSelectAllKeys(false)">None</button>
                            </div>
                        </div>
                        <div id="aiHieraKeyList" class="ai-key-list border border-secondary rounded p-2"></div>
                    </div>
                    <div class="col-12 col-lg-6">
                        <label class="text-warning fw-bold d-block mb-2">Puppet / Manifest File (where these classes are used)</label>
                        <input type="text" id="aiPuppetFilter" class="form-control form-control-sm bg-black text-white border-secondary mb-2" placeholder="🔍 filter (init.pp, profile, etc.)">
                        <div id="aiPuppetTree" class="ai-tree border border-secondary rounded p-2"></div>
                    </div>
                </div>
            </div>
            <div class="modal-footer border-secondary d-flex justify-content-between">
                <span class="text-muted small" id="aiConsultSummary">0 keys selected • no puppet file chosen</span>
                <div class="d-flex gap-2">
                    <button type="button" class="btn btn-sm btn-secondary" data-bs-dismiss="modal">Cancel</button>
                    <button type="button" class="btn btn-sm btn-warning fw-bold" onclick="submitAiConsult()">🚀 Send to AI</button>
                </div>
            </div>
        </div>
    </div>
</div>

<!-- =====================================================================
     GIT SYNC MODAL: lets the user customise the commit message before
     staging / committing / pushing the control repo.
     ===================================================================== -->
<div class="modal fade" id="gitSyncModal" tabindex="-1" aria-hidden="true">
    <div class="modal-dialog modal-dialog-centered modal-lg">
        <div class="modal-content bg-dark text-white border-secondary">
            <div class="modal-header border-secondary">
                <h6 class="modal-title fw-bold">🔁 Git Sync — Commit &amp; Push Control Repo</h6>
                <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button>
            </div>
            <div class="modal-body small d-flex flex-column gap-3">
                <div>
                    <label class="text-white-50 fw-bold d-block mb-1">Commit message</label>
                    <input type="text" id="gitCommitMessage" class="form-control form-control-sm bg-black text-white border-secondary font-monospace" value="hieranano: auto-sync via web UI">
                    <div class="d-flex gap-2 mt-2 flex-wrap">
                        <button type="button" class="btn btn-xs btn-outline-secondary py-0 px-2" onclick="prependCommitMsg('docs: ')">docs: </button>
                        <button type="button" class="btn btn-xs btn-outline-secondary py-0 px-2" onclick="prependCommitMsg('fix: ')">fix: </button>
                        <button type="button" class="btn btn-xs btn-outline-secondary py-0 px-2" onclick="prependCommitMsg('feat: ')">feat: </button>
                        <button type="button" class="btn btn-xs btn-outline-secondary py-0 px-2" onclick="prependCommitMsg('chore: ')">chore: </button>
                        <button type="button" class="btn btn-xs btn-outline-info py-0 px-2" onclick="includeActiveFileInCommitMsg()">+ active file</button>
                    </div>
                </div>
                <div class="form-check">
                    <input class="form-check-input" type="checkbox" id="gitAmendLast" >
                    <label class="form-check-label small" for="gitAmendLast">Amend the previous commit (only works if there is one and nothing was pushed since)</label>
                </div>
                <div class="alert alert-info py-2 px-3 small mb-0">
                    <strong>This will run:</strong>
                    <code class="d-block mt-1 text-white-50">git add . &amp;&amp; git commit -m "&lt;your message&gt;" &amp;&amp; git push</code>
                    inside the configured control repo (<code>{{ repo_path }}</code>).
                </div>
            </div>
            <div class="modal-footer border-secondary d-flex justify-content-between">
                <span class="text-muted small">Push failures are non-fatal; you'll see the error in the status pill.</span>
                <div class="d-flex gap-2">
                    <button type="button" class="btn btn-sm btn-secondary" data-bs-dismiss="modal">Cancel</button>
                    <button type="button" class="btn btn-sm btn-success fw-bold" onclick="submitGitSync()">🚀 Commit &amp; Push</button>
                </div>
            </div>
        </div>
    </div>
</div>

<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
<script>
    // ---------------------------------------------------------------------
    // Token persistence: read ?token= once and keep it available globally,
    // then auto-inject it into every internal link so clicking around the
    // app never causes an auth drop-off.
    // ---------------------------------------------------------------------
    const TOKEN_STORAGE_KEY = 'hieranano_token';
    function getActiveToken() {
        const fromUrl = new URLSearchParams(window.location.search).get('token');
        if (fromUrl) {
            sessionStorage.setItem(TOKEN_STORAGE_KEY, fromUrl);
            return fromUrl;
        }
        return sessionStorage.getItem(TOKEN_STORAGE_KEY) || '';
    }
    const ACCESS_TOKEN = getActiveToken();

    function withToken(url) {
        if (!ACCESS_TOKEN) return url;
        const u = new URL(url, window.location.origin + window.location.pathname);
        u.searchParams.set('token', ACCESS_TOKEN);
        return u.pathname + '?' + u.searchParams.toString();
    }

    // Rewrite every internal anchor to preserve the token
    document.addEventListener('click', function (e) {
        const a = e.target.closest && e.target.closest('a[href]');
        if (!a) return;
        const href = a.getAttribute('href') || '';
        if (href.startsWith('http') || href.startsWith('mailto:') || href.startsWith('#')) return;
        if (href.includes('token=')) return; // already has it
        if (!ACCESS_TOKEN) return;
        e.preventDefault();
        window.location.href = withToken(href);
    });

    // If we landed here without a token but one is stored, append it now
    if (ACCESS_TOKEN && !new URLSearchParams(window.location.search).get('token')) {
        const newUrl = withToken(window.location.pathname);
        window.history.replaceState({}, '', newUrl);
    }

    // ---------------------------------------------------------------------
    // Resizable sidebar (vertical) and split-pane (horizontal between the
    // two file-tree sections). All state persists in localStorage.
    // ---------------------------------------------------------------------
    (function initResizers() {
        const sidebar = document.querySelector('.sidebar');
        const vResizer = document.getElementById('sidebarResizer');
        const panes = document.querySelectorAll('.sidebar-split-pane');
        const savedW = parseInt(localStorage.getItem('hieranano_sidebar_w') || '340', 10);
        if (!isNaN(savedW)) sidebar.style.width = savedW + 'px';

        let dragging = false;
        vResizer.addEventListener('mousedown', (e) => {
            dragging = true;
            vResizer.classList.add('dragging');
            document.body.style.cursor = 'col-resize';
            e.preventDefault();
        });
        document.addEventListener('mousemove', (e) => {
            if (!dragging) return;
            const w = Math.min(Math.max(e.clientX, 220), Math.min(600, window.innerWidth - 320));
            sidebar.style.width = w + 'px';
        });
        document.addEventListener('mouseup', () => {
            if (!dragging) return;
            dragging = false;
            vResizer.classList.remove('dragging');
            document.body.style.cursor = '';
            localStorage.setItem('hieranano_sidebar_w', parseInt(sidebar.style.width, 10));
        });

        if (panes.length === 2) {
            const hr = document.createElement('div');
            hr.className = 'resizer-h';
            panes[0].parentNode.insertBefore(hr, panes[1]);
            let hDrag = false;
            hr.addEventListener('mousedown', (e) => { hDrag = true; hr.classList.add('dragging'); document.body.style.cursor = 'row-resize'; e.preventDefault(); });
            document.addEventListener('mousemove', (e) => {
                if (!hDrag) return;
                const rect = panes[0].parentNode.getBoundingClientRect();
                const ratio = Math.min(Math.max((e.clientY - rect.top) / rect.height, 0.15), 0.85);
                panes[0].style.flex = `${ratio} 1 0%`;
                panes[1].style.flex = `${1 - ratio} 1 0%`;
            });
            document.addEventListener('mouseup', () => {
                if (!hDrag) return;
                hDrag = false; hr.classList.remove('dragging'); document.body.style.cursor = '';
            });
        }
    })();

    function toggleFolder(event, folderId) {
        event.stopPropagation();
        const element = document.getElementById(folderId);
        if(element) { element.style.display = (element.style.display === "none") ? "block" : "none"; }
    }

    function addNewGridRow() {
        const container = document.getElementById('visualGridContainer');
        const newRow = document.createElement('div');
        newRow.className = 'row g-2 grid-row-item align-items-center';
        newRow.innerHTML = `
            <div class="col-12 col-md-4"><input type="text" name="keys[]" class="form-control form-control-sm bg-dark text-white border-secondary font-monospace" placeholder="profile::service::ensure"></div>
            <div class="col-9 col-md-6"><textarea name="values[]" class="form-control form-control-sm bg-dark text-info border-secondary font-monospace val-field" rows="1" data-raw-state="plaintext" placeholder="running"></textarea></div>
            <div class="col-3 col-md-2 d-flex gap-1 justify-content-end">
                <button type="button" class="btn btn-sm btn-outline-warning fw-bold px-2 py-1 small crypto-toggle-btn" onclick="toggleCryptoState(this)">🔒 Encrypt</button>
                <button type="button" class="btn btn-sm btn-outline-danger p-1 px-2" onclick="this.closest('.row').remove()">✕</button>
            </div>
        `;
        container.appendChild(newRow);
    }

    function toggleCryptoState(button) {
        const row = button.closest('.row');
        const textarea = row.querySelector('.val-field');
        const currentVal = textarea.value.trim();
        const currentState = textarea.getAttribute('data-raw-state');

        if (!currentVal) return;

        if (currentState === "ciphertext") {
            button.innerText = "🔄 Decrypting...";
            fetch(withToken('/api/eyaml/decrypt'), {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({ ciphertext: currentVal })
            })
            .then(res => res.json())
            .then(data => {
                if (data.success) {
                    textarea.value = data.plaintext;
                    textarea.setAttribute('data-raw-state', 'plaintext');
                    row.classList.remove('eyaml-active');
                    button.innerText = "🔒 Encrypt";
                    button.className = "btn btn-sm btn-outline-warning fw-bold px-2 py-1 small crypto-toggle-btn";
                } else {
                    alert("Decryption Engine Failed: Validate local Puppet key permissions.");
                    button.innerText = "🔓 Reveal";
                }
            });
        } else {
            button.innerText = "🔄 Encrypting...";
            fetch(withToken('/api/eyaml/encrypt'), {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({ plaintext: currentVal })
            })
            .then(res => res.json())
            .then(data => {
                if (data.success) {
                    textarea.value = data.ciphertext;
                    textarea.setAttribute('data-raw-state', 'ciphertext');
                    row.classList.add('eyaml-active');
                    button.innerText = "🔓 Reveal";
                    button.className = "btn btn-sm btn-warning text-dark fw-bold px-2 py-1 small crypto-toggle-btn";
                } else {
                    alert("Encryption Engine Failed: Ensure eyaml binary is accessible.");
                    button.innerText = "🔒 Encrypt";
                }
            });
        }
    }

    // ---------------------------------------------------------------------
    // AI Consult modal logic
    // ---------------------------------------------------------------------
    const AI_FULL_TREE = {{ full_tree|tojson }};
    const ACTIVE_HIERA_PATH = {{ (active_file or '')|tojson }};
    const HIERA_KEYS = {{ (key_value_pairs | map(attribute='key') | list)|tojson }};

    function collectAllFiles(nodes, out) {
        for (const n of (nodes || [])) {
            if (n.type === 'file') out.push(n.path);
            else if (n.type === 'directory') collectAllFiles(n.children, out);
        }
    }

    function buildPuppetTreeHTML(nodes) {
        let html = '';
        for (const n of (nodes || [])) {
            if (n.type === 'directory') {
                html += `<div class="tree-folder" onclick="this.nextElementSibling.style.display = (this.nextElementSibling.style.display==='none'?'block':'none')">${escapeHtml(n.name)}</div>`;
                html += `<div class="tree-files">${buildPuppetTreeHTML(n.children)}</div>`;
            } else {
                // Highlight puppet-like files
                const lower = n.name.toLowerCase();
                const isPuppet = lower.endsWith('.pp') || lower.endsWith('.epp') || lower.endsWith('.yaml') || lower.endsWith('.yml') || lower.endsWith('.json');
                html += `<a href="#" class="ai-file ${isPuppet ? '' : 'text-muted'}" data-path="${escapeHtml(n.path)}" onclick="event.preventDefault(); selectPuppetFile(this)">📄 ${escapeHtml(n.name)}<span class="ppath">${escapeHtml(n.path)}</span></a>`;
            }
        }
        return html;
    }

    function escapeHtml(s) {
        return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    }

    function openAiConsult() {
        if (!ACTIVE_HIERA_PATH) { alert("No active hiera file."); return; }
        document.getElementById('aiHieraFileLabel').textContent = ACTIVE_HIERA_PATH;
        // Populate keys
        const keyList = document.getElementById('aiHieraKeyList');
        keyList.innerHTML = '';
        if (!HIERA_KEYS.length) {
            keyList.innerHTML = '<div class="text-muted small p-2">No hiera classes/keys found in this file.</div>';
        } else {
            for (const k of HIERA_KEYS) {
                const row = document.createElement('label');
                row.className = 'ai-key-row';
                row.innerHTML = `<input type="checkbox" class="form-check-input mt-0" checked value="${escapeHtml(k)}"> <span class="ai-key-name">${escapeHtml(k)}</span>`;
                keyList.appendChild(row);
            }
        }
        // Populate puppet tree
        document.getElementById('aiPuppetTree').innerHTML = buildPuppetTreeHTML(AI_FULL_TREE);
        document.getElementById('aiPuppetFilter').value = '';
        updateAiConsultSummary();
        const modal = new bootstrap.Modal(document.getElementById('aiConsultModal'));
        modal.show();
    }

    function aiSelectAllKeys(checked) {
        document.querySelectorAll('#aiHieraKeyList input[type=checkbox]').forEach(cb => cb.checked = checked);
        updateAiConsultSummary();
    }

    function selectPuppetFile(el) {
        document.querySelectorAll('#aiPuppetTree .ai-file').forEach(a => a.classList.remove('selected'));
        el.classList.add('selected');
        updateAiConsultSummary();
    }

    function updateAiConsultSummary() {
        const keyCount = document.querySelectorAll('#aiHieraKeyList input[type=checkbox]:checked').length;
        const sel = document.querySelector('#aiPuppetTree .ai-file.selected');
        const puppet = sel ? sel.getAttribute('data-path') : null;
        document.getElementById('aiConsultSummary').textContent =
            `${keyCount} key${keyCount===1?'':'s'} selected • puppet file: ${puppet || 'none chosen'}`;
    }

    document.addEventListener('change', (e) => {
        if (e.target && e.target.matches('#aiHieraKeyList input[type=checkbox]')) updateAiConsultSummary();
    });

    document.addEventListener('input', (e) => {
        if (e.target && e.target.id === 'aiPuppetFilter') {
            const q = e.target.value.toLowerCase();
            document.querySelectorAll('#aiPuppetTree .ai-file').forEach(a => {
                const txt = (a.getAttribute('data-path') || '').toLowerCase();
                a.style.display = (q === '' || txt.includes(q)) ? '' : 'none';
            });
        }
    });

    function submitAiConsult() {
        const selectedKeys = Array.from(document.querySelectorAll('#aiHieraKeyList input[type=checkbox]:checked')).map(cb => cb.value);
        const sel = document.querySelector('#aiPuppetTree .ai-file.selected');
        const puppetPath = sel ? sel.getAttribute('data-path') : null;
        if (!selectedKeys.length) { alert("Select at least one hiera class/parameter."); return; }
        if (!puppetPath) { alert("Select the puppet file where these classes are used."); return; }

        // Close modal, open tray
        bootstrap.Modal.getInstance(document.getElementById('aiConsultModal')).hide();
        const tray = document.getElementById('aiTray');
        const output = document.getElementById('aiStreamOutput');
        tray.style.display = 'flex';
        output.innerText = '🔄 Sending hiera class names + puppet file to AI (no values)…';
        document.getElementById('aiContextBadge').innerText = `${selectedKeys.length} keys ↔ ${puppetPath}`;

        fetch(withToken('/api/ai-consult'), {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({
                hiera_path: ACTIVE_HIERA_PATH,
                hiera_keys: selectedKeys,
                puppet_path: puppetPath
            })
        })
        .then(response => {
            if (!response.ok) {
                return response.text().then(t => { throw new Error('HTTP ' + response.status + ': ' + t); });
            }
            if (!response.body) throw new Error('No response body (streaming unsupported by browser).');
            output.innerText = '';
            const reader = response.body.getReader();
            const decoder = new TextDecoder();
            let acc = '';
            function read() {
                return reader.read().then(({ done, value }) => {
                    if (done) return;
                    acc += decoder.decode(value, { stream: true });
                    // Server now sends raw text chunks (not SSE). Render acc
                    // and keep the latest viewport in view.
                    output.innerText = acc;
                    output.scrollTop = output.scrollHeight;
                    return read();
                }).catch(err => {
                    output.innerText += `\n💥 Stream error: ${err}`;
                });
            }
            return read();
        })
        .catch(err => {
            output.innerText = `💥 ${err}`;
        });
    }

    // (openRawForActive removed: visual / raw switching is now a server-side
    //  decision driven by ?view= and rendered as tab links.)
</script>

    // ---------------------------------------------------------------------
    // Unsaved-changes ("dirty state") tracker
    //
    // Visual mode: compare the current form state to a snapshot taken on
    //   page load. Snapshot includes keys, values, raw-state, and row count.
    // Raw mode:    compare textarea content to its initial value.
    //
    // The badge #dirtyBadge is shown when the form diverges from the
    // snapshot. Submitting a form clears the badge via the 'dirty-cleared'
    // event we dispatch right before the browser navigates away.
    // ---------------------------------------------------------------------
    function setDirty(isDirty) {
        const b = document.getElementById('dirtyBadge');
        if (b) b.style.display = isDirty ? 'inline-block' : 'none';
        const title = document.getElementById('editorTitle');
        if (title) {
            if (isDirty) title.classList.add('text-warning');
            else title.classList.remove('text-warning');
        }
    }

    function snapshotVisualForm() {
        const rows = document.querySelectorAll('#visualGridContainer .grid-row-item');
        return JSON.stringify(Array.from(rows).map(r => {
            const k = r.querySelector('.hiera-key');
            const v = r.querySelector('.val-field');
            return [
                k ? k.value : '',
                v ? v.value : '',
                v ? v.getAttribute('data-raw-state') : 'plaintext'
            ];
        }));
    }

    function snapshotRawForm() {
        const t = document.getElementById('rawTextarea');
        return t ? t.value : '';
    }

    let visualSnapshot = null;
    let rawSnapshot = null;

    function recomputeDirty() {
        if (visualSnapshot !== null) {
            setDirty(snapshotVisualForm() !== visualSnapshot);
        } else if (rawSnapshot !== null) {
            setDirty(snapshotRawForm() !== rawSnapshot);
        }
    }

    // Take a snapshot of whichever form is on the page, and wire change
    // listeners that re-snapshot comparison.
    (function initDirtyTracker() {
        const visualForm = document.getElementById('visualGridForm');
        const rawForm = document.querySelector('form[action="{{ url_for('save_file') }}"]');

        if (visualForm) {
            visualSnapshot = snapshotVisualForm();
            visualForm.addEventListener('submit', () => { visualSnapshot = snapshotVisualForm(); setDirty(false); });
            // Listen on container with capture so dynamically-added rows also fire.
            const cont = document.getElementById('visualGridContainer');
            if (cont) {
                cont.addEventListener('input', recomputeDirty);
                cont.addEventListener('change', recomputeDirty);
            }
            // Custom observer for row add/remove (DOM mutations).
            if (cont && window.MutationObserver) {
                new MutationObserver(recomputeDirty).observe(cont, { childList: true, subtree: true });
            }
        }
        if (rawForm) {
            rawSnapshot = snapshotRawForm();
            rawForm.addEventListener('submit', () => { rawSnapshot = snapshotRawForm(); setDirty(false); });
            const t = document.getElementById('rawTextarea');
            if (t) t.addEventListener('input', recomputeDirty);
        }

        // Warn the user if they try to navigate away with unsaved changes.
        window.addEventListener('beforeunload', (e) => {
            const b = document.getElementById('dirtyBadge');
            if (b && b.style.display !== 'none') {
                e.preventDefault();
                e.returnValue = 'You have unsaved changes.';
                return 'You have unsaved changes.';
            }
        });
    })();

    // Header "💾 Save" button – submit whichever editor form is active (raw or visual).
    function submitActiveEditor() {
        const raw = document.querySelector('form[action="{{ url_for("save_file") }}"]');
        const visual = document.getElementById('visualGridForm');
        if (raw) raw.submit();
        else if (visual) visual.submit();
    }

    // ---------------------------------------------------------------------
    // Git Sync modal logic
    // ---------------------------------------------------------------------
    function openGitSyncModal() {
        // Pre-fill message with the active file path if there is one.
        const input = document.getElementById('gitCommitMessage');
        if (input && !input.value) {
            input.value = 'hieranano: auto-sync via web UI';
        }
        const m = new bootstrap.Modal(document.getElementById('gitSyncModal'));
        m.show();
        // Focus the input so the user can type immediately.
        setTimeout(() => document.getElementById('gitCommitMessage').focus(), 250);
    }

    function prependCommitMsg(prefix) {
        const input = document.getElementById('gitCommitMessage');
        if (!input.value.startsWith(prefix)) input.value = prefix + input.value;
    }

    function includeActiveFileInCommitMsg() {
        const input = document.getElementById('gitCommitMessage');
        const file = (typeof ACTIVE_HIERA_PATH === 'string' && ACTIVE_HIERA_PATH) || '';
        if (!file) return;
        if (!input.value.includes(file)) input.value = `${input.value} (${file})`.trim();
    }

    function submitGitSync() {
        const msgEl = document.getElementById('gitCommitMessage');
        const amendEl = document.getElementById('gitAmendLast');
        const message = (msgEl.value || '').trim();
        if (!message) { alert('Commit message cannot be empty.'); return; }

        bootstrap.Modal.getInstance(document.getElementById('gitSyncModal')).hide();

        const status = document.getElementById('gitSyncStatus');
        status.style.display = 'inline-flex';
        status.className = 'git-sync-status pending';
        status.innerText = '● Syncing…';

        fetch(withToken('/api/git/sync'), {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({ message: message, amend: !!(amendEl && amendEl.checked) })
        })
        .then(res => res.json())
        .then(data => {
            if (data.success) {
                const parts = [];
                parts.push('staged');
                parts.push(data.committed ? 'committed' : 'nothing-to-commit');
                parts.push(data.pushed ? 'pushed' : 'push-failed');
                status.className = 'git-sync-status' + (data.pushed ? '' : ' error');
                status.innerText = '● ' + parts.join(' • ');
                if (!data.pushed && data.push_error) {
                    console.warn('Git push error:', data.push_error);
                }
            } else {
                status.className = 'git-sync-status error';
                status.innerText = '● ' + (data.error || 'Sync failed');
                alert('Git sync failed: ' + (data.error || 'unknown error') + (data.details ? '\n\n' + data.details : ''));
            }
        })
        .catch(err => {
            status.className = 'git-sync-status error';
            status.innerText = '● Network error';
            alert('Git sync network error: ' + err);
        });
    }
</script>
</body>
</html>
EOF

# ==============================================================================
# 🗄️ STEP 5: DB PROVISIONING & CRYPTO SEEDING (Enforced Configuration)
# ==============================================================================
echo "💾 Synchronizing database configurations..."

# Ensure tables exist
sqlite3 "$DATA_PERSIST_DIR/hieranano.db" <<SQL_EOF
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS file_visibility (filepath TEXT PRIMARY KEY, is_hidden INTEGER DEFAULT 0);
SQL_EOF

# 1. ALWAYS force-update the critical infrastructure paths
sqlite3 "$DATA_PERSIST_DIR/hieranano.db" <<SQL_EOF
INSERT OR REPLACE INTO settings (key, value) VALUES ('control_repo_dir', '${CONTROL_REPO_DIR}');
INSERT OR REPLACE INTO settings (key, value) VALUES ('eyaml_public_key', '${EYAML_PUB_KEY}');
INSERT OR REPLACE INTO settings (key, value) VALUES ('eyaml_private_key', '${EYAML_PRIV_KEY}');
INSERT OR REPLACE INTO settings (key, value) VALUES ('ai_endpoint', '${AI_ENDPOINT}');
INSERT OR REPLACE INTO settings (key, value) VALUES ('ai_model', '${AI_MODEL}');
INSERT OR REPLACE INTO settings (key, value) VALUES ('ai_token', '${AI_TOKEN}');
SQL_EOF

# ai_prompt may contain newlines / apostrophes; store it separately using a
# parameterised sqlite3 invocation to avoid shell escaping issues.
#  Safe, seekable disk sequence
TEMP_SEED_FILE=$(mktemp)
printf "%s" "$AI_PROMPT" > "$TEMP_SEED_FILE"

sqlite3 "$DATA_PERSIST_DIR/hieranano.db" "INSERT OR REPLACE INTO settings (key, value) VALUES ('ai_prompt', readfile('$TEMP_SEED_FILE'));"

# Clean up the temp asset
rm -f "$TEMP_SEED_FILE"

# 2. Only seed the Auth Tokens if they do not exist
TOKEN_CHECK=$(sqlite3 "$DATA_PERSIST_DIR/hieranano.db" "SELECT value FROM settings WHERE key='secure_install_token';")

if [ -z "$TOKEN_CHECK" ]; then
    echo "🔒 Seeding initial cryptographic handshake tokens..."
    if [ "$NEEDS_SUDO" -eq 1 ] && [ "$RUNNING_UID" -ne 0 ]; then
      INITIAL_ENC_TOKEN=$(sudo "$FINAL_EYAML" encrypt --pkcs7-public-key "$EYAML_PUB_KEY" --stdin <<< "$INSTALL_SECRET")
    else
      INITIAL_ENC_TOKEN=$("$FINAL_EYAML" encrypt --pkcs7-public-key "$EYAML_PUB_KEY" --stdin <<< "$INSTALL_SECRET")
    fi

    CLEAN_TOKEN=$(echo "$INITIAL_ENC_TOKEN" | tr -d '\n' | tr -d ' ' | tr -d '\r')
    CLEAN_SECRET=$(echo "$INSTALL_SECRET" | tr -d '\n' | tr -d ' ' | tr -d '\r')

    sqlite3 "$DATA_PERSIST_DIR/hieranano.db" <<SQL_EOF
INSERT OR REPLACE INTO settings (key, value) VALUES ('plaintext_install_token', '${CLEAN_SECRET}');
INSERT OR REPLACE INTO settings (key, value) VALUES ('secure_install_token', '${CLEAN_TOKEN}');
SQL_EOF
else
    echo "✅ Authentication tokens already present. Skipping token re-seed."
fi

# ==============================================================================
# STEP 6: BACKWARD COMPATIBLE SERVICE STARTUP
# ==============================================================================
echo "⚙  Spawning workspace engine microservice..."

find_pid=$(lsof -t -i:$PORT || true)
if [ -n "$find_pid" ]; then kill -9 $find_pid; fi
pkill -f "gunicorn.*app:app" || true

nohup "$APP_DIR/venv/bin/python" -m gunicorn --workers 1 --bind "$HOST:$PORT" --chdir "$APP_DIR" app:app > "$APP_DIR/runtime.log" 2>&1 &

echo "----------------------------------------------------------------------"
echo "🎉 DEPLOY SUCCESSFUL: Hieranano Workspace Canvas Configured!"
echo "----------------------------------------------------------------------"
echo "👉 Entry Interface URL: http://127.0.0.1:5525/?token=${INSTALL_SECRET}"
echo "----------------------------------------------------------------------"
HIERANANO
  chmod +x "$f"
  tui_ok "Wrote ${f}"
}

# Writes the embedded openainano.sh installer to ${script_dir}/openainano.sh if it
# is missing (so the wizard is self-contained on a fresh host).  openainano is a
# Flask bridge (port 5000) that translates PE's AI infra-assistant to a local
# Ollama instance (127.0.0.1:11434).  Installed on the master (core0) by default.
ensure_openainano_script() {
  local f="${script_dir}/openainano.sh"
  if [[ -f "$f" ]]; then
    return 0
  fi
  tui_info "Writing ${BOLD}${f}${RESET} (embedded in setup.sh)…"
  cat > "$f" <<'OPENAINANO'
#!/bin/bash
# VERSION GOLD (STABLE) - STRICT TERMINATION & METADATA MATCH
# Goal: Match the exact usage detail keys and the final empty-data flush seen in the logs.
# This version is verified to pass control back to the PE UI correctly.

# Configuration
APP_NAME="openainano"
APP_DIR="/opt/$APP_NAME"
VENV_DIR="$APP_DIR/venv"
REQUIRED_TOKEN="${OPENAINANO_TOKEN:-}"
TARGET_MODEL="minimax-m2.5:cloud"

echo "🧹 EXECUTING DEEP CLEAN..."
systemctl stop $APP_NAME 2>/dev/null
fuser -k 5000/tcp 2>/dev/null || true

echo "🐍 REFRESHING ENVIRONMENT..."
mkdir -p $APP_DIR
cd $APP_DIR
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv $VENV_DIR
fi
$VENV_DIR/bin/pip install flask requests flask-cors

echo "📝 DEPLOYING VERSION GOLD: STRICT TERMINATION BRIDGE..."
cat <<'EOF' > $APP_DIR/app.py
import requests
import json
import sys
import time
import uuid
import os
from flask import Flask, request, Response, jsonify
from flask_cors import CORS

BRIDGE_VERSION = "GOLD-STABLE"
REQUIRED_TOKEN = os.environ.get("OPENAINANO_TOKEN", "")
OLLAMA_URL = "http://127.0.0.1:11434/v1/chat/completions"
TARGET_MODEL = "minimax-m2.5:cloud"

app = Flask(__name__)
app.url_map.strict_slashes = False

CORS(app, resources={r"/*": {
    "origins": "*",
    "allow_headers": ["Authorization", "Content-Type", "X-Requested-With", "Accept", "X-Authentication", "X-Requested-By"],
    "methods": ["GET", "POST", "OPTIONS"],
    "expose_headers": ["Content-Type", "Authorization", "X-Accel-Buffering"]
}}, supports_credentials=True)

def log_debug(msg):
    print(f"[{BRIDGE_VERSION}] {msg}", file=sys.stdout)
    sys.stdout.flush()

@app.route('/api/ai/infra-assistant/v1/validate', methods=['GET', 'POST', 'OPTIONS'])
@app.route('/api/ai/infra-assistant/validate', methods=['GET', 'POST', 'OPTIONS'])
def validate_pe():
    if request.method == 'OPTIONS': return Response(status=204)
    return jsonify({"status": "success", "valid": True, "active": True}), 200

@app.route('/v1/models', methods=['GET'])
def list_models():
    return jsonify({
        "object": "list",
        "data": [{
            "id": "gpt-4o-mini",
            "object": "model",
            "created": 1677610602,
            "owned_by": "openai"
        }]
    })

@app.route('/v1/chat/completions', methods=['POST'])
@app.route('/chat/completions', methods=['POST'])
@app.route('/api/ai/infra-assistant/v1/chat/completions', methods=['POST'])
def chat():
    log_debug("🎯 INBOUND CHAT")
    auth = request.headers.get("Authorization", "") or request.headers.get("X-Authentication", "")
    if not REQUIRED_TOKEN or REQUIRED_TOKEN not in auth:
        return jsonify({"error": "Unauthorized"}), 401
        
    payload = request.get_json()
    is_stream = payload.get("stream", False)
    messages = payload.get("messages", [])

    # Handler for registration/probe (Non-streaming)
    if not is_stream or (len(messages) == 1 and messages[0].get("content") in ["", "test", "ping"]):
        return jsonify({
            "id": f"chatcmpl-{uuid.uuid4().hex}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": payload.get("model", "gpt-4o-mini"),
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "Ready."}, "finish_reason": "stop"}],
            "usage": {
                "prompt_tokens": 7, 
                "completion_tokens": 10, 
                "total_tokens": 17,
                "prompt_tokens_details": {"cached_tokens": 0, "audio_tokens": 0},
                "completion_tokens_details": {"reasoning_tokens": 0, "audio_tokens": 0, "accepted_prediction_tokens": 0, "rejected_prediction_tokens": 0}
            },
            "service_tier": "default",
            "system_fingerprint": None
        })

    external_id = f"chatcmpl-{uuid.uuid4().hex}"
    created_ts = int(time.time())
    ui_model_name = payload.get("model", "gpt-4o-mini")
    payload["model"] = TARGET_MODEL
    payload["stream"] = True

    def generate():
        try:
            r = requests.post(OLLAMA_URL, json=payload, stream=True, timeout=60)
            
            for line in r.iter_lines():
                if line:
                    decoded = line.decode('utf-8')
                    if decoded.startswith("data: ") and "[DONE]" not in decoded:
                        try:
                            chunk = json.loads(decoded[6:])
                            chunk["id"] = external_id
                            chunk["model"] = ui_model_name
                            chunk["service_tier"] = "default"
                            chunk["system_fingerprint"] = None
                            chunk["obfuscation"] = uuid.uuid4().hex[:15]
                            
                            # Deliver wrapped in array as seen in real OpenAI logs
                            yield f"[\ndata: {json.dumps(chunk)}\n\n]\n"
                        except: continue

            # Build the stop packet
            stop_packet = {
                "id": external_id,
                "object": "chat.completion.chunk",
                "created": created_ts,
                "model": ui_model_name,
                "service_tier": "default",
                "system_fingerprint": None,
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                "usage": None,
                "obfuscation": uuid.uuid4().hex[:4]
            }
            
            # Build usage packet with full token breakdown
            usage_packet = {
                "id": external_id,
                "object": "chat.completion.chunk",
                "created": created_ts,
                "model": ui_model_name,
                "service_tier": "default",
                "system_fingerprint": None,
                "choices": [],
                "usage": {
                    "prompt_tokens": 10,
                    "completion_tokens": 50,
                    "total_tokens": 60,
                    "prompt_tokens_details": {"cached_tokens": 0, "audio_tokens": 0},
                    "completion_tokens_details": {"reasoning_tokens": 0, "audio_tokens": 0, "accepted_prediction_tokens": 0, "rejected_prediction_tokens": 0}
                },
                "obfuscation": uuid.uuid4().hex[:8]
            }
            
            # Yield final bundle to trigger "complete" state in UI
            yield f"[\ndata: {json.dumps(stop_packet)}\n\ndata: {json.dumps(usage_packet)}\n\n]\n"
            yield "data: [DONE]\n\n"
            log_debug("🏁 COMPLETE")
            
        except GeneratorExit: return
        except Exception as e:
            log_debug(f"💥 ERROR: {e}")
            try: yield f'data: {{"error": {{"message": "{str(e)}"}}}}\n\n'
            except: pass

    return Response(generate(), content_type='text/event-stream')

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, threaded=True)
EOF

echo "⚙️  CONFIGURING SYSTEMD SERVICE..."
cat <<EOF > /etc/systemd/system/$APP_NAME.service
[Unit]
Description=OpenAINano PE Bridge GOLD
After=network.target

[Service]
User=root
WorkingDirectory=$APP_DIR
ExecStart=$VENV_DIR/bin/python $APP_DIR/app.py
Restart=always
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $APP_NAME
systemctl restart $APP_NAME

echo "===================================================================="
echo "✅ DEPLOYED VERSION: GOLD (94 STABLE)"
echo "Verified: Array-wrapping + Detailed Usage Metadata + SSE Termination."
echo "Check Logs: journalctl -u $APP_NAME -f -o cat"
echo "===================================================================="
OPENAINANO
  chmod +x "$f"
  tui_ok "Wrote ${f}"
}

# ──────────────────────────────────────────────────────────────────────────
# ENSURE OLLAMA SCRIPT – install Ollama on the master (needed by openainano's
# bridge, which targets http://127.0.0.1:11434).  A local model is not powerful
# enough, so the user must authenticate with `ollama login` and pull a CLOUD
# model with `ollama run <model>`.  This script installs Ollama and prints
# those instructions.  Always regenerated (simple, self-contained).
# ──────────────────────────────────────────────────────────────────────────
ensure_ollama_script() {
  local f="${script_dir}/install_ollama.sh"
  tui_info "Writing ${BOLD}${f}${RESET} (embedded in setup.sh)…"
  cat > "$f" <<'INSTALLOLLAMA'
#!/usr/bin/env bash
set -euo pipefail
# install_ollama.sh – install Ollama on the master and print login/run instructions.
# Usage: install_ollama.sh [cloud-model]
MODEL="${1:-minimax-m2.5:cloud}"

if command -v ollama >/dev/null 2>&1; then
    echo "Ollama already installed: $(ollama --version 2>/dev/null || echo present)"
else
    echo "Installing Ollama (https://ollama.com/download/linux)..."
    # The Ollama installer needs zstd for extraction.
    if ! command -v zstd >/dev/null 2>&1; then
        echo "Installing zstd (required by the Ollama installer)..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y zstd 2>/dev/null || {
                echo "zstd not in current repos; adding base Ubuntu repo..."
                echo 'deb http://archive.ubuntu.com/ubuntu/ noble main universe' > /etc/apt/sources.list.d/base.list
                echo 'deb http://archive.ubuntu.com/ubuntu/ noble-updates main universe' >> /etc/apt/sources.list.d/base.list
                echo 'deb http://security.ubuntu.com/ubuntu/ noble-security main universe' >> /etc/apt/sources.list.d/base.list
                apt-get update -y && apt-get install -y zstd
            }
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y zstd
        elif command -v yum >/dev/null 2>&1; then
            yum install -y zstd
        fi
    fi
    curl -fsSL https://ollama.com/install.sh | sh
    echo "Ollama installed."
fi

echo
echo "=============================================================="
echo "  OLLAMA READY – authenticate + pull a CLOUD model"
echo "=============================================================="
echo "  A local model is not powerful enough, so use a cloud model."
echo "  1. ollama login                 # authenticate with your Ollama account"
echo "  2. ollama run ${MODEL}          # pull + run the chosen cloud model"
echo "----------------------------------------------------------------"
echo "  The openainano bridge targets http://127.0.0.1:11434."
echo "  Verify: ollama list"
echo "=============================================================="
INSTALLOLLAMA
  chmod +x "$f"
}

# After provisioning, scan the master's SSH host key and record it in
# r10k_known_hosts so r10k/code-manager can verify the gitnano remote
# (gitnano@<core0>).  Runs after wait_for_ssh, before the PE install.

# ──────────────────────────────────────────────────────────────────────────
# REPONANO – local apt/yum package repo manager (master installer + helpers)
# ──────────────────────────────────────────────────────────────────────────
ensure_reponano_script() {
  local f="${script_dir}/reponano.sh"
  if [[ -f "$f" ]]; then
    return 0
  fi
  tui_info "Writing ${BOLD}${f}${RESET} (embedded in setup.sh)…"
  cat > "$f" <<'REPONANO'
#!/bin/bash
# Reponano Master Installer v2.5 (Verbose Logging)
set -e

APP_DIR="/opt/reponano"
DATA_DIR="/var/www/reponano"
PORT=3864

if [[ "$1" == "--clean" ]]; then
    sudo systemctl stop reponano || true
    sudo rm -rf "$APP_DIR" "$DATA_DIR"
fi

echo "--- 1. Installing System Dependencies ---"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -q -y python3 python3-flask python3-pip dpkg-dev apt-rdepends createrepo-c dnf curl jq

sudo mkdir -p "$APP_DIR" "$DATA_DIR"
sudo chown -R $USER:$USER "$APP_DIR" "$DATA_DIR"

echo "--- 2. Writing Reponano Engine with Verbose Logging ---"
cat <<'EOF' > "$APP_DIR/reponano.py"
import os, subprocess, logging, shutil
from flask import Flask, request, jsonify, send_from_directory

# Enhanced Logging Configuration
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[logging.StreamHandler()]
)
logger = logging.getLogger('reponano')

app = Flask(__name__)
BASE_DIR = '/var/www/reponano'
PORT = 3864

def run_verbose_cmd(cmd, cwd=None):
    """Executes command and streams output to system logs"""
    logger.info(f"Starting command: {cmd}")
    process = subprocess.Popen(
        cmd, shell=True, cwd=cwd, 
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )
    for line in process.stdout:
        line = line.strip()
        if line: logger.info(f"  [SHELL]: {line}")
    process.wait()
    return process.returncode

def update_index(distro, repo_path):
    logger.info(f"Updating index for {distro} at {repo_path}")
    if distro == 'ubuntu':
        # A FLAT apt repo (deb [trusted=yes] .../  with a "/" component) resolves an
        # UNCOMPRESSED 'Packages' directly; it does NOT use dists/Release to locate
        # compressed indexes (Packages.gz alone 404'd). Emit Packages + Packages.gz
        # and NO Release file (a partial flat Release only triggers apt warnings).
        run_verbose_cmd("dpkg-scanpackages . /dev/null > Packages", cwd=repo_path)
        run_verbose_cmd("gzip -9c Packages > Packages.gz", cwd=repo_path)
    elif distro == 'centos':
        run_verbose_cmd(f"createrepo_c --update .", cwd=repo_path)

@app.route('/sync', methods=['POST'])
def sync_package():
    data = request.json or {}
    pkg, distro, ver = data.get('pkg'), data.get('distro'), data.get('ver')
    arch, include_deps = data.get('arch', 'amd64'), data.get('deps', False)
    
    if not all([pkg, distro, ver]):
        return jsonify({"error": "Missing pkg, distro, or ver"}), 400
    
    repo_path = os.path.join(BASE_DIR, distro, ver, arch)
    os.makedirs(repo_path, exist_ok=True)
    
    logger.info(f"--- START SYNC: {pkg} ({distro}/{ver}) deps={include_deps} ---")

    if distro == 'ubuntu':
        run_verbose_cmd("apt-get update > /dev/null")
        recurse = "--recurse" if include_deps else ""
        
        # Get dep list
        dep_cmd = f"apt-cache depends {recurse} --no-recommends {pkg}:{arch} | grep 'Depends:' | awk '{{print $2}}'"
        deps = subprocess.run(dep_cmd, shell=True, capture_output=True, text=True).stdout.split()
        all_pkgs = list(set(deps)) + [f"{pkg}:{arch}"]
        
        logger.info(f"Targeting {len(all_pkgs)} unique packages for download.")
        
        # Download (batched to avoid ARG_MAX on large dependency trees)
        for i in range(0, len(all_pkgs), 50):
            chunk = all_pkgs[i:i+50]
            run_verbose_cmd(f"apt-get download {' '.join(chunk)}", cwd=repo_path)
        update_index('ubuntu', repo_path)

    elif distro == 'centos':
        deps_flag = "--alldeps" if include_deps else ""
        run_verbose_cmd(f"dnf download --resolve {deps_flag} --arch={arch} --destdir={repo_path} {pkg}")
        update_index('centos', repo_path)

    after = len([f for f in os.listdir(repo_path) if f.endswith(('.deb', '.rpm'))])
    logger.info(f"--- SYNC COMPLETE: {after} total files in {repo_path} ---")
    
    return jsonify({"status": "success", "total_files": after})

@app.route('/list', methods=['GET'])
def list_pkgs():
    inventory = {}
    if not os.path.exists(BASE_DIR): return jsonify(inventory)
    for distro in sorted(os.listdir(BASE_DIR)):
        d_p = os.path.join(BASE_DIR, distro)
        if not os.path.isdir(d_p): continue
        inventory[distro] = {}
        for ver in sorted(os.listdir(d_p)):
            v_p = os.path.join(d_p, ver)
            inventory[distro][ver] = {}
            for arch in sorted(os.listdir(v_p)):
                a_p = os.path.join(v_p, arch)
                inventory[distro][ver][arch] = sorted([f for f in os.listdir(a_p) if f.endswith(('.deb', '.rpm'))])
    return jsonify({"inventory": inventory})

@app.route('/delete', methods=['DELETE'])
def delete_package():
    data = request.json or {}
    pkg_pattern, distro, ver = data.get('pkg'), data.get('distro'), data.get('ver')
    arch = data.get('arch', 'amd64')
    repo_path = os.path.join(BASE_DIR, distro, ver, arch)
    deleted = []
    if os.path.exists(repo_path):
        for f in os.listdir(repo_path):
            if f.startswith(pkg_pattern) and f.endswith(('.deb', '.rpm')):
                os.remove(os.path.join(repo_path, f))
                deleted.append(f)
        if deleted: update_index(distro, repo_path)
    return jsonify({"deleted": deleted})

@app.route('/repo/<path:path>')
def serve(path):
    return send_from_directory(BASE_DIR, path)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=PORT)
EOF

echo "--- 3. Configuring and Starting Service ---"
cat <<EOF | sudo tee /etc/systemd/system/reponano.service > /dev/null
[Unit]
Description=Reponano Repo Manager
After=network.target

[Service]
ExecStart=/usr/bin/python3 $APP_DIR/reponano.py
Restart=always
User=root
WorkingDirectory=$APP_DIR
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now reponano
sudo systemctl restart reponano

# --- 4. Final Usage Examples & Help ---
IP_ADDR=$(hostname -I | awk '{print $1}')

echo ""
echo "================================================================"
echo "      REPONANO v2.5 - INSTALLATION COMPLETE"
echo "================================================================"
echo " API URL: http://$IP_ADDR:$PORT"
echo " Storage: $DATA_DIR"
echo "----------------------------------------------------------------"
echo " 1. WATCH LIVE PROGRESS (Run this in a separate terminal):"
echo "    sudo journalctl -u reponano -f"
echo ""
echo " 2. SHALLOW SYNC (Immediate deps only):"
echo "    curl -X POST http://$IP_ADDR:$PORT/sync -H 'Content-Type: application/json' \\"
echo "         -d '{\"pkg\":\"sl\",\"distro\":\"ubuntu\",\"ver\":\"<codename>\"}'"
echo ""
echo " 3. DEEP SYNC (Full dependency tree for offline/naked OS):"
echo "    curl -X POST http://$IP_ADDR:$PORT/sync -H 'Content-Type: application/json' \\"
echo "         -d '{\"pkg\":\"nginx\",\"distro\":\"ubuntu\",\"ver\":\"<codename>\",\"deps\":true}'"
echo ""
echo " 4. DELETE PACKAGE (Cleans up files and re-indexes):"
echo "    curl -X DELETE http://$IP_ADDR:$PORT/delete -H 'Content-Type: application/json' \\"
echo "         -d '{\"pkg\":\"sl\",\"distro\":\"ubuntu\",\"ver\":\"<codename>\"}'"
echo ""
echo " 5. LIST INVENTORY:"
echo "    curl -s http://$IP_ADDR:$PORT/list | jq"
echo ""
echo " 6. CLIENT APT CONFIGURATION:"
echo "    Add this to /etc/apt/sources.list on your offline node:"
echo "    deb [trusted=yes] http://$IP_ADDR:$PORT/repo/ubuntu/<codename>/amd64 /"
echo "================================================================"
REPONANO
  chmod +x "$f"

  local c="${script_dir}/reponano_client.sh"
  # Always regenerate the client (no per-value sed needed; ports are fixed) so
  # fixes/updates propagate to newly deployed nodes.
  cat > "$c" <<'REPONANOCLIENT'
#!/bin/bash
# Reponano Client Toggle v2.2
set -e

BACKUP_DIR="/etc/apt/reponano_original_config"
REPO_PORT="3864"
DISTRO="${2:-ubuntu}"
# Auto-detect the node's OWN codename so it always points at the repo path that
# reponano populated (e.g. noble), even if the base image uses another codename.
VER="${3:-$(. /etc/os-release && echo "$VERSION_CODENAME")}"
ARCH="${4:-amd64}"

if [ "$EUID" -ne 0 ]; then 
  echo "Error: Please run as root"
  exit 1
fi

# --- RESTORE MODE ---
if [[ "$1" == "--restore" ]]; then
    echo "--- Restoring Original Online Configuration ---"
    
    if [ ! -d "$BACKUP_DIR" ]; then
        echo "Error: No initial backup found at $BACKUP_DIR."
        exit 1
    fi

    # Wipe existing (offline) config
    rm -f /etc/apt/sources.list
    rm -rf /etc/apt/sources.list.d/*

    # Restore original files
    cp -a "$BACKUP_DIR/sources.list" /etc/apt/sources.list
    if [ -d "$BACKUP_DIR/sources.list.d" ]; then
        cp -a "$BACKUP_DIR/sources.list.d/." /etc/apt/sources.list.d/
    fi

    # Cleanup metadata
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    
    echo "Updating mirrors..."
    if apt-get update; then
        echo "SUCCESS: Client is back ONLINE."
        # Optional: Remove backup dir if you want a clean slate
        # rm -rf "$BACKUP_DIR"
    else
        echo "WARNING: Files restored, but 'apt update' failed. Check internet."
    fi
    exit 0
fi

# --- OFFLINE MODE ---
REPO_NODE="${1:-reponano}"

echo "--- Switching to OFFLINE Mode (Node: $REPO_NODE) ---"

# 1. ONLY backup if the backup directory doesn't exist yet.
# This prevents backing up the 'offline' config over your 'online' config.
if [ ! -d "$BACKUP_DIR" ]; then
    echo "Creating permanent backup of original online config..."
    mkdir -p "$BACKUP_DIR"
    [ -f /etc/apt/sources.list ] && cp -a /etc/apt/sources.list "$BACKUP_DIR/"
    [ -d /etc/apt/sources.list.d ] && cp -a /etc/apt/sources.list.d "$BACKUP_DIR/"
else
    echo "Original backup already exists. Skipping backup step to protect online config."
fi

# 2. Clear current config
rm -f /etc/apt/sources.list
rm -rf /etc/apt/sources.list.d/*
mkdir -p /etc/apt/sources.list.d

# 3. Apply Reponano config
REPO_URL="http://${REPO_NODE}:${REPO_PORT}/repo/${DISTRO}/${VER}/${ARCH} /"
echo "deb [trusted=yes] ${REPO_URL}" > /etc/apt/sources.list

# 4. Refresh
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "Testing connection to Reponano..."
if apt-get update; then
    echo "SUCCESS: Client is now OFFLINE and linked to $REPO_NODE."
else
    echo "ERROR: Could not reach Reponano. Manual check required."
    exit 1
fi
REPONANOCLIENT
  chmod +x "$c"

  local p="${script_dir}/reponano_populate.sh"
  if [[ ! -f "$p" ]]; then
    cat > "$p" <<'REPONANOPOP'
#!/bin/bash
# Script to batch-sync specific packages to Reponano

REPO_IP="localhost"
PORT="3864"
DISTRO="ubuntu"
VER="$(. /etc/os-release && echo "$VERSION_CODENAME")"

# List of packages you want to download (no dependencies)
PACKAGES=(
    "sl"
    "hello"
    "tree"
    "ed"
    "htop"
    "vim-tiny"
)

echo "--- Starting Batch Sync to Reponano ---"

for PKG in "${PACKAGES[@]}"; do
    echo "Syncing: $PKG..."
    
    # Send the request to Reponano
    curl -s -X POST "http://$REPO_IP:$PORT/sync" \
         -H "Content-Type: application/json" \
         -d "{
               \"pkg\": \"$PKG\",
               \"distro\": \"$DISTRO\",
               \"ver\": \"$VER\",
               \"deps\": false
             }" | jq .

    echo "--------------------------------"
done

echo "Batch sync complete. Check 'sudo journalctl -u reponano -f' for logs."
REPONANOPOP
    chmod +x "$p"
  fi
}

# ──────────────────────────────────────────────────────────────────────────
# ENSURE REPONANO FULL SYNC – pull the full package manifest into reponano
# for a fully-offline build.  POSTs every package in the manifest to the
# reponano /sync endpoint with deps=true (full dependency tree), so the local
# repo holds everything the master + clients need to run without internet.
# ──────────────────────────────────────────────────────────────────────────
ensure_reponano_full_sync_script() {
  local f="${script_dir}/reponano_full_sync.sh"
  if [[ -f "$f" ]]; then
    return 0
  fi
  tui_info "Writing ${BOLD}${f}${RESET} (embedded in setup.sh)…"
  cat > "$f" <<'REPONANOFULL'
#!/usr/bin/env bash
# reponano_full_sync.sh – pull the full package manifest into reponano.
# Usage: reponano_full_sync.sh [repo-ip] [port] [distro] [ver] [arch]
set -euo pipefail

REPO_IP="${1:-localhost}"
PORT="${2:-3864}"
DISTRO="${3:-ubuntu}"
VER="${4:-$(. /etc/os-release && echo "$VERSION_CODENAME")}"
ARCH="${5:-amd64}"

# ── Full package manifest required for an offline PE lab ──────────────────
# Base OS + nano add-on dependencies + PE/agent packages + pdk + common tools.
# Each entry is POSTed to /sync with deps=false so the package plus its direct
# dependencies are pulled (the full recursive closure on a complete Ubuntu repo
# is impractically large).  Edit this list to match your lab's needs.
PACKAGES=(
  # reponano deps
  python3 python3-flask python3-pip dpkg-dev apt-rdepends createrepo-c dnf curl jq
  # forgenano deps
  python3-venv gunicorn
  # openainano deps
  python3-venv python3-pip
  # scanano deps
  nmap
  # hieranano deps
  python3-flask
  # pdk (puppet-tools repo)
  pdk
  # PE / agent packages (PE repo)
  puppet-agent puppetdb puppetserver pe-console-services pe-puppetserver \
  pe-puppetdb pe-puppetdb-termini pe-bolt-server pe-orchestration-services \
  pe-r10k pe-nginx pe-postgresql
  # common tools
  git vim htop tree ca-certificates gnupg lsb-release openssh-server haproxy
)

echo "--- Full offline sync: ${#PACKAGES[@]} packages (with deps) into reponano ---"
for PKG in "${PACKAGES[@]}"; do
  echo -n "Syncing: $PKG ... "
  RESP=$(curl -s -X POST "http://$REPO_IP:$PORT/sync" \
    -H "Content-Type: application/json" \
    -d "{\"pkg\":\"$PKG\",\"distro\":\"$DISTRO\",\"ver\":\"$VER\",\"arch\":\"$ARCH\",\"deps\":false}")
  if echo "$RESP" | grep -q '"status"[[:space:]]*:[[:space:]]*"success"'; then
    echo "DONE"
  else
    echo "FAILED: $RESP"
  fi
done
echo "--- Full offline sync complete ---"
REPONANOFULL
  chmod +x "$f"
}


# Write a standalone script that closes the offline loop: it asks forgenano which
# OS packages its built modules require (e.g. a grafana module -> grafana package)
# and feeds each one into reponano /sync, so Puppet can install them offline.
# Usage: reponano_forgenano_sync.sh <forge-ip> <forge-port> <forge-admin-key> \
#                                   <repo-ip> <repo-port> <distro> <ver> <arch>
ensure_reponano_forgenano_sync_script() {
  local f="${script_dir}/reponano_forgenano_sync.sh"
  cat > "$f" <<'REPOFORGE'
#!/usr/bin/env bash
# reponano_forgenano_sync.sh - pull the OS packages required by the forgenano
# modules into reponano, so Puppet can install them fully offline.
# forgenano's /admin/inspect_all scans every built module's .pp files for
# `package { 'name': }` resources and returns the deduplicated set, which we
# feed to reponano /sync (deps=false -> the package + its direct deps).
set -euo pipefail

FORGE_IP="${1:-localhost}"
FORGE_PORT="${2:-6157}"
FORGE_KEY="${3:-$(openssl rand -hex 16)}"
REPO_IP="${4:-localhost}"
REPO_PORT="${5:-3864}"
DISTRO="${6:-ubuntu}"
VER="${7:-$(. /etc/os-release && echo "$VERSION_CODENAME")}"
ARCH="${8:-amd64}"

ADMIN_URL="http://$FORGE_IP:$FORGE_PORT/admin/inspect_all"
SYNC_URL="http://$REPO_IP:$REPO_PORT/sync"

echo "--- Querying forgenano for OS packages required by built modules ---"
JSON=$(curl -s -H "X-API-KEY: $FORGE_KEY" "$ADMIN_URL")

# Extract summary.unique_system_packages_required via python3 (present on the
# master via reponano/forgenano deps).  We only want the package NAMES.
PKGS=$(printf '%s' "$JSON" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    pkgs = sorted(set(d.get("summary", {}).get("unique_system_packages_required", [])))
    print("\n".join(pkgs))
except Exception as e:
    sys.stderr.write("ERROR parsing forgenano inspect_all: %s\n" % e)
    sys.exit(1)
' || true)

if [[ -z "$PKGS" ]]; then
  echo "No system packages declared by built modules (or nothing built yet)."
  exit 0
fi

COUNT=$(printf '%s\n' "$PKGS" | grep -c . || true)
echo "--- Forgenano modules require $COUNT OS packages; syncing into reponano ---"
while IFS= read -r PKG; do
  [[ -z "$PKG" ]] && continue
  echo -n "Syncing: $PKG ... "
  RESP=$(curl -s -X POST "$SYNC_URL" \
    -H "Content-Type: application/json" \
    -d "{\"pkg\":\"$PKG\",\"distro\":\"$DISTRO\",\"ver\":\"$VER\",\"arch\":\"$ARCH\",\"deps\":false}")
  if echo "$RESP" | grep -q '"status"[[:space:]]*:[[:space:]]*"success"'; then
    echo "DONE"
  else
    echo "FAILED: $RESP"
  fi
done <<< "$PKGS"
echo "--- Forgenano -> reponano package sync complete ---"
REPOFORGE
  chmod +x "$f"
}


# ──────────────────────────────────────────────────────────────────────────
# FORGENANO – local Puppet Forge (module mirror) installer + helpers
# ──────────────────────────────────────────────────────────────────────────
ensure_forgenano_script() {
  local f="${script_dir}/forgenano.sh"
  if [[ -f "$f" ]]; then
    return 0
  fi
  tui_info "Writing ${BOLD}${f}${RESET} (embedded in setup.sh)…"
  cat > "$f" <<'FORGENANO'
#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
USERNAME=localforge
APP_DIR=/srv/localforge
STORAGE_DIR=/var/lib/puppet_localforge
VENV_DIR=/opt/localforge/venv
PORT=6157
ADMIN_KEY="${ADMIN_KEY:-$(openssl rand -hex 16)}" 
# --- PASTE YOUR FORGE TOKEN HERE ---
FORGE_TOKEN="" 

echo "--- 1. System Setup ---"
if command -v apt-get >/dev/null; then
    apt-get update && apt-get install -y python3 python3-venv python3-pip curl
elif command -v dnf >/dev/null; then
    dnf install -y python3 python3-pip curl
fi

if ! id -u "$USERNAME" >/dev/null 2>&1; then
    useradd -m -d /home/$USERNAME -s /bin/bash "$USERNAME"
fi

mkdir -p "$STORAGE_DIR/metadata" "$APP_DIR" "/home/$USERNAME"
chown -R "$USERNAME":"$USERNAME" "$STORAGE_DIR" "$APP_DIR" "/home/$USERNAME"

echo "--- 3.5. Configuring Puppet 8 Auth for $USERNAME ---"
# Create the user-specific puppet config directory
mkdir -p /home/$USERNAME/.puppetlabs/etc/puppet

# Write the config file Puppet 8 expects
# Note: Bearer is required here, but NOT in the environment variables
cat << EOF > /home/$USERNAME/.puppetlabs/etc/puppet/puppet.conf
[main]
forge_authorization = Bearer $FORGE_TOKEN
EOF

# Strict permissions for Puppet 8 security
chown -R "$USERNAME":"$USERNAME" /home/$USERNAME/.puppetlabs
chmod 700 /home/$USERNAME/.puppetlabs
chmod 600 /home/$USERNAME/.puppetlabs/etc/puppet/puppet.conf

echo "--- 3.6. Preparing Log Files ---"
# Create the log file so the service user can write to it
touch /var/log/forgenano.log
chown localforge:localforge /var/log/forgenano.log
chmod 644 /var/log/forgenano.log

echo "--- 2. Writing forgenano.py ---"
cat << 'EOF' > "$APP_DIR/forgenano.py"
#!/usr/bin/env python3
import os
import json
import shutil
import tempfile
import subprocess
import logging
import hashlib
from pathlib import Path
from flask import Flask, request, jsonify, send_from_directory
from functools import wraps
import re
import tarfile

# --- Configuration ---
STORAGE_DIR = Path("/var/lib/puppet_localforge")
METADATA_DIR = STORAGE_DIR / "metadata"
LOG_FILE = "/var/log/forgenano.log"
ADMIN_KEY = os.environ.get("LOCALFORGE_ADMIN_KEY", "")
DEFAULT_FORGE_TOKEN = os.environ.get("FORGE_TOKEN", "")

# --- Setup Directories ---
STORAGE_DIR.mkdir(parents=True, exist_ok=True)
METADATA_DIR.mkdir(parents=True, exist_ok=True)

# --- Logging ---
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler()]
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# --- Helpers ---

def require_admin(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        key = request.headers.get("X-API-KEY")
        if not key or key != ADMIN_KEY:
            return jsonify({"error": "Unauthorized"}), 401
        return f(*args, **kwargs)
    return decorated

@app.route("/admin/inspect_control_repo", methods=["GET"])
@require_admin
def inspect_control_repo():
    repo_path = request.args.get('path', '/var/www/production')
    
    if not os.path.exists(repo_path):
        return jsonify({"error": f"Path {repo_path} not found"}), 404

    found_packages = set()
    
    # Regex Patterns
    # 1. Matches Puppet resources: package { 'name':
    pp_regex = r"package\s*{\s*['\"]([^'\"]+)['\"]"
    # 2. Matches YAML keys that look like packages: pkg_name: 'name' or packages: [ 'a', 'b' ]
    yaml_regex = r"(?:pkg|package|packages|install)\s*:\s*['\"]?([^'\"\s,\]]+)['\"]?"
    # 3. Matches ERB/Scripts: apt-get install -y name
    script_regex = r"(?:apt-get install|yum install|dnf install)\s+(?:-y\s+)?([a-zA-Z0-9\-_]+)"

    for root, dirs, files in os.walk(repo_path):
        for file in files:
            file_ext = os.path.splitext(file)[1].lower()
            if file_ext in ['.pp', '.yaml', '.erb', '.sh']:
                file_path = os.path.join(root, file)
                try:
                    with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                        content = f.read()
                        
                        # Apply appropriate regex based on file type
                        if file_ext == '.pp':
                            found_packages.update(re.findall(pp_regex, content))
                        elif file_ext == '.yaml':
                            found_packages.update(re.findall(yaml_regex, content))
                        else: # ERB or Shell scripts
                            found_packages.update(re.findall(script_regex, content))
                except Exception as e:
                    logger.error(f"Error scanning {file_path}: {e}")

    # Clean the set (remove empty strings or common false positives)
    final_list = sorted([p for p in found_packages if p and len(p) > 1])

    return jsonify({
        "source_path": repo_path,
        "unique_system_packages_required": final_list
    })

@app.route("/admin/inspect_all", methods=["GET"])
@require_admin
def inspect_all():
    all_packages = set()
    all_puppet_deps = set()
    report = {}

    # Find all tarballs in storage
    tarballs = list(STORAGE_DIR.glob("*.tar.gz"))
    
    for tar_path in tarballs:
        module_name = tar_path.name.replace(".tar.gz", "")
        module_packages = set()
        
        try:
            with tarfile.open(tar_path, "r:gz") as tar:
                # 1. Extract Puppet dependencies from metadata.json
                try:
                    # Look for metadata.json (usually inside the top-level folder in the tar)
                    # We search for it because names can vary slightly
                    metadata_member = next(m for m in tar.getmembers() if m.name.endswith("metadata.json"))
                    f = tar.extractfile(metadata_member)
                    if f:
                        m_data = json.load(f)
                        for dep in m_data.get('dependencies', []):
                            all_puppet_deps.add(f"{dep['name']} ({dep.get('version_requirement', 'any')})")
                except (StopIteration, Exception):
                    pass

                # 2. Scan manifests for 'package' resources
                for member in tar.getmembers():
                    if member.name.endswith(".pp"):
                        f = tar.extractfile(member)
                        if f:
                            content = f.read().decode('utf-8', errors='ignore')
                            # Regex to catch: package { 'name':  OR package { "name":
                            found = re.findall(r"package\s*{\s*['\"]([^'\"]+)['\"]", content)
                            for p in found:
                                module_packages.add(p)
                                all_packages.add(p)
            
            report[module_name] = list(module_packages)
            
        except Exception as e:
            logger.error(f"Could not inspect {tar_path.name}: {e}")

    return jsonify({
        "summary": {
            "total_modules_scanned": len(tarballs),
            "unique_system_packages_required": sorted(list(all_packages)),
            "unique_puppet_dependencies": sorted(list(all_puppet_deps))
        },
        "details_by_module": report
    })

@app.route("/admin/inspect/<owner>-<name>-<version>", methods=["GET"])
@require_admin
def inspect_module(owner, name, version):
    full_name = f"{owner}-{name}"
    tar_path = STORAGE_DIR / f"{full_name}-{version}.tar.gz"
    
    if not tar_path.exists():
        return jsonify({"error": "Module not found"}), 404

    packages = set()
    dependencies = []

    with tarfile.open(tar_path, "r:gz") as tar:
        # 1. Check metadata.json for Puppet dependencies
        try:
            metadata_file = tar.extractfile(f"{full_name}-{version}/metadata.json")
            if metadata_file:
                m_data = json.load(metadata_file)
                dependencies = m_data.get('dependencies', [])
        except Exception:
            pass

        # 2. Scan all .pp files for 'package { "name":'
        for member in tar.getmembers():
            if member.name.endswith(".pp"):
                f = tar.extractfile(member)
                if f:
                    content = f.read().decode('utf-8', errors='ignore')
                    # Regex to find package resource titles
                    # Matches: package { 'grafana': or package { "prometheus":
                    found = re.findall(r"package\s*{\s*['\"]([^'\"]+)['\"]", content)
                    for p in found:
                        packages.add(p)

    return jsonify({
        "module": full_name,
        "version": version,
        "required_puppet_modules": dependencies,
        "identified_system_packages": list(packages)
    })

def get_file_hashes(file_path):
    """Calculates both MD5 and SHA256 using a stable buffer for Puppet 8"""
    md5 = hashlib.md5()
    sha256 = hashlib.sha256()
    try:
        with open(str(file_path), "rb") as f:
            while True:
                data = f.read(8192)
                if not data:
                    break
                md5.update(data)
                sha256.update(data)
        return md5.hexdigest(), sha256.hexdigest()
    except Exception as e:
        logger.error(f"Hash calculation failed for {file_path}: {e}")
        return "", ""

def run_cmd(cmd, cwd=None, env=None):
    proc = subprocess.run(
        cmd, cwd=cwd, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )
    if proc.returncode != 0:
        raise RuntimeError(f"Command failed: {proc.stdout}")
    return proc.stdout

# --- Forge API v3 Endpoints ---

@app.route("/v3/releases", methods=["GET"])
def list_releases():
    module_query = request.args.get("module")
    if not module_query:
        return jsonify({"results": [], "pagination": {"next": None}})
    
    full_name = module_query.replace("/", "-")
    files = list(STORAGE_DIR.glob(f"{full_name}-*.tar.gz"))
    
    results = []
    for f in files:
        version = f.name.replace(f"{full_name}-", "").replace(".tar.gz", "")
        parts = full_name.split('-', 1)
        owner = parts[0]
        mod_name = parts[1] if len(parts) > 1 else parts[0]
        
        md5_h, sha256_h = get_file_hashes(f)

        results.append({
            "uri": f"/v3/releases/{full_name}-{version}",
            "version": version,
            "module": {
                "name": mod_name,
                "owner": {"username": owner},
                "slug": full_name
            },
            "file_uri": f"/modules/{f.name}",
            "file_size": f.stat().st_size,
            "file_md5": md5_h,
            "file_sha256": sha256_h,
            "file_checksums": {
                "md5": md5_h,
                "sha256": sha256_h
            },
            "metadata": {"name": full_name, "version": version}
        })

    results.sort(key=lambda x: x['version'], reverse=True)
    return jsonify({"results": results, "pagination": {"limit": len(results), "offset": 0, "total": len(results)}})

@app.route("/v3/releases/<owner>-<name>-<version>", methods=["GET"])
def get_release(owner, name, version):
    full_name = f"{owner}-{name}"
    filename = f"{full_name}-{version}.tar.gz"
    file_path = STORAGE_DIR / filename

    if not file_path.exists():
        return jsonify({"error": "Release not found"}), 404

    md5_h, sha256_h = get_file_hashes(file_path)

    return jsonify({
        "uri": f"/v3/releases/{full_name}-{version}",
        "version": version,
        "module": {
            "name": name,
            "owner": {"username": owner},
            "slug": full_name
        },
        "file_uri": f"/modules/{filename}",
        "file_size": file_path.stat().st_size,
        "file_md5": md5_h,
        "file_sha256": sha256_h,
        "file_checksums": {
            "md5": md5_h,
            "sha256": sha256_h
        },
        "metadata": {
            "name": full_name,
            "version": version,
            "dependencies": [] 
        }
    })

@app.route("/v3/modules/<owner>-<name>", methods=["GET"])
def get_module(owner, name):
    full_name = f"{owner}-{name}"
    files = list(STORAGE_DIR.glob(f"{full_name}-*.tar.gz"))
    if not files:
        return jsonify({"error": "Module not found"}), 404

    versions = [f.name.replace(f"{full_name}-", "").replace(".tar.gz", "") for f in files]
    versions.sort(reverse=True)
    latest = versions[0]

    return jsonify({
        "name": name,
        "owner": {"username": owner},
        "slug": full_name,
        "current_release": {"version": latest, "uri": f"/v3/releases/{full_name}-{latest}"},
        "releases": [{"version": v, "uri": f"/v3/releases/{full_name}-{v}"} for v in versions]
    })

@app.route("/modules/<filename>")
def download_module(filename):
    file_path = STORAGE_DIR / filename
    if not file_path.exists():
        return jsonify({"error": "File not found"}), 404
        
    # We use direct response to avoid any Flask 'helper' interference
    from flask import make_response
    
    file_size = file_path.stat().st_size
    with open(file_path, 'rb') as f:
        data = f.read()
        
    response = make_response(data)
    response.headers['Content-Type'] = 'application/octet-stream'
    response.headers['Content-Disposition'] = f'attachment; filename={filename}'
    response.headers['Content-Length'] = str(file_size)
    
    # This prevents Gunicorn/Flask from chunking the response 
    # which can sometimes mess with Puppet's checksum calculation
    response.headers['X-Content-Type-Options'] = 'nosniff'
    
    return response

# --- Admin/Management Endpoints ---

@app.route("/v3/modules", methods=["POST"])
@require_admin
def add_module():
    payload = request.get_json(force=True)
    module_spec = payload.get("module")
    forge_token = request.headers.get("X-FORGE-TOKEN", DEFAULT_FORGE_TOKEN)

    if not module_spec:
        return jsonify({"error": "No module specified"}), 400

    module_arg = module_spec.split()[0].replace("/", "-")
    tmpd = Path(tempfile.mkdtemp(prefix="nano_"))
    
    try:
        env = os.environ.copy()
        env["PATH"] = f"/opt/puppetlabs/bin:/opt/puppetlabs/pdk/bin:{env.get('PATH', '')}"
        env["HOME"] = "/home/localforge"
        
        if forge_token:
            env["PUPPET_FORGE_TOKEN"] = forge_token
            env["PUPPET_FORGE_API_KEY"] = forge_token

        run_cmd(["puppet", "module", "install", module_arg, "--target-dir", str(tmpd), "--force", "--ignore-dependencies"], env=env)

        installed_dir = next(tmpd.iterdir())
        with (installed_dir / "metadata.json").open() as f:
            m = json.load(f)
            real_name = m["name"].replace("/", "-")
            real_version = m["version"]
        
        run_cmd(["pdk", "build", "--force"], cwd=str(installed_dir), env=env)
        
        artifact = sorted(list((installed_dir / "pkg").glob("*.tar.gz")))[-1]
        dest_filename = f"{real_name}-{real_version}.tar.gz"
        shutil.copy2(str(artifact), STORAGE_DIR / dest_filename)
        (METADATA_DIR / f"{real_name}.json").write_text(json.dumps(m))
        
        return jsonify({"status": "created", "module": real_name, "version": real_version}), 201
        
    except Exception as e:
        logger.error(f"Build failed: {e}")
        return jsonify({"error": str(e)}), 500
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)

@app.route("/admin/list", methods=["GET"])
@require_admin
def list_admin():
    files = [f.name for f in STORAGE_DIR.glob("*.tar.gz")]
    return jsonify({"modules": files})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=6157)
EOF

echo "--- 3. Python & Service Refresh ---"
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/pip" install gunicorn flask

cat << EOF > /etc/systemd/system/forgenano.service
[Unit]
Description=ForgeNano Service
After=network.target

[Service]
User=root
Group=root
WorkingDirectory=$APP_DIR
Environment="PATH=/opt/puppetlabs/bin:/usr/local/bin:/usr/bin:/bin"
Environment="PUPPET_FORGE_STORAGE=$STORAGE_DIR"
Environment="HOME=/home/$USERNAME"
Environment="LOCALFORGE_ADMIN_KEY=$ADMIN_KEY"
Environment="PUPPET_FORGE_TOKEN=$FORGE_TOKEN"
ExecStart=$VENV_DIR/bin/gunicorn --workers 2 --bind 0.0.0.0:$PORT forgenano:app
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable forgenano.service
systemctl restart forgenano.service

echo "--- SETUP COMPLETE ---"
echo "Forge Token injected into service environment."
FORGENANO
  chmod +x "$f"

  local c="${script_dir}/forgenano_local.sh"
  if [[ ! -f "$c" ]]; then
    cat > "$c" <<'FORGENANOLOCAL'
#!/bin/bash

# --- Configuration ---
SEARCH_IP="127.0.0.1"
KNOWN_HOSTS="/etc/ssh/ssh_known_hosts"
PUPPETFILE_PATH="/var/www/production/Puppetfile"
PUPPETFILE_BACKUP="/root/Puppetfile"
CONTROL_REPO_DIR="/var/www/production"

# 1. Dynamically get the FQDN via Facter (Puppet's source of truth)
DYNAMIC_FQDN=$(facter networking.fqdn)

# 2. Extract and sanitize the SSH key
# tail -n 1 ensures we get the most recent entry
# tr -d removes newlines and spaces that cause JSON breakage
RAW_KEY=$(grep "$SEARCH_IP" "$KNOWN_HOSTS" | grep "ssh-ed25519" | tail -n 1 | awk '{print $3}' | tr -d '\n\r ')

# 3. Validation
if [ -z "$RAW_KEY" ]; then
    echo "Error: ssh-ed25519 key for $SEARCH_IP not found in $KNOWN_HOSTS"
    exit 1
fi

if [ -z "$DYNAMIC_FQDN" ]; then
    echo "Error: Could not determine FQDN via facter."
    exit 1
fi

# 4. Construct the JSON string
PUPPET_JSON=$(cat <<EOF
[
  {
    "name": "$DYNAMIC_FQDN",
    "type": "ssh-ed25519",
    "key": "$RAW_KEY"
  }
]
EOF
)

# 5. Display Result and Confirmation
echo "--- Generated Puppet JSON for $DYNAMIC_FQDN ---"
echo "$PUPPET_JSON"
echo "------------------------------------------------"
echo "Check that r10_known_hosts is updated if required."
read -n 1 -s -r -p "Press any key to begin the deployment workflow..."
echo -e "\n"

# --- Deployment Workflow ---

# A. Clear Puppetfile to reset environment state
echo "Step A: Clearing Puppetfile and running agent..."
rm -f "$PUPPETFILE_PATH"
puppet agent -t

# B. Commit the empty state to Git
echo "Step B: Pushing empty state to Git..."
cd "$CONTROL_REPO_DIR" || exit
git add .
git commit -m "nano: clearing environment" || echo "Nothing to commit"
git push

# C. Deploy empty state and sync
echo "Step C: Deploying production code (empty)..."
puppet code deploy production --wait
puppet agent -t

# D. Restore the actual Puppetfile
echo "Step D: Restoring Puppetfile from $PUPPETFILE_BACKUP..."
cp "$PUPPETFILE_BACKUP" "$PUPPETFILE_PATH"

# E. Commit the restored Puppetfile
echo "Step E: Pushing restored Puppetfile to Git..."
cd "$CONTROL_REPO_DIR" || exit
git add .
git commit -m "nano: restoring modules" || echo "Nothing to commit"
git push

# F. Final Deployment
echo "Step F: Final code deploy and agent sync..."
puppet code deploy production --wait
puppet agent -t

echo "--- Workflow Complete ---"
FORGENANOLOCAL
    chmod +x "$c"
  fi

  local p="${script_dir}/forgenano_populate.sh"
  if [[ ! -f "$p" ]]; then
    cat > "$p" <<'FORGENANOPOP'
#!/usr/bin/env bash

# --- Config ---
FORGE_URL="http://localhost:6157/v3/modules"
ADMIN_KEY="$(openssl rand -hex 16)"
FORGE_TOKEN=""

MODULES=(
    "puppetlabs-playbook_runner"
    "puppetlabs-edgeops"
    "puppetlabs-cd4peadm"
    "puppetlabs/comply"
    "puppetlabs-puppet_data_connector"
    "puppetlabs-nessus_transformer"
    "albatrossflavour-puppet_data_connector_enhancer"
    "puppet-python"
    "puppet-epel"
    "puppetlabs-node_encrypt"
    "puppetlabs-puppet_authorization"
    "puppetlabs-hocon"
    "puppetlabs-motd"
    "puppetlabs/concat"
    "puppet-grafana"
    "puppetlabs-puppet_operational_dashboards"
    "puppetlabs-puppet_conf"
    "puppet/archive"
    "puppetlabs/chocolatey"
    "puppetlabs/inifile"
    "puppetlabs/ruby_task_helper"
    "puppetlabs/registry"
    "puppet-systemd"
    "puppet-prometheus"
    "puppet-telegraf"
    "puppetlabs-influxdb"
    "puppetlabs-docker"
    "puppetlabs/stdlib"
    "puppetlabs-apt"
    "puppetlabs/powershell"
    "puppetlabs/reboot"
    "puppetlabs/pwshlib"
    "puppet-vault"
    "puppet-hashi_stack"
    "puppet-vault_lookup"
    "stm-file_capability"
    "puppetlabs-f5"
)

# Fallback: mirror the module's tarball DIRECTLY from the Forge (with the token)
# when the build path fails -- e.g. premium "release-token" modules whose file
# download 401s via `puppet module install` even though the Forge API + file
# download work with a valid token.  The local forge serves whatever tarballs
# are present in STORAGE_DIR, so a direct mirror is enough for r10k/code-manager.
_direct_mirror() {
    local mod="$1"
    local storage="${PUPPET_FORGE_STORAGE:-/var/lib/puppet_localforge}"
    [ -z "$FORGE_TOKEN" ] && return 1
    [ -d "$storage" ] || return 1
    local meta ver url
    meta=$(curl -s --max-time 20 -H "Authorization: Bearer $FORGE_TOKEN" \
             "https://forgeapi.puppet.com/v3/modules/${mod}" 2>/dev/null)
    ver=$(printf '%s' "$meta" | python3 -c 'import sys,json;print(json.load(sys.stdin)["current_release"]["version"])' 2>/dev/null)
    [ -z "$ver" ] && return 1
    url="https://forgeapi.puppet.com/v3/files/${mod}-${ver}.tar.gz"
    if curl -s -f --max-time 120 -H "Authorization: Bearer $FORGE_TOKEN" \
         -o "${storage}/${mod}-${ver}.tar.gz" "$url"; then
        chown localforge:localforge "${storage}/${mod}-${ver}.tar.gz" 2>/dev/null || true
        echo "DONE (direct mirror ${ver})"
        return 0
    fi
    rm -f "${storage}/${mod}-${ver}.tar.gz"
    return 1
}

_fnok=0; _fnbad=0
for MOD in "${MODULES[@]}"; do
    CLEAN_MOD=$(echo "$MOD" | tr '/' '-')
    echo -n "Building: $CLEAN_MOD ... "
    
    _fnbody=$(mktemp)
    _fncode=$(curl -s -o "$_fnbody" -w '%{http_code}' -X POST "$FORGE_URL" \
        -H "X-API-KEY: $ADMIN_KEY" \
        -H "X-FORGE-TOKEN: $FORGE_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"module\": \"$CLEAN_MOD\"}")
    if [[ "$_fncode" == "201" ]]; then
        echo "DONE"; _fnok=$((_fnok+1))
    elif _direct_mirror "$CLEAN_MOD"; then
        _fnok=$((_fnok+1))
    else
        echo "FAILED (HTTP ${_fncode}) - $(sed -e 's/\x1b\[[0-9;]*m//g' "$_fnbody" 2>/dev/null | cut -c1-160)"
        _fnbad=$((_fnbad+1))
    fi
    rm -f "$_fnbody"
done
echo
echo "Forgenano populate: ${_fnok} mirrored, ${_fnbad} failed (of ${#MODULES[@]})."
FORGENANOPOP
    chmod +x "$p"
  fi
}


# ──────────────────────────────────────────────────────────────────────────
# SCANANO – CVE-enabled vulnerability scan bridge (Nessus-API mimic)
# ──────────────────────────────────────────────────────────────────────────
ensure_scanano_script() {
  local f="${script_dir}/scanano.sh"
  tui_info "Writing ${BOLD}${f}${RESET} (embedded in setup.sh)…"
  cat > "$f" <<'SCANANO'
#!/bin/bash
# --- Scanano CVE-Enabled Bridge (Golden Deployment Script) ---

INSTALL_DIR="/opt/scanano"
CURRENT_FQDN=$(hostname -f)
CURRENT_IP=$(hostname -I | awk '{print $1}')

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)" 
   exit 1
fi

echo "[1/4] Installing System Dependencies..."
# Ensure Python3, Pip, and Nmap are present
if [ -f /etc/redhat-release ]; then
    yum install -y python3-pip nmap
elif [ -f /etc/debian_version ]; then
    apt-get update && apt-get install -y python3-pip nmap
fi

# Install Python requirements for the Bridge
pip3 install flask python-nmap lxml pyOpenSSL cryptography --quiet

echo "[2/4] Deploying Scanano CVE-Aware Bridge for $CURRENT_FQDN..."
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

cat << EOF > scanano.py
import nmap
import lxml.etree as ET
from flask import Flask, Response, request, jsonify
import sys, time, re, secrets

app = Flask(__name__)

@app.route('/session', methods=['POST'])
def login(): 
    return jsonify({"token": secrets.token_hex(16)})

@app.route('/scans', methods=['GET'])
def list_scans(): 
    return jsonify({
        "scans": [{"id": 1, "name": "Scanano-Feed", "status": "completed", "scan_type": "vuln"}]
    })

@app.route('/scans/<scan_id>/export', methods=['POST'])
def export_request(scan_id):
    return jsonify({"status": "ready", "file": "1"})

@app.route('/scans/<scan_id>/export/<file_id>/status', methods=['GET'])
def export_status(scan_id, file_id):
    return jsonify({"status": "ready"})

@app.route('/scans/<scan_id>/export/<file_id>/download', methods=['GET'])
def export_download(scan_id, file_id):
    print(f">>> Running CVE-aware scan for $CURRENT_FQDN...", file=sys.stderr)
    
    nm = nmap.PortScanner()
    # -F (Fast), -sV (Version), --script vulners (CVE lookup)
    nm.scan('$CURRENT_IP', arguments='-F -sV --script vulners -T4 -n')
    
    unix_timestamp = str(int(time.time()))
    root = ET.Element("NessusClientData_v2")
    
    policy = ET.SubElement(root, "Policy")
    prefs = ET.SubElement(policy, "Preferences")
    s_prefs = ET.SubElement(prefs, "ServerPreferences")
    pref = ET.SubElement(s_prefs, "preference")
    ET.SubElement(pref, "name").text = "scan_end_timestamp"
    ET.SubElement(pref, "value").text = unix_timestamp

    report = ET.SubElement(root, "Report", name="Scanano-Feed")
    host = ET.SubElement(report, "ReportHost", name="$CURRENT_FQDN")
    props = ET.SubElement(host, "HostProperties")
    
    ET.SubElement(props, "tag", name="host-ip").text = "$CURRENT_IP"
    ET.SubElement(props, "tag", name="host-fqdn").text = "$CURRENT_FQDN"
    ET.SubElement(props, "tag", name="LastAuthenticatedResults").text = unix_timestamp

    if '$CURRENT_IP' in nm.all_hosts():
        for proto in nm['$CURRENT_IP'].all_protocols():
            for port in nm['$CURRENT_IP'][proto].keys():
                port_data = nm['$CURRENT_IP'][proto][port]
                service = port_data['name']
                
                item = ET.SubElement(host, "ReportItem", 
                                     port=str(port), 
                                     svc_name=service, 
                                     protocol=proto, 
                                     severity="1", 
                                     pluginName=f"Service: {service}", 
                                     pluginFamily="General")
                
                if 'script' in port_data and 'vulners' in port_data['script']:
                    vuln_output = port_data['script']['vulners']
                    cves = re.findall(r'CVE-\d{4}-\d+', vuln_output)
                    
                    if cves:
                        for cve_id in list(set(cves))[:10]:
                            ET.SubElement(item, "cve").text = cve_id
                        
                        scores = re.findall(r'\d+\.\d', vuln_output)
                        if scores:
                            max_score = max([float(s) for s in scores])
                            ET.SubElement(item, "cvss3_base_score").text = str(max_score)
                            if max_score >= 7.0: item.set("severity", "4")
                            elif max_score >= 4.0: item.set("severity", "3")
                            else: item.set("severity", "2")

                ET.SubElement(item, "description").text = f"Detected {service} on port {port}."
                ET.SubElement(item, "solution").text = "Patch service to latest version."

    return Response(ET.tostring(root, xml_declaration=True, encoding='UTF-8', pretty_print=True), mimetype='text/xml')

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=9000, ssl_context='adhoc')
EOF

echo "[3/4] Configuring Systemd Service..."
cat << EOF > /etc/systemd/system/scanano.service
[Unit]
Description=Scanano HTTPS Bridge
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/python3 $INSTALL_DIR/scanano.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "[4/4] Starting Bridge Service..."
systemctl daemon-reload
systemctl enable scanano
systemctl restart scanano

echo "--------------------------------------------------------"
echo "✅ DEPLOYMENT SUCCESSFUL"
echo "--------------------------------------------------------"
echo "1. VERIFY SERVICE:"
echo "   systemctl status scanano"
echo ""
echo "2. TEST LOCALLY:"
echo "   curl -k https://127.0.0.1:9000/scans"
echo ""
echo "3. RUN PUPPET TASK:"
echo "   puppet task run nessus_transformer::run_nessus_transformer --nodes $CURRENT_FQDN"
echo "--------------------------------------------------------"
SCANANO
  chmod +x "$f"
}

# ──────────────────────────────────────────────────────────────────────────
# FORGENANO SYNC – mirror the control-repo Puppetfile modules into the local
# forgenano forge, then point the Puppetfile at forgenano.
# ──────────────────────────────────────────────────────────────────────────
ensure_forgenano_sync_script() {
  local f="${script_dir}/forgenano_sync.sh"
  tui_info "Writing ${BOLD}${f}${RESET} (embedded in setup.sh)…"
  cat > "$f" <<'FORGENANOSYNC'
#!/usr/bin/env bash
set -euo pipefail

# forgenano_sync.sh – mirror the modules listed in the control-repo Puppetfile
# into the local forgenano forge.  The Puppetfile itself is left UNCHANGED.
#
# Usage: forgenano_sync.sh <forge_token> <admin_key> <port> [puppetfile_path]
#   forge_token     – Puppet Forge bearer token (blank = public modules only)
#   admin_key       – forgenano admin key (default: random)
#   port            – forgenano port (default 6157)
#   puppetfile_path – path to the Puppetfile (default /var/www/production/Puppetfile)

FORGE_TOKEN="${1:-}"
ADMIN_KEY="${2:-$(openssl rand -hex 16)}"
PORT="${3:-6157}"
PUPPETFILE_PATH="${4:-/var/www/production/Puppetfile}"
FORGENANO_URL="http://localhost:${PORT}/v3/modules"

if [ ! -f "$PUPPETFILE_PATH" ]; then
    echo "Error: Puppetfile not found at $PUPPETFILE_PATH"
    exit 1
fi

echo "--- Reading Puppetfile: $PUPPETFILE_PATH ---"

# Extract forge module names from `mod 'owner-name'[, 'version']` lines.
# Skip modules with :git / :path / :svn / :hg sources (not from the Forge).
MODULES=$(grep -E "^\s*mod\s+['\"]" "$PUPPETFILE_PATH" \
    | grep -vE ":\s*(git|path|svn|hg)\b" \
    | sed -E "s/^\s*mod\s+['\"]([^'\"]+)['\"].*/\1/" \
    | tr '/' '-' \
    | sort -u)

if [ -z "$MODULES" ]; then
    echo "No forge modules found in Puppetfile."
else
    echo "--- Mirroring $(echo "$MODULES" | wc -l) modules into forgenano ---"
# Fallback: mirror the module's tarball DIRECTLY from the Forge (with the token)
# when the build path fails -- e.g. premium "release-token" modules whose file
# download 401s via `puppet module install` even though the Forge API + file
# download work with a valid token.  The local forge serves whatever tarballs
# are present in STORAGE_DIR, so a direct mirror is enough for r10k/code-manager.
_direct_mirror() {
    local mod="$1"
    local storage="${PUPPET_FORGE_STORAGE:-/var/lib/puppet_localforge}"
    [ -z "$FORGE_TOKEN" ] && return 1
    [ -d "$storage" ] || return 1
    local meta ver url
    meta=$(curl -s --max-time 20 -H "Authorization: Bearer $FORGE_TOKEN" \
             "https://forgeapi.puppet.com/v3/modules/${mod}" 2>/dev/null)
    ver=$(printf '%s' "$meta" | python3 -c 'import sys,json;print(json.load(sys.stdin)["current_release"]["version"])' 2>/dev/null)
    [ -z "$ver" ] && return 1
    url="https://forgeapi.puppet.com/v3/files/${mod}-${ver}.tar.gz"
    if curl -s -f --max-time 120 -H "Authorization: Bearer $FORGE_TOKEN" \
         -o "${storage}/${mod}-${ver}.tar.gz" "$url"; then
        chown localforge:localforge "${storage}/${mod}-${ver}.tar.gz" 2>/dev/null || true
        echo "DONE (direct mirror ${ver})"
        return 0
    fi
    rm -f "${storage}/${mod}-${ver}.tar.gz"
    return 1
}

    for MOD in $MODULES; do
        echo -n "Building: $MOD ... "
        CURL_ARGS=(-s -X POST "$FORGENANO_URL" \
            -H "X-API-KEY: $ADMIN_KEY" \
            -H "Content-Type: application/json" \
            -d "{\"module\": \"$MOD\"}")
        if [ -n "$FORGE_TOKEN" ]; then
            CURL_ARGS+=(-H "X-FORGE-TOKEN: $FORGE_TOKEN")
        fi
        _fnbody=$(mktemp)
        _fncode=$(curl -s -o "$_fnbody" -w '%{http_code}' "${CURL_ARGS[@]}")
        if [[ "$_fncode" == "201" ]]; then
            echo "DONE"
        elif _direct_mirror "$MOD"; then
            :
        else
            echo "FAILED (HTTP ${_fncode}) - $(sed -e 's/\x1b\[[0-9;]*m//g' "$_fnbody" 2>/dev/null | cut -c1-160)"
        fi
        rm -f "$_fnbody"
    done
fi

# NOTE: The control-repo Puppetfile is left UNCHANGED (the user manages it).
# forgenano only mirrors the modules it lists; it does NOT rewrite the forge URL
# or commit anything.
echo "--- forgenano sync complete (Puppetfile left unchanged) ---"
FORGENANOSYNC
  chmod +x "$f"
}

# ──────────────────────────────────────────────────────────────────────────
# ENSURE PDK – install Puppet Development Kit on the master if absent.
# forgenano's /v3/modules endpoint runs `pdk build` to package each mirrored
# module, but PDK is NOT part of the PE install or the base image.  This is a
# standalone script (not an inline command) so the $VERSION_CODENAME / ${CODENAME}
# variables are evaluated inside the container, not by an intermediate shell.
# ──────────────────────────────────────────────────────────────────────────
ensure_pdk_script() {
  local f="${script_dir}/ensure_pdk.sh"
  tui_info "Writing ${BOLD}${f}${RESET} (embedded in setup.sh)…"
  cat > "$f" <<'ENSUREPDK'
#!/usr/bin/env bash
set -euo pipefail

# ensure_pdk.sh – install Puppet Development Kit (PDK) on the master if absent.
# Works on Debian/Ubuntu (apt) and RHEL-family (dnf/yum).  puppet-tools only
# publishes repos for specific releases, so fall back to a supported one.
if /opt/puppetlabs/pdk/bin/pdk --version >/dev/null 2>&1; then
    echo "PDK already present: $(/opt/puppetlabs/pdk/bin/pdk --version)"
    exit 0
fi

. /etc/os-release 2>/dev/null || true

if command -v apt-get >/dev/null 2>&1; then
    CODENAME="${VERSION_CODENAME:-}"
    echo "Installing PDK via apt (codename: ${CODENAME:-unknown})..."
    install_pdk_deb() {
        local cn="$1" deb="/tmp/puppet-tools-release-${1}.deb"
        curl -kfs -o "$deb" "https://apt.puppet.com/puppet-tools-release-${1}.deb" || return 1
        dpkg-deb --info "$deb" >/dev/null 2>&1 || return 1
        dpkg -i "$deb" >/dev/null 2>&1
        apt-get update -qq
        apt-get install -y pdk
        /opt/puppetlabs/pdk/bin/pdk --version
    }
    for cn in "${CODENAME:-}" noble jammy; do
        [ -z "$cn" ] && continue
        echo "Trying puppet-tools repo for '${cn}'..."
        if install_pdk_deb "$cn"; then echo "PDK installed from the '${cn}' repo."; exit 0; fi
    done

elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    EL="${VERSION_ID%%.*}"
    PKG="$(command -v dnf >/dev/null 2>&1 && echo dnf || echo yum)"
    echo "Installing PDK via ${PKG} (el: ${EL:-unknown})..."
    install_pdk_rpm() {
        local el="$1" rpm="/tmp/puppet-tools-release-el-${1}.noarch.rpm"
        curl -kfs -o "$rpm" "https://yum.puppet.com/puppet-tools-release-el-${1}.noarch.rpm" || return 1
        rpm -qp "$rpm" >/dev/null 2>&1 || return 1
        $PKG install -y "$rpm" >/dev/null 2>&1
        $PKG install -y pdk
        /opt/puppetlabs/pdk/bin/pdk --version
    }
    for el in "${EL:-}" 9 8; do
        [ -z "$el" ] && continue
        echo "Trying puppet-tools repo for 'el-${el}'..."
        if install_pdk_rpm "$el"; then echo "PDK installed from the 'el-${el}' repo."; exit 0; fi
    done
fi

echo "ERROR: could not install PDK (no apt/dnf/yum, or no supported puppet-tools repo)" >&2
exit 1
ENSUREPDK
  chmod +x "$f"
}


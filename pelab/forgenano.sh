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

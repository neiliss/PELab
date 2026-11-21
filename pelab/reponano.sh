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

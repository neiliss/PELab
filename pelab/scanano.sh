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

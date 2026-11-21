# =============================================================================
# common.sh  –  extracted from setup.sh (lines 28-295)
# Sourced by pelab.sh.  Do not run directly.
# =============================================================================
# All user-configurable variables with safe empty defaults
provider=""
runtime="vm"
docker_host="cloud"   # Docker ALWAYS runs on a provisioned (cloud) VM – never on this jump host
docker_host_static_ip=""   # desired static internal IP for the Docker-host VM (blank = ephemeral)
nodeprefix=""
adminpwd=""
instype=""
region=""
zone=""
gcp_project=""
gcp_dns_suffix=""          # e.g. "c.myproject.internal" – prompted
nodepooladdress=""
node_size=""
gcp_machine_type=""
gcp_compiler_type=""
aws_instance_type=""
azure_vm_size=""
pe_version=""
pe_tarball_path=""
pe_platform="ubuntu-24.04-amd64"
base_os=""                            # chosen base OS (drives pe_platform + docker_base)
peadm_newest="2025.11"
peadm_module_dir=""     # optional path to a local/custom peadm module (experimental builds)
custom_image=""
ssh_key_path=""
ssh_user=""
bolt_ssh_key=""
r10k_remote=""
r10k_private_key_file=""
r10k_private_key_source=""
r10k_known_hosts="[]"
use_gitnano="false"
use_openainano="true"
use_reponano="true"
use_forgenano="true"
use_scanano="true"
full_offline="false"

# ── Nano add-on configurable values (with defaults) ─────────────────────────
gitnano_port="5000"
hieranano_port="5525"
hieranano_http_port="5526"
openainano_port="5001"
openainano_model="minimax-m2.5:cloud"
reponano_port="3864"
forgenano_port="6157"
forgenano_admin_key="$(openssl rand -hex 16)"
forgenano_forge_token=""
forge_proxy=""
scanano_port="9000"
scanano_token="$(openssl rand -hex 16)"
enable_dr="false"
del_now="Y"
aws_vpc_id=""
aws_subnet_id=""
aws_region=""
azure_location=""
azure_resource_group=""
suite_license_path=""
docker_image=""
docker_base=""                       # container base OS; empty = derive from the base image/PE platform
docker_default_tag="pe-lab-base:24.04" # image tag = pe-lab-base:<base version>
docker_network=""
docker_topology="separate"

# Runtime-computed (not saved)
node_count=0
core_count=0
compiler_count=0
haproxy_count=0
primary_host=""
primary_postgresql_host=""
replica_host=""
replica_postgresql_host=""
tf_dir_active=""
full_zone=""
PARAMS_FILE=""
BOLT=""

# ──────────────────────────────────────────────────────────────────────────────
# COLOUR & TUI  –  fixed 74-char content panel, compact and readable
# ──────────────────────────────────────────────────────────────────────────────
#  Palette
RESET='\033[0m';  BOLD='\033[1m';    DIM='\033[2m'
BLACK='\033[30m'; RED='\033[31m';    GREEN='\033[32m'; YELLOW='\033[33m'
BLUE='\033[34m';  MAGENTA='\033[35m';CYAN='\033[36m';  WHITE='\033[37m'
BG_DARK='\033[48;5;234m'   # very dark grey background for header/footer
BG_MID='\033[48;5;236m'    # mid grey for section headers
FG_HEAD='\033[38;5;117m'   # bright sky-blue for logo text
FG_ACC='\033[38;5;214m'    # amber accent
FG_DIM='\033[38;5;244m'    # muted grey

# Panel width (content inside borders) – capped at 78, min 60
_panel_width() {
  local tw; tw=$(tput cols 2>/dev/null || echo 80)
  local w=$(( tw > 80 ? 78 : tw - 2 ))
  echo $(( w < 60 ? 60 : w ))
}
PW=$(_panel_width)   # total printed width including │ borders

# ── primitives ────────────────────────────────────────────────────────────────
_rep() { printf "%${2}s" | tr ' ' "$1"; }   # repeat char $1 × $2

# Top/mid/bottom box borders
_top()  { printf "${FG_DIM}╭$(_rep ─ $((PW-2)))╮${RESET}\n"; }
_mid()  { printf "${FG_DIM}├$(_rep ─ $((PW-2)))┤${RESET}\n"; }
_bot()  { printf "${FG_DIM}╰$(_rep ─ $((PW-2)))╯${RESET}\n"; }

# Row: │ <padded content> │
_row() {
  # $1 = raw text (may contain escapes), $2 = visible length of $1
  local visible_len="${2:-${#1}}"
  local pad=$(( PW - 2 - visible_len ))
  printf "${FG_DIM}│${RESET}%b%${pad}s${FG_DIM}│${RESET}\n" "$1" ''
}

# Blank row inside box
_row_blank() { _row '' 0; }

# ── banner ────────────────────────────────────────────────────────────────────
tui_banner() {
  clear
  local inner=$(( PW - 2 ))
  local logo=" ▣  PE Lab Setup Wizard"
  local ver="v2.2"
  local ts; ts=$(date '+%Y-%m-%d %H:%M')
  local rhs="${ver}  ${ts} "
  local lpad=$(( (inner - ${#logo}) / 2 ))
  local rpad=$(( inner - ${#logo} - lpad ))

  echo
  printf "${FG_DIM}╭$(_rep ═ $((PW-2)))╮${RESET}\n"
  printf "${FG_DIM}║${RESET}${BG_DARK}${FG_HEAD}${BOLD}%${lpad}s%s%${rpad}s${RESET}${FG_DIM}║${RESET}\n" \
    '' "$logo" ''
  printf "${FG_DIM}║${RESET}${BG_DARK}${FG_DIM}%*s${RESET}${FG_DIM}║${RESET}\n" \
    "$inner" "$rhs"
  printf "${FG_DIM}╰$(_rep ═ $((PW-2)))╯${RESET}\n"
  echo
}

# ── section header ────────────────────────────────────────────────────────────
# tui_section "Title"
# The number of sections varies with the chosen provider/runtime/topology, so we
# show only the current stage number (not a fixed total) to keep it accurate.
_step_cur=0
tui_section() {
  local title="$1"
  local lbl=""
  (( _step_cur++ )) || true
  lbl=" ${FG_DIM}[${_step_cur}]${RESET}"
  echo
  printf "${FG_DIM}╭$(_rep ─ $((PW-2)))╮${RESET}\n"
  local inner="${BOLD}${FG_ACC} ▸ ${WHITE}${title}${RESET}${lbl}"
  local vlen=$(( 6 + ${#title} + ${#_step_cur} ))
  local pad=$(( PW - 2 - vlen ))
  printf "${FG_DIM}│${RESET}${BG_MID}${inner}%${pad}s${RESET}${FG_DIM}│${RESET}\n" ''
  printf "${FG_DIM}╰$(_rep ─ $((PW-2)))╯${RESET}\n"
}

# ── status lines (not boxed – inline flow) ───────────────────────────────────
tui_ok()   { printf "  ${GREEN}✔${RESET}  %b\n"         "$*"; }
tui_warn() { printf "  ${YELLOW}⚠${RESET}  ${YELLOW}%b${RESET}\n" "$*"; }
tui_err()  { printf "  ${RED}✖${RESET}  ${RED}%b${RESET}\n"       "$*" >&2; }
tui_info() { printf "  ${FG_DIM}·${RESET}  ${FG_DIM}%b${RESET}\n" "$*"; }
tui_step() { printf "\n  ${BOLD}${CYAN}→${RESET}  ${BOLD}%b${RESET}\n" "$*"; }
tui_blank() { echo; }

# ── prompts ───────────────────────────────────────────────────────────────────
# tui_prompt VAR "Label" "default"
# ENTER keeps the default (if any).  Typing "-" explicitly blanks the value,
# overriding a saved default (used e.g. to clear a remembered PE tarball path).
tui_prompt() {
  local _v="$1" _lbl="$2" _def="$3" _in _hint=""
  if [[ -n "$_def" ]]; then
    _hint="${FG_DIM} (${_def}) [- = blank]${RESET}"
  fi
  printf "  ${FG_ACC}›${RESET} ${BOLD}%-30s${RESET}%b " "$_lbl" "$_hint"
  read -r _in || true
  if [[ "$_in" == "-" ]]; then
    printf -v "$_v" '%s' ''          # "-" means: clear the value (even the default)
  else
    printf -v "$_v" '%s' "${_in:-$_def}"
  fi
}

# tui_prompt_secret VAR "Label"
tui_prompt_secret() {
  local _v="$1" _lbl="$2" _in
  printf "  ${FG_ACC}›${RESET} ${BOLD}%-30s${RESET} " "$_lbl"
  read -rs _in || true; echo
  printf -v "$_v" '%s' "$_in"
}

# tui_confirm VAR "Label" Y|N
tui_confirm() {
  local _v="$1" _lbl="$2" _def="${3:-Y}" _opts _yn
  if [[ "${_def^^}" == "Y" ]]; then _opts="${GREEN}Y${RESET}/n"
  else                               _opts="y/${RED}N${RESET}"; fi
  printf "  ${FG_ACC}›${RESET} ${BOLD}%-30s${RESET} ${FG_DIM}[%b]${RESET} " "$_lbl" "$_opts"
  read -r _yn || true
  _yn="${_yn:-$_def}"
  if [[ "${_yn^^}" =~ ^Y ]]; then printf -v "$_v" 'true'
  else                              printf -v "$_v" 'false'; fi
}

# tui_menu_default VAR "Label" default_index opt1 opt2 …
# Renders a compact inline-numbered list
tui_menu_default() {
  local _v="$1" _lbl="$2" _di="$3"; shift 3
  local _opts=("$@") _i=1 _ch
  printf "  ${BOLD}%s${RESET}\n" "$_lbl"
  for _o in "${_opts[@]}"; do
    local _marker="   "
    [[ $_i -eq $_di ]] && _marker="${FG_ACC}▸${RESET} "
    printf "    %b${FG_DIM}%d)${RESET}  %s\n" "$_marker" "$_i" "$_o"
    _i=$((_i+1))
  done
  printf "  ${FG_ACC}›${RESET} ${FG_DIM}choice${RESET} ${FG_DIM}(default %d)${RESET} " "$_di"
  read -r _ch || true
  _ch="${_ch:-$_di}"
  # Guard against non-numeric input (e.g. terminal escape sequences) before
  # doing arithmetic – otherwise `(( _ch < 1 ))` throws a syntax error.
  if [[ ! "$_ch" =~ ^[0-9]+$ ]] || (( _ch < 1 || _ch > ${#_opts[@]} )); then _ch="$_di"; fi
  printf -v "$_v" '%s' "${_opts[$((_ch-1))]}"
}

# tui_menu VAR "Label" opt1 opt2 …  (default = 1)
tui_menu() { tui_menu_default "$1" "$2" 1 "${@:3}"; }

# ── key/value table (compact summary rows) ───────────────────────────────────
# tui_kv "Key" "Value"
tui_kv() {
  printf "  ${FG_DIM}%-22s${RESET}  ${WHITE}%b${RESET}\n" "$1" "$2"
}

# tui_kv_head "Title"  – thin separator before a group
tui_kv_head() {
  echo
  printf "  ${FG_ACC}${BOLD}%s${RESET}\n" "$1"
  printf "  ${FG_DIM}%s${RESET}\n" "$(_rep ─ $(( ${#1} + 2 )))"
}

# ── summary box ───────────────────────────────────────────────────────────────
tui_summary_open()  { echo; _top; _row_blank; }
tui_summary_close() { _row_blank; _bot; echo; }

# tui_summary_row "Key" "Value"
tui_summary_row() {
  local k="$1" v="$2"
  local inner="${FG_DIM}  ${RESET}${BOLD}${CYAN}${k}${RESET}${FG_DIM}:${RESET}  ${WHITE}${v}${RESET}"
  local vlen=$(( 4 + ${#k} + 2 + ${#v} ))
  _row "$inner" "$vlen"
}

# tui_summary_div  – thin rule inside the summary box
tui_summary_div() {
  printf "${FG_DIM}├$(_rep ╌ $((PW-2)))┤${RESET}\n"
}

# ── progress bar (used during wait loops) ────────────────────────────────────
# tui_progress "label" current max
tui_progress() {
  local lbl="$1" cur="$2" max="$3"
  local bar_w=$(( PW - ${#lbl} - 12 ))
  local filled=$(( bar_w * cur / max ))
  local empty=$(( bar_w - filled ))
  printf "  ${FG_ACC}%s${RESET}  ${GREEN}%s${FG_DIM}%s${RESET}  ${FG_DIM}%d/%d${RESET}\r" \
    "$lbl" \
    "$(_rep █ $filled)" \
    "$(_rep ░ $empty)" \
    "$cur" "$max"
}

# ── deferred hint box ─────────────────────────────────────────────────────────
tui_hint_box() {
  echo
  printf "${FG_DIM}  ╭$(_rep ─ $((PW-4)))╮${RESET}\n"
  while IFS= read -r _hline; do
    local _vl=${#_hline}
    local _hp=$(( PW - 4 - _vl ))
    printf "${FG_DIM}  │${RESET}  %s%${_hp}s${FG_DIM}  │${RESET}\n" "$_hline" ''
  done
  printf "${FG_DIM}  ╰$(_rep ─ $((PW-4)))╯${RESET}\n"
  echo
}

# ── done banner ───────────────────────────────────────────────────────────────
tui_done() {
  echo
  printf "${FG_DIM}╭$(_rep ═ $((PW-2)))╮${RESET}\n"
  local msg="  ${GREEN}${BOLD}✔  Provisioning Complete${RESET}"
  local vl=24
  local pad=$(( PW - 2 - vl ))
  printf "${FG_DIM}║${RESET}${BG_DARK}${msg}%${pad}s${FG_DIM}║${RESET}\n" ''
  printf "${FG_DIM}╰$(_rep ═ $((PW-2)))╯${RESET}\n"
  echo
}

# ──────────────────────────────────────────────────────────────────────────────
# LOAD DEFAULTS
# ──────────────────────────────────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────────────────────
# /etc/hosts MANAGEMENT
# The wizard rewrites /etc/hosts to map container/VM hostnames to their IPs.
# To make sure existing/custom entries are never silently lost, every write is
# preceded by a timestamped backup, and removals are narrowly scoped to the
# exact managed hostnames (comments, aliases and custom lines are preserved).
# ──────────────────────────────────────────────────────────────────────────────
# Where backups live (override with HOSTS_BACKUP_DIR) and how many to keep.
HOSTS_BACKUP_DIR="${HOSTS_BACKUP_DIR:-${script_dir:-/root/pelab-dev}/.hosts-backups}"
HOSTS_BACKUP_KEEP="${HOSTS_BACKUP_KEEP:-30}"

# Suggest a static internal IP for the Docker-host VM, preferring (in order):
# the previously chosen docker_host_static_ip, then an IP inside the CURRENT
# GCP subnet for the selected region, else 10.0.0.50 (generic fallback).  The subnet
# is discovered from GCP so the suggestion is valid for whoever runs it, not
# hard-coded to one environment.
suggest_docker_host_ip() {
  if [[ -n "${docker_host_static_ip:-}" ]]; then
    printf '%s\n' "$docker_host_static_ip"; return
  fi
  if command -v gcloud >/dev/null 2>&1; then
    local _cidr _base
    _cidr=$(timeout 20 gcloud compute networks subnets describe default \
              --project="${gcp_project:-}" --region="${region:-us-central1}" \
              --format='value(ipCidrRange)' 2>/dev/null) || _cidr=""
    if [[ -n "$_cidr" ]]; then
      _base="${_cidr%%/*}"                 # e.g. 10.0.0.0
      _base="${_base%.*}"                  # drop last octet -> 10.128.0
      printf '%s.10\n' "$_base"; return    # suggest 10.0.0.10
    fi
  fi
  printf '%s\n' "10.0.0.50"             # generic fallback private address
}

# Back up /etc/hosts before any modification.  Idempotent within the same
# nanosecond stamp so a burst of edits in one step creates a single snapshot
# of the pre-edit state.
hosts_backup() {
  [[ -f /etc/hosts ]] || return 0
  mkdir -p "$HOSTS_BACKUP_DIR"
  local stamp; stamp=$(date -u +%Y%m%d%H%M%S%N)
  local dst="$HOSTS_BACKUP_DIR/hosts.$stamp"
  if [[ ! -f "$dst" ]]; then
    cp -a /etc/hosts "$dst"
    tui_info "Backed up /etc/hosts → $dst"
  fi
  ls -1t "$HOSTS_BACKUP_DIR"/hosts.* 2>/dev/null \
    | tail -n +$((HOSTS_BACKUP_KEEP + 1)) | xargs -r rm -f
}

# Append an exact "IP name" mapping if not already present (idempotent).
# Existing lines that carry extra hostnames/comments are left alone.
hosts_add() {
  local ip="$1" name="$2"
  hosts_backup
  [[ -f /etc/hosts ]] || touch /etc/hosts
  # Escape the dots in the IP so it is matched literally.
  local ipre; ipre=$(printf '%s' "$ip" | sed 's/\./\\./g')
  grep -qE "^${ipre}[[:space:]]+${name}([[:space:]]|$)" /etc/hosts 2>/dev/null \
    || printf '%-18s%s\n' "$ip" "$name" >> /etc/hosts
}

# Remove the EXACT "<ip> <name>" entry for a single managed hostname.  Only
# whole-line exact matches are removed; comments and custom lines survive.
hosts_remove_name() {
  local name="$1"
  hosts_backup
  [[ -f /etc/hosts ]] || return 0
  sed -i -E "/^[0-9.]+[[:space:]]+${name}[[:space:]]*$/d" /etc/hosts
  sed -i '/^[[:space:]]*$/d' /etc/hosts
}

# Remove stale entries for a whole node prefix (core/compiler/haproxy/test)
# that may exist from earlier runs / older VM IPs, then callers re-add the
# current mapping.  Scoped to the exact prefix + known role names, whole line
# only – unrelated or custom entries are preserved.
hosts_remove_prefix() {
  local prefix="$1"
  hosts_backup
  [[ -f /etc/hosts ]] || return 0
  sed -i -E "/^[0-9.]+[[:space:]]+${prefix}(core|compiler|haproxy|test)[0-9]*[[:space:]]*$/d" /etc/hosts
  sed -i '/^[[:space:]]*$/d' /etc/hosts
}

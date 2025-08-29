#!/usr/bin/env bash
set -euo pipefail

# =====================
# Couleurs et helpers
# =====================
if command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
  C_GREEN="$(tput setaf 2)"; C_RED="$(tput setaf 1)"; C_YELLOW="$(tput setaf 3)"; C_BLUE="$(tput setaf 4)"; C_RESET="$(tput sgr0)"
else
  C_GREEN="\033[32m"; C_RED="\033[31m"; C_YELLOW="\033[33m"; C_BLUE="\033[34m"; C_RESET="\033[0m"
fi
step() { echo -e "${C_BLUE}==>${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}✔${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}⚠${C_RESET} $*"; }
err()  { echo -e "${C_RED}✖${C_RESET} $*"; }
trap 'err "Échec à la ligne ${LINENO}."' ERR

# =====================
# Paramètres par défaut
# =====================
VM_NAME="omv"
MEMORY="4096"           # MiB
CORES="2"
DISK_SIZE="32G"
BRIDGE="vmbr0"
STORAGE="local-lvm"     # stockage pour le disque système
TIMEZONE="Europe/Zurich"
SSH_KEY=""
WITH_CLOUDINIT=1         # par défaut: AVEC cloud-init

CLOUD_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
CLOUD_IMAGE_CACHE="/var/lib/vz/template/cache"
CLOUD_IMAGE_FILE="${CLOUD_IMAGE_CACHE}/debian-12-genericcloud-amd64.qcow2"
SNIPPETS_DIR="/var/lib/vz/snippets"
OMV_USER="omvadmin"
OMV_DEFAULT_PWD=""
OMV_INSTALL_URL="https://raw.githubusercontent.com/OpenMediaVault-Plugin-Developers/installScript/master/install"

# =====================
# Parsing des arguments
# =====================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) VM_NAME="$2"; shift; shift;;
    --memory) MEMORY="$2"; shift; shift;;
    --cores) CORES="$2"; shift; shift;;
    --disk) DISK_SIZE="$2"; shift; shift;;
    --bridge) BRIDGE="$2"; shift; shift;;
    --storage) STORAGE="$2"; shift; shift;;
    --with-cloudinit) WITH_CLOUDINIT=1; shift;;
    --no-cloudinit) WITH_CLOUDINIT=0; shift;;
    --ssh-key) SSH_KEY="$2"; shift; shift;;
    --timezone) TIMEZONE="$2"; shift; shift;;
    --omv-install-url) OMV_INSTALL_URL="$2"; shift; shift;;
    *) err "Argument inconnu: $1"; exit 1;;
  esac
done

# =====================
# Pré-checks
# =====================
if [[ $(id -u) -ne 0 ]]; then
  err "Ce script doit être exécuté en root sur un nœud Proxmox."
  exit 1
fi
command -v pvesh >/dev/null 2>&1 || { err "pvesh introuvable. Exécuter sur un nœud Proxmox."; exit 1; }
command -v qm >/dev/null 2>&1 || { err "qm introuvable. Exécuter sur un nœud Proxmox."; exit 1; }

mkdir -p "$CLOUD_IMAGE_CACHE" "$SNIPPETS_DIR"

# =====================
# Validation des stockages
# =====================
step "Validation des stockages"
# Vérifier que le stockage système existe
if ! pvesm status | awk 'NR>1{print $1}' | grep -qx "$STORAGE"; then
  err "Le stockage spécifié --storage='$STORAGE' est introuvable."; pvesm status | awk 'NR==1 || NR>1{print $1, $2, $3, $4}' >&2 || true; exit 1
fi
# Vérifier que le stockage supporte 'images'
STORAGE_CONTENTS=$(pvesm config "$STORAGE" 2>/dev/null | awk -F': ' '/^\s*content:/{print $2}' || true)
if [[ -n "$STORAGE_CONTENTS" ]] && ! echo "$STORAGE_CONTENTS" | grep -qw "images"; then
  err "Le stockage '$STORAGE' ne supporte pas le contenu 'images'. Contenu actuel: $STORAGE_CONTENTS"
  exit 1
fi
ok "Stockage '$STORAGE' prêt (images)"

# Si Cloud-Init requis, s'assurer que 'local' et 'snippets' existent
if [[ $WITH_CLOUDINIT -eq 1 ]]; then
  if ! pvesm status | awk 'NR>1{print $1}' | grep -qx "local"; then
    err "Cloud-Init demandé, mais le stockage 'local' est introuvable."
    exit 1
  fi
  LOCAL_CONTENTS=$(pvesm config local 2>/dev/null | awk -F': ' '/^\s*content:/{print $2}' || true)
  if ! echo "$LOCAL_CONTENTS" | grep -qw "snippets"; then
    step "Activation du contenu 'snippets' sur 'local'"
    pvesm set local --content "images,iso,backup,vztmpl,snippets" >/dev/null 2>&1 || { err "Impossible d'activer 'snippets' sur 'local'"; exit 1; }
  fi
  ok "Snippets disponibles sur 'local'"
fi

# =====================
# Téléchargement de l'image Debian Cloud
# =====================
if [[ ! -f "$CLOUD_IMAGE_FILE" ]]; then
  step "Téléchargement de l'image Debian Cloud"
  curl -fL "$CLOUD_IMAGE_URL" -o "$CLOUD_IMAGE_FILE"
  ok "Image téléchargée: $(basename "$CLOUD_IMAGE_FILE")"
else
  ok "Image Debian Cloud déjà présente"
fi

# =====================
# Allocation d'un VMID et création de la VM
# =====================
step "Allocation d'un VMID libre"
VMID=$(pvesh get /cluster/nextid)
ok "VMID alloué: $VMID"

step "Création de la VM"
qm create "$VMID" \
  --name "$VM_NAME" \
  --memory "$MEMORY" \
  --cores "$CORES" \
  --net0 "virtio,bridge=${BRIDGE}" \
  --scsihw virtio-scsi-pci \
  --agent enabled=1

step "Import du disque cloud dans '$STORAGE'"
qm importdisk "$VMID" "$CLOUD_IMAGE_FILE" "$STORAGE"

step "Configuration du boot sur scsi0"
qm set "$VMID" \
  --scsi0 "${STORAGE}:vm-${VMID}-disk-0" \
  --boot c \
  --bootdisk scsi0 \
  --serial0 socket \
  --vga serial0

if [[ -n "$DISK_SIZE" ]]; then
  step "Redimensionnement du disque système à ${DISK_SIZE}"
  qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0,size=${DISK_SIZE}"
fi

# =====================
# Mode Cloud-Init (optionnel)
# =====================
if [[ $WITH_CLOUDINIT -eq 1 ]]; then
  step "Ajout du lecteur Cloud-Init"
  qm set "$VMID" --ide2 "${STORAGE}:cloudinit"

  # Gestion SSH key ou mot de passe temporaire
  if [[ -z "$SSH_KEY" ]]; then
    OMV_DEFAULT_PWD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)
    warn "Aucune clé SSH fournie. Mot de passe temporaire pour ${OMV_USER}: ${OMV_DEFAULT_PWD}"
  else
    TMP_SSH_KEY=$(mktemp)
    printf '%s\n' "$SSH_KEY" > "$TMP_SSH_KEY"
  fi

  step "Génération du user-data Cloud-Init"
  USER_DATA_FILE="${SNIPPETS_DIR}/omv-${VMID}-user.yaml"
  cat > "$USER_DATA_FILE" <<EOF
#cloud-config
preserve_hostname: false
hostname: ${VM_NAME}
manage_etc_hosts: true
timezone: ${TIMEZONE}
locale: fr_CH.UTF-8
keyboard:
  layout: ch
  variant: fr
users:
  - name: ${OMV_USER}
    groups: [adm, cdrom, dip, plugdev, sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
package_update: true
package_upgrade: false
packages:
  - qemu-guest-agent
  - curl
  - ca-certificates
  - gnupg
  - locales
  - console-setup
  - keyboard-configuration
runcmd:
  - [ bash, -lc, "systemctl enable --now qemu-guest-agent || true" ]
  - [ bash, -lc, "curl -fsSL ${OMV_INSTALL_URL} -o /root/omv-install.sh" ]
  - [ bash, -lc, "bash /root/omv-install.sh || (echo 'Échec installation OMV' && exit 1)" ]
  - [ bash, -lc, "wget -qO - https://github.com/OpenMediaVault-Plugin-Developers/packages/raw/master/install | bash || true" ]
  - [ bash, -lc, "apt-get update" ]
  - [ bash, -lc, "apt-get install -y openmediavault-luksencryption || true" ]
EOF

  step "Paramétrage Cloud-Init (utilisateur/SSH/IP/DHCP)"
  if [[ -n "$OMV_DEFAULT_PWD" ]]; then
    qm set "$VMID" --ciuser "$OMV_USER" --cipassword "$OMV_DEFAULT_PWD"
  else
    qm set "$VMID" --ciuser "$OMV_USER" --sshkey "$TMP_SSH_KEY"
  fi
  qm set "$VMID" --cicustom "user=local:snippets/$(basename "$USER_DATA_FILE")"
  qm set "$VMID" --ipconfig0 ip=dhcp
  if [[ -n "${TMP_SSH_KEY:-}" && -f "$TMP_SSH_KEY" ]]; then rm -f "$TMP_SSH_KEY"; fi
else
  warn "Cloud-Init désactivé: aucune installation OMV automatique. Vous pourrez l'installer manuellement dans la VM."
fi

# =====================
# Démarrage et infos
# =====================
step "Démarrage de la VM"
qm start "$VMID"

echo ""
ok "VM créée et démarrée"
echo "  VMID: $VMID"
echo "  Nom:  $VM_NAME"
echo "  Stockage: $STORAGE"
echo "  Disque: $DISK_SIZE"
echo "  Réseau: bridge $BRIDGE (DHCP)"
if [[ -n "$OMV_DEFAULT_PWD" ]]; then
  echo "  Utilisateur: ${OMV_USER} / Mot de passe temporaire: ${OMV_DEFAULT_PWD}"
fi

# Tentative de récupération d'IP
for i in {1..30}; do
  sleep 5
  if qm agent "$VMID" ping >/dev/null 2>&1; then
    RAW_JSON=$(qm agent "$VMID" network-get-interfaces 2>/dev/null || true)
    if command -v jq >/dev/null 2>&1; then
      IPs=$(echo "$RAW_JSON" | jq -r '.[] | select(."ip-addresses") | ."ip-addresses"[]? | select(."ip-address-type"=="ipv4") | .address' 2>/dev/null || true)
      if [[ -n "$IPs" ]]; then
        ok "Adresses IP détectées:"; echo "$IPs" | sed 's/^/  - /'
        break
      fi
    else
      warn "qemu-guest-agent actif mais 'jq' est indisponible. JSON brut des interfaces:"; echo "$RAW_JSON"; break
    fi
  fi
  if [[ $i -eq 30 ]]; then warn "Impossible d'obtenir l'IP (qemu-guest-agent peut ne pas être prêt)."; fi
done

echo ""
if [[ $WITH_CLOUDINIT -eq 1 ]]; then
  echo "Accédez à l'interface OMV via http://<IP_VM>/"
else
  echo "VM prête sans Cloud-Init. Installez OMV manuellement si souhaité."
fi

#!/usr/bin/env bash
set -euo pipefail

# Automatisation de création d'une VM Debian + installation OMV sur Proxmox via Cloud-Init
# - VMID choisi automatiquement par Proxmox
# - Installation OMV + OMV-Extras + plugin LUKS
# - qemu-guest-agent activé
#
# Usage basique:
#   ./setup-omv-on-proxmox.sh --name omv --memory 4096 --cores 2 --disk 32G --bridge vmbr0 --storage local-lvm --ssh-key "$(cat ~/.ssh/id_rsa.pub)"
#
# À exécuter en root sur un nœud Proxmox.

# =====================
# Paramètres par défaut
# =====================
VM_NAME="omv"
MEMORY="4096"           # MiB
CORES="2"
DISK_SIZE="32G"
BRIDGE="vmbr0"
STORAGE="local-lvm"     # stockage pour le disque et cloud-init
TIMEZONE="Europe/Zurich"
SSH_KEY=""
CLOUD_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
CLOUD_IMAGE_CACHE="/var/lib/vz/template/cache"
CLOUD_IMAGE_FILE="${CLOUD_IMAGE_CACHE}/debian-12-genericcloud-amd64.qcow2"
SNIPPETS_DIR="/var/lib/vz/snippets"
OMV_USER="omvadmin"
OMV_DEFAULT_PWD=""
# Script d'installation OMV (communautaire, maintenu par OMV-Plugin-Developers)
OMV_INSTALL_URL="https://raw.githubusercontent.com/OpenMediaVault-Plugin-Developers/installScript/master/install"

# Disques de données optionnels
DATA_DISKS=()           # tailles, ex: ("1T" "500G")
DATA_STORAGE=""        # stockage pour les disques de données (défaut: STORAGE)

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
    --data-disk) DATA_DISKS+=("$2"); shift; shift;;
    --data-storage) DATA_STORAGE="$2"; shift; shift;;
    --ssh-key) SSH_KEY="$2"; shift; shift;;
    --timezone) TIMEZONE="$2"; shift; shift;;
    --omv-install-url) OMV_INSTALL_URL="$2"; shift; shift;;
    *) echo "Argument inconnu: $1"; exit 1;;
  esac
done

# =====================
# Pré-checks
# =====================
if [[ $(id -u) -ne 0 ]]; then
  echo "Ce script doit être exécuté en root sur un nœud Proxmox." >&2
  exit 1
fi

# Si un stockage de données a été spécifié, le valider; sinon, utiliser STORAGE
if [[ -z "$DATA_STORAGE" ]]; then
  DATA_STORAGE="$STORAGE"
fi
if ! pvesm status | awk 'NR>1{print $1}' | grep -qx "$DATA_STORAGE"; then
  echo "[ERREUR] Le stockage spécifié --data-storage='$DATA_STORAGE' est introuvable." >&2
  pvesm status | awk 'NR==1 || NR>1{print $1, $2, $3, $4}' >&2 || true
  exit 1
fi
DATA_STORAGE_CONTENTS=$(pvesm config "$DATA_STORAGE" 2>/dev/null | awk -F': ' '/^\s*content:/{print $2}' || true)
if [[ -n "$DATA_STORAGE_CONTENTS" ]] && ! echo "$DATA_STORAGE_CONTENTS" | grep -qw "images"; then
  echo "[ERREUR] Le stockage '$DATA_STORAGE' ne supporte pas le contenu 'images' nécessaire pour créer des disques." >&2
  echo "Contenu actuel: $DATA_STORAGE_CONTENTS" >&2
  exit 1
fi

command -v pvesh >/dev/null 2>&1 || { echo "pvesh introuvable. Exécuter sur un nœud Proxmox." >&2; exit 1; }
command -v qm >/dev/null 2>&1 || { echo "qm introuvable. Exécuter sur un nœud Proxmox." >&2; exit 1; }

mkdir -p "$CLOUD_IMAGE_CACHE" "$SNIPPETS_DIR"

# =====================
# Validation des stockages
# =====================
echo "Validation des stockages..."

# Vérifier que 'local' existe (utilisé pour snippets/user-data)
if ! pvesm status | awk 'NR>1{print $1}' | grep -qx "local"; then
  echo "[ERREUR] Le stockage 'local' est introuvable. Veuillez définir un stockage 'local' (dir) sur ce nœud." >&2
  exit 1
fi

# Activer snippets sur 'local' si besoin
LOCAL_CONTENTS=$(pvesm config local 2>/dev/null | awk -F': ' '/^\s*content:/{print $2}' || true)
if ! echo "$LOCAL_CONTENTS" | grep -qw "snippets"; then
  echo "Activation du contenu 'snippets' sur le stockage 'local'..."
  if ! pvesm set local --content "images,iso,backup,vztmpl,snippets" >/dev/null 2>&1; then
    echo "[ERREUR] Impossible d'activer 'snippets' sur 'local'. Contenu actuel: $LOCAL_CONTENTS" >&2
    exit 1
  fi
fi

# Vérifier que le stockage de disque spécifié existe
if ! pvesm status | awk 'NR>1{print $1}' | grep -qx "$STORAGE"; then
  echo "[ERREUR] Le stockage spécifié --storage='$STORAGE' est introuvable. Storages disponibles:" >&2
  pvesm status | awk 'NR==1 || NR>1{print $1, $2, $3, $4}' >&2 || true
  exit 1
fi

# Vérifier que le stockage supporte le contenu 'images'
STORAGE_CONTENTS=$(pvesm config "$STORAGE" 2>/dev/null | awk -F': ' '/^\s*content:/{print $2}' || true)
if [[ -n "$STORAGE_CONTENTS" ]] && ! echo "$STORAGE_CONTENTS" | grep -qw "images"; then
  echo "[ERREUR] Le stockage '$STORAGE' ne supporte pas le contenu 'images'. Contenu actuel: $STORAGE_CONTENTS" >&2
  echo "Veuillez choisir un autre stockage via --storage (ex: local-lvm) ou activer 'images' sur ce stockage." >&2
  exit 1
fi

# =====================
# Téléchargement de l'image Debian Cloud
# =====================
if [[ ! -f "$CLOUD_IMAGE_FILE" ]]; then
  echo "Téléchargement de l'image Debian Cloud: $CLOUD_IMAGE_URL"
  curl -fL "$CLOUD_IMAGE_URL" -o "$CLOUD_IMAGE_FILE"
fi

# =====================
# Allocation d'un VMID et création de la VM
# =====================
VMID=$(pvesh get /cluster/nextid)
echo "VMID alloué: $VMID"

# Créer la VM de base
qm create "$VMID" \
  --name "$VM_NAME" \
  --memory "$MEMORY" \
  --cores "$CORES" \
  --net0 "virtio,bridge=${BRIDGE}" \
  --scsihw virtio-scsi-pci \
  --agent enabled=1

# Importer le disque cloud dans le stockage choisi
qm importdisk "$VMID" "$CLOUD_IMAGE_FILE" "$STORAGE"

# Attacher le disque importé sur scsi0 et configurer le boot
qm set "$VMID" \
  --scsi0 "${STORAGE}:vm-${VMID}-disk-0" \
  --boot c \
  --bootdisk scsi0 \
  --serial0 socket \
  --vga serial0

# Ajouter le lecteur cloud-init
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"

# Redimensionner le disque système si demandé
if [[ -n "$DISK_SIZE" ]]; then
  qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0,size=${DISK_SIZE}"
fi

# Créer et attacher les disques de données (scsi1, scsi2, ...)
if [[ ${#DATA_DISKS[@]} -gt 0 ]]; then
  echo "Création des disques de données sur '$DATA_STORAGE': ${DATA_DISKS[*]}"
  IDX=1
  for SIZE in "${DATA_DISKS[@]}"; do
    # trouver le prochain index SCSI libre (éviter conflit si déjà utilisé)
    while qm config "$VMID" | awk -F': ' '/^scsi[0-9]+:/{print $1}' | grep -qx "scsi${IDX}"; do
      IDX=$((IDX+1))
    done
    echo " - Ajout scsi${IDX}: ${DATA_STORAGE}:${SIZE}"
    qm set "$VMID" --scsi${IDX} "${DATA_STORAGE}:${SIZE},ssd=1,discard=on"
    IDX=$((IDX+1))
  done
fi

# =====================
# Cloud-Init: utilisateur, SSH, runcmd pour OMV
# =====================
# Gestion SSH key et mot de passe fallback
if [[ -z "$SSH_KEY" ]]; then
  # Générer un mot de passe simple pour le premier accès (à changer ensuite)
  OMV_DEFAULT_PWD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)
  echo "AUCUNE clé SSH fournie. Un mot de passe temporaire sera défini pour ${OMV_USER}: ${OMV_DEFAULT_PWD}"
else
  # Écrire la clé dans un fichier temporaire pour qm set --sshkey
  TMP_SSH_KEY=$(mktemp)
  printf '%s\n' "$SSH_KEY" > "$TMP_SSH_KEY"
fi

# Construire un user-data personnalisé pour installer OMV
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

# Si pas de clé SSH, définir un mot de passe via qm set --cipassword
if [[ -n "$OMV_DEFAULT_PWD" ]]; then
  qm set "$VMID" --ciuser "$OMV_USER" --cipassword "$OMV_DEFAULT_PWD"
else
  qm set "$VMID" --ciuser "$OMV_USER" --sshkey "$TMP_SSH_KEY"
fi

# Fuseau horaire via ci ? sinon laisser par défaut
if [[ -n "$TIMEZONE" ]]; then
  qm set "$VMID" --cisettings "timezone=${TIMEZONE}"
fi

# DHCP par défaut
qm set "$VMID" --ipconfig0 ip=dhcp

# Lier le user-data custom via snippets
qm set "$VMID" --cicustom "user=local:snippets/$(basename "$USER_DATA_FILE")"

# Nettoyage temp clé
if [[ -n "${TMP_SSH_KEY:-}" && -f "$TMP_SSH_KEY" ]]; then
  rm -f "$TMP_SSH_KEY"
fi

# =====================
# Démarrage et affichage d'infos
# =====================
qm start "$VMID"

echo "\nVM créée et démarrée:"
echo "  VMID: $VMID"
echo "  Nom:  $VM_NAME"
echo "  Stockage: $STORAGE"
echo "  Disque: $DISK_SIZE"
echo "  Réseau: bridge $BRIDGE (DHCP)"
if [[ -n "$OMV_DEFAULT_PWD" ]]; then
  echo "  Utilisateur: ${OMV_USER} / Mot de passe temporaire: ${OMV_DEFAULT_PWD}"
else
  echo "  Utilisateur: ${OMV_USER} (connexion par SSH key)"
fi

# Tentative de récupération d'IP (si agent prêt)
for i in {1..30}; do
  sleep 5
  if qm agent "$VMID" ping >/dev/null 2>&1; then
    RAW_JSON=$(qm agent "$VMID" network-get-interfaces 2>/dev/null || true)
    if command -v jq >/dev/null 2>&1; then
      IPs=$(echo "$RAW_JSON" | jq -r '.[] | select(."ip-addresses") | ."ip-addresses"[]? | select(."ip-address-type"=="ipv4") | .address' 2>/dev/null || true)
      if [[ -n "$IPs" ]]; then
        echo "Adresses IP détectées:"; echo "$IPs" | sed 's/^/  - /'
        break
      fi
    else
      echo "qemu-guest-agent actif mais 'jq' est indisponible. JSON brut des interfaces:"
      echo "$RAW_JSON"
      break
    fi
  fi
  if [[ $i -eq 30 ]]; then echo "Impossible d'obtenir l'IP (qemu-guest-agent peut ne pas être prêt)."; fi
done

echo "\nAccédez à l'interface OMV via http://<IP_VM>/"

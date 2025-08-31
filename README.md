# Déploiement automatique d'OpenMediaVault (OMV) sur Proxmox

Ce dépôt fournit un script shell à exécuter sur un nœud Proxmox pour créer automatiquement une VM Debian, y installer OpenMediaVault, OMV-Extras, puis le plugin de chiffrement des disques (LUKS). Le script valide les stockages Proxmox utilisés et configure la zone horaire, la langue et le clavier.

- VMID: automatiquement choisi par Proxmox (`/cluster/nextid`).
- Image: Debian 12 (bookworm) Generic Cloud (QCOW2).
- Provisioning: Cloud-Init avec exécution du script officiel d'installation OMV, installation d'OMV-Extras puis du plugin `openmediavault-luksencryption`.

## Prérequis
- Proxmox VE (root sur le nœud)
- Stockages par défaut `local` (dir) et `local-lvm` (LVM-Thin) présents. Le script vérifie:
  - que `local` existe et supporte `snippets` (l'active si nécessaire)
  - que `--storage` existe et supporte le contenu `images`
- Accès Internet sortant depuis le nœud Proxmox
- Une clé SSH publique si vous souhaitez un accès SSH sans mot de passe dans la VM

## One-liner d'installation
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/sdavid66/omv-proxmox-swiss/main/setup-omv-on-proxmox.sh)" -- \
  --name omv \
  --memory 2048 \
  --cores 2 \
  --disk 32G \
  --bridge vmbr0 \
  --storage local-lvm \
  --ssh-key "$(cat ~/.ssh/id_rsa.pub)"
```

Paramètres disponibles (tous optionnels):
- `--name` Nom de la VM (défaut: `omv`)
- `--memory` RAM en MiB (défaut: `2048`)
- `--cores` vCPU (défaut: `2`)
- `--disk` Taille du disque système (défaut: `32G`)
- `--bridge` Pont réseau Proxmox (défaut: `vmbr0`)
- `--storage` Stockage pour le disque (défaut: `local-lvm`)
- `--ssh-key` Clé publique SSH à injecter pour l'utilisateur `omvadmin`
- `--timezone` Fuseau horaire (défaut: `Europe/Zurich`)
- `--with-cloudinit` Force Cloud-Init (par défaut déjà activé)
- `--no-cloudinit` Désactive Cloud-Init et l'installation auto dans la VM

Paramètres régionaux par défaut dans la VM:
- Fuseau horaire: Europe/Zurich
- Langue: fr_CH.UTF-8
- Clavier: Suisse (français) — layout `ch`, variant `fr`

Le script va (par défaut avec Cloud-Init):
1. Télécharger l'image Debian 12 Generic Cloud si absente
2. Créer un VMID libre automatiquement
3. Créer la VM et y importer le disque
4. Ajouter le lecteur Cloud-Init, injecter un user-data, configurer DHCP
5. Démarrer la VM et afficher son VMID (et si possible son IP via qemu-guest-agent)

Une fois la VM démarrée, accédez à l'interface OMV via HTTP sur l'IP de la VM (port 80). Les identifiants par défaut OMV sont définis par OMV lors de l'installation (admin / mot de passe demandé par OMV). Le plugin de chiffrement LUKS sera présent dans l'UI (vous pourrez ensuite chiffrer/configurer vos disques via l'interface OMV).

## Modes d'installation
- **Avec Cloud-Init (par défaut)**: ajoute un lecteur Cloud-Init, injecte un `user-data` avec utilisateur `omvadmin`, configure DHCP et lance l'installation automatique d'OMV (ainsi que `qemu-guest-agent` et le plugin LUKS).
- **Sans Cloud-Init (`--no-cloudinit`)**: la VM est créée et démarrée, mais aucune configuration/installation dans l'OS invité n'est effectuée automatiquement. Vous pouvez installer OMV manuellement.

## Notes
- Le script active et installe `qemu-guest-agent` dans la VM pour permettre à Proxmox de récupérer l'IP.
- Si vous ne fournissez pas `--ssh-key`, le compte `omvadmin` sera créé avec un mot de passe par défaut faible (affiché par le script). Changez-le immédiatement.
- Vous pouvez ajuster l'URL de l'image Debian ou les options hardware dans le script selon vos besoins.
- Pour ajouter des disques de données, créez-les depuis Proxmox (qm set --scsiX <storage>:<size>) ou via l'UI de Proxmox, puis chiffrez-les et montez-les dans OMV.

## Sortie colorée
Le script affiche les étapes en bleu, les succès en vert, les avertissements en jaune et les erreurs en rouge. En cas d'échec, une trace claire est affichée (trap sur erreur).

## Désinstallation / suppression de la VM
Pour supprimer la VM (exemple avec VMID 101):
```bash
qm stop 101 || true
qm destroy 101
```

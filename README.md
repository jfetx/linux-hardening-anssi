<div align="center">

# 🛡️ linux-hardening-anssi

**Audit et durcissement d'Ubuntu selon le guide ANSSI-BP-028 v2.0**
*« Recommandations de configuration d'un système GNU/Linux » — niveaux Minimal et Intermédiaire*

![Version](https://img.shields.io/badge/version-v1.7-blue)
![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04%20LTS-E95420?logo=ubuntu&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-5.x-4EAA25?logo=gnubash&logoColor=white)
![ANSSI](https://img.shields.io/badge/ANSSI--BP--028-Minimal%20%7C%20Interm%C3%A9diaire%20%7C%20Renforc%C3%A9-002395)
![Mesures](https://img.shields.io/badge/mesures-41%20%2B%207%20renforc%C3%A9%20%2B%208%20%C3%A0%20%C3%A9tudier-success)
![R1–R80](https://img.shields.io/badge/R1%E2%80%93R80-Interm%C3%A9diaire%20complet-002395)

</div>

---

## 📑 Sommaire

- [✨ En bref](#-en-bref)
- [📦 Contenu du dépôt](#-contenu-du-dépôt)
- [🧭 Démarche globale](#-démarche-globale)
- [❓ Étape 0 — Questions à poser avant l'installation](#-étape-0--questions-à-poser-avant-linstallation)
- [💽 Étape 1 — Installation et partitionnement](#-étape-1--installation-et-partitionnement)
- [🔑 Étape 2 — Accès SSH par clé](#-étape-2--accès-ssh-par-clé)
- [🔍 Étape 3 — Audit initial](#-étape-3--audit-initial)
- [🔒 Étape 4 — Durcissement](#-étape-4--durcissement)
- [✅ Étape 5 — Vérification après redémarrage](#-étape-5--vérification-après-redémarrage)
- [🧪 Vérification supplémentaire R1–R80](#-vérification-supplémentaire-r1r80)
- [📋 Liste des mesures](#-liste-des-mesures)
- [🐳 Docker et durcissement](#-docker-et-durcissement)
- [⚠️ Pièges connus sur Ubuntu](#️-pièges-connus-sur-ubuntu)
- [♻️ Sauvegardes et retour arrière](#️-sauvegardes-et-retour-arrière)
- [🛠️ Dépannage](#️-dépannage)
- [🗓️ Historique des versions](#️-historique-des-versions)
- [⚖️ Avertissement](#️-avertissement)

---

## ✨ En bref

| | |
| --- | --- |
| 🎯 **Objectif** | Amener un poste Ubuntu au niveau **Minimal** ou **Intermédiaire** du guide ANSSI-BP-028 et le prouver, **recommandation par recommandation (R1–R80)** |
| 🔍 **Audit** | Contrôle en lecture seule, tableau coloré, export CSV pour la documentation |
| 🔒 **Durcissement** | Interactif, automatique ou mesure par mesure, avec simulation (`-n`) |
| 💾 **Sécurité** | Sauvegarde de chaque fichier modifié, journal de toutes les actions, validation `sshd -t` / `visudo` |
| 🔁 **Persistance** | Les contrôles vérifient la configuration chargée au prochain démarrage, pas seulement l'état en mémoire |
| 📊 **Résultat de référence** | 44 % après installation → **100 %** après durcissement et redémarrage (VM Ubuntu 24.04, mesures v1.5) |
| 📑 **Preuve** | Rapport R1–R80 : chaque recommandation du niveau est conforme, justifiée par écrit, attestée ou sans objet |

---

## 📦 Contenu du dépôt

| Fichier | Rôle |
| --- | --- |
| 🟥 `anssi-lib-renforce.sh` | Niveau Renforcé : mesures simples (R01–R11) et points à étudier (R20–R27) |
| 📚 `anssi-lib.sh` | Mesures Minimal (M01–M15) et Intermédiaire (I01–I26) : une fonction `check_<ID>` (contrôle) et une fonction `apply_<ID>` (correction) par mesure |
| 🔍 `anssi-audit.sh` | Audit en lecture seule, tableau de conformité, export CSV |
| 🔒 `anssi-harden.sh` | Durcissement : menu interactif, mode automatique, sélection d'IDs, simulation |
| 🧪 `anssi-bp028-r80.sh` | Vérification indépendante des **80 recommandations R1–R80** du guide (lecture seule), d'après le référentiel ComplianceAsCode adapté à Ubuntu ; gère les écarts justifiés (`-j`) |
| 📝 `ecarts-justifies.exemple.conf` | Modèle d'écarts justifiés et d'attestations, à adapter à chaque poste |
| 📄 `.gitattributes` | Force les fins de ligne Unix (LF) : un script en CRLF ne s'exécute pas sous Linux |

> 💡 L'audit et le durcissement appellent **les mêmes fonctions de contrôle** : ils ne peuvent pas être en désaccord sur ce qui est « conforme ».

---

## 🧭 Démarche globale

```mermaid
flowchart LR
    A["💽 Installation<br/>partitionnement LVM"] --> B["📝 fstab<br/>nodev / nosuid / noexec"]
    B --> C["🔍 Audit initial"]
    C --> D["🔒 Niveau Minimal"]
    D --> E["🔒 Niveau Intermédiaire"]
    E --> F["🔄 Redémarrage"]
    F --> G["✅ Audit final<br/>+ CSV"]
    G -.->|écart| E
```

> 📸 **Sur une VM** (Proxmox, VirtualBox…), prenez un **snapshot avant chaque étape** : un retour arrière prend alors quelques secondes.

---

## ❓ Étape 0 — Questions à poser avant l'installation

> 🎯 **Une réponse manquante = un problème après le durcissement.** Ces questions se posent **avant** d'installer, idéalement lors d'une journée de cadrage.

| Thème | Question | Pourquoi (mesure concernée) |
| --- | --- | --- |
| 🎚️ Niveau | Quel niveau ANSSI est attendu (Minimal, Intermédiaire, Renforcé) ? Un référentiel est-il imposé ? | Fixe le périmètre et la durée |
| 📦 Applications | Quels logiciels et **dépendances** installer (paquets, versions, Python, Java, Node…) ? Qui les installe ? | `noexec` sur `/tmp` (I05), umask 027 (I10), paquets retirés (M03) |
| 🐳 Conteneurs | Docker est-il utilisé ? Images disponibles sur un registre ou fournies en fichiers ? Versions figées ? | Partition dédiée, pare-feu (Docker contourne ufw), `ip_forward` (I01) |
| 🗄️ Base de données | Quel moteur (SQL Server, PostgreSQL, MySQL) ? En conteneur ou sur l'hôte ? Volume de données prévu ? | Taille de `/srv` ou `/var/lib/docker` |
| 🌐 Réseau | Ports à ouvrir ? Accès local uniquement ou depuis d'autres machines ? | Pare-feu (M05), publication des ports Docker |
| 📴 Connexion | Poste connecté à Internet ou isolé en production ? | Tout doit être installé **avant** la déconnexion |
| 🕐 Heure | Un serveur NTP interne sera-t-il disponible ? | Horodatage des journaux (M12) |
| 🔄 Mises à jour | Automatiques ou gérées par le client ? | M02 : écart à justifier si désactivées |
| 👥 Comptes | Combien d'administrateurs et d'utilisateurs ? Qui a besoin de SSH ? | sudo (I09), `AllowGroups` (I16), groupe `docker` |
| 🔑 SSH | Accès distant nécessaire ? Depuis quel réseau ? | M06, I16, règle ufw limitée au réseau d'administration |
| 🔌 Périphériques | Quels périphériques USB (souris, clavier, adaptateurs série, sondes) ? | Blocage du stockage USB (I04) |
| 💻 Matériel | Modèle, UEFI/Secure Boot, TPM, **taille et type du disque** (NVMe/SATA) ? Portable ? | Partitionnement, Wi-Fi, fermeture du capot |
| 🔐 Chiffrement | Chiffrement du disque exigé ? | Se décide **à l'installation** (LUKS) |
| 🖥️ Interface | Interface graphique nécessaire ? | Ubuntu Server ou Desktop, `fusermount3` (I15) |

> 📝 Toute réponse « non connue » devient une **hypothèse écrite** dans le bon de commande ou la documentation.

---

## 💽 Étape 1 — Installation et partitionnement

> ⚠️ **Le partitionnement se décide à l'installation.** C'est la seule mesure qu'on ne peut pas corriger après coup sans réinstaller (mesure I06).

### Pourquoi séparer les partitions ?

| Raison | Exemple |
| --- | --- |
| 🧱 **Limiter l'impact d'un remplissage** | Des journaux qui saturent `/var/log` ne bloquent pas tout le système |
| 🚫 **Appliquer des options restrictives** | `noexec` sur `/var/tmp` empêche d'y exécuter un binaire déposé par un attaquant |
| 📈 **Agrandir sans réinstaller** | Avec LVM, de l'espace libre dans le groupe de volumes permet d'étendre un volume à chaud |

### Options de montage

| Option | Effet |
| --- | --- |
| `nodev` | Interdit les fichiers de périphérique sur la partition |
| `nosuid` | Ignore les bits setuid/setgid des exécutables qui s'y trouvent |
| `noexec` | Interdit l'exécution directe de binaires depuis la partition |

### Schéma de référence (disque de 64 Go)

| | Volume | Taille | Système de fichiers | Point de montage | Options |
| --- | --- | --- | --- | --- | --- |
| 🥾 | Partition EFI *(UEFI uniquement)* | 1 Go | FAT32 | `/boot/efi` | `umask=0077` |
| 🥾 | Partition GPT | 2 Go | ext4 | `/boot` | `nodev,nosuid,noexec` |
| 🌳 | `vg0/lv_root` | 20 Go | ext4 | `/` | `defaults` |
| 🏠 | `vg0/lv_home` | 8 Go | ext4 | `/home` | `nodev,nosuid` |
| 🗄️ | `vg0/lv_var` | 10 Go | ext4 | `/var` | `nodev,nosuid` |
| 📜 | `vg0/lv_varlog` | 5 Go | ext4 | `/var/log` | `nodev,nosuid,noexec` |
| 🕵️ | `vg0/lv_audit` | 3 Go | ext4 | `/var/log/audit` | `nodev,nosuid,noexec` |
| 🧹 | `vg0/lv_vartmp` | 3 Go | ext4 | `/var/tmp` | `nodev,nosuid,noexec` |
| 💤 | `vg0/lv_swap` | 4 Go | swap | — | — |
| ⚡ | tmpfs *(créé par la mesure I05)* | RAM | tmpfs | `/tmp`, `/dev/shm` | `nodev,nosuid,noexec` |
| ➕ | Espace libre dans `vg0` | ~9 Go | — | — | Réserve pour agrandir un volume |

```mermaid
flowchart TB
    DISK["💾 Disque 64 Go"] --> EFI["🥾 /boot/efi · 1 Go"]
    DISK --> BOOT["🥾 /boot · 2 Go"]
    DISK --> PV["📦 PV LVM · ~61 Go"]
    PV --> VG["vg0"]
    VG --> R["🌳 / · 20 Go"]
    VG --> H["🏠 /home · 8 Go"]
    VG --> V["🗄️ /var · 10 Go"]
    VG --> VL["📜 /var/log · 5 Go"]
    VG --> VA["🕵️ /var/log/audit · 3 Go"]
    VG --> VT["🧹 /var/tmp · 3 Go"]
    VG --> SW["💤 swap · 4 Go"]
    VG --> FREE["➕ libre · ~9 Go"]
```

### 📏 Dimensionnement selon la taille du disque

Schéma pour un **poste avec Docker et une base de données** (le cas le plus exigeant). Les capacités sont **réelles** : un disque « 256 Go » offre environ 238 Gio.

| Volume | Options | 256 Go (~238 Gio) | 512 Go (~476 Gio) | 1 To (~931 Gio) |
| --- | --- | --- | --- | --- |
| 🥾 `/boot/efi` | `umask=0077` | 1 | 1 | 1 |
| 🥾 `/boot` | `nodev,nosuid,noexec` | 2 | 2 | 2 |
| 🌳 `/` | `defaults` | 30 | 40 | 50 |
| 🏠 `/home` | `nodev,nosuid` | 10 | 20 | 40 |
| 🗄️ `/var` | `nodev,nosuid` | 15 | 20 | 30 |
| 📜 `/var/log` | `nodev,nosuid,noexec` | 10 | 20 | 30 |
| 🕵️ `/var/log/audit` | `nodev,nosuid,noexec` | 5 | 10 | 15 |
| 🧹 `/var/tmp` | `nodev,nosuid,noexec` | 5 | 10 | 15 |
| 💤 swap | — | 8 | 16 | 16 |
| 🐳 `/var/lib/docker` | `defaults` (voir ci-dessous) | 70 | 150 | 300 |
| 🗃️ `/srv` (données, volumes BDD) | `nodev,nosuid,noexec` | 50 | 120 | 300 |
| ➕ **Libre dans `vg0`** | — | **~32 (13 %)** | **~67 (14 %)** | **~132 (14 %)** |

Repères de calcul :

- **Garder 10 à 15 % libres** dans le groupe de volumes : un volume plein s'agrandit à chaud (`lvextend -r`), sans réinstaller.
- **Swap** : 8 à 16 Gio suffisent sur un serveur sans mise en veille prolongée (hibernation).
- **`/var/lib/docker`** : taille des images × 2 (mises à jour, couches) + marge. Une image SQL Server pèse ~1,5 Go, PostgreSQL ~0,4 Go.
- **`/srv`** : volume de données de la base sur la durée de vie du poste × 2. **À demander au client** (Étape 0).
- **Poste sans Docker ni base** : supprimer `/var/lib/docker` et `/srv`, et reporter l'espace sur l'espace libre ou `/var`.

### 🐳 Cas particulier : poste avec Docker et base de données

| Choix | Raison |
| --- | --- |
| **Volume dédié `/var/lib/docker`** | Les images et couches ne saturent pas `/var` (recommandation du CIS Docker Benchmark) |
| `/var/lib/docker` en **`defaults`** | Docker gère ses propres montages (overlay) ; des options restrictives peuvent casser certains conteneurs. **À durcir seulement après tests** |
| **Données de la base dans `/srv`** (volume *bind mount*) | Les données survivent à la suppression d'un conteneur, sont faciles à sauvegarder et peuvent porter `nodev,nosuid,noexec` |
| Exemple | `docker run -v /srv/mssql:/var/opt/mssql …` ou `-v /srv/pgdata:/var/lib/postgresql/data …` |

Lignes `fstab` supplémentaires :

```bash
add_opts /srv nodev,nosuid,noexec
# /var/lib/docker reste en « defaults »
```

### 💻 Cas particulier : ordinateur portable utilisé comme serveur

| Point | Action |
| --- | --- |
| Disque NVMe | Le disque s'appelle `nvme0n1` (partitions `nvme0n1p1`…), pas `sda` |
| Fermeture du capot | `HandleLidSwitch=ignore` dans `/etc/systemd/logind.conf`, sinon le poste se met en veille |
| Wi-Fi / Bluetooth | Désactiver s'ils ne servent pas (`rfkill block all`, pilotes interdits) |
| Vol | Un portable se vole : sans chiffrement, le documenter comme **risque résiduel accepté** |

### Dans l'installateur Ubuntu Server (Subiquity)

1. Type d'installation : **Ubuntu Server (minimized)**.
2. Stockage : choisir **Custom storage layout**.
3. Sélectionner le disque → **Use As Boot Device**. Cela crée `/boot/efi` en UEFI, ou une partition `bios_grub` de 1 Mo en BIOS.
4. **free space** → **Add GPT Partition** : `2G`, ext4, montée sur `/boot`.
5. **free space** → **Add GPT Partition** : taille vide (tout le reste), **Leave unformatted**.
6. **Create volume group (LVM)** : nom `vg0`, cocher la partition de l'étape 5.
7. Pour chaque ligne `vg0/…` du tableau : **free space** de `vg0` → **Create Logical Volume**. Pour `/var/log`, `/var/log/audit` et `/var/tmp`, choisir **Other** dans le menu *Mount* et saisir le chemin.
8. Vérifier le **FILE SYSTEM SUMMARY**, puis **Done** → **Continue**.
9. Profil : un compte administrateur **nominatif**. Cocher **Install OpenSSH server**. Aucun *featured snap*.

> 🖥️ **UEFI recommandé.** Sur Proxmox, choisir **OVMF (UEFI)** avec un *EFI Disk* (clés pré-enrôlées) et un *TPM v2.0* : c'est plus proche d'un poste réel et cela permet de tester Secure Boot.

### Ajouter les options de montage dans `/etc/fstab`

L'installateur ne permet pas de saisir les options : on les ajoute après le premier démarrage.

```bash
sudo cp -a /etc/fstab /etc/fstab.orig

add_opts() {  # point_de_montage options
  sudo sed -i -E "s#^(\S+\s+$1\s+ext4\s+)defaults(\s)#\1defaults,$2\2#" /etc/fstab
}
add_opts /boot          nodev,nosuid,noexec
add_opts /home          nodev,nosuid
add_opts /var           nodev,nosuid
add_opts /var/log       nodev,nosuid,noexec
add_opts /var/log/audit nodev,nosuid,noexec
add_opts /var/tmp       nodev,nosuid,noexec

sudo findmnt --verify            # doit afficher « 0 errors »
sudo systemctl daemon-reload && sudo mount -a && sudo reboot
```

> 🔎 Le `\s` après le point de montage est indispensable : sans lui, la règle de `/var` modifierait aussi `/var/log` et `/var/log/audit`.

Vérification après redémarrage :

```bash
for m in /boot /home /var /var/log /var/log/audit /var/tmp; do findmnt -no TARGET,OPTIONS "$m"; done
```

> 🆘 Si le poste ne démarre plus, on arrive en mode secours : `cp /etc/fstab.orig /etc/fstab && reboot`.

---

## 🔑 Étape 2 — Accès SSH par clé

La mesure M06 propose de désactiver l'authentification SSH par mot de passe : **déployez et testez votre clé avant**.

Depuis Windows (PowerShell) :

```powershell
ssh-keygen -t ed25519                     # accepter le chemin par défaut, choisir une passphrase
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh <user>@<ip> "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
ssh <user>@<ip>                           # ne doit plus demander le mot de passe du compte
```

Depuis Linux ou macOS : `ssh-copy-id <user>@<ip>`.

---

## 🔍 Étape 3 — Audit initial

```bash
git clone --depth 1 --branch v1.5.1 https://github.com/jfetx/linux-hardening-anssi.git
cd linux-hardening-anssi
sudo bash anssi-audit.sh -o audit-0-initial-$(hostname).csv
```

| Option | Rôle |
| --- | --- |
| `-l minimal` \| `-l intermediaire` | Niveau audité (défaut : `intermediaire`, qui inclut `minimal`) |
| `-o fichier.csv` | Export CSV (séparateur `;`, lisible dans Excel / LibreOffice) |

| Statut | Signification |
| --- | --- |
| 🟢 **CONFORME** | La mesure est appliquée et persistante |
| 🔴 **NON CONFORME** | À corriger avec `anssi-harden.sh` |
| 🟡 **À VÉRIFIER** | Décision humaine requise, à justifier dans la documentation |
| ⚪ **N/A** | Mesure sans objet sur ce poste (ex. pas de serveur SSH) |

---

## 🔒 Étape 4 — Durcissement

> 🧯 **Gardez une seconde session SSH ouverte** (ou la console de l'hyperviseur) pendant toute l'étape.

```bash
sudo bash anssi-harden.sh -n                      # 🧪 simulation : affiche, ne modifie rien
sudo bash anssi-harden.sh -l minimal              # 🖐️ interactif, mesure par mesure
sudo bash anssi-harden.sh -l intermediaire        # 🖐️ interactif, niveau complet
sudo bash anssi-harden.sh -l intermediaire -a     # 🤖 automatique (hors mesures sensibles)
sudo bash anssi-harden.sh -m I12                  # 🎯 une ou plusieurs mesures : -m M05,I12
```

**Niveau Intermédiaire complet (procédure de livraison)** :

```bash
sudo bash anssi-harden.sh -l intermediaire -a                      # 1. tout ce qui est sans risque
sudo bash anssi-harden.sh -m I12,I16,I17,I20,I21,I24,I25           # 2. mesures sensibles, une par une, avec test
sudo reboot                                                        # 3. redémarrage
sudo bash anssi-harden.sh -m I26                                   # 4. AIDE EN DERNIER (base du poste final)
sudo bash anssi-audit.sh -o audit-$(hostname).csv                  # 5. nos mesures : 100 % attendu
sudo bash anssi-bp028-r80.sh -j ecarts-$(hostname).conf -o r80-$(hostname).csv   # 6. preuve R1–R80
```

| Option | Rôle |
| --- | --- |
| `-l niveau` | `minimal` ou `intermediaire` (sinon menu) |
| `-a` | Automatique : réponses par défaut, aucune question |
| `-n` | Simulation : rien n'est modifié |
| `-m ID,ID` | Ne traite que les mesures listées |

### 🚦 Mesures sensibles

Elles ne sont **jamais** appliquées en mode automatique, et posent toujours leurs questions :

| Mesure | Pourquoi | Conseil |
| --- | --- | --- |
| 🔌 **I04** — blocage du stockage USB | Clés et disques USB inutilisables | Les adaptateurs série/JTAG (`ftdi_sio`, `cdc_acm`) ne sont pas touchés : à tester avec votre matériel |
| 🥾 **I12** — mot de passe GRUB | Un mot de passe perdu bloque l'édition du démarrage | Le noter dans un coffre-fort ; le démarrage normal reste sans mot de passe |
| 🔑 **I16** — SSH réservé au groupe `ssh-users` | Un compte hors du groupe ne peut plus se connecter | Tester une nouvelle connexion avant de fermer la session |
| 🧠 **I17** — options mémoire du noyau (R8) | `mds=full,nosmt` coupe l'hyperthreading ; `slub_debug`, `page_poison` coûtent en performance | Mesurer les applications avant/après ; refus = écart justifié |
| 🔐 **I20** — `pam_faillock` + historique | Une erreur PAM bloque toute authentification | Garder une session root ouverte ; déblocage `faillock --user <nom> --reset` |
| 🧑‍💼 **I21** — `Defaults noexec`, `requiretty`… | Les règles sudo sans tag `EXEC:` ne peuvent plus lancer de sous-processus | Les administrateurs (`%sudo`) reçoivent `EXEC:` ; tester `sudo -i` et `sudo apt update` |
| 💽 **I24** — `noexec` sur `/var`, `/home`… et `hidepid=2` | Scripts non exécutables depuis ces partitions | Un hook APT remonte `/var`, `/tmp`, `/var/tmp` en exec pendant dpkg ; `/var` reste sans noexec si Docker n'a pas de volume dédié |
| 🗂️ **I25** — `/tmp` par utilisateur (`pam_namespace`) | Les sessions interactives ne partagent plus `/tmp` | Services, sudo et cron ne sont pas concernés ; tester une connexion SSH |

### Réponses à surveiller en mode interactif

| Mesure | Question | Réponse conseillée |
| --- | --- | --- |
| M05 | *Autoriser SSH entrant ?* | **Oui**, sinon vous vous enfermez dehors |
| M06 | *Désactiver l'authentification par mot de passe ?* | **Oui** seulement si la clé fonctionne (étape 2) |
| M02 | *Activer les mises à jour automatiques ?* | Non par défaut : sur un banc de test, elles modifient l'environnement testé |
| I15 | *Retirer SUID de fusermount3 ?* | **Non** sur un poste graphique (gvfs, sshfs, AppImage) |

---

## ✅ Étape 5 — Vérification après redémarrage

```bash
sudo reboot
# … puis :
sudo bash anssi-audit.sh -o audit-final-$(hostname).csv
```

> 🔁 **L'audit après redémarrage est obligatoire.** Il prouve que les réglages survivent au démarrage (voir [pièges connus](#️-pièges-connus-sur-ubuntu)).

Tests fonctionnels à faire **en tant qu'utilisateur normal, pas en root** :

- [ ] 🔑 Connexion SSH par clé acceptée, par mot de passe refusée : `ssh -o PubkeyAuthentication=no <user>@<ip>`
- [ ] 🧑‍💼 `sudo -n true && echo OK`, et les commandes sont tracées dans `/var/log/sudo.log`
- [ ] 🔐 `passwd` demande le mot de passe actuel (annuler avec Ctrl+C)
- [ ] 🥾 Démarrage normal sans mot de passe ; touche `e` dans GRUB → identifiant demandé
- [ ] 🧑‍💼 `sudo -i` puis `sudo apt update` fonctionnent (administrateurs avec `EXEC:`, I21)
- [ ] ⏱️ `echo $TMOUT` affiche 600 et `TMOUT=0` est refusé (lecture seule, I19)
- [ ] 🗂️ `touch /tmp/test && ls /tmp` : seul votre fichier apparaît (`/tmp` par utilisateur, I25)
- [ ] 👀 `ps aux` ne montre que vos processus (`hidepid=2`, I24)
- [ ] 📦 `sudo apt install --reinstall cowsay` puis `sudo apt purge cowsay` : dpkg fonctionne malgré `noexec` (hook APT, I24)
- [ ] 🐳 `docker run --rm hello-world` et vos conteneurs démarrent ; la base de données répond
- [ ] 🧩 Vos applications et votre matériel fonctionnent sur le poste durci

---

## 🧪 Vérification supplémentaire R1–R80

`anssi-audit.sh` contrôle **nos 42 mesures**. `anssi-bp028-r80.sh` prend le problème dans l'autre sens : il part des **80 recommandations numérotées du guide** (R1 à R80) et vérifie chacune sur le poste. Il sert de **contre-audit** : il montre ce que nos mesures ne couvrent pas encore et ce qu'il faut justifier comme écart.

- 📚 **Référentiel** : fichier `controls/anssi.yml` du projet [ComplianceAsCode](https://github.com/ComplianceAsCode/content) (base d'OpenSCAP), qui associe à chaque recommandation son niveau et des contrôles techniques. Ce projet ne fournit pas de profil ANSSI pour Ubuntu : les contrôles ont été **réécrits pour Ubuntu** (AppArmor au lieu de SELinux, `dpkg` au lieu de `rpm`, `/etc/pam.d/common-*`, ufw…).
- 🔒 **Lecture seule** : rien n'est modifié, aucune dépendance aux autres scripts.
- ⏱️ **Durée** : 20 secondes à 3 minutes (R53–R57 parcourent les systèmes de fichiers locaux).

```bash
sudo bash anssi-bp028-r80.sh                          # niveau Intermédiaire (inclut Minimal)
sudo bash anssi-bp028-r80.sh -l renforce -q           # Renforcé, seulement ce qui n'est pas conforme
sudo bash anssi-bp028-r80.sh -r R12,R28 -v            # quelques recommandations, détail complet
sudo bash anssi-bp028-r80.sh -o r80-$(hostname).csv   # export CSV pour la documentation
```

| Résultat | Signification |
| --- | --- |
| 🟢 `CONFORME` | Tous les points contrôlés sont conformes |
| 🔴 `NON CONFORME` | Au moins un point non conforme (le détail `✘` dit lequel) |
| 🟡 `À VÉRIFIER` | Points conformes, mais des compléments recommandés (`⚠`) manquent |
| 🔵 `MANUEL` | Recommandation organisationnelle ou matérielle : le script affiche des **éléments de preuve** (comptes, services, empreintes SSH…) à examiner et à documenter |
| ⚪ `N/A` | Sans objet sur ce poste (SELinux, annuaire, architecture ARM…) |

> ⚠️ **Ne pas confondre les numéros.** `R1`–`R80` (sans zéro) sont les recommandations du **guide**. `R01`–`R27` (avec zéro) sont les mesures du **niveau Renforcé de nos scripts**. La colonne **Script** indique quelles mesures de nos scripts couvrent chaque recommandation du guide.

### 📝 Écarts justifiés et attestations (`-j`)

Un auditeur n'attend pas 100 % de conformité technique : il attend que **chaque recommandation soit appliquée, ou que son écart soit justifié par écrit**, et que les points organisationnels aient été vérifiés. Le fichier passé avec `-j` sert à cela :

```text
# Rxx | motif | justification
R12 | net.ipv4.ip_forward | Docker exige le routage IPv4. Compensation : ufw, DOCKER-USER, ports publiés limités à 443.
R30 | *                   | Comptes revus le 18/11/2026 avec le responsable IT : admin1 (exploitation), admin2 (secours).
```

- Le **motif** doit apparaître dans le point signalé (`✘` ou `⚠`) : une justification ne masque **que** ce point, pas toute la recommandation. `*` couvre la recommandation entière et sert à **attester** une recommandation `MANUEL`.
- Un texte encore au format modèle (`<…>`, `JJ/MM/AAAA`, « à compléter ») est **refusé**.
- Une justification qui ne correspond plus à rien est signalée « sans objet ».
- Partir de [`ecarts-justifies.exemple.conf`](ecarts-justifies.exemple.conf) et ne garder que les lignes vraies pour le poste.

| Nouveau résultat | Signification |
| --- | --- |
| 🔷 `ÉCART JUSTIFIÉ` | Tous les points non conformes sont couverts par une justification |
| 🔷 `ATTESTÉ` | Recommandation organisationnelle vérifiée, avec date et interlocuteur |

Objectif de livraison : la dernière ligne du rapport doit afficher **« ✔ Toutes les recommandations vérifiées sont conformes, justifiées, attestées ou sans objet »**. Le CSV (`-o`) contient le résultat et la justification de chaque recommandation, prêt à être repris dans la documentation.

**Écarts habituels sur un poste Ubuntu avec Docker** (à justifier, pas à « corriger » à tout prix) :

| Recommandation | Raison |
| --- | --- |
| R12 | `ip_forward=1` imposé par Docker |
| R28 | Pas de `noexec` sur `/var` si Docker n'a pas de volume `/var/lib/docker` dédié |
| R40 | Règle d'administration `%sudo ALL=(ALL:ALL) ALL` |
| R59 | Dépôt Docker (officiel, signé, mais non Ubuntu) |
| R61 | Poste hors ligne : pas de mises à jour automatiques |
| R79, R80 | Services exposés sans profil AppArmor fourni (sshd, docker-proxy…), ports publiés par les conteneurs |
| R15–R27 | Niveau Élevé seulement : options de compilation du noyau, impossibles avec le noyau Ubuntu |

---

## 📋 Liste des mesures

### 🟦 Niveau Minimal (15)

| ID | Thème | Mesure | Correction |
| --- | --- | --- | --- |
| M01 | 🔄 Mises à jour | Système à jour | ✅ auto |
| M02 | 🔄 Mises à jour | Mises à jour de sécurité automatiques | ✅ auto (défaut : non) |
| M03 | ✂️ Surface | Absence de paquets obsolètes (telnet, rsh, nis, tftp, ftp, serveur DHCP, sendmail…) — R62 | ✅ auto |
| M04 | ✂️ Surface | Services inutiles désactivés (avahi, cups, bluetooth, rpcbind, samba…) | ✅ auto |
| M05 | 🧱 Réseau | Pare-feu ufw, entrant refusé par défaut | ✅ auto |
| M06 | 🔑 SSH | Root interdit, X11 et tunnels désactivés, journalisation | ✅ auto |
| M07 | 👤 Comptes | Mot de passe root verrouillé | ✅ auto |
| M08 | 🔐 Authentification | pam_pwquality : 12 caractères, 3 classes | ✅ auto |
| M09 | 📁 Fichiers | Droits restreints sur shadow, sudoers, sshd_config, grub.cfg | ✅ auto |
| M10 | 📁 Fichiers | Sticky bit sur les répertoires accessibles à tous, aucun fichier inscriptible par tous — R54 | ✅ auto |
| M11 | 📁 Fichiers | Aucun fichier sans propriétaire | 👁️ contrôle seul |
| M12 | 🕐 Journalisation | Horloge synchronisée (NTP) | ✅ auto |
| M13 | 🕐 Journalisation | Journal systemd persistant | ✅ auto |
| M14 | 🕐 Journalisation | Bannière légale (`/etc/issue`, `/etc/issue.net`) | ✅ auto |
| M15 | 🔄 Mises à jour | Dépôts APT officiels et signés, dépôts tiers à justifier — R59 | 👁️ contrôle seul |

### 🟪 Niveau Intermédiaire (26)

Depuis v1.7, ce niveau couvre **toutes les recommandations automatisables** des niveaux Minimal et Intermédiaire du guide. Les autres (BIOS, revue des comptes…) sont attestées dans le fichier d'écarts.

| ID | Thème | Mesure | Correction |
| --- | --- | --- | --- |
| I01 | 🧠 Noyau / réseau | Paramètres réseau IPv4 (redirections, ARP, rp_filter, log_martians, ports locaux…) — R12 | ✅ auto |
| I02 | 🧠 Noyau | Paramètres de sécurité du noyau (kptr, dmesg, ptrace, BPF, perf, pid_max, protected_*) — R9, R11, R14 | ✅ auto |
| I03 | 🧠 Noyau | Modules inutiles interdits (cramfs, hfs, dccp, sctp, firewire…) | ✅ auto |
| I04 | 🔌 Périphériques | Stockage USB bloqué | 🚦 sensible |
| I05 | 💽 Partitionnement | `/tmp` et `/dev/shm` en nodev,nosuid,noexec | ✅ auto |
| I06 | 💽 Partitionnement | Partitions séparées | 👁️ contrôle seul (à l'installation) |
| I07 | 🛡️ Contrôle d'accès | AppArmor actif, profils en mode enforce | ✅ auto |
| I08 | 🕵️ Journalisation | auditd avec règles ANSSI | ✅ auto |
| I09 | 👤 Comptes | sudo durci (use_pty, journal dédié, délai) | ✅ auto |
| I10 | 📁 Fichiers | umask 027 | ✅ auto |
| I11 | 🧠 Noyau | Core dumps désactivés | ✅ auto |
| I12 | 🥾 Démarrage | Mot de passe GRUB | 🚦 sensible |
| I13 | 👤 Comptes | Pas de mot de passe vide ni d'UID 0 hors root ; comptes de service sans shell ni mot de passe — R34 | ✅ auto |
| I14 | 📁 Fichiers | Inventaire setuid/setgid | 👁️ à justifier |
| I15 | 📁 Fichiers | Bits SUID/SGID superflus retirés (`dpkg-statoverride`) | ✅ auto |
| I16 | 🔑 SSH | Connexion SSH réservée au groupe `ssh-users` (`AllowGroups`) | 🚦 sensible |
| I17 | 🧠 Noyau | Options mémoire au démarrage (`pti`, `slab_nomerge`, `spectre_v2`, `mds`…) — R8 | 🚦 sensible · 🔄 redémarrage |
| I18 | 🧱 Réseau | IPv6 désactivé s'il est inutile, sinon annonces de routeurs ignorées — R13 | ✅ auto |
| I19 | 👤 Comptes | Sessions inactives fermées après 10 min (`TMOUT`, logind) — R32 | ✅ auto |
| I20 | 🔐 Authentification | Verrouillage après 5 échecs (`pam_faillock`), historique des mots de passe — R31 | 🚦 sensible |
| I21 | 👤 Comptes | sudo : `noexec`, `requiretty`, `umask=0077`, `ignore_dot` ; `EXEC:` pour les administrateurs — R39, R41 | 🚦 sensible |
| I22 | 📁 Fichiers | Répertoires personnels en 750, fichiers d'initialisation protégés — R50 | ✅ auto |
| I23 | 🥾 Démarrage | UEFI + Secure Boot actif — R3 | 👁️ contrôle seul (UEFI) |
| I24 | 💽 Partitionnement | nosuid/nodev/noexec par partition, nodev partout, `/proc` en `hidepid=2` — R28 | 🚦 sensible · 🔄 redémarrage |
| I25 | 👤 Comptes | `/tmp` et `/var/tmp` propres à chaque utilisateur (`pam_namespace`) — R55 | 🚦 sensible |
| I26 | 🕵️ Journalisation | Intégrité des fichiers : AIDE, base de référence, contrôle quotidien — R79 | ✅ auto (plusieurs minutes, en dernier) |

### 🟥 Niveau Renforcé (`-l renforce`, depuis v1.5)

> ⚠️ Le niveau Renforcé n'est pas « un script de plus » : la moitié des points dépend des applications, de l'infrastructure ou du matériel. Le script applique les mesures **génériques** et **signale** les autres.

**Mesures simples (contrôle + correction)** — R02, R04, R07, R10 et R12 sont passées au niveau Intermédiaire en v1.7 (I20, I22, I19, I26, I18), car le guide les y classe.

| ID | Mesure | Correction |
| --- | --- | --- |
| R01 | Options noyau au démarrage (`init_on_free`, `vsyscall=none`, `debugfs=off`…) | ✅ auto · 🔄 redémarrage |
| R03 | umask 077 | ✅ auto |
| R05 | Aucun compilateur installé | ✅ auto |
| R06 | SSH : algorithmes restreints (guide ANSSI OpenSSH) | ✅ auto |
| R08 | Ctrl-Alt-Suppr désactivé | ✅ auto |
| R09 | Règles auditd verrouillées (`-e 2`) | ✅ auto · 🔄 redémarrage |
| R11 | Modules noyau bloqués après le démarrage | 🚦 sensible · 🔄 redémarrage |

**Points à étudier (contrôle seul)**

| ID | Point | Dépend de |
| --- | --- | --- |
| R20 | Isolation des services systemd | Chaque service (`systemd-analyze security`) |
| R21 | Profils AppArmor des services exposés | Applications en écoute réseau |
| R22 | Journalisation centralisée | Un serveur de journaux |
| R23 | Règles sudo par commande | Les rôles des administrateurs |
| R24 | `/proc` avec `hidepid` | Outils de supervision, systemd-logind |
| R25 | USBGuard | Inventaire des périphériques légitimes |
| R26 | Chiffrement LUKS | Installation (phrase de passe ou TPM) |
| R27 | UEFI + Secure Boot, IOMMU | Matériel et micrologiciel |

---

## 🐳 Docker et durcissement

> 🔁 **Ordre d'installation** : Ubuntu → partitionnement → **Docker + applications + dépendances** → tests → durcissement → **tests à nouveau** → audit → déconnexion du réseau. Durcir avant d'installer les applications multiplie les problèmes.

| Point | Risque | Solution |
| --- | --- | --- |
| 🔴 **Docker contourne ufw** | Un port publié (`-p 1433:1433`) est joignable depuis le réseau **même si ufw le bloque** : Docker insère ses règles iptables avant celles d'ufw | Publier sur `127.0.0.1:1433:1433` si l'accès est local, ou filtrer dans la chaîne `DOCKER-USER` |
| 🟠 `ip_forward` | Docker en a besoin | Le script le conserve automatiquement si Docker est détecté (I01) : **installer Docker avant** |
| 🟠 Groupe `docker` | Appartenir au groupe `docker` **équivaut à être root** | Réservé aux administrateurs |
| 🟠 Images | En production hors ligne, une image manquante ne peut plus être téléchargée | Versions figées (pas de `latest`), copie de secours avec `docker save` |
| 🟢 auditd | Pas de règles Docker par défaut | Surveiller `/usr/bin/dockerd`, `/etc/docker`, `/var/lib/docker`, `docker.sock` |
| 🟢 Configuration du démon | Valeurs par défaut permissives | `/etc/docker/daemon.json` : `no-new-privileges`, `icc: false`, `live-restore`, limites de journaux |
| 🟢 Modules noyau | Docker charge des modules réseau à la volée | Compatible Intermédiaire ; **incompatible avec R11** (blocage des modules) sauf préchargement |

Exemple de `/etc/docker/daemon.json` :

```json
{
  "no-new-privileges": true,
  "icc": false,
  "live-restore": true,
  "userland-proxy": false,
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```

> ⚠️ `icc: false` coupe la communication entre conteneurs du réseau par défaut : à tester si l'application est composée de plusieurs conteneurs (préférer alors un réseau Docker dédié).

---

## ⚠️ Pièges connus sur Ubuntu

Trois composants d'Ubuntu **réécrivent des paramètres du noyau au démarrage**. Les scripts en tiennent compte depuis la v1.2.

| Paramètre | Valeur ANSSI | Réécrit par | Parade |
| --- | --- | --- | --- |
| `fs.protected_fifos` | 2 | `/usr/lib/sysctl.d/99-protect-links.conf` | Fichiers nommés `99-zz-anssi-*.conf` pour être lus en dernier |
| `net.ipv4.conf.*.log_martians` | 1 | ufw (`/etc/ufw/sysctl.conf`) | Valeur corrigée aussi dans ce fichier |
| `fs.suid_dumpable` | 0 | apport | Service apport désactivé |

> 🧪 `systemd-analyze cat-config sysctl.d` affiche l'ordre réel de lecture des fichiers sysctl.

Autres points utiles :

- 🧷 **SUID** : `chmod u-s` est annulé à la prochaine mise à jour du paquet ; `dpkg-statoverride` est persistant. Liste des exceptions : `sudo dpkg-statoverride --list`.
- 🛡️ **AppArmor** : les ~89 profils « unconfined » d'Ubuntu 24.04 servent à autoriser les espaces de noms utilisateur ; ce n'est **pas** un mode dégradé, contrairement au mode « complain ».

---

## ♻️ Sauvegardes et retour arrière

| Élément | Emplacement |
| --- | --- |
| 💾 Fichiers d'origine | `/var/backups/anssi-hardening/<date>/` (même arborescence) |
| 📝 Journal des actions | `/var/log/anssi-hardening.log` |

Annuler toutes les modifications d'une exécution :

```bash
B=/var/backups/anssi-hardening/<date>
sudo cp -a "$B"/. /     # restaure les fichiers d'origine
sudo reboot
```

> ℹ️ Les fichiers **créés** (et non modifiés) par les scripts apparaissent dans le journal sur les lignes `ECRITURE` ; ils se suppriment à la main.

---

## 🛠️ Dépannage

| Symptôme | Cause probable | Solution |
| --- | --- | --- |
| 🔒 Plus d'accès SSH après M06 | Clé non déployée | Console de l'hyperviseur : `sudo rm /etc/ssh/sshd_config.d/00-anssi.conf && sudo systemctl reload ssh` |
| 🧱 Plus d'accès réseau après M05 | SSH non autorisé dans ufw | Console : `sudo ufw allow OpenSSH` |
| 🔁 I01 / I02 / I11 non conformes après redémarrage | Version < v1.2 | Mettre à jour en v1.3, relancer `-m I01,I02,I11`, redémarrer |
| 🚫 `bash: ./anssi-audit.sh: Permission denied` | Bit d'exécution absent (ou partition `noexec`) | Lancer avec `sudo bash anssi-audit.sh` |
| `$'\r': command not found` | Fichier en fins de ligne Windows (CRLF) | `sed -i 's/\r$//' *.sh` (le `.gitattributes` l'évite) |
| 💽 Le poste ne démarre plus après `fstab` | Erreur de syntaxe | Mode secours : `cp /etc/fstab.orig /etc/fstab` |

---

## 🗓️ Historique des versions

| Version | Changements |
| --- | --- |
| **v1.7** | **Niveau Intermédiaire complet vis-à-vis de R1–R80** : 10 nouvelles mesures I17–I26 (options mémoire du noyau, IPv6, sessions inactives, faillock + historique, directives sudo, répertoires personnels, Secure Boot, options de montage + hidepid, `pam_namespace`, AIDE), M15 (dépôts APT) ; I01, I02, I13, M03, M10 complétés ; R02, R04, R07, R10, R12 déplacées vers l'Intermédiaire ; `anssi-bp028-r80.sh` 1.1 : écarts justifiés et attestations (`-j`) |
| **v1.6** | Nouveau script `anssi-bp028-r80.sh` : vérification supplémentaire des 80 recommandations R1–R80 du guide (référentiel ComplianceAsCode `controls/anssi.yml`, adapté à Ubuntu), lecture seule, export CSV |
| **docs** | README : questions préalables (Étape 0), dimensionnement 256 Go / 512 Go / 1 To, cas Docker + base de données, portables, section Docker |
| **v1.5.1** | R05 : `gcc-NN-base` (bibliothèque d'exécution) n'est plus pris pour un compilateur |
| **v1.5** | Module `anssi-lib-renforce.sh`, niveau `-l renforce` : 12 mesures simples (R01–R12, dont 3 sensibles) + 8 points à étudier en contrôle seul (R20–R27) |
| **v1.4.1** | M04 : test des snaps sur disque (la commande `snap` bloquait une fois snapd arrêté) ; sockets désactivés avant leurs services |
| **v1.4** | Correction `unprivileged_bpf_disabled` (valeur exacte 1) ; M14 bannière légale ; I16 `AllowGroups` SSH (sensible) ; droits `sudoers.d` et cron ; SSH `MaxSessions`/`TCPKeepAlive` ; sysctl `ldisc_autoload`, `core_uses_pid` ; services SAN/PackageKit/thermald/snapd — 30 mesures |
| **v1.3** | I07 passe automatiquement les profils AppArmor « complain » en « enforce » ; nouvelle mesure I15 (retrait SUID/SGID via `dpkg-statoverride`) — 28 mesures |
| **v1.2** | Les contrôles I01, I02 et I11 vérifient la configuration persistante, pas seulement l'état en mémoire |
| **v1.1** | Persistance des paramètres sysctl après redémarrage (ordre des fichiers, ufw, apport) |
| **v1.0** | Première version : audit + durcissement, 27 mesures |

---

## ⚖️ Avertissement

- 🧪 **Testez d'abord sur une VM** ou un poste non critique, avec `-n` pour simuler.
- 📖 Ces scripts **ne remplacent pas la lecture du guide** ANSSI-BP-028 (disponible sur [cyber.gouv.fr](https://cyber.gouv.fr/)) ; la correspondance avec ses numéros de recommandation (Rxx) est à établir dans votre documentation.
- 🎚️ Le **niveau attendu** (Minimal, Intermédiaire, Renforcé…) se décide avec le commanditaire, selon la sensibilité du système.
- 🏷️ Ce projet n'est ni produit, ni validé, ni certifié par l'ANSSI.

<div align="center">

Fait avec ☕ et beaucoup de snapshots Proxmox · [@jfetx](https://github.com/jfetx)

</div>

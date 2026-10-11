#!/usr/bin/env bash
# =============================================================================
#  anssi-lib.sh — Bibliothèque commune à anssi-audit.sh et anssi-harden.sh
# -----------------------------------------------------------------------------
#  Référentiel : ANSSI-BP-028 v2.0 « Recommandations de configuration d'un
#                système GNU/Linux » — niveaux Minimal (M) et Intermédiaire (I)
#                + guide ANSSI OpenSSH pour la partie SSH
#  Cible       : Ubuntu 22.04 / 24.04 LTS (poste de travail)
#
#  Chaque mesure est déclarée par `register` puis implémentée par :
#    check_<ID>  : contrôle en lecture seule, renseigne $DETAIL et retourne
#                  0=CONFORME 1=NON CONFORME 2=À VÉRIFIER 3=NON APPLICABLE
#    apply_<ID>  : (optionnelle) correction. Absente => mesure manuelle.
#
#  NB : la colonne « Thème » regroupe les mesures par chapitre du guide ; la
#       correspondance avec les numéros Rxx du guide est à reporter dans la
#       documentation de livraison.
# =============================================================================

export LC_ALL=C.UTF-8          # sorties des outils (ufw, sshd…) non traduites

# --- Codes retour des contrôles ---------------------------------------------
OK=0; KO=1; WARN=2; NA=3

# --- Couleurs (désactivées hors terminal) -----------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'
  C_DIM=$'\e[2m';  C_BLD=$'\e[1m';  C_RST=$'\e[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_BLU=; C_DIM=; C_BLD=; C_RST=
fi

# --- Variables globales -----------------------------------------------------
DRY_RUN=${DRY_RUN:-0}          # 1 = simulation, aucune modification
AUTO=${AUTO:-0}                # 1 = réponses par défaut, sans question
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/var/backups/anssi-hardening/$TS"
LOG_FILE="/var/log/anssi-hardening.log"
REBOOT_NEEDED=0
DETAIL=""
# Terminal pour les questions (stdin si aucun terminal n'est disponible)
if { : <"$TTY"; } 2>/dev/null; then TTY=/dev/tty; else TTY=/dev/stdin; fi

declare -a MEASURES=()
declare -A M_LEVEL=() M_THEME=() M_DESC=() M_RISKY=()

# register ID NIVEAU(M|I) THEME DESCRIPTION [SENSIBLE(0|1)]
# Une mesure « sensible » n'est jamais appliquée en mode automatique.
register() {
  MEASURES+=("$1"); M_LEVEL[$1]=$2; M_THEME[$1]=$3; M_DESC[$1]=$4; M_RISKY[$1]=${5:-0}
}

# Le niveau choisi inclut-il la mesure ? (intermédiaire inclut minimal)
level_includes() { # niveau_choisi niveau_mesure
  [[ $2 == M ]] && return 0
  [[ $1 == intermediaire && $2 == I ]]
}

# =============================================================================
#  Fonctions utilitaires
# =============================================================================
log() {
  ((DRY_RUN)) && return 0
  [[ -w $(dirname "$LOG_FILE") ]] && echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"
  return 0
}
info() { echo "${C_BLU}[i]${C_RST} $*"; log "INFO $*"; }
warn() { echo "${C_YEL}[!]${C_RST} $*"; log "WARN $*"; }
err()  { echo "${C_RED}[x]${C_RST} $*" >&2; log "ERREUR $*"; }

# Exécute une commande (ou l'affiche seulement en simulation)
run() {
  log "CMD $*"
  if ((DRY_RUN)); then echo "    ${C_DIM}[simulation] $*${C_RST}"; return 0; fi
  "$@"
}

# Sauvegarde l'original une seule fois par exécution (arborescence conservée)
backup_file() {
  local f=$1
  [[ -e $f ]] || return 0
  ((DRY_RUN)) && return 0
  [[ -e $BACKUP_DIR$f ]] && return 0
  mkdir -p "$BACKUP_DIR$(dirname "$f")"
  cp -a "$f" "$BACKUP_DIR$f"
  log "SAUVEGARDE $f -> $BACKUP_DIR$f"
}

# Restaure la sauvegarde (ou supprime le fichier s'il n'existait pas avant)
restore_file() {
  local f=$1
  ((DRY_RUN)) && return 0
  if [[ -e $BACKUP_DIR$f ]]; then cp -a "$BACKUP_DIR$f" "$f"; else rm -f "$f"; fi
  log "RESTAURATION $f"
}

# Écrit un fichier complet : write_file CHEMIN MODE CONTENU
write_file() {
  local f=$1 mode=$2 content=$3
  if ((DRY_RUN)); then
    echo "    ${C_DIM}[simulation] écriture de $f (mode $mode) :${C_RST}"
    sed 's/^/      | /' <<<"$content"
    return 0
  fi
  backup_file "$f"
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$content" > "$f"
  chmod "$mode" "$f"
  log "ECRITURE $f"
}

# Ajoute une ligne en fin de fichier
append_line() {
  local f=$1 line=$2
  if ((DRY_RUN)); then echo "    ${C_DIM}[simulation] ajout dans $f : $line${C_RST}"; return 0; fi
  backup_file "$f"
  printf '%s\n' "$line" >> "$f"
  log "AJOUT $f : $line"
}

# Fixe « clé<sep>valeur » : supprime les occurrences actives puis ajoute la ligne
set_kv() { # fichier clé valeur [séparateur]
  local f=$1 k=$2 v=$3 sep=${4:- = }
  if ((DRY_RUN)); then echo "    ${C_DIM}[simulation] $f : $k$sep$v${C_RST}"; return 0; fi
  backup_file "$f"
  sed -i -E "/^[[:space:]]*$k([[:space:]]|=)/d" "$f"
  printf '%s%s%s\n' "$k" "$sep" "$v" >> "$f"
  log "PARAM $f : $k$sep$v"
}

# Question oui/non. En mode AUTO, la valeur par défaut est retenue.
confirm() { # question [défaut o|n]
  local q=$1 def=${2:-n} ans hint="[o/N]"
  if ((AUTO)); then [[ $def == o ]]; return; fi
  [[ $def == o ]] && hint="[O/n]"
  read -r -p "    $q $hint " ans <"$TTY" || ans=""
  ans=${ans:-$def}
  [[ ${ans,,} == o* || ${ans,,} == y* ]]
}

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
apt_install() {
  compgen -G '/var/lib/apt/lists/*_Packages' >/dev/null || run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" || { err "Installation impossible : $*"; return 1; }
}

# Vrai si les droits de $1 ne dépassent pas $2 (octal) et propriétaire = $3
perm_ok() {
  local f=$1 max=$2 owner=$3 cur own
  [[ -e $f ]] || return 0
  cur=$(stat -c '%a' "$f"); own=$(stat -c '%U:%G' "$f")
  (( (8#$cur & ~8#$max) == 0 )) && [[ $own == "$owner" ]]
}

# Systèmes de fichiers locaux à parcourir pour les recherches find
local_mounts() {
  local m
  m=$(findmnt -rn -o TARGET,FSTYPE 2>/dev/null \
      | awk '$2 ~ /^(ext[234]|xfs|btrfs|f2fs|overlay)$/ {print $1}')
  echo "${m:-/}"
}

# Le point de montage $1 possède-t-il toutes les options passées ensuite ?
mount_has() {
  local mp=$1 o opts; shift
  opts=$(findmnt -no OPTIONS "$mp" 2>/dev/null) || return 1
  for o; do [[ ,$opts, == *",$o,"* ]] || return 1; done
}

# Le poste fait-il tourner un hyperviseur / des conteneurs (routage requis) ?
needs_forwarding() {
  command -v docker >/dev/null 2>&1 || command -v lxd >/dev/null 2>&1 \
    || systemctl is-active -q libvirtd 2>/dev/null
}

# Remplissage à largeur fixe compatible UTF-8 (printf compte les octets)
pad() { local s=${1:0:$2}; printf '%s%*s' "$s" $(( $2 - ${#s} )) ""; }

# Résume une liste en une ligne (max 6 éléments)
summarize() {
  local n=$# s
  ((n==0)) && { echo "aucun"; return; }
  s=$(printf '%s ' "${@:1:6}"); s=${s% }
  ((n>6)) && s+=" … (+$((n-6)))"
  echo "$s"
}

# =============================================================================
#  NIVEAU MINIMAL
# =============================================================================

# --- M01 : système à jour ----------------------------------------------------
register M01 M "Mises à jour" "Système à jour (correctifs de sécurité appliqués)"
check_M01() {
  local n
  n=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -c '^Inst ')
  DETAIL="$n paquet(s) en attente (d'après le cache apt local)"
  ((n==0)) && return $OK || return $KO
}
apply_M01() {
  run apt-get update && run env DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
}

# --- M02 : mises à jour automatiques ------------------------------------------
register M02 M "Mises à jour" "Mises à jour de sécurité automatiques (unattended-upgrades)"
check_M02() {
  if ! pkg_installed unattended-upgrades; then DETAIL="paquet absent"; return $KO; fi
  if apt-config dump 2>/dev/null | grep -q 'APT::Periodic::Unattended-Upgrade "1"'; then
    DETAIL="actif"; return $OK
  fi
  DETAIL="installé mais non activé"; return $KO
}
apply_M02() {
  warn "Sur un banc de test/certification, des mises à jour automatiques modifient l'environnement testé."
  confirm "Activer quand même les mises à jour automatiques ?" n || return 0
  pkg_installed unattended-upgrades || apt_install unattended-upgrades || return 1
  write_file /etc/apt/apt.conf.d/20auto-upgrades 644 \
'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";'
}

# --- M03 : paquets obsolètes ---------------------------------------------------
PKGS_UNWANTED=(telnet inetutils-telnet telnetd rsh-client rsh-server nis talk talkd
               xinetd tftp tftp-hpa tftpd-hpa ftp vsftpd)
register M03 M "Réduction de la surface" "Absence de paquets réseau obsolètes (telnet, rsh, nis, tftp, ftp…)"
check_M03() {
  local p found=()
  for p in "${PKGS_UNWANTED[@]}"; do pkg_installed "$p" && found+=("$p"); done
  DETAIL="installés : $(summarize "${found[@]}")"
  ((${#found[@]}==0)) && return $OK || return $KO
}
apply_M03() {
  local p
  for p in "${PKGS_UNWANTED[@]}"; do
    if pkg_installed "$p" && confirm "Purger $p ?" o; then run apt-get purge -y "$p"; fi
  done
  return 0
}

# --- M04 : services inutiles ---------------------------------------------------
SVC_UNWANTED=(avahi-daemon.service avahi-daemon.socket cups.service cups.socket cups.path
              cups-browsed.service bluetooth.service ModemManager.service rpcbind.service
              rpcbind.socket nfs-server.service smbd.service nmbd.service)
register M04 M "Réduction de la surface" "Services inutiles désactivés (avahi, cups, bluetooth, rpcbind, samba…)"
check_M04() {
  local s found=()
  for s in "${SVC_UNWANTED[@]}"; do
    [[ $(systemctl is-enabled "$s" 2>/dev/null) == enabled ]] && found+=("$s")
  done
  DETAIL="actifs : $(summarize "${found[@]}")"
  ((${#found[@]}==0)) && return $OK || return $KO
}
apply_M04() {
  local s
  info "Conserver un service s'il est utile au projet (ex. cups pour une imprimante)."
  for s in "${SVC_UNWANTED[@]}"; do
    [[ $(systemctl is-enabled "$s" 2>/dev/null) == enabled ]] || continue
    if confirm "Désactiver et masquer $s ?" o; then
      run systemctl disable --now "$s" && run systemctl mask "$s"
    fi
  done
  return 0
}

# --- M05 : pare-feu local ------------------------------------------------------
register M05 M "Réseau" "Pare-feu local actif, flux entrants refusés par défaut (ufw)"
check_M05() {
  if ! command -v ufw >/dev/null 2>&1; then
    DETAIL="ufw absent (vérifier nftables/iptables manuellement)"; return $KO
  fi
  local st; st=$(ufw status verbose 2>/dev/null)
  if grep -q '^Status: active' <<<"$st" && grep -q 'deny (incoming)' <<<"$st"; then
    DETAIL="actif, entrant refusé par défaut"; return $OK
  fi
  DETAIL="inactif ou politique entrante permissive"; return $KO
}
apply_M05() {
  command -v ufw >/dev/null 2>&1 || apt_install ufw || return 1
  if pkg_installed openssh-server && confirm "Autoriser SSH entrant (administration à distance) ?" o; then
    run ufw allow OpenSSH
  fi
  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw logging low
  run ufw --force enable
  info "Filtrage sortant non appliqué : à définir avec l'équipe projet si besoin."
}

# --- M06 : SSH -----------------------------------------------------------------
SSH_DROPIN=/etc/ssh/sshd_config.d/00-anssi.conf
declare -A SSH_WANT=(
  [permitrootlogin]=no        [permitemptypasswords]=no   [x11forwarding]=no
  [maxauthtries]=3            [logingracetime]=30         [hostbasedauthentication]=no
  [ignorerhosts]=yes          [permituserenvironment]=no  [allowtcpforwarding]=no
  [allowagentforwarding]=no   [clientaliveinterval]=300   [clientalivecountmax]=2
  [loglevel]=VERBOSE          [strictmodes]=yes
)
register M06 M "Services réseau" "Serveur SSH durci (root interdit, X11/tunnels off, journalisation…)"
check_M06() {
  pkg_installed openssh-server || { DETAIL="serveur SSH non installé"; return $NA; }
  local cfg k bad=()
  mkdir -p /run/sshd 2>/dev/null
  cfg=$(sshd -T 2>/dev/null) || { DETAIL="sshd -T en échec (exécuter en root)"; return $WARN; }
  for k in "${!SSH_WANT[@]}"; do
    grep -qix "$k ${SSH_WANT[$k]}" <<<"$cfg" || bad+=("$k")
  done
  DETAIL="paramètres non conformes : $(summarize "${bad[@]}")"
  ((${#bad[@]}==0)) && return $OK || return $KO
}
apply_M06() {
  local k content
  content="# Durcissement SSH (guide ANSSI OpenSSH) - généré par anssi-harden.sh
# Préfixe 00 : sous OpenSSH, la première valeur lue l'emporte."
  for k in $(printf '%s\n' "${!SSH_WANT[@]}" | sort); do
    content+=$'\n'"$k ${SSH_WANT[$k]}"
  done
  if confirm "Désactiver l'authentification par mot de passe (clés SSH déjà déployées) ?" n; then
    content+=$'\npasswordauthentication no\nkbdinteractiveauthentication no'
  fi
  write_file "$SSH_DROPIN" 600 "$content"
  grep -q '^Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config \
    || warn "La directive Include est absente de sshd_config : le fichier $SSH_DROPIN ne sera pas lu."
  ((DRY_RUN)) && return 0
  if sshd -t; then
    run systemctl reload ssh 2>/dev/null || run systemctl reload sshd
  else
    err "Configuration SSH invalide : restauration."; restore_file "$SSH_DROPIN"; return 1
  fi
}

# --- M07 : compte root ---------------------------------------------------------
register M07 M "Comptes" "Mot de passe root verrouillé (administration via sudo nominatif)"
check_M07() {
  local st; st=$(passwd -S root 2>/dev/null | awk '{print $2}')
  DETAIL="statut root : ${st:-inconnu}"
  [[ $st == L ]] && return $OK || return $KO
}
apply_M07() {
  local admins; admins=$(getent group sudo | cut -d: -f4)
  if [[ -z $admins ]]; then err "Aucun membre du groupe sudo : verrouillage refusé."; return 1; fi
  confirm "Verrouiller root (administrateurs sudo : $admins) ?" o && run passwd -l root
}

# --- M08 : politique de mots de passe -----------------------------------------
PWQ_CONF=/etc/security/pwquality.conf
declare -A PWQ_WANT=([minlen]=12 [minclass]=3 [maxrepeat]=3 [usercheck]=1 [dictcheck]=1 [enforce_for_root]="")
register M08 M "Authentification" "Robustesse des mots de passe (pam_pwquality : 12 car., 3 classes)"
check_M08() {
  if ! pkg_installed libpam-pwquality; then DETAIL="libpam-pwquality absent"; return $KO; fi
  if ! grep -q pam_pwquality /etc/pam.d/common-password; then DETAIL="pam_pwquality absent de common-password"; return $KO; fi
  local minlen minclass
  minlen=$(awk -F= '/^[[:space:]]*minlen[[:space:]]*=/{gsub(/ /,"",$2);v=$2} END{print v+0}' "$PWQ_CONF")
  minclass=$(awk -F= '/^[[:space:]]*minclass[[:space:]]*=/{gsub(/ /,"",$2);v=$2} END{print v+0}' "$PWQ_CONF")
  DETAIL="minlen=$minlen minclass=$minclass"
  ((minlen>=12 && minclass>=3)) && return $OK || return $KO
}
apply_M08() {
  pkg_installed libpam-pwquality || apt_install libpam-pwquality || return 1
  local k
  for k in "${!PWQ_WANT[@]}"; do
    if [[ -z ${PWQ_WANT[$k]} ]]; then
      # option sans valeur (ex. enforce_for_root)
      if ((DRY_RUN)); then echo "    ${C_DIM}[simulation] $PWQ_CONF : $k${C_RST}"
      else backup_file "$PWQ_CONF"; sed -i -E "/^[[:space:]]*${k}[[:space:]]*$/d" "$PWQ_CONF"; echo "$k" >> "$PWQ_CONF"; fi
    else
      set_kv "$PWQ_CONF" "$k" "${PWQ_WANT[$k]}"
    fi
  done
}

# --- M09 : droits des fichiers sensibles ----------------------------------------
PERM_FILES=("/etc/passwd 644 root:root" "/etc/group 644 root:root"
            "/etc/shadow 640 root:shadow" "/etc/gshadow 640 root:shadow"
            "/etc/sudoers 440 root:root" "/etc/ssh/sshd_config 600 root:root"
            "/boot/grub/grub.cfg 600 root:root")
register M09 M "Fichiers" "Droits restreints sur les fichiers sensibles (shadow, sudoers, grub.cfg…)"
check_M09() {
  local e f m o bad=()
  for e in "${PERM_FILES[@]}"; do
    read -r f m o <<<"$e"
    perm_ok "$f" "$m" "$o" || bad+=("$f($(stat -c '%a' "$f"))")
  done
  DETAIL="non conformes : $(summarize "${bad[@]}")"
  ((${#bad[@]}==0)) && return $OK || return $KO
}
apply_M09() {
  local e f m o
  for e in "${PERM_FILES[@]}"; do
    read -r f m o <<<"$e"
    perm_ok "$f" "$m" "$o" && continue
    run chown "$o" "$f" && run chmod "$m" "$f"
  done
  info "grub.cfg repasse en 444 à chaque update-grub tant qu'aucun mot de passe GRUB n'est défini (mesure I12)."
}

# --- M10 : répertoires accessibles en écriture à tous --------------------------
register M10 M "Fichiers" "Sticky bit sur tous les répertoires accessibles en écriture à tous"
find_ww_dirs() {
  local mp
  for mp in $(local_mounts); do
    find "$mp" -xdev -type d -perm -0002 ! -perm -1000 -print0 2>/dev/null
  done
}
check_M10() {
  local l=()
  mapfile -d '' -t l < <(find_ww_dirs)
  DETAIL="sans sticky bit : $(summarize "${l[@]}")"
  ((${#l[@]}==0)) && return $OK || return $KO
}
apply_M10() {
  local d
  while IFS= read -r -d '' d; do run chmod +t "$d"; done < <(find_ww_dirs)
}

# --- M11 : fichiers sans propriétaire (contrôle seul) --------------------------
register M11 M "Fichiers" "Aucun fichier sans utilisateur ou groupe propriétaire"
check_M11() {
  local mp l=()
  for mp in $(local_mounts); do
    mapfile -t -O "${#l[@]}" l < <(find "$mp" -xdev \( -nouser -o -nogroup \) 2>/dev/null | head -50)
  done
  DETAIL="orphelins : $(summarize "${l[@]}") — à attribuer ou supprimer manuellement"
  ((${#l[@]}==0)) && return $OK || return $WARN
}

# --- M12 : synchronisation horaire ---------------------------------------------
register M12 M "Journalisation" "Horloge synchronisée (NTP) pour l'horodatage des journaux"
check_M12() {
  local ntp sync
  ntp=$(timedatectl show -p NTP --value 2>/dev/null) || { DETAIL="timedatectl indisponible"; return $WARN; }
  sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  DETAIL="NTP=$ntp synchronisé=$sync"
  [[ $ntp == yes ]] && return $OK || return $KO
}
apply_M12() {
  run timedatectl set-ntp true
  info "Poste isolé ? Pointer /etc/systemd/timesyncd.conf (NTP=) vers un serveur interne."
}

# --- M13 : journaux persistants ------------------------------------------------
register M13 M "Journalisation" "Journal systemd persistant (conservé après redémarrage)"
check_M13() {
  local s
  s=$(grep -hE '^[[:space:]]*Storage=' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf 2>/dev/null | tail -1 | cut -d= -f2)
  DETAIL="Storage=${s:-auto (défaut)} ; /var/log/journal $([[ -d /var/log/journal ]] && echo présent || echo absent)"
  if [[ $s == persistent ]] || { [[ -z $s || $s == auto ]] && [[ -d /var/log/journal ]]; }; then return $OK; fi
  return $KO
}
apply_M13() {
  write_file /etc/systemd/journald.conf.d/50-anssi.conf 644 \
'[Journal]
Storage=persistent
Compress=yes'
  run systemctl restart systemd-journald
}

# =============================================================================
#  NIVEAU INTERMÉDIAIRE
# =============================================================================

# Clés pour lesquelles une valeur supérieure (plus stricte) est acceptée
declare -A SYSCTL_GE=([kernel.perf_event_paranoid]=1 [kernel.unprivileged_bpf_disabled]=1
                      [kernel.kptr_restrict]=1 [kernel.yama.ptrace_scope]=1)

declare -A SYSCTL_NET=(
  [net.ipv4.ip_forward]=0
  [net.ipv4.conf.all.accept_redirects]=0      [net.ipv4.conf.default.accept_redirects]=0
  [net.ipv4.conf.all.secure_redirects]=0      [net.ipv4.conf.default.secure_redirects]=0
  [net.ipv4.conf.all.send_redirects]=0        [net.ipv4.conf.default.send_redirects]=0
  [net.ipv4.conf.all.accept_source_route]=0   [net.ipv4.conf.default.accept_source_route]=0
  [net.ipv4.conf.all.rp_filter]=1             [net.ipv4.conf.default.rp_filter]=1
  [net.ipv4.conf.all.log_martians]=1          [net.ipv4.conf.default.log_martians]=1
  [net.ipv4.icmp_echo_ignore_broadcasts]=1    [net.ipv4.icmp_ignore_bogus_error_responses]=1
  [net.ipv4.tcp_syncookies]=1                 [net.ipv4.tcp_rfc1337]=1
  [net.ipv6.conf.all.accept_redirects]=0      [net.ipv6.conf.default.accept_redirects]=0
  [net.ipv6.conf.all.accept_source_route]=0   [net.ipv6.conf.default.accept_source_route]=0
)
declare -A SYSCTL_KERN=(
  [kernel.kptr_restrict]=2          [kernel.dmesg_restrict]=1
  [kernel.yama.ptrace_scope]=1      [kernel.unprivileged_bpf_disabled]=1
  [net.core.bpf_jit_harden]=2       [kernel.perf_event_paranoid]=2
  [kernel.randomize_va_space]=2     [kernel.sysrq]=0
  [kernel.kexec_load_disabled]=1    [fs.suid_dumpable]=0
  [fs.protected_symlinks]=1         [fs.protected_hardlinks]=1
  [fs.protected_fifos]=2            [fs.protected_regular]=2
)

# Clé à ignorer dans le contexte du poste ?
sysctl_skip() { [[ $1 == net.ipv4.ip_forward ]] && needs_forwarding; }

sysctl_check() { # nom_du_tableau
  local -n _arr=$1
  local k cur want bad=()
  for k in "${!_arr[@]}"; do
    sysctl_skip "$k" && continue
    cur=$(sysctl -n "$k" 2>/dev/null) || continue        # clé absente du noyau
    want=${_arr[$k]}
    if [[ -n ${SYSCTL_GE[$k]:-} ]]; then
      ((cur >= want)) || bad+=("$k=$cur")
    else
      [[ $cur == "$want" ]] || bad+=("$k=$cur")
    fi
  done
  DETAIL="écarts : $(summarize "${bad[@]}")"
  ((${#bad[@]}==0))
}

sysctl_apply() { # nom_du_tableau fichier
  local -n _arr=$1
  local f=$2 k v cur content="# Paramètres noyau ANSSI-BP-028 - généré par anssi-harden.sh"
  for k in $(printf '%s\n' "${!_arr[@]}" | sort); do
    if sysctl_skip "$k"; then
      warn "$k conservé : Docker/LXD/libvirt détecté (routage nécessaire)."; continue
    fi
    sysctl -n "$k" >/dev/null 2>&1 || continue
    v=${_arr[$k]}
    if [[ -n ${SYSCTL_GE[$k]:-} ]]; then          # ne jamais affaiblir une valeur plus stricte
      cur=$(sysctl -n "$k"); ((cur > v)) && v=$cur
    fi
    content+=$'\n'"$k = $v"
  done
  write_file "$f" 644 "$content"
  run sysctl -q -p "$f"
}

# Supprime un ancien fichier sysctl (versions précédentes du script)
remove_old_sysctl() { [[ -f $1 ]] || return 0; backup_file "$1"; run rm -f "$1"; }

# apport (Ubuntu) remet fs.suid_dumpable=2 à chaque démarrage : on le désactive
disable_apport() {
  pkg_installed apport || return 0
  info "apport détecté : il force fs.suid_dumpable=2 au démarrage, désactivation."
  [[ -f /etc/default/apport ]] && set_kv /etc/default/apport enabled 0 "="
  run systemctl disable --now apport.service 2>/dev/null
  run sysctl -q -w fs.suid_dumpable=0
}

register I01 I "Noyau / réseau" "Paramètres réseau du noyau (redirections, routage source, rp_filter…)"
check_I01() {
  sysctl_check SYSCTL_NET || return $KO
  # Persistance : fichier ANSSI présent et ufw ne remet pas log_martians à 0 au démarrage
  [[ -f /etc/sysctl.d/99-zz-anssi-reseau.conf ]] || { DETAIL="valeurs OK mais non persistantes (fichier 99-zz-anssi-reseau.conf absent)"; return $KO; }
  if grep -qE '^net/ipv4/conf/(all|default)/log_martians=0' /etc/ufw/sysctl.conf 2>/dev/null; then
    DETAIL="ufw remettra log_martians=0 au démarrage (/etc/ufw/sysctl.conf)"; return $KO
  fi
  return $OK
}
# NB : préfixe 99-zz pour passer APRÈS /usr/lib/sysctl.d/99-protect-links.conf (Ubuntu)
apply_I01() {
  remove_old_sysctl /etc/sysctl.d/90-anssi-reseau.conf
  sysctl_apply SYSCTL_NET /etc/sysctl.d/99-zz-anssi-reseau.conf
  # ufw réapplique /etc/ufw/sysctl.conf à chaque démarrage (log_martians=0 par défaut)
  if [[ -f /etc/ufw/sysctl.conf ]] && grep -qE '^net/ipv4/conf/(all|default)/log_martians=0' /etc/ufw/sysctl.conf; then
    if ((DRY_RUN)); then echo "    ${C_DIM}[simulation] /etc/ufw/sysctl.conf : log_martians=1${C_RST}"
    else
      backup_file /etc/ufw/sysctl.conf
      sed -i -E 's#^(net/ipv4/conf/(all|default)/log_martians)=0#\1=1#' /etc/ufw/sysctl.conf
      log "PARAM /etc/ufw/sysctl.conf : log_martians=1"
    fi
  fi
}

register I02 I "Noyau" "Paramètres de sécurité du noyau (kptr, dmesg, ptrace, BPF, protected_*…)"
apport_active() { pkg_installed apport && systemctl is-enabled -q apport.service 2>/dev/null; }
check_I02() {
  sysctl_check SYSCTL_KERN || return $KO
  [[ -f /etc/sysctl.d/99-zz-anssi-noyau.conf ]] || { DETAIL="valeurs OK mais non persistantes (fichier 99-zz-anssi-noyau.conf absent)"; return $KO; }
  apport_active && { DETAIL="apport actif : remettra fs.suid_dumpable=2 au démarrage"; return $KO; }
  return $OK
}
apply_I02() {
  remove_old_sysctl /etc/sysctl.d/91-anssi-noyau.conf
  sysctl_apply SYSCTL_KERN /etc/sysctl.d/99-zz-anssi-noyau.conf
  disable_apport
}

# --- I03 : modules noyau inutiles ----------------------------------------------
MOD_BLACKLIST=(cramfs freevxfs jffs2 hfs hfsplus dccp sctp rds tipc firewire-core)
MOD_FILE=/etc/modprobe.d/anssi-blacklist.conf
module_blocked() {
  modprobe -n -v "$1" 2>/dev/null | grep -qE 'install /bin/(false|true)' && return 0
  ! modinfo "$1" >/dev/null 2>&1                    # module inexistant = conforme
}
register I03 I "Noyau" "Chargement interdit des modules inutiles (fs exotiques, dccp, sctp, firewire…)"
check_I03() {
  local m bad=()
  for m in "${MOD_BLACKLIST[@]}"; do module_blocked "$m" || bad+=("$m"); done
  DETAIL="chargeables : $(summarize "${bad[@]}")"
  ((${#bad[@]}==0)) && return $OK || return $KO
}
apply_I03() {
  local m content="# Modules interdits (ANSSI-BP-028) - généré par anssi-harden.sh"
  for m in "${MOD_BLACKLIST[@]}"; do content+=$'\n'"install $m /bin/false"$'\n'"blacklist $m"; done
  write_file "$MOD_FILE" 644 "$content"
  for m in "${MOD_BLACKLIST[@]}"; do
    lsmod | grep -q "^${m//-/_} " && run modprobe -r "$m"
  done
  return 0
}

# --- I04 : stockage USB (sensible) ---------------------------------------------
register I04 I "Périphériques" "Blocage du stockage de masse USB (usb-storage, uas)" 1
check_I04() {
  local m bad=()
  for m in usb-storage uas; do module_blocked "$m" || bad+=("$m"); done
  DETAIL="autorisés : $(summarize "${bad[@]}")"
  ((${#bad[@]}==0)) && return $OK || return $KO
}
apply_I04() {
  warn "Les maquettes peuvent être reliées en USB : les adaptateurs série/JTAG (usbserial, ftdi_sio, cdc_acm)"
  warn "ne sont PAS bloqués ici, mais clés et disques USB ne fonctionneront plus."
  confirm "Bloquer le stockage USB ?" n || return 0
  write_file /etc/modprobe.d/anssi-usb-storage.conf 644 \
'install usb-storage /bin/false
blacklist usb-storage
install uas /bin/false
blacklist uas'
}

# --- I05 : options de montage ----------------------------------------------------
register I05 I "Partitionnement" "Options de montage nodev/nosuid/noexec sur /tmp et /dev/shm"
check_I05() {
  local bad=()
  if findmnt -n /dev/shm >/dev/null 2>&1; then
    mount_has /dev/shm nodev nosuid noexec || bad+=("/dev/shm")
  fi
  if findmnt -n /tmp >/dev/null 2>&1; then
    mount_has /tmp nodev nosuid || bad+=("/tmp(options)")
    mount_has /tmp noexec || bad+=("/tmp(noexec)")
  else
    bad+=("/tmp(non séparé)")
  fi
  DETAIL="écarts : $(summarize "${bad[@]}")"
  ((${#bad[@]}==0)) && return $OK || return $KO
}
apply_I05() {
  if grep -qE '^[[:space:]]*[^#[:space:]]+[[:space:]]+/dev/shm[[:space:]]' /etc/fstab; then
    warn "/dev/shm déjà déclaré dans /etc/fstab : ajouter nodev,nosuid,noexec manuellement."
  elif confirm "Monter /dev/shm avec nodev,nosuid,noexec ?" o; then
    append_line /etc/fstab "tmpfs /dev/shm tmpfs defaults,rw,nodev,nosuid,noexec 0 0"
    run mount -o remount,nodev,nosuid,noexec /dev/shm
  fi
  if grep -qE '^[[:space:]]*[^#[:space:]]+[[:space:]]+/tmp[[:space:]]' /etc/fstab; then
    warn "/tmp déjà déclaré dans /etc/fstab : ajouter nodev,nosuid(,noexec) manuellement."
  elif confirm "Monter /tmp en tmpfs (nodev,nosuid) au prochain démarrage ?" o; then
    local opt="defaults,rw,nodev,nosuid,mode=1777"
    confirm "Ajouter noexec sur /tmp (peut gêner certains installeurs) ?" o && opt+=",noexec"
    append_line /etc/fstab "tmpfs /tmp tmpfs $opt 0 0"
    REBOOT_NEEDED=1
  fi
}

# --- I06 : partitionnement (contrôle seul) ---------------------------------------
register I06 I "Partitionnement" "Partitions séparées (/home, /var, /var/log, /var/tmp, /var/log/audit)"
check_I06() {
  local p miss=()
  for p in /home /var /var/log /var/tmp /var/log/audit; do
    findmnt -n "$p" >/dev/null 2>&1 || miss+=("$p")
  done
  DETAIL="non séparées : $(summarize "${miss[@]}") — à prévoir à l'installation (LVM)"
  ((${#miss[@]}==0)) && return $OK || return $WARN
}

# --- I07 : AppArmor -------------------------------------------------------------
register I07 I "Contrôle d'accès" "AppArmor actif, profils en mode enforce"
check_I07() {
  command -v aa-status >/dev/null 2>&1 || { DETAIL="AppArmor absent"; return $KO; }
  aa-status --enabled 2>/dev/null || { DETAIL="AppArmor désactivé"; return $KO; }
  local enf cmp
  enf=$(aa-status --enforced 2>/dev/null); cmp=$(aa-status --complaining 2>/dev/null)
  DETAIL="${enf:-?} profil(s) enforce, ${cmp:-?} en complain"
  [[ ${cmp:-0} -eq 0 ]] && return $OK || return $WARN
}
apply_I07() {
  pkg_installed apparmor || apt_install apparmor || return 1
  pkg_installed apparmor-utils || apt_install apparmor-utils || return 1
  run systemctl enable --now apparmor
  grep -q 'apparmor=0' /proc/cmdline && warn "apparmor=0 présent sur la ligne de commande noyau (GRUB) : à retirer."
  info "Profils en complain : vérifier avec « aa-status » puis « aa-enforce /etc/apparmor.d/<profil> » après tests."
}

# --- I08 : auditd ---------------------------------------------------------------
AUDIT_RULES=/etc/audit/rules.d/50-anssi.rules
register I08 I "Journalisation" "Journalisation des événements sensibles (auditd)"
check_I08() {
  pkg_installed auditd || { DETAIL="auditd absent"; return $KO; }
  systemctl is-active -q auditd 2>/dev/null || { DETAIL="auditd installé mais inactif"; return $KO; }
  [[ -f $AUDIT_RULES ]] || { DETAIL="actif, règles ANSSI absentes"; return $WARN; }
  DETAIL="actif, $(auditctl -l 2>/dev/null | grep -vc '^No rules') règle(s) chargée(s)"
  return $OK
}
apply_I08() {
  pkg_installed auditd || apt_install auditd audispd-plugins || return 1
  local rules
  rules='## Règles auditd (ANSSI-BP-028) - générées par anssi-harden.sh
## Comptes et authentification
-w /etc/passwd -p wa -k identite
-w /etc/group -p wa -k identite
-w /etc/shadow -p wa -k identite
-w /etc/gshadow -p wa -k identite
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /var/log/sudo.log -p wa -k sudo_log
## Configuration SSH
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd
## Modules noyau
-w /usr/sbin/insmod -p x -k modules
-w /usr/sbin/rmmod -p x -k modules
-w /usr/sbin/modprobe -p x -k modules
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k modules
## Montages et heure système
-a always,exit -F arch=b64 -S mount,umount2 -F auid>=1000 -F auid!=unset -k montages
-a always,exit -F arch=b64 -S adjtimex,settimeofday,clock_settime -k heure
-w /etc/localtime -p wa -k heure
## Commandes exécutées en root par un utilisateur
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k exec_root'
  if [[ $(uname -m) == x86_64 ]]; then
    rules+=$'\n-a always,exit -F arch=b32 -S init_module,finit_module,delete_module -k modules'
    rules+=$'\n-a always,exit -F arch=b32 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k exec_root'
  fi
  rules+=$'\n## Pour figer les règles jusqu\'au redémarrage, ajouter : -e 2'
  write_file "$AUDIT_RULES" 640 "$rules"
  run systemctl enable --now auditd
  run augenrules --load
}

# --- I09 : sudo -----------------------------------------------------------------
SUDO_FILE=/etc/sudoers.d/50-anssi
register I09 I "Comptes" "sudo durci (use_pty, journal dédié, délai, essais limités)"
check_I09() {
  local all members
  all=$(cat /etc/sudoers /etc/sudoers.d/* 2>/dev/null)
  members=$(getent group sudo | cut -d: -f4)
  DETAIL="membres du groupe sudo : ${members:-aucun}"
  grep -qE '^Defaults.*use_pty' <<<"$all" && grep -qE '^Defaults.*logfile' <<<"$all" && return $OK
  return $KO
}
apply_I09() {
  local content tmp
  content='# Durcissement sudo (ANSSI-BP-028) - généré par anssi-harden.sh
Defaults use_pty
Defaults logfile="/var/log/sudo.log"
Defaults !visiblepw
Defaults timestamp_timeout=5
Defaults passwd_tries=3'
  tmp=$(mktemp); printf '%s\n' "$content" > "$tmp"
  if ! visudo -cqf "$tmp"; then err "Syntaxe sudoers invalide, abandon."; rm -f "$tmp"; return 1; fi
  rm -f "$tmp"
  write_file "$SUDO_FILE" 440 "$content"
  info "Revoir les membres du groupe sudo : $(getent group sudo | cut -d: -f4)"
}

# --- I10 : umask ----------------------------------------------------------------
register I10 I "Fichiers" "umask restrictif par défaut (027)"
check_I10() {
  local u; u=$(awk '/^[[:space:]]*UMASK/{v=$2} END{print v}' /etc/login.defs)
  DETAIL="UMASK=${u:-non défini}"
  [[ $u == 027 || $u == 0027 || $u == 077 || $u == 0077 ]] && return $OK || return $KO
}
apply_I10() {
  set_kv /etc/login.defs UMASK 027 " "
  write_file /etc/profile.d/anssi-umask.sh 644 'umask 027'
}

# --- I11 : core dumps -----------------------------------------------------------
register I11 I "Noyau" "Core dumps désactivés (fuite de secrets en mémoire)"
check_I11() {
  local bad=()
  grep -hqE '^[[:space:]]*\*[[:space:]]+hard[[:space:]]+core[[:space:]]+0' \
       /etc/security/limits.conf /etc/security/limits.d/*.conf 2>/dev/null || bad+=("limits")
  [[ $(sysctl -n fs.suid_dumpable 2>/dev/null) == 0 ]] || bad+=("suid_dumpable")
  if pkg_installed systemd-coredump; then
    grep -hqE '^Storage=none' /etc/systemd/coredump.conf /etc/systemd/coredump.conf.d/*.conf 2>/dev/null || bad+=("systemd-coredump")
  fi
  apport_active && bad+=("apport actif")
  DETAIL="écarts : $(summarize "${bad[@]}")"
  ((${#bad[@]}==0)) && return $OK || return $KO
}
apply_I11() {
  write_file /etc/security/limits.d/50-anssi-core.conf 644 '* hard core 0'
  run sysctl -q -w fs.suid_dumpable=0
  disable_apport
  if pkg_installed systemd-coredump; then
    write_file /etc/systemd/coredump.conf.d/50-anssi.conf 644 \
'[Coredump]
Storage=none
ProcessSizeMax=0'
  fi
  info "fs.suid_dumpable est rendu persistant par la mesure I02."
}

# --- I12 : mot de passe GRUB (sensible) ------------------------------------------
register I12 I "Démarrage" "Chargeur de démarrage protégé par mot de passe (GRUB)" 1
check_I12() {
  [[ -r /boot/grub/grub.cfg ]] || { DETAIL="grub.cfg illisible ou absent"; return $WARN; }
  if grep -qE '^[[:space:]]*password(_pbkdf2)?[[:space:]]' /boot/grub/grub.cfg; then
    DETAIL="mot de passe défini"; return $OK
  fi
  DETAIL="aucun mot de passe"; return $KO
}
apply_I12() {
  if ((DRY_RUN)); then
    echo "    ${C_DIM}[simulation] création de /etc/grub.d/01_anssi_password + update-grub${C_RST}"; return 0
  fi
  local u p1 p2 hash
  read -r -p "    Utilisateur GRUB [grubadmin] : " u <"$TTY"; u=${u:-grubadmin}
  read -rs -p "    Mot de passe GRUB : " p1 <"$TTY"; echo
  read -rs -p "    Confirmation : " p2 <"$TTY"; echo
  [[ $p1 == "$p2" && -n $p1 ]] || { err "Mots de passe différents ou vides."; return 1; }
  ((${#p1} >= 12)) || warn "Mot de passe de moins de 12 caractères."
  hash=$(printf '%s\n%s\n' "$p1" "$p1" | grub-mkpasswd-pbkdf2 2>/dev/null | awk '/grub\.pbkdf2/{print $NF}')
  [[ -n $hash ]] || { err "Échec de grub-mkpasswd-pbkdf2."; return 1; }
  write_file /etc/grub.d/01_anssi_password 755 "#!/bin/sh
cat <<'EOF'
set superusers=\"$u\"
password_pbkdf2 $u $hash
EOF"
  if confirm "Démarrage normal sans mot de passe (seules l'édition et la console GRUB protégées) ?" o \
     && ! grep -q -- '--unrestricted' /etc/grub.d/10_linux; then
    backup_file /etc/grub.d/10_linux
    sed -i 's/^CLASS="--class gnu-linux --class gnu --class os"/CLASS="--class gnu-linux --class gnu --class os --unrestricted"/' /etc/grub.d/10_linux
  fi
  run update-grub
  info "Conserver ce mot de passe dans le coffre-fort de l'équipe (à mentionner dans la documentation)."
}

# --- I13 : comptes --------------------------------------------------------------
register I13 I "Comptes" "Pas de mot de passe vide, pas d'UID 0 hors root, comptes système sans shell"
check_I13() {
  local empty uid0 syssh
  empty=$(awk -F: '($2==""){print $1}' /etc/shadow 2>/dev/null | xargs)
  uid0=$(awk -F: '($3==0 && $1!="root"){print $1}' /etc/passwd | xargs)
  syssh=$(awk -F: '($3<1000 && $1!="root" && $7!~/(nologin|false|sync|shutdown|halt)$/){print $1}' /etc/passwd | xargs)
  DETAIL="mdp vide: ${empty:-aucun} | UID0: ${uid0:-aucun} | système avec shell: ${syssh:-aucun}"
  [[ -n $empty || -n $uid0 ]] && return $KO
  [[ -n $syssh ]] && return $WARN
  return $OK
}
apply_I13() {
  local u
  for u in $(awk -F: '($2==""){print $1}' /etc/shadow); do
    confirm "Verrouiller le compte $u (mot de passe vide) ?" o && run passwd -l "$u"
  done
  for u in $(awk -F: '($3==0 && $1!="root"){print $1}' /etc/passwd); do
    warn "Compte $u avec UID 0 : à traiter manuellement."
  done
  for u in $(awk -F: '($3<1000 && $1!="root" && $7!~/(nologin|false|sync|shutdown|halt)$/){print $1}' /etc/passwd); do
    confirm "Retirer le shell du compte système $u ?" n && run usermod -s /usr/sbin/nologin "$u"
  done
  return 0
}

# --- I14 : inventaire setuid/setgid (contrôle seul) --------------------------------
register I14 I "Fichiers" "Inventaire des exécutables setuid/setgid (à justifier)"
check_I14() {
  local mp n=0 c
  for mp in $(local_mounts); do
    c=$(find "$mp" -xdev -type f -perm /6000 2>/dev/null | wc -l); n=$((n+c))
  done
  DETAIL="$n fichier(s) — liste : find / -xdev -type f -perm /6000"
  return $WARN
}

#!/usr/bin/env bash
# =============================================================================
#  anssi-lib-renforce.sh — Mesures du niveau RENFORCÉ (R), chargé par anssi-lib.sh
# -----------------------------------------------------------------------------
#  Deux familles :
#    R01–R12 : mesures « simples » — contrôle + correction (certaines sensibles)
#    R20–R27 : points « à étudier » — contrôle seul : ils dépendent des
#              applications installées, de l'infrastructure ou du matériel et
#              ne peuvent pas être corrigés par un script générique.
#  Activation : -l renforce (inclut Minimal + Intermédiaire)
#  NB : sélection indicative à rapprocher des recommandations Rxx du guide
#       ANSSI-BP-028 v2.0 avant toute livraison.
# =============================================================================

# =============================================================================
#  R01–R12 : MESURES SIMPLES
# =============================================================================

# --- R01 : options de durcissement du noyau au démarrage -------------------------
KCMD_FILE=/etc/default/grub.d/99-anssi-renforce.cfg
KCMD_OPTS=(init_on_alloc=1 init_on_free=1 slab_nomerge page_alloc.shuffle=1
           pti=on randomize_kstack_offset=on vsyscall=none debugfs=off)
register R01 R "Noyau" "Options de durcissement du noyau au démarrage (init_on_free, pti, vsyscall=none…)"
check_R01() {
  local o miss=()
  for o in "${KCMD_OPTS[@]}"; do [[ " $(cat /proc/cmdline) " == *" $o "* ]] || miss+=("$o"); done
  if ((${#miss[@]}==0)); then DETAIL="toutes actives"; return $OK; fi
  if [[ -f $KCMD_FILE ]]; then DETAIL="configurées, actives au prochain redémarrage"; return $WARN; fi
  DETAIL="absentes : $(summarize "${miss[@]}")"; return $KO
}
apply_R01() {
  info "Coût : quelques % de performances (init_on_free). vsyscall=none casse de très vieux binaires."
  confirm "Ajouter ces options à la ligne de commande du noyau ?" o || return 0
  write_file "$KCMD_FILE" 644 "# Durcissement noyau (niveau renforcé) - anssi-harden.sh
GRUB_CMDLINE_LINUX=\"\$GRUB_CMDLINE_LINUX ${KCMD_OPTS[*]}\""
  run update-grub
  REBOOT_NEEDED=1
}

# --- R02 : verrouillage après échecs d'authentification — SENSIBLE --------------------
register R02 R "Authentification" "Verrouillage temporaire après 5 échecs d'authentification (pam_faillock)" 1
check_R02() {
  local d; d=$(awk -F= '/^[[:space:]]*deny[[:space:]]*=/{gsub(/ /,"",$2);v=$2} END{print v}' /etc/security/faillock.conf 2>/dev/null)
  if grep -q pam_faillock /etc/pam.d/common-auth 2>/dev/null && [[ -n $d ]]; then
    DETAIL="actif : deny=$d"; return $OK
  fi
  DETAIL="pam_faillock non configuré"; return $KO
}
apply_R02() {
  warn "Une erreur dans PAM peut bloquer toute authentification : gardez une session root ouverte."
  confirm "Activer le verrouillage (5 échecs, 15 min) ?" n || return 0
  set_kv /etc/security/faillock.conf deny 5
  set_kv /etc/security/faillock.conf unlock_time 900
  set_kv /etc/security/faillock.conf fail_interval 900
  write_file /usr/share/pam-configs/faillock 644 'Name: Enable pam_faillock to deny access
Default: yes
Priority: 0
Auth-Type: Primary
Auth:
	[default=die] pam_faillock.so authfail'
  write_file /usr/share/pam-configs/faillock_notify 644 'Name: Notify of failed login attempts and reset count upon success
Default: yes
Priority: 1024
Auth-Type: Primary
Auth:
	requisite pam_faillock.so preauth
Account-Type: Primary
Account:
	required pam_faillock.so'
  backup_file /etc/pam.d/common-auth; backup_file /etc/pam.d/common-account
  run pam-auth-update --enable faillock faillock_notify
  warn "TEST : dans une AUTRE session, « sudo -k; sudo true » doit fonctionner. Déblocage : faillock --user <nom> --reset"
}

# --- R03 : umask 077 pour les utilisateurs ------------------------------------------
register R03 R "Fichiers" "umask 077 : fichiers des utilisateurs illisibles par les autres"
check_R03() {
  local u; u=$(awk '/^[[:space:]]*UMASK/{v=$2} END{print v}' /etc/login.defs)
  DETAIL="UMASK=${u:-non défini}"
  [[ $u == 077 || $u == 0077 ]] && grep -qs 'umask 077' /etc/profile.d/anssi-umask.sh && return $OK
  return $KO
}
apply_R03() {
  info "Les fichiers créés ne seront plus lisibles par le groupe : à valider si des répertoires sont partagés."
  confirm "Passer l'umask à 077 ?" o || return 0
  set_kv /etc/login.defs UMASK 077 " "
  write_file /etc/profile.d/anssi-umask.sh 644 'umask 077'
}

# --- R04 : répertoires personnels en 750 maximum -------------------------------------
register R04 R "Fichiers" "Répertoires personnels non accessibles aux autres utilisateurs (750 max)"
home_dirs() { awk -F: '$3>=1000 && $3<65534 {print $6}' /etc/passwd | sort -u; }
check_R04() {
  local h bad=() m
  for h in $(home_dirs); do
    [[ -d $h ]] || continue
    m=$(stat -c '%a' "$h"); (( (8#$m & 8#027) == 0 )) || bad+=("$h($m)")
  done
  grep -qE '^[[:space:]]*HOME_MODE[[:space:]]+0?750' /etc/login.defs || bad+=("login.defs:HOME_MODE")
  DETAIL="écarts : $(summarize "${bad[@]}")"
  ((${#bad[@]}==0)) && return $OK || return $KO
}
apply_R04() {
  local h m
  for h in $(home_dirs); do
    [[ -d $h ]] || continue
    m=$(stat -c '%a' "$h"); (( (8#$m & 8#027) == 0 )) || run chmod 750 "$h"
  done
  set_kv /etc/login.defs HOME_MODE 0750 " "
}

# --- R05 : absence de compilateurs ---------------------------------------------------
# NB : gcc-NN-base est une bibliothèque d'exécution (requise par libgcc), pas un compilateur
PKGS_COMPILERS=(build-essential gcc g++ clang tcc gfortran)
register R05 R "Réduction de la surface" "Aucun compilateur installé (gcc, g++, clang…)"
check_R05() {
  local p found=()
  for p in "${PKGS_COMPILERS[@]}"; do pkg_installed "$p" && found+=("$p"); done
  found+=( $(dpkg-query -W -f='${Package} ${Status}\n' 'gcc-[0-9]*' 2>/dev/null | awk '/install ok installed/ && $1 !~ /-base$/ {print $1}') )
  DETAIL="installés : $(summarize "${found[@]}")"
  ((${#found[@]}==0)) && return $OK || return $KO
}
apply_R05() {
  local p
  for p in "${PKGS_COMPILERS[@]}" $(dpkg-query -W -f='${Package} ${Status}\n' 'gcc-[0-9]*' 2>/dev/null | awk '/install ok installed/ && $1 !~ /-base$/ {print $1}'); do
    pkg_installed "$p" && confirm "Purger $p (vérifier qu'aucune application n'en dépend) ?" o && run apt-get purge -y "$p"
  done
  run apt-get autoremove -y
}

# --- R06 : algorithmes SSH restreints (guide ANSSI OpenSSH) ----------------------------
SSH_CRYPTO_FILE=/etc/ssh/sshd_config.d/02-anssi-crypto.conf
declare -A SSH_CRYPTO=(
  [ciphers]="chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"
  [macs]="hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com"
  [kexalgorithms]="sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512"
)
register R06 R "Services réseau" "SSH : algorithmes de chiffrement, MAC et échange de clés restreints"
check_R06() {
  pkg_installed openssh-server || { DETAIL="serveur SSH non installé"; return $NA; }
  local cfg k bad=(); mkdir -p /run/sshd 2>/dev/null
  cfg=$(sshd -T 2>/dev/null) || { DETAIL="sshd -T en échec"; return $WARN; }
  for k in "${!SSH_CRYPTO[@]}"; do grep -qx "$k ${SSH_CRYPTO[$k]}" <<<"$cfg" || bad+=("$k"); done
  DETAIL="non restreints : $(summarize "${bad[@]}")"
  ((${#bad[@]}==0)) && return $OK || return $KO
}
apply_R06() {
  info "Les clients SSH très anciens (PuTTY < 0.68, OpenSSH < 6.5) ne pourront plus se connecter."
  confirm "Restreindre les algorithmes SSH ?" o || return 0
  local k content="# Algorithmes SSH (guide ANSSI OpenSSH) - anssi-harden.sh"
  for k in ciphers macs kexalgorithms; do content+=$'\n'"$k ${SSH_CRYPTO[$k]}"; done
  write_file "$SSH_CRYPTO_FILE" 600 "$content"
  ((DRY_RUN)) && return 0
  if sshd -t; then run systemctl reload ssh 2>/dev/null || run systemctl reload sshd
    warn "TESTEZ une nouvelle connexion SSH avant de fermer la session en cours."
  else err "Configuration SSH invalide : restauration."; restore_file "$SSH_CRYPTO_FILE"; return 1; fi
}

# --- R07 : déconnexion des sessions shell inactives ------------------------------------
register R07 R "Comptes" "Déconnexion automatique des shells inactifs (TMOUT=900 s)"
check_R07() {
  grep -qs 'TMOUT=900' /etc/profile.d/anssi-tmout.sh && { DETAIL="TMOUT=900"; return $OK; }
  DETAIL="aucun délai d'inactivité"; return $KO
}
apply_R07() {
  write_file /etc/profile.d/anssi-tmout.sh 644 '# Déconnexion après 15 min d'"'"'inactivité (anssi-harden.sh)
if [ "${TMOUT:-0}" != 900 ]; then TMOUT=900; readonly TMOUT; export TMOUT; fi'
}

# --- R08 : Ctrl-Alt-Suppr désactivé ----------------------------------------------------
register R08 R "Démarrage" "Redémarrage par Ctrl-Alt-Suppr désactivé"
check_R08() {
  local s; s=$(systemctl is-enabled ctrl-alt-del.target 2>/dev/null)
  DETAIL="ctrl-alt-del.target : ${s:-inconnu}"
  [[ $s == masked ]] && return $OK || return $KO
}
apply_R08() { run systemctl mask ctrl-alt-del.target; }

# --- R09 : règles auditd immuables -----------------------------------------------------
AUDIT_IMMUTABLE=/etc/audit/rules.d/99-anssi-immutable.rules
register R09 R "Journalisation" "Règles auditd verrouillées jusqu'au redémarrage (-e 2)"
check_R09() {
  pkg_installed auditd || { DETAIL="auditd absent (mesure I08)"; return $KO; }
  [[ -f $AUDIT_IMMUTABLE ]] || { DETAIL="non configuré"; return $KO; }
  auditctl -s 2>/dev/null | grep -q '^enabled 2' && { DETAIL="verrouillé"; return $OK; }
  DETAIL="configuré, actif au prochain redémarrage"; return $WARN
}
apply_R09() {
  pkg_installed auditd || { err "auditd absent : appliquer d'abord la mesure I08."; return 1; }
  warn "Une fois verrouillées, les règles auditd ne se modifient qu'après un redémarrage."
  confirm "Verrouiller les règles auditd ?" o || return 0
  write_file "$AUDIT_IMMUTABLE" 640 '## Verrouillage des règles (doit rester le DERNIER fichier) - anssi-harden.sh
-e 2'
  run augenrules --load
}

# --- R10 : contrôle d'intégrité des fichiers (AIDE) -----------------------------------
register R10 R "Journalisation" "Contrôle d'intégrité des fichiers système (AIDE, base de référence)"
check_R10() {
  pkg_installed aide || { DETAIL="AIDE absent"; return $KO; }
  [[ -s /var/lib/aide/aide.db ]] || { DETAIL="AIDE installé, base de référence absente"; return $KO; }
  DETAIL="base : $(date -r /var/lib/aide/aide.db '+%F %T')"; return $OK
}
apply_R10() {
  info "L'initialisation de la base prend plusieurs minutes. À refaire après chaque mise à jour validée."
  confirm "Installer AIDE et créer la base de référence ?" o || return 0
  pkg_installed aide || apt_install aide aide-common || return 1
  run aideinit -y -f
  info "Contrôle manuel : sudo aide --config /etc/aide/aide.conf --check"
}

# --- R11 : blocage du chargement de modules après démarrage — SENSIBLE ----------------
MODLOCK_UNIT=/etc/systemd/system/anssi-modules-disabled.service
register R11 R "Noyau" "Chargement de modules noyau interdit une fois le démarrage terminé" 1
check_R11() {
  local v; v=$(sysctl -n kernel.modules_disabled 2>/dev/null)
  if [[ $v == 1 ]]; then DETAIL="actif"; return $OK; fi
  systemctl is-enabled -q anssi-modules-disabled.service 2>/dev/null && { DETAIL="configuré, actif au prochain démarrage"; return $WARN; }
  DETAIL="modules chargeables à tout moment"; return $KO
}
apply_R11() {
  warn "Plus AUCUN module ne pourra être chargé après le démarrage (irréversible jusqu'au redémarrage)."
  warn "Tout matériel branché à chaud (adaptateur USB-série, JTAG, clé…) devra être présent AU DÉMARRAGE."
  confirm "Activer le blocage des modules après démarrage ?" n || return 0
  write_file "$MODLOCK_UNIT" 644 '[Unit]
Description=ANSSI : blocage du chargement de modules noyau apres demarrage
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/sysctl -w kernel.modules_disabled=1

[Install]
WantedBy=multi-user.target'
  run systemctl daemon-reload
  run systemctl enable anssi-modules-disabled.service
  REBOOT_NEEDED=1
  info "Pour désactiver : systemctl disable anssi-modules-disabled.service, puis redémarrer."
}

# --- R12 : IPv6 désactivé s'il n'est pas utilisé — SENSIBLE ---------------------------
IPV6_FILE=/etc/sysctl.d/99-zz-anssi-ipv6.conf
register R12 R "Réseau" "IPv6 désactivé s'il n'est pas utilisé" 1
check_R12() {
  if [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null) == 1 && -f $IPV6_FILE ]]; then
    DETAIL="désactivé"; return $OK
  fi
  if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
    DETAIL="adresse IPv6 globale présente : vérifier avant de désactiver"; return $WARN
  fi
  DETAIL="activé mais non utilisé"; return $KO
}
apply_R12() {
  ip -6 addr show scope global 2>/dev/null | grep -q inet6 && warn "Une adresse IPv6 globale est configurée sur ce poste."
  confirm "Désactiver IPv6 ?" n || return 0
  write_file "$IPV6_FILE" 644 '# IPv6 non utilisé (anssi-harden.sh)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1'
  run sysctl -q -p "$IPV6_FILE"
}

# =============================================================================
#  R20–R27 : POINTS À ÉTUDIER (contrôle seul, pas de correction automatique)
#  Ils dépendent des applications, de l'infrastructure ou du matériel.
# =============================================================================

register R20 R "À étudier" "[À étudier] Isolation des services systemd (ProtectSystem, PrivateTmp…)"
check_R20() {
  local n; n=$(systemd-analyze security --no-pager 2>/dev/null | grep -c 'UNSAFE')
  DETAIL="$n service(s) UNSAFE — détail : systemd-analyze security <service> ; corriger par drop-in [Service]"
  return $WARN
}

register R21 R "À étudier" "[À étudier] Profils AppArmor pour les services exposés sur le réseau"
check_R21() {
  local p; p=$(ss -tulpnH 2>/dev/null | grep -o 'users:(("[^"]*"' | cut -d'"' -f2 | sort -u | xargs)
  DETAIL="processus en écoute : ${p:-aucun} — confiner ceux qui sont exposés (aa-genprof)"
  return $WARN
}

register R22 R "À étudier" "[À étudier] Journalisation centralisée vers un serveur dédié"
check_R22() {
  if grep -rqsE '^[^#]*(@@?[a-zA-Z0-9]|omfwd)' /etc/rsyslog.conf /etc/rsyslog.d/ \
     || systemctl is-enabled -q systemd-journal-upload 2>/dev/null; then
    DETAIL="envoi distant configuré"; return $OK
  fi
  DETAIL="aucun envoi distant — nécessite un serveur de journaux (rsyslog TLS, journal-remote…)"; return $WARN
}

register R23 R "À étudier" "[À étudier] Règles sudo limitées aux commandes nécessaires"
check_R23() {
  local r; r=$(grep -rhsE '^[^#].*=[[:space:]]*\(ALL(:ALL)?\)[[:space:]]*ALL' /etc/sudoers /etc/sudoers.d/ | grep -v '^root[[:space:]]' | xargs)
  DETAIL="règles « tout autoriser » : ${r:-aucune} — à remplacer par des règles par commande selon les rôles"
  [[ -z $r ]] && return $OK || return $WARN
}

register R24 R "À étudier" "[À étudier] /proc monté avec hidepid (processus des autres utilisateurs masqués)"
check_R24() {
  findmnt -no OPTIONS /proc | grep -q hidepid && { DETAIL="hidepid actif"; return $OK; }
  DETAIL="non configuré — prévoir un groupe d'exception (systemd-logind, supervision)"; return $WARN
}

register R25 R "À étudier" "[À étudier] Contrôle des périphériques USB autorisés (USBGuard)"
check_R25() {
  pkg_installed usbguard && systemctl is-active -q usbguard 2>/dev/null && { DETAIL="USBGuard actif"; return $OK; }
  DETAIL="absent — nécessite l'inventaire des périphériques légitimes (maquettes, sondes…)"; return $WARN
}

register R26 R "À étudier" "[À étudier] Chiffrement du disque (LUKS)"
check_R26() {
  lsblk -no TYPE 2>/dev/null | grep -q crypt && { DETAIL="volume chiffré présent"; return $OK; }
  DETAIL="non chiffré — se décide à l'installation (déverrouillage par phrase de passe ou TPM)"; return $WARN
}

register R27 R "À étudier" "[À étudier] Démarrage UEFI + Secure Boot, IOMMU activé"
check_R27() {
  local sb="BIOS (pas d'UEFI)" iommu="non"
  if [[ -d /sys/firmware/efi ]]; then
    sb=$(mokutil --sb-state 2>/dev/null | head -1); sb=${sb:-UEFI (état Secure Boot inconnu)}
  fi
  grep -qE 'iommu=(force|on|pt)|intel_iommu=on|amd_iommu=on' /proc/cmdline && iommu="oui"
  DETAIL="$sb ; IOMMU forcé : $iommu — dépend du matériel et du micrologiciel"
  [[ $sb == *"SecureBoot enabled"* && $iommu == oui ]] && return $OK || return $WARN
}

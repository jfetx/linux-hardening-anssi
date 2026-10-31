#!/usr/bin/env bash
# =============================================================================
#  anssi-bp028-r80.sh — Vérification des 80 recommandations ANSSI-BP-028 v2.0
# -----------------------------------------------------------------------------
#  Usage : sudo ./anssi-bp028-r80.sh [-l minimal|intermediaire|renforce|eleve]
#                 [-r R12,R28] [-j ecarts.conf] [-o rapport.csv] [-q] [-v]
#    -l  niveau (défaut : intermediaire, qui inclut minimal)
#    -r  ne vérifier que certaines recommandations (quel que soit le niveau)
#    -j  fichier d'écarts justifiés et d'attestations (« Rxx | motif | texte »)
#    -o  export CSV (séparateur « ; ») pour la documentation de livraison
#    -q  n'afficher que les recommandations restant à traiter
#    -v  détail de chaque point contrôlé (y compris les points conformes)
#  Référentiel : ComplianceAsCode controls/anssi.yml (R1–R80), adapté à Ubuntu.
#  Lecture seule : ne modifie rien. Complément indépendant de anssi-audit.sh.
#  Code retour : 0 si plus rien n'est à traiter (KO, à vérifier, manuel non attesté), 1 sinon.
# =============================================================================
SCRIPT_VERSION=1.2
# Locale UTF-8 (alignement des colonnes accentuées) et sorties des commandes en anglais (analyse fiable)
if locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$'; then export LC_ALL=C.UTF-8; fi
LEVEL=intermediaire ONLY="" CSV="" JFILE="" QUIET=0 VERBOSE=0 MAXD=6
usage() { sed -n '3,16p' "$0" | sed 's/^#  \{0,1\}//'; exit "${1:-0}"; }

while (($#)); do
  case $1 in
    -l|--level)    LEVEL=$2; shift 2 ;;
    -r|--reco)     ONLY=",${2^^},"; ONLY=${ONLY// /}; shift 2 ;;
    -o|--csv)      CSV=$2; shift 2 ;;
    -j|--justif)   JFILE=$2; shift 2 ;;
    -q|--quiet)    QUIET=1; shift ;;
    -v|--verbose)  VERBOSE=1; MAXD=9999; shift ;;
    --no-color)    NO_COLOR=1; shift ;;
    -h|--help)     usage 0 ;;
    *) echo "Option inconnue : $1" >&2; usage 1 ;;
  esac
done
case $LEVEL in
  minimal) LNUM=1 ;; intermediaire) LNUM=2 ;; renforce) LNUM=3 ;; eleve) LNUM=4 ;;
  *) echo "Niveau invalide : $LEVEL" >&2; exit 1 ;;
esac

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YEL=$'\e[33m' C_BLU=$'\e[36m' C_DIM=$'\e[2m' C_BLD=$'\e[1m' C_RST=$'\e[0m'
else
  C_RED="" C_GRN="" C_YEL="" C_BLU="" C_DIM="" C_BLD="" C_RST=""
fi
IS_ROOT=0; ((EUID == 0)) && IS_ROOT=1
SCAN_FILE=""
trap 'rm -f "${SCAN_FILE:-}"' EXIT

# =============================================================================
#  Outils génériques
# =============================================================================
norm() { local -a a; read -ra a <<<"$1"; printf '%s' "${a[*]}"; }
pad()  { local s=${1:0:$2}; printf '%s%*s' "$s" $(($2 - ${#s})) ""; }
join() { local sep=$1; shift; local out="" x; for x in "$@"; do out+="${out:+$sep}$x"; done; printf '%s' "$out"; }
pkg_installed() { [[ $(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) == installed ]]; }
svc_active()  { systemctl is-active  --quiet "$1" 2>/dev/null; }
svc_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }

# --- Catalogue : ID, niveau (1=M 2=I 3=R 4=E), titre, mesures couvrantes, remarque Ubuntu
declare -a IDS=()
declare -A T_LVL=() T_TITLE=() T_COVER=() T_NOTE=()
def() { IDS+=("$1"); T_LVL[$1]=$2; T_TITLE[$1]=$3; T_COVER[$1]=${4:--}; T_NOTE[$1]=${5:-}; }

# --- État d'une vérification ------------------------------------------------
P_OK=0 P_TOT=0 FORCE=""; declare -a KO_L=() WARN_L=() INFO_L=()
reset_state() { P_OK=0; P_TOT=0; FORCE=""; KO_L=(); WARN_L=(); INFO_L=(); }
ok()     { ((P_OK++, P_TOT++)); INFO_L+=("✔ $*"); }
ko()     { ((P_TOT++)); KO_L+=("$*"); }
soft()   { ((P_TOT++)); WARN_L+=("$*"); }          # point recommandé, non bloquant
note()   { INFO_L+=("• $*"); }                      # élément de preuve / information
manual() { FORCE=MANUEL; local x; for x in "$@"; do note "$x"; done; }
na()     { FORCE=NA; local x; for x in "$@"; do note "$x"; done; }
needroot() { ((IS_ROOT)) && return 0; FORCE=MANUEL; note "Contrôle impossible sans root : $*"; return 1; }

# =============================================================================
#  Collecte des données (une seule fois)
# =============================================================================
# --- sysctl : valeur appliquée au démarrage (dernier fichier gagnant) --------
declare -a SC_K=() SC_V=()
load_sysctl_conf() {
  local bin="" b out line
  for b in /usr/lib/systemd/systemd-sysctl /lib/systemd/systemd-sysctl; do [[ -x $b ]] && { bin=$b; break; }; done
  if [[ -n $bin ]] && out=$("$bin" --cat-config 2>/dev/null) && [[ -n $out ]]; then :
  else out=$(cat /usr/lib/sysctl.d/*.conf /run/sysctl.d/*.conf /etc/sysctl.d/*.conf /etc/sysctl.conf 2>/dev/null); fi
  # ufw réapplique /etc/ufw/sysctl.conf à son démarrage, après systemd-sysctl
  if grep -qs '^ENABLED=yes' /etc/ufw/ufw.conf && [[ -r /etc/ufw/sysctl.conf ]]; then
    out+=$'\n'$(cat /etc/ufw/sysctl.conf)
  fi
  while IFS= read -r line; do
    line=${line%%[#;]*}
    [[ $line =~ ^[[:space:]]*-?([^=[:space:]]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    SC_K+=("${BASH_REMATCH[1]//\//.}"); SC_V+=("$(norm "${BASH_REMATCH[2]}")")
  done <<<"$out"
}
sysctl_persist() { # clé -> valeur configurée (motifs glob acceptés)
  local i k=$1
  for ((i = ${#SC_K[@]} - 1; i >= 0; i--)); do
    # shellcheck disable=SC2053
    if [[ ${SC_K[i]} == "$k" || $k == ${SC_K[i]} ]]; then printf '%s' "${SC_V[i]}"; return 0; fi
  done
  return 1
}
cmp_val() { # valeur attendu mode
  case $3 in
    ge) [[ $1 =~ ^-?[0-9]+$ ]] && (($1 >= $2)) ;;
    le) [[ $1 =~ ^-?[0-9]+$ ]] && (($1 <= $2)) ;;
    *)  [[ $1 == "$2" ]] ;;
  esac
}
chk_sysctl() { # clé attendu [eq|ge|le]
  local key=$1 exp=$2 mode=${3:-eq} f rt pv sym="="
  [[ $mode == ge ]] && sym="≥"; [[ $mode == le ]] && sym="≤"
  f=/proc/sys/${key//.//}
  if [[ ! -r $f ]]; then note "$key absent de ce noyau — non compté"; return; fi
  rt=$(norm "$(cat "$f" 2>/dev/null)")
  pv=$(sysctl_persist "$key") || pv=""
  if ! cmp_val "$rt" "$exp" "$mode"; then ko "$key = $rt (attendu $sym $exp)"
  elif [[ -n $pv ]] && ! cmp_val "$pv" "$exp" "$mode"; then
    ko "$key = $rt en cours, mais $pv au prochain démarrage (configuration sysctl/ufw)"
  else ok "$key = $rt"; fi
}
sysctl_set() { local mode=$1 kv; shift; for kv in "$@"; do chk_sysctl "${kv%%=*}" "${kv#*=}" "$mode"; done; }

# --- Ligne de commande du noyau ------------------------------------------------
CMDLINE_RT=" $(cat /proc/cmdline 2>/dev/null) "
CMDLINE_CFG=" $( (
  GRUB_CMDLINE_LINUX="" GRUB_CMDLINE_LINUX_DEFAULT=""
  # shellcheck disable=SC1091
  [[ -r /etc/default/grub ]] && . /etc/default/grub >/dev/null 2>&1
  # shellcheck disable=SC1090
  for f in /etc/default/grub.d/*.cfg; do [[ -r $f ]] && . "$f" >/dev/null 2>&1; done
  echo "$GRUB_CMDLINE_LINUX $GRUB_CMDLINE_LINUX_DEFAULT") 2>/dev/null) "
chk_param() { # paramètre exact (ex. pti=on)
  local p=$1 rt=0 pc=0
  [[ $CMDLINE_RT == *" $p "* ]] && rt=1
  [[ $CMDLINE_CFG == *" $p "* ]] && pc=1
  if ((rt && pc)); then ok "$p"
  elif ((rt)); then ko "$p actif mais absent de /etc/default/grub (perdu à la prochaine régénération)"
  elif ((pc)); then ko "$p configuré mais non actif (update-grub puis redémarrage ?)"
  else ko "$p absent de la ligne de commande du noyau"; fi
}

# --- Configuration de compilation du noyau ---------------------------------------
declare -A KC=()
load_kconfig() {
  local f line v
  f=/boot/config-$(uname -r)
  [[ -r $f ]] || { [[ -r /proc/config.gz ]] && f=/proc/config.gz || return 1; }
  while IFS= read -r line; do
    if [[ $line =~ ^(CONFIG_[A-Za-z0-9_]+)=(.*)$ ]]; then
      v=${BASH_REMATCH[2]}; v=${v#\"}; v=${v%\"}; KC[${BASH_REMATCH[1]}]=$v
    elif [[ $line =~ ^#\ (CONFIG_[A-Za-z0-9_]+)\ is\ not\ set ]]; then KC[${BASH_REMATCH[1]}]=n; fi
  done < <(if [[ $f == *.gz ]]; then zcat "$f"; else cat "$f"; fi)
}
kcfg_set() { # entrées "NOM|attendu[|NOM_ALTERNATIF]"
  local kv n e a v
  if ((${#KC[@]} == 0)); then manual "Configuration du noyau introuvable (/boot/config-$(uname -r))"; return; fi
  for kv in "$@"; do
    IFS='|' read -r n e a <<<"$kv"
    [[ -z ${KC[CONFIG_$n]+x} && -n $a && -n ${KC[CONFIG_$a]+x} ]] && n=$a
    if [[ -z ${KC[CONFIG_$n]+x} ]]; then
      if [[ $e == n ]]; then ok "CONFIG_$n absent (équivaut à n)"
      else note "CONFIG_$n absent de ce noyau (option supprimée ou renommée) — non compté"; fi
      continue
    fi
    v=${KC[CONFIG_$n]}
    if [[ $v == "$e" ]]; then ok "CONFIG_$n=$v"; else ko "CONFIG_$n=$v (attendu $e)"; fi
  done
}

# --- Points de montage -------------------------------------------------------
has_opt() { [[ ",$1," == *",$2,"* ]]; }
chk_mount() { # point options requis|optionnel
  local mp=$1 opts=$2 req=$3 rt fs o
  rt=$(findmnt -rn -M "$mp" -o OPTIONS 2>/dev/null | head -1)
  fs=$(findmnt -rn --fstab -M "$mp" -o OPTIONS 2>/dev/null | head -1)
  if [[ -z $rt ]]; then
    if [[ $req == requis ]]; then ko "$mp : pas de partition dédiée"
    else soft "$mp : pas de partition dédiée (recommandé si le répertoire est utilisé)"; fi
    return
  fi
  ok "$mp : partition dédiée"
  for o in ${opts//,/ }; do
    if ! has_opt "$rt" "$o"; then ko "$mp : option $o absente"
    elif [[ -n $fs ]] && ! has_opt "$fs" "$o"; then ko "$mp : $o actif mais absent de /etc/fstab"
    else ok "$mp : $o"; fi
  done
}

# --- Droits sur fichiers -------------------------------------------------------
chk_perm() { # chemin droits_max propriétaire [groupes séparés par |]
  local p=$1 max=$2 own=$3 grp=${4:-} m u g
  [[ -e $p ]] || return 0
  read -r m u g < <(stat -Lc '%a %U %G' "$p" 2>/dev/null) || return 0
  local -a bad=()
  (((8#$m & ~8#$max & 8#7777) != 0)) && bad+=("droits $m > $max")
  [[ -n $own && $u != "$own" ]] && bad+=("propriétaire $u au lieu de $own")
  [[ -n $grp && "|$grp|" != *"|$g|"* ]] && bad+=("groupe $g au lieu de ${grp//|/ ou }")
  if ((${#bad[@]})); then ko "$p : $(join ', ' "${bad[@]}")"; else ok "$p ($m $u:$g)"; fi
}

# --- Comptes -----------------------------------------------------------------
declare -a HUMANS=()
declare -A SHADOW=()
NOLOGIN_RE='^(/usr)?/s?bin/(nologin|false)$'
load_accounts() {
  local u x uid gid gecos home sh
  while IFS=: read -r u x uid gid gecos home sh; do
    ((uid >= 1000 && uid < 60000)) && [[ ! $sh =~ $NOLOGIN_RE ]] && HUMANS+=("$u")
  done < <(getent passwd)
  if [[ -r /etc/shadow ]]; then
    while IFS=: read -r u x _; do SHADOW[$u]=$x; done </etc/shadow
  fi
}

# --- Services réseau en écoute ---------------------------------------------------
declare -a L_PROTO=() L_ADDR=() L_PORT=() L_PROC=() L_PID=()
LISTEN_LOADED=0
load_listen() {
  ((LISTEN_LOADED)) && return; LISTEN_LOADED=1
  command -v ss >/dev/null || return
  local netid state rq sq loc peer proc pn pid
  # shellcheck disable=SC2034
  while read -r netid state rq sq loc peer proc; do
    pn="?" pid=""
    [[ $proc =~ \(\(\"([^\"]+)\",pid=([0-9]+) ]] && { pn=${BASH_REMATCH[1]}; pid=${BASH_REMATCH[2]}; }
    L_PROTO+=("$netid"); L_ADDR+=("${loc%:*}"); L_PORT+=("${loc##*:}"); L_PROC+=("$pn"); L_PID+=("$pid")
  done < <(LC_ALL=C ss -Htulnp 2>/dev/null)
}
is_loopback() { local a=${1#[}; a=${a%]}; [[ $1 == *%lo* ]] && return 0; a=${a%%\%*}; [[ $a == 127.* || $a == ::1 || $a == ::ffff:127.* ]]; }

# --- sudoers -----------------------------------------------------------------
declare -a SD_OPTS=() SP_SRC=() SP_WHO=() SP_RUNAS=() SP_TAGS=() SP_CMD=()
SUDO_LOADED=0
parse_sudo_line() {
  local src=$1 l=$2 o who rhs item c cur="" runas="root" tags="" depth=0 i
  if [[ $l =~ ^Defaults([[:space:]]|$) ]]; then
    local -a parts; IFS=',' read -ra parts <<<"${l#Defaults}"
    for o in "${parts[@]}"; do
      o=$(norm "$o"); o=${o// = /=}; o=${o// =/=}; o=${o//= /=}
      [[ -n $o ]] && SD_OPTS+=("$o")
    done
    return
  fi
  [[ $l =~ ^Defaults ]] && return                       # Defaults:user, Defaults>… (non globaux)
  [[ $l =~ ^(User|Runas|Host|Cmnd|Cmd)_Alias ]] && return
  [[ $l == *=* ]] || return
  who=$(norm "${l%%=*}"); rhs=${l#*=}
  local -a items=()
  for ((i = 0; i < ${#rhs}; i++)); do
    c=${rhs:i:1}
    case $c in
      '(') ((depth++)); cur+=$c ;;
      ')') ((depth--)); cur+=$c ;;
      ',') if ((depth == 0)); then items+=("$cur"); cur=""; else cur+=$c; fi ;;
      *)   cur+=$c ;;
    esac
  done
  items+=("$cur")
  for item in "${items[@]}"; do
    item=$(norm "$item")
    if [[ $item =~ ^\(([^\)]*)\)[[:space:]]*(.*)$ ]]; then runas=$(norm "${BASH_REMATCH[1]}"); item=${BASH_REMATCH[2]}; fi
    while [[ $item =~ ^([A-Z_]+):[[:space:]]*(.*)$ ]]; do tags+="${BASH_REMATCH[1]} "; item=${BASH_REMATCH[2]}; done
    [[ -z $item ]] && continue
    SP_SRC+=("$src"); SP_WHO+=("$who"); SP_RUNAS+=("${runas:-root}"); SP_TAGS+=("$tags"); SP_CMD+=("$item")
  done
}
load_sudoers() {
  ((SUDO_LOADED)) && return 0; SUDO_LOADED=1
  [[ -r /etc/sudoers ]] || return 1
  local -a files=(/etc/sudoers); local d f line buf
  while read -r _ d; do
    [[ -d $d ]] || continue
    for f in "$d"/*; do [[ -f $f && ${f##*/} != *[.~]* ]] && files+=("$f"); done
  done < <(grep -hE '^[#@]includedir[[:space:]]' /etc/sudoers)
  while read -r _ f; do [[ -f $f ]] && files+=("$f"); done < <(grep -hE '^[#@]include[[:space:]]' /etc/sudoers)
  for f in "${files[@]}"; do
    [[ -r $f ]] || continue
    buf=""
    while IFS= read -r line || [[ -n $line ]]; do
      [[ $line =~ ^[[:space:]]*[#@]include ]] && continue
      line=${line%%#*}
      if [[ $line == *\\ ]]; then buf+="${line%\\} "; continue; fi
      line=$(norm "$buf$line"); buf=""
      [[ -n $line ]] && parse_sudo_line "$f" "$line"
    done <"$f"
  done
}
sudo_flag() { local o st=1; for o in "${SD_OPTS[@]}"; do case $o in "$1"|"$1="*) st=0 ;; "!$1") st=1 ;; esac; done; return $st; }
sudo_val()  { local o v=""; for o in "${SD_OPTS[@]}"; do [[ $o == "$1="* ]] && v=${o#*=}; done; printf '%s' "${v//\"/}"; }

# --- Analyse des systèmes de fichiers locaux (R52–R57) -------------------------------
fs_scan() {
  [[ -n $SCAN_FILE ]] && return
  SCAN_FILE=$(mktemp)
  [[ -t 2 ]] && printf '%s' "${C_DIM}  … analyse des systèmes de fichiers locaux (1 à 3 min)${C_RST}" >&2
  local mp
  while read -r mp; do
    find "$mp" -xdev \( -path /var/lib/docker -o -path /var/lib/containerd -o -path /proc -o -path /sys \) -prune -o \
      \( -nouser -o -nogroup -o \( -type f \( -perm -4000 -o -perm -2000 \) \) -o \( ! -type l -perm -0002 \) \) \
      -printf '%y|%m|%u|%g|%p\n' 2>/dev/null
  done < <({ findmnt -rn -t ext2,ext3,ext4,xfs,btrfs,f2fs,vfat,zfs -o TARGET; printf '%s\n' /tmp /var/tmp /dev/shm; } | sort -u) >"$SCAN_FILE"
  [[ -t 2 ]] && printf '\r%*s\r' 70 "" >&2
}
declare -A DPKG_OWNED=()
dpkg_owner_batch() { # remplit DPKG_OWNED pour une liste de chemins
  local p alt
  while IFS= read -r p; do DPKG_OWNED[${p#*: }]=1; done < <(dpkg -S "$@" 2>/dev/null | grep -v '^diversion')
  for p in "$@"; do
    [[ -n ${DPKG_OWNED[$p]:-} ]] && continue
    case $p in /usr/*) alt=${p#/usr} ;; /bin/*|/sbin/*|/lib/*) alt=/usr$p ;; *) continue ;; esac
    dpkg -S "$alt" >/dev/null 2>&1 && DPKG_OWNED[$p]=1
  done
}

# --- Règles auditd ------------------------------------------------------------
AUD_RT="" AUD_CFG="" AUD_LOADED=0
load_audit() {
  ((AUD_LOADED)) && return; AUD_LOADED=1
  AUD_CFG=$(cat /etc/audit/rules.d/*.rules 2>/dev/null)
  ((IS_ROOT)) && command -v auditctl >/dev/null && AUD_RT=$(auditctl -l 2>/dev/null)
}
aud_has() { # type(sc|w) valeur texte
  case $1 in
    sc) grep -qE "(^|[[:space:]])-S[[:space:]]*([a-z0-9_]+,)*$2(,|[[:space:]]|$)" <<<"$3" ;;
    w)  grep -qE "(-w[[:space:]]+|(path|dir)=)$2([[:space:]/]|$)" <<<"$3" ;;
  esac
}
chk_aud() { # type valeur libellé
  local in_rt=1 in_cfg=1
  aud_has "$1" "$2" "$AUD_RT" || in_rt=0
  aud_has "$1" "$2" "$AUD_CFG" || in_cfg=0
  if [[ -n $AUD_RT ]]; then
    if ((in_rt && in_cfg)); then ok "$3"
    elif ((in_rt)); then ko "$3 : règle chargée mais absente de /etc/audit/rules.d (non persistante)"
    elif ((in_cfg)); then soft "$3 : règle définie mais non chargée (augenrules --load / redémarrage)"
    else ko "$3 : aucune règle"; fi
  else
    if ((in_cfg)); then ok "$3 (fichiers de règles)"; else ko "$3 : aucune règle"; fi
  fi
}

# --- Écarts justifiés et attestations (-j) ----------------------------------------
declare -a J_ID=() J_PAT=() J_TXT=() J_USED=() JUST_L=() INC_L=()
ATTEST=""
load_just() {
  local f=$1 line id pat txt
  [[ -r $f ]] || { echo "Fichier de justifications introuvable : $f" >&2; exit 1; }
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    IFS='|' read -r id pat txt <<<"$line"
    id=$(norm "${id^^}"); pat=$(norm "$pat"); txt=$(norm "$txt")
    if [[ ! $id =~ ^R[0-9]+$ || -z $pat || -z $txt ]]; then
      echo "Ligne ignorée (format attendu « Rxx | motif | justification ») : $line" >&2; continue
    fi
    J_ID+=("$id"); J_PAT+=("$pat"); J_TXT+=("$txt"); J_USED+=(0)
  done <"$f"
}
# Texte modèle non complété (« <…> », « JJ/MM/AAAA », « à compléter »)
just_incomplete() { [[ $1 == *"<"*">"* || $1 == *JJ/MM* || ${1,,} == *"à compléter"* ]]; }
# Déplace les points couverts par une justification de KO_L/WARN_L vers JUST_L.
# Motif « * » : tous les points de la recommandation, et attestation d'une recommandation MANUEL.
apply_just() {
  local id=$1 i x
  local -a kept
  JUST_L=(); INC_L=(); ATTEST=""
  for i in "${!J_ID[@]}"; do
    [[ ${J_ID[i]} == "$id" ]] || continue
    if just_incomplete "${J_TXT[i]}"; then INC_L+=("justification à compléter : « ${J_PAT[i]} » (${J_TXT[i]})"); J_USED[i]=1; continue; fi
    kept=()
    for x in "${KO_L[@]}"; do
      if [[ ${J_PAT[i]} == "*" || $x == *"${J_PAT[i]}"* ]]; then JUST_L+=("$x  →  ${J_TXT[i]}"); J_USED[i]=1; else kept+=("$x"); fi
    done
    KO_L=("${kept[@]}")
    kept=()
    for x in "${WARN_L[@]}"; do
      if [[ ${J_PAT[i]} == "*" || $x == *"${J_PAT[i]}"* ]]; then JUST_L+=("$x  →  ${J_TXT[i]}"); J_USED[i]=1; else kept+=("$x"); fi
    done
    WARN_L=("${kept[@]}")
    if [[ $FORCE == MANUEL && ${J_PAT[i]} == "*" ]]; then ATTEST=${J_TXT[i]}; J_USED[i]=1; fi
  done
}

# =============================================================================
#  Catalogue des 80 recommandations (niveaux issus de ComplianceAsCode)
# =============================================================================
def R1  3 "Support matériel : 64 bits, NX, SMEP/SMAP (DAT-24)"     "-"
def R2  2 "Configuration du BIOS/UEFI (DAT-24)"                    "-"
def R3  2 "Activer le démarrage sécurisé UEFI (Secure Boot)"       "I23" "Sur VM Proxmox : OVMF avec clés pré-enrôlées (efitype 4m + pre-enrolled-keys)."
def R4  4 "Remplacer les clés UEFI préchargées"                    "-"
def R5  2 "Protéger le chargeur de démarrage par mot de passe"     "I12"
def R6  4 "Protéger les paramètres de ligne de commande du noyau"  "-"
def R7  3 "Activer l'IOMMU (iommu=force)"                          "R27" "Sur VM, l'IOMMU dépend de l'hyperviseur (vIOMMU) : écart justifiable."
def R8  2 "Options mémoire de la ligne de commande du noyau"       "I17,R01" "À ajouter dans GRUB_CMDLINE_LINUX puis update-grub. mds=full,nosmt désactive l'hyperthreading, slub_debug/page_poison coûtent en performance, mce=0 provoque un arrêt sur erreur mémoire non corrigible : tester avant la production."
def R9  2 "Options de configuration du noyau (sysctl kernel.*)"    "I02" "pid_max=65536 : vérifier la compatibilité avec Docker et la base de données (nombreux threads)."
def R10 3 "Interdire le chargement des modules noyau"             "R11" "modules_disabled=1 est irréversible jusqu'au redémarrage : à positionner en fin de démarrage. Incompatible avec Docker (modules réseau chargés à la demande)."
def R11 2 "Activer et configurer le LSM Yama"                      "I02"
def R12 2 "Options de configuration du réseau IPv4"               "I01" "ip_forward=1 est imposé par Docker : écart à justifier sur un poste Docker."
def R13 2 "Désactiver IPv6 ou durcir sa configuration"            "I18" "IPv6 inutilisé : ajouter ipv6.disable=1 à la ligne de commande du noyau."
def R14 2 "Options de configuration des systèmes de fichiers"     "I02,I11" "Sous Ubuntu, ufw (/etc/ufw/sysctl.conf) et apport peuvent réécrire certaines valeurs au démarrage."
KNOTE="Niveau Élevé : nécessite un noyau recompilé. Le noyau générique Ubuntu ne peut pas satisfaire toutes ces options (écart à documenter)."
def R15 4 "Compilation : gestion de la mémoire"                    "-" "$KNOTE"
def R16 4 "Compilation : structures de données du noyau"           "-" "$KNOTE"
def R17 4 "Compilation : allocateur mémoire"                       "-" "$KNOTE"
def R18 4 "Compilation : gestion des modules noyau"                "-" "$KNOTE"
def R19 4 "Compilation : évènements anormaux"                      "-" "$KNOTE"
def R20 4 "Compilation : primitives de sécurité du noyau"          "-" "$KNOTE"
def R21 4 "Compilation : plugins du compilateur"                   "-" "$KNOTE"
def R22 4 "Compilation : pile IP"                                   "-" "$KNOTE"
def R23 4 "Compilation : comportements divers du noyau"            "-" "$KNOTE"
def R24 4 "Compilation : architectures 32 bits"                    "-"
def R25 4 "Compilation : architecture x86_64"                      "-" "$KNOTE"
def R26 4 "Compilation : architecture ARM"                         "-"
def R27 4 "Compilation : architecture ARM 64 bits"                 "-" "$KNOTE"
def R28 2 "Partitionnement type et options de montage"            "I05,I06,I24" "Ubuntu : noexec sur /var casse dpkg (scripts de maintenance) et Docker, écart courant à justifier. hidepid=2 sur /proc nécessite une option gid= pour les services système (polkit, logind)."
def R29 3 "Restreindre l'accès au dossier /boot"                   "M09" "Ubuntu : /boot est en 755 par défaut (chmod 700 /boot)."
def R30 1 "Supprimer les comptes utilisateur inutilisés"           "-"
def R31 1 "Utiliser des mots de passe robustes"                    "M08,I20" "ComplianceAsCode retient minlen=15 et faillock deny=3 ; le guide renvoie aux recommandations ANSSI sur les mots de passe (12 caractères et complexité au minimum)."
def R32 2 "Verrouiller les sessions inactives"                     "I19" "Sans interface graphique, TMOUT suffit ; StopIdleSessionSec (logind, systemd ≥ 252) couvre aussi les sessions SSH."
def R33 2 "Imputabilité des opérations d'administration"           "M06,M07,I08"
def R34 2 "Désactiver les comptes de service"                      "I13"
def R35 2 "Comptes de service uniques et exclusifs"                "-"
def R36 3 "UMASK 0077 pour les shells"                             "I10,R03" "077 pour les shells, 027 pour les services (UMask= dans les unités systemd)."
def R37 3 "Utiliser un contrôle d'accès obligatoire (MAC)"         "I07"
def R38 3 "Groupe dédié à l'usage de sudo"                         "-" "Ubuntu : /usr/bin/sudo est en 4755. Exemple : groupadd sudogrp ; dpkg-statoverride --update --add root sudogrp 4750 /usr/bin/sudo."
def R39 2 "Directives de configuration sudo"                       "I09,I21" "« Defaults noexec » empêche les commandes lancées par sudo de créer des sous-processus (apt, systemctl… cassés) : prévoir le tag EXEC: pour ces commandes (R41). requiretty bloque sudo dans les scripts sans terminal."
def R40 2 "Utilisateurs cibles non privilégiés dans sudo"          "R23" "La règle d'administration %sudo ALL=(ALL:ALL) ALL est l'écart habituel, à justifier."
def R41 3 "Limiter les commandes nécessitant la directive EXEC"   "I21"
def R42 2 "Bannir les négations dans les règles sudo"              "R23"
def R43 2 "Préciser les arguments dans les règles sudo"            "R23"
def R44 2 "Éditer les fichiers avec sudoedit"                      "R23"
def R45 3 "Activer les profils de sécurité AppArmor (enforce)"     "I07,R21"
def R46 4 "Activer SELinux avec la politique targeted"            "-" "Ubuntu utilise AppArmor (voir R37 et R45)."
def R47 4 "Confiner les utilisateurs interactifs non privilégiés"  "-" "Ubuntu utilise AppArmor (voir R37 et R45)."
def R48 4 "Paramétrer les booléens SELinux"                        "-" "Ubuntu utilise AppArmor (voir R37 et R45)."
def R49 4 "Désinstaller les outils de débogage SELinux"            "-" "Ubuntu utilise AppArmor (voir R37 et R45)."
def R50 2 "Droits d'accès aux fichiers et répertoires sensibles"   "M09,I22" "Les binaires setgid d'Ubuntu (crontab, chage, wall…) n'appartiennent pas au groupe root : seul le propriétaire est contrôlé."
def R51 3 "Changer les secrets et accès dès l'installation"       "-"
def R52 2 "Restreindre l'accès aux sockets et pipes nommés"        "-"
def R53 1 "Aucun fichier sans utilisateur ou groupe connu"         "M11"
def R54 1 "Sticky bit sur les répertoires inscriptibles par tous"  "M10"
def R55 2 "Répertoires temporaires dédiés aux comptes"             "I25" "Pour les services : PrivateTmp=yes dans les unités systemd. Pour les utilisateurs : pam_namespace + /etc/security/namespace.conf."
def R56 1 "Exécutables setuid/setgid justifiés"                    "I14"
def R57 3 "Réduire les exécutables setuid root / setgid root"      "I15"
def R58 1 "N'installer que les paquets strictement nécessaires"    "M03,R05"
def R59 1 "Dépôts de paquets officiels et de confiance"            "M15" "Un dépôt tiers (Docker…) n'est pas « officiel » : à justifier, avec clé dédiée (signed-by)."
def R60 3 "Dépôts de paquets durcis"                               "-"
def R61 1 "Mises à jour régulières"                                "M01,M02" "Poste hors ligne en production : prévoir une procédure de mise à jour (miroir local ou paquets transférés)."
def R62 1 "Désinstaller les services non nécessaires"              "M03"
def R63 2 "Réduire les fonctionnalités des services au minimum" "M04"
def R64 3 "Privilèges minimaux des services"                       "R20" "Exposition élevée normale pour getty, ssh ou cron ; viser en priorité les services applicatifs (ProtectSystem, PrivateTmp, NoNewPrivileges…)."
def R65 3 "Cloisonner les services"                                "R20"
def R66 4 "Durcir les composants de virtualisation"                "-"
def R67 2 "Authentifications distantes par PAM sécurisées"         "-"
def R68 1 "Protéger les mots de passe stockés"                     "M08"
def R69 2 "Sécuriser l'accès aux bases utilisateurs distantes"     "-"
def R70 2 "Séparer comptes système et administrateur d'annuaire"   "-"
def R71 3 "Mettre en place un système de journalisation"           "M12,M13,I06,R22" "Poste hors ligne : la centralisation des journaux peut être un écart justifié."
def R72 3 "Journaux d'activité dédiés par service"                 "-"
def R73 3 "Journaliser l'activité système avec auditd"             "I08,R09" "Règles de référence : /usr/share/doc/auditd/examples/rules/ (30-ospp-v42, 30-stig…), puis augenrules --load."
def R74 2 "Durcir le service de messagerie locale"                 "-"
def R75 2 "Alias de messagerie pour les comptes de service"        "-"
def R76 4 "Sceller et vérifier l'intégrité des fichiers"           "I26"
def R77 4 "Protéger la base de données des scellés"                "I26"
def R78 3 "Cloisonner les services réseau"                         "-"
def R79 2 "Durcir et surveiller les services exposés"              "I07,I26"
def R80 1 "Réduire la surface d'attaque des services réseau"       "M04,M05"

# =============================================================================
#  Vérifications
# =============================================================================
chk_R1() {
  local a; a=$(uname -m)
  [[ $a == x86_64 || $a == aarch64 ]] && ok "architecture 64 bits ($a)" || ko "architecture $a (64 bits recommandé)"
  if [[ $a == x86_64 ]]; then
    grep -qw nx /proc/cpuinfo && ok "bit NX supporté" || ko "bit NX absent ou désactivé"
    grep -qw smep /proc/cpuinfo && ok "SMEP supporté" || soft "SMEP non exposé par le processeur (ou la VM)"
    grep -qw smap /proc/cpuinfo && ok "SMAP supporté" || soft "SMAP non exposé par le processeur (ou la VM)"
    grep -qw aes /proc/cpuinfo && ok "AES-NI supporté" || soft "AES-NI non exposé (type de CPU de la VM ?)"
  fi
  local p; for p in nosmep nosmap noexec=off mitigations=off nopti; do
    [[ $CMDLINE_RT == *" $p "* ]] && ko "paramètre $p présent sur la ligne de commande du noyau"
  done
}
chk_R2() {
  local v; v=$(systemd-detect-virt 2>/dev/null)
  manual "Mode de démarrage : $([[ -d /sys/firmware/efi ]] && echo UEFI || echo 'BIOS hérité')" \
    "Plateforme : $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null) — BIOS $(cat /sys/class/dmi/id/bios_version 2>/dev/null)${v:+ — virtualisation : $v}" \
    "À vérifier dans le BIOS/UEFI : mot de passe administrateur, démarrage sur le disque interne uniquement, périphériques inutiles désactivés (Wi-Fi, Bluetooth, caméra, ports), protection DMA/Thunderbolt, VT-x/AMD-V désactivé si inutile."
}
chk_R3() {
  if [[ ! -d /sys/firmware/efi ]]; then ko "démarrage en mode BIOS hérité (UEFI requis pour Secure Boot)"; return; fi
  ok "démarrage UEFI"
  local f b
  f=$(ls /sys/firmware/efi/efivars/SecureBoot-8be4df61-* 2>/dev/null | head -1)
  if [[ -n $f ]]; then b=$(od -An -t u1 -j4 -N1 "$f" 2>/dev/null | tr -d ' ')
    [[ $b == 1 ]] && ok "Secure Boot activé" || ko "Secure Boot désactivé"
  elif command -v mokutil >/dev/null; then
    mokutil --sb-state 2>/dev/null | grep -q 'enabled' && ok "Secure Boot activé" || ko "Secure Boot désactivé"
  else ko "état Secure Boot indéterminé (variable EFI absente)"; fi
}
chk_R4() { manual "Remplacement des clés PK/KEK/db par des clés propres (niveau Élevé) : opération manuelle dans l'UEFI, à documenter."; }
chk_R5() {
  local cfg=/boot/grub/grub.cfg
  needroot "lecture de $cfg" || return
  [[ -r $cfg ]] || { manual "$cfg introuvable (autre chargeur de démarrage ?) : vérifier la protection par mot de passe."; return; }
  grep -qE '^[[:space:]]*set[[:space:]]+superusers=' "$cfg" && ok "superutilisateur GRUB défini" || ko "aucun superutilisateur GRUB (set superusers)"
  grep -qE '^[[:space:]]*password_pbkdf2[[:space:]]' "$cfg" && ok "mot de passe GRUB chiffré (PBKDF2)" || ko "aucun mot de passe GRUB password_pbkdf2"
  grep -qsE '^[[:space:]]*password[[:space:]]' "$cfg" && ko "mot de passe GRUB en clair (password au lieu de password_pbkdf2)"
  grep -rqsE 'superusers|password_pbkdf2' /etc/grub.d/ && ok "configuration persistante dans /etc/grub.d" || ko "mot de passe absent de /etc/grub.d (perdu à la régénération)"
}
chk_R6() {
  manual "Avec GRUB, les paramètres du noyau restent modifiables au démarrage sauf mot de passe GRUB (R5). Le niveau Élevé demande un noyau unifié signé (UKI) avec Secure Boot."
}
chk_R7() {
  chk_param iommu=force
  if compgen -G "/sys/class/iommu/*" >/dev/null; then ok "IOMMU actif"; else soft "aucune IOMMU active (désactivée dans l'UEFI ou VM sans vIOMMU)"; fi
}
chk_R8() {
  local p
  for p in l1tf=full,force page_poison=on pti=on slab_nomerge=yes slub_debug=FZP \
           spec_store_bypass_disable=seccomp spectre_v2=on mds=full,nosmt mce=0 \
           page_alloc.shuffle=1 rng_core.default_quality=500; do chk_param "$p"; done
  [[ $CMDLINE_RT == *" mitigations=off "* ]] && ko "mitigations=off présent"
  chk_sysctl vm.mmap_min_addr 65536
}
chk_R9() {
  sysctl_set eq kernel.dmesg_restrict=1 kernel.kptr_restrict=2 kernel.pid_max=65536 \
    kernel.perf_cpu_time_max_percent=1 kernel.perf_event_max_sample_rate=1 \
    kernel.randomize_va_space=2 kernel.sysrq=0 kernel.unprivileged_bpf_disabled=1 kernel.panic_on_oops=1
  chk_sysctl kernel.perf_event_paranoid 2 ge   # Ubuntu >= 24.04 : 4 (plus strict)
}
chk_R10() {
  local v; v=$(cat /proc/sys/kernel/modules_disabled 2>/dev/null)
  [[ $v == 1 ]] && ok "kernel.modules_disabled = 1" || ko "kernel.modules_disabled = ${v:-?} (attendu 1)"
}
chk_R11() {
  if grep -qs yama /sys/kernel/security/lsm; then ok "LSM Yama chargé"
  elif [[ -r /sys/kernel/security/lsm ]]; then ko "LSM Yama non chargé"; fi
  chk_sysctl kernel.yama.ptrace_scope 1 ge
}
chk_R12() {
  sysctl_set eq net.core.bpf_jit_harden=2 net.ipv4.ip_forward=0 \
    net.ipv4.conf.all.accept_local=0 net.ipv4.conf.all.accept_redirects=0 net.ipv4.conf.default.accept_redirects=0 \
    net.ipv4.conf.all.secure_redirects=0 net.ipv4.conf.default.secure_redirects=0 \
    net.ipv4.conf.all.shared_media=0 net.ipv4.conf.default.shared_media=0 \
    net.ipv4.conf.all.accept_source_route=0 net.ipv4.conf.default.accept_source_route=0 \
    net.ipv4.conf.all.arp_filter=1 net.ipv4.conf.all.arp_ignore=2 net.ipv4.conf.all.route_localnet=0 \
    net.ipv4.conf.all.drop_gratuitous_arp=1 net.ipv4.conf.all.rp_filter=1 net.ipv4.conf.default.rp_filter=1 \
    net.ipv4.conf.all.send_redirects=0 net.ipv4.conf.default.send_redirects=0 \
    net.ipv4.icmp_ignore_bogus_error_responses=1 "net.ipv4.ip_local_port_range=32768 65535" \
    net.ipv4.tcp_rfc1337=1 net.ipv4.tcp_syncookies=1
}
chk_R13() {
  if [[ ! -d /proc/sys/net/ipv6 || $CMDLINE_RT == *" ipv6.disable=1 "* ]]; then ok "IPv6 désactivé (ipv6.disable=1)"; return; fi
  if [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null) == 1 && $(cat /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null) == 1 ]]; then
    ok "IPv6 désactivé (disable_ipv6=1)"; chk_sysctl net.ipv6.conf.all.disable_ipv6 1; chk_sysctl net.ipv6.conf.default.disable_ipv6 1; return
  fi
  soft "IPv6 actif : à désactiver s'il n'est pas utilisé, sinon durcir"
  local s k
  for s in all default; do
    for k in router_solicitations=0 accept_ra_rtr_pref=0 accept_ra_pinfo=0 accept_ra_defrtr=0 autoconf=0 \
             accept_redirects=0 accept_source_route=0 max_addresses=1; do
      chk_sysctl "net.ipv6.conf.$s.${k%%=*}" "${k#*=}"
    done
  done
}
chk_R14() {
  sysctl_set eq fs.suid_dumpable=0 fs.protected_fifos=2 fs.protected_regular=2 fs.protected_symlinks=1 fs.protected_hardlinks=1
}
chk_R15() {
  kcfg_set "STRICT_KERNEL_RWX|y" "DEBUG_WX|y" "DEBUG_FS|n" "STACKPROTECTOR|y" "STACKPROTECTOR_STRONG|y" \
    "SCHED_STACK_END_CHECK|y" "HARDENED_USERCOPY|y" "HARDENED_USERCOPY_FALLBACK|n" "VMAP_STACK|y" "REFCOUNT_FULL|y" \
    "FORTIFY_SOURCE|y" "ACPI_CUSTOM_METHOD|n" "DEVKMEM|n" "PROC_KCORE|n" "COMPAT_VDSO|n" "SECURITY_DMESG_RESTRICT|y"
  if [[ $(uname -m) == x86_64 ]]; then
    kcfg_set "RETPOLINE|y|MITIGATION_RETPOLINE" "LEGACY_VSYSCALL_NONE|y" "LEGACY_VSYSCALL_EMULATE|n" \
      "LEGACY_VSYSCALL_XONLY|n" "X86_VSYSCALL_EMULATION|n"
  fi
}
chk_R16() { kcfg_set "DEBUG_CREDENTIALS|y" "DEBUG_NOTIFIERS|y" "DEBUG_LIST|y" "DEBUG_SG|y" "BUG_ON_DATA_CORRUPTION|y"; }
chk_R17() {
  kcfg_set "SLAB_FREELIST_RANDOM|y" "SLAB_FREELIST_HARDENED|y" "SLAB_MERGE_DEFAULT|n" "SLUB_DEBUG|y" \
    "PAGE_POISONING|y" "PAGE_POISONING_NO_SANITY|y" "PAGE_POISONING_ZERO|y" "COMPAT_BRK|n"
}
chk_R18() {
  kcfg_set "STRICT_MODULE_RWX|y" "MODULE_SIG|y" "MODULE_SIG_FORCE|y" "MODULE_SIG_ALL|y" "MODULE_SIG_SHA512|y" \
    "MODULE_SIG_HASH|sha512" "MODULE_SIG_KEY|certs/signing_key.pem"
}
chk_R19() { kcfg_set "BUG|y" "PANIC_ON_OOPS|y" "PANIC_TIMEOUT|-1"; }
chk_R20() { kcfg_set "SECCOMP|y" "SECCOMP_FILTER|y" "SECURITY|y" "SECURITY_YAMA|y" "SECURITY_WRITABLE_HOOKS|n"; }
chk_R21() {
  kcfg_set "GCC_PLUGIN_LATENT_ENTROPY|y" "GCC_PLUGIN_STACKLEAK|y" "GCC_PLUGIN_STRUCTLEAK|y" \
    "GCC_PLUGIN_STRUCTLEAK_BYREF_ALL|y" "GCC_PLUGIN_RANDSTRUCT|y|RANDSTRUCT_FULL"
}
chk_R22() { kcfg_set "SYN_COOKIES|y"; }
chk_R23() { kcfg_set "KEXEC|n" "HIBERNATION|n" "BINFMT_MISC|n" "LEGACY_PTYS|n"; }
chk_R24() { na "Système 64 bits : non applicable."; }
chk_R25() {
  [[ $(uname -m) == x86_64 ]] || { na "Architecture $(uname -m) : non applicable."; return; }
  kcfg_set "DEFAULT_MMAP_MIN_ADDR|65536" "RANDOMIZE_BASE|y" "RANDOMIZE_MEMORY|y" \
    "PAGE_TABLE_ISOLATION|y|MITIGATION_PAGE_TABLE_ISOLATION" "IA32_EMULATION|n" "MODIFY_LDT_SYSCALL|n"
}
chk_R26() { na "Architecture $(uname -m) : non applicable."; }
chk_R27() {
  [[ $(uname -m) == aarch64 ]] || { na "Architecture $(uname -m) : non applicable."; return; }
  kcfg_set "DEFAULT_MMAP_MIN_ADDR|32768" "RANDOMIZE_BASE|y" "ARM64_SW_TTBR0_PAN|y" "UNMAP_KERNEL_AT_EL0|y|MITIGATION_UNMAP_KERNEL_AT_EL0"
}
chk_R28() {
  chk_mount /boot    nosuid,nodev,noexec requis
  chk_mount /home    nosuid,nodev,noexec requis
  chk_mount /tmp     nosuid,nodev,noexec requis
  chk_mount /var     nosuid,nodev,noexec requis
  chk_mount /var/log nosuid,nodev,noexec requis
  chk_mount /var/tmp nosuid,nodev,noexec requis
  chk_mount /opt     nosuid,nodev        optionnel
  chk_mount /srv     nosuid,nodev        optionnel
  if findmnt -rn -M /usr >/dev/null 2>&1; then chk_mount /usr nodev requis
  else note "/usr non séparé (usr fusionné d'Ubuntu, non proposé par l'installeur) — non compté"; fi
  local po; po=$(findmnt -rn -M /proc -o OPTIONS 2>/dev/null)
  if has_opt "$po" hidepid=2 || has_opt "$po" hidepid=invisible; then ok "/proc : hidepid=2"; else ko "/proc : hidepid=2 absent"; fi
  local mp opts
  while read -r mp opts; do
    case $mp in /|/boot|/home|/tmp|/var|/var/log|/var/tmp|/opt|/srv|/usr) continue ;; esac
    has_opt "$opts" nodev && ok "$mp : nodev" || ko "$mp : nodev absent (toute partition locale autre que /)"
  done < <(findmnt -rn -t ext2,ext3,ext4,xfs,btrfs,f2fs,vfat -o TARGET,OPTIONS 2>/dev/null)
}
chk_R29() {
  chk_perm /boot 700 root
  chk_perm /boot/grub/grub.cfg 600 root root
  chk_perm /boot/grub/user.cfg 600 root root
  local f
  for f in /boot/efi/EFI/*/grub.cfg; do [[ -e $f ]] && chk_perm "$f" 700 root; done
  for f in /boot/System.map-*; do [[ -e $f ]] && chk_perm "$f" 600 root; done
  findmnt --fstab -rn -M /boot -o OPTIONS 2>/dev/null | grep -q noauto && ok "/boot non monté automatiquement (noauto)" \
    || note "/boot monté automatiquement (noauto conseillé quand c'est possible)"
}
chk_R30() {
  local u ll ev=()
  for u in "${HUMANS[@]}"; do
    ll="inconnue"
    if command -v lastlog >/dev/null; then ll=$(lastlog -u "$u" 2>/dev/null | tail -n1 | awk '{$1=""; print}' | sed 's/^ *//')
    elif command -v lastlog2 >/dev/null; then ll=$(lastlog2 -u "$u" 2>/dev/null | tail -n1 | awk '{$1=""; print}' | sed 's/^ *//'); fi
    ev+=("$u — dernière connexion : ${ll:-jamais}")
  done
  manual "Comptes interactifs (${#HUMANS[@]}) : vérifier que chacun est nominatif et utilisé." "${ev[@]}"
}
pwq_get() {
  local k=$1 v="" f x pl
  for f in /etc/security/pwquality.conf.d/*.conf /etc/security/pwquality.conf; do
    [[ -r $f ]] || continue
    x=$(grep -E "^[[:space:]]*${k}[[:space:]]*=" "$f" | tail -1 | cut -d= -f2 | tr -d ' ')
    [[ -n $x ]] && v=$x
  done
  pl=$(grep -E '^[^#]*pam_pwquality\.so' /etc/pam.d/common-password 2>/dev/null | head -1)
  [[ $pl =~ (^|[[:space:]])$k=([^[:space:]]+) ]] && v=${BASH_REMATCH[2]}
  printf '%s' "$v"
}
chk_R31() {
  if grep -qE '^[^#]*pam_pwquality\.so' /etc/pam.d/common-password 2>/dev/null; then ok "pam_pwquality actif"
  else ko "pam_pwquality absent de /etc/pam.d/common-password"; fi
  local minlen minclass n=0 c v
  minlen=$(pwq_get minlen); minlen=${minlen:-8}
  ((minlen >= 12)) && ok "longueur minimale $minlen" || ko "longueur minimale $minlen (attendu ≥ 12)"
  ((minlen >= 15)) || note "ComplianceAsCode retient minlen=15"
  minclass=$(pwq_get minclass); minclass=${minclass:-0}
  for c in dcredit ucredit lcredit ocredit; do v=$(pwq_get $c); [[ $v == -* && $v != -0 ]] && ((n++)); done
  if ((minclass >= 3 || n >= 3)); then ok "complexité exigée (minclass=$minclass, classes imposées=$n)"
  else ko "complexité insuffisante (minclass=$minclass, classes imposées=$n ; attendu ≥ 3 classes)"; fi
  if grep -qsE '^[^#]*pam_faillock\.so' /etc/pam.d/common-auth; then ok "verrouillage après échecs (pam_faillock)"
  else soft "pas de verrouillage après échecs (pam_faillock, ComplianceAsCode : deny=3, unlock_time=900)"; fi
  if grep -qsE '^[^#]*(pam_pwhistory\.so.*remember=[1-9]|pam_unix\.so.*remember=[1-9])' /etc/pam.d/common-password; then ok "historique des mots de passe"
  else soft "pas d'historique des mots de passe (pam_pwhistory remember ≥ 2)"; fi
}
chk_R32() {
  local t v
  t=$(grep -hsE '^[[:space:]]*(readonly[[:space:]]+|declare[[:space:]]+-[a-z]*r[a-z]*[[:space:]]+|typeset[[:space:]]+-r[[:space:]]+|export[[:space:]]+)?TMOUT=[0-9]+' \
      /etc/profile /etc/profile.d/*.sh /etc/bash.bashrc | tail -1)
  v=${t##*TMOUT=}; v=${v%%[!0-9]*}
  if [[ -z $v ]]; then ko "TMOUT non défini (déconnexion des shells inactifs)"
  elif ((v > 0 && v <= 900)); then ok "TMOUT=$v s"
  else ko "TMOUT=$v s (attendu entre 1 et 900, ComplianceAsCode : 600)"; fi
  if [[ -n $v ]]; then
    grep -hsqE "readonly[[:space:]]+TMOUT|declare[[:space:]]+-[a-z]*r[a-z]*[[:space:]]+TMOUT|typeset[[:space:]]+-r[[:space:]]+TMOUT" /etc/profile /etc/profile.d/*.sh /etc/bash.bashrc \
      && ok "TMOUT en lecture seule" || soft "TMOUT modifiable par l'utilisateur (readonly conseillé)"
  fi
  local s; s=$(systemd-analyze cat-config systemd/logind.conf 2>/dev/null | grep -E '^[[:space:]]*StopIdleSessionSec=' | tail -1 | cut -d= -f2)
  if [[ -n $s && $s != infinity ]]; then ok "logind StopIdleSessionSec=$s"; else soft "logind StopIdleSessionSec non défini (couvre aussi les sessions SSH)"; fi
}
chk_R33() {
  local st pr
  st=$(passwd -S root 2>/dev/null | awk '{print $2}')
  case $st in L|LK) ok "mot de passe root verrouillé" ;; "") needroot "état du compte root" ;; *) ko "mot de passe root utilisable (connexion directe possible)" ;; esac
  if ((IS_ROOT)) && command -v sshd >/dev/null; then pr=$(sshd -T 2>/dev/null | awk '$1=="permitrootlogin"{print $2}'); fi
  [[ -z $pr ]] && pr=$(grep -hsiE '^[[:space:]]*PermitRootLogin' /etc/ssh/sshd_config.d/*.conf /etc/ssh/sshd_config | head -1 | awk '{print $2}')
  if ! command -v sshd >/dev/null; then note "serveur SSH non installé"
  elif [[ ${pr,,} == no ]]; then ok "SSH : PermitRootLogin no"
  else ko "SSH : PermitRootLogin ${pr:-prohibit-password (défaut)} (attendu no)"; fi
  command -v sudo >/dev/null && ok "sudo installé" || ko "sudo absent"
  svc_active auditd && ok "auditd actif (traçabilité)" || soft "auditd inactif : actions d'administration non tracées"
}
chk_R34() {
  needroot "lecture de /etc/shadow" || return
  local u x uid gid gecos home sh pw n=0
  # shellcheck disable=SC2034
  while IFS=: read -r u x uid gid gecos home sh; do
    ((uid == 0)) && continue
    ((uid < 1000 || uid == 65534)) || continue
    ((n++))
    if [[ $sh == /bin/sync || $sh == /usr/bin/sync ]]; then soft "$u : shell $sh (nologin conseillé)"
    elif [[ ! $sh =~ $NOLOGIN_RE ]]; then ko "$u : compte de service avec shell interactif ($sh)"; fi
    pw=${SHADOW[$u]-}
    if [[ -z $pw ]]; then [[ -n ${SHADOW[$u]+x} ]] && ko "$u : mot de passe vide"
    elif [[ $pw != [\!\*]* ]]; then ko "$u : compte de service avec mot de passe utilisable"; fi
  done < <(getent passwd)
  ((${#KO_L[@]} + ${#WARN_L[@]} == 0)) && ok "$n comptes de service sans shell ni mot de passe"
}
chk_R35() {
  local d
  d=$(getent passwd | cut -d: -f3 | sort | uniq -d | tr '\n' ' ')
  [[ -n $d ]] && ko "UID dupliqués : $d" || ok "aucun UID dupliqué"
  d=$(getent group | cut -d: -f3 | sort | uniq -d | tr '\n' ' ')
  [[ -n $d ]] && ko "GID dupliqués : $d" || ok "aucun GID dupliqué"
  d=$(ps -eo user=,comm= 2>/dev/null | awk '$1=="nobody"{print $2}' | sort -u | tr '\n' ' ')
  [[ -n $d ]] && soft "processus exécutés en « nobody » (compte partagé) : $d"
  manual "Vérifier qu'un compte dédié est attribué à chaque service (y compris Docker et la base de données)."
}
chk_R36() {
  local ld prof eff
  ld=$(awk '$1=="UMASK"{v=$2} END{print v}' /etc/login.defs 2>/dev/null)
  prof=$(grep -hsE '^[[:space:]]*umask[[:space:]]+[0-7]+' /etc/profile /etc/profile.d/*.sh /etc/bash.bashrc | tail -1 | awk '{print $2}')
  [[ -n $ld && $((8#$ld)) -eq $((8#077)) ]] && ok "login.defs UMASK $ld" || ko "login.defs UMASK ${ld:-non défini} (attendu 077)"
  eff=${prof:-$ld}
  [[ -n $eff && $((8#$eff)) -eq $((8#077)) ]] && ok "umask des shells $eff" || ko "umask des shells ${eff:-?} (attendu 077)"
}
chk_R37() {
  if [[ $(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) == Y ]]; then ok "AppArmor actif"
  elif command -v selinuxenabled >/dev/null && selinuxenabled; then ok "SELinux actif"
  else ko "aucun contrôle d'accès obligatoire (AppArmor/SELinux) actif"; fi
}
chk_R38() {
  local m u g
  read -r m u g < <(stat -c '%a %U %G' /usr/bin/sudo 2>/dev/null) || { ko "/usr/bin/sudo introuvable"; return; }
  if [[ $g != root ]] && (((8#$m & 1) == 0)); then ok "/usr/bin/sudo réservé au groupe $g ($m)"
  else ko "/usr/bin/sudo exécutable par tous ($m $u:$g) : groupe dédié + droits 4750 attendus"; fi
}
chk_R39() {
  needroot "lecture de /etc/sudoers" || return
  load_sudoers
  local o um rs=0
  [[ $(sudo -V 2>/dev/null | head -1) == sudo-rs* ]] && rs=1
  for o in noexec requiretty use_pty ignore_dot env_reset; do
    if sudo_flag "$o"; then ok "Defaults $o"
    elif ((rs)) && [[ $o == requiretty ]]; then
      ko "Defaults requiretty absent : directive non supportée par sudo-rs (erreur de syntaxe) → écart à justifier (compensé par use_pty + authentification + auditd)"
    else ko "Defaults $o absent"; fi
  done
  ((rs)) && note "sudo-rs : pas de « Defaults logfile » ; journalisation des commandes dans journald (COMMAND=) — journalctl _COMM=sudo"
  um=$(sudo_val umask)
  if [[ -n $um && $((8#$um)) -eq $((8#077)) ]]; then ok "Defaults umask=$um"; else ko "Defaults umask=0077 absent${um:+ (actuel : $um)}"; fi
}
chk_R40() {
  needroot "lecture de /etc/sudoers" || return
  load_sudoers
  local i n=0
  for i in "${!SP_CMD[@]}"; do
    [[ ${SP_WHO[i]} == root\ * ]] && continue
    ((n++))
    if [[ ,${SP_RUNAS[i]//[: ]/,}, == *,ALL,* || ,${SP_RUNAS[i]//[: ]/,}, == *,root,* ]]; then
      soft "${SP_WHO[i]} → ${SP_CMD[i]} exécuté en tant que ${SP_RUNAS[i]} (à justifier)"
    else ok "${SP_WHO[i]} → ${SP_CMD[i]} en tant que ${SP_RUNAS[i]}"; fi
  done
  ((n)) || ok "aucune règle sudo hors root"
}
chk_R41() {
  needroot "lecture de /etc/sudoers" || return
  load_sudoers
  local i ev=()
  for i in "${!SP_CMD[@]}"; do [[ ${SP_TAGS[i]} == *EXEC* && ${SP_TAGS[i]} != *NOEXEC* ]] && ev+=("EXEC : ${SP_WHO[i]} → ${SP_CMD[i]}"); done
  manual "${#ev[@]} règle(s) avec le tag EXEC : à réduire au strict minimum." "${ev[@]}"
  sudo_flag noexec || note "« Defaults noexec » absent : toutes les commandes sudo peuvent lancer des sous-processus."
}
chk_R42() {
  needroot "lecture de /etc/sudoers" || return
  load_sudoers
  local i
  for i in "${!SP_CMD[@]}"; do [[ ${SP_CMD[i]} == !* ]] && ko "négation : ${SP_WHO[i]} → ${SP_CMD[i]} (${SP_SRC[i]})"; done
  ((${#KO_L[@]})) || ok "aucune négation dans les règles sudo"
}
chk_R43() {
  needroot "lecture de /etc/sudoers" || return
  load_sudoers
  local i c n=0
  for i in "${!SP_CMD[@]}"; do
    c=${SP_CMD[i]}
    [[ $c == ALL || $c == !* || ${SP_WHO[i]} == root\ * ]] && continue
    ((n++))
    if [[ $c != *" "* ]]; then ko "${SP_WHO[i]} → $c : sans argument explicite (tous les arguments autorisés)"
    elif [[ $c == *\** ]]; then soft "${SP_WHO[i]} → $c : joker dans les arguments"
    else ok "${SP_WHO[i]} → $c"; fi
  done
  ((n)) || ok "aucune règle sudo à commande restreinte (règles ALL : voir R40)"
}
chk_R44() {
  needroot "lecture de /etc/sudoers" || return
  load_sudoers
  local i b
  for i in "${!SP_CMD[@]}"; do
    b=${SP_CMD[i]%% *}; b=${b##*/}
    case $b in vi|vim|vim.basic|vim.tiny|nvim|nano|emacs|ed|ex|joe|mcedit|less|more|view)
      ko "${SP_WHO[i]} → ${SP_CMD[i]} : éditeur/visualiseur via sudo (utiliser sudoedit)" ;;
    esac
  done
  ((${#KO_L[@]})) || ok "aucun éditeur lancé directement via sudo"
}
chk_R45() {
  [[ $(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) == Y ]] && ok "AppArmor activé dans le noyau" || { ko "AppArmor inactif"; return; }
  needroot "aa-status" || return
  local out loaded comp unc
  out=$(LC_ALL=C aa-status 2>/dev/null)
  loaded=$(sed -nE 's/^([0-9]+) profiles are loaded.*/\1/p' <<<"$out")
  comp=$(sed -nE 's/^([0-9]+) profiles are in complain mode.*/\1/p' <<<"$out")
  unc=$(sed -nE 's/^([0-9]+) processes are unconfined but have a profile defined.*/\1/p' <<<"$out")
  ok "${loaded:-0} profils chargés"
  if [[ ${comp:-0} -gt 0 ]]; then
    ko "$comp profil(s) en mode complain : $(awk '/profiles are in complain mode/{f=1;next} /^[0-9]/{f=0} f{gsub(/^ +/,""); printf "%s ", $0}' <<<"$out")"
  else ok "aucun profil en mode complain"; fi
  [[ ${unc:-0} -gt 0 ]] && soft "$unc processus non confinés alors qu'un profil existe (redémarrer le service)"
  pkg_installed libpam-apparmor && ok "libpam-apparmor installé" || note "libpam-apparmor non installé (confinement par utilisateur, optionnel)"
}
chk_R46() { na; }
chk_R47() { na; }
chk_R48() { na; }
chk_R49() { if pkg_installed setroubleshoot; then ko "setroubleshoot installé"; else na; fi; }
chk_R50() {
  chk_perm /etc/shadow 640 root "root|shadow"
  chk_perm /etc/gshadow 640 root "root|shadow"
  chk_perm /etc/passwd 644 root root
  chk_perm /etc/group 644 root root
  chk_perm /etc/shells 644 root root
  chk_perm /etc/security/opasswd 600 root root
  chk_perm /etc/sudoers 440 root root
  chk_perm /etc/sudoers.d 750 root root
  chk_perm /etc/sysctl.d 755 root root
  chk_perm /etc/crypttab 600 root root
  chk_perm /etc/chrony/chrony.keys 640 root "root|_chrony"
  chk_perm /etc/ssh/sshd_config 600 root root
  local f
  for f in /etc/ssh/ssh_host_*_key; do [[ -e $f ]] && chk_perm "$f" 600 root root; done
  for f in /etc/ssh/ssh_host_*_key.pub; do [[ -e $f ]] && chk_perm "$f" 644 root root; done
  local bad
  bad=$(find /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin -xdev ! -type l \( ! -user root -o -perm /022 \) 2>/dev/null | head -20)
  if [[ -n $bad ]]; then while read -r f; do ko "binaire système non possédé par root ou modifiable : $f"; done <<<"$bad"
  else ok "binaires système possédés par root et non modifiables par le groupe/les autres"; fi
  local u home m own
  for u in "${HUMANS[@]}"; do
    home=$(getent passwd "$u" | cut -d: -f6); [[ -d $home ]] || continue
    read -r m own < <(stat -c '%a %U' "$home")
    [[ $own == "$u" ]] && ok "$home appartient à $u" || ko "$home appartient à $own au lieu de $u"
    (((8#$m & 8#027) == 0)) && ok "$home ($m)" || ko "$home : droits $m (attendu ≤ 750)"
    for f in "$home"/.bashrc "$home"/.profile "$home"/.bash_logout "$home"/.bash_history "$home"/.ssh; do
      [[ -e $f ]] || continue
      read -r m own < <(stat -c '%a %U' "$f")
      [[ $own == "$u" ]] || ko "$f appartient à $own au lieu de $u"
      (((8#$m & 8#022) == 0)) || ko "$f modifiable par le groupe ou les autres ($m)"
      [[ -f $f ]] && (((8#$m & 8#037) != 0)) && soft "$f : droits $m (ComplianceAsCode : ≤ 740)"
    done
  done
}
chk_R51() {
  local ev=() f
  for f in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
    [[ -r $f ]] && ev+=("Empreinte $(basename "$f") : $(ssh-keygen -lf "$f" 2>/dev/null | awk '{print $2}') (créée le $(date -r "$f" +%F))")
  done
  [[ -r /etc/machine-id ]] && ev+=("machine-id : $(cat /etc/machine-id)")
  manual "Comparer ces valeurs entre les postes : elles doivent être différentes (postes clonés = clés SSH et machine-id identiques)." \
    "Vérifier qu'aucun secret par défaut ne subsiste (mots de passe d'installation, comptes applicatifs, base de données)." "${ev[@]}"
}
chk_R52() {
  local -a l
  mapfile -t l < <(find /run /tmp /var/tmp /dev/shm -xdev \( -type s -o -type p \) -perm -0002 2>/dev/null)
  manual "${#l[@]} socket(s)/pipe(s) accessibles en écriture à tous dans /run, /tmp, /var/tmp et /dev/shm (vérifier que l'accès est voulu)." \
    "${l[@]}"
}
chk_R53() {
  fs_scan
  local t m u g p n=0
  while IFS='|' read -r t m u g p; do
    if [[ $u =~ ^[0-9]+$ || $g =~ ^[0-9]+$ ]]; then ko "sans propriétaire connu : $p ($u:$g)"; ((n++)); fi
  done <"$SCAN_FILE"
  ((n)) || ok "aucun fichier sans utilisateur ou groupe connu"
}
chk_R54() {
  fs_scan
  local t m u g p n=0
  while IFS='|' read -r t m u g p; do
    (((8#$m & 2) != 0)) || continue
    if [[ $t == d ]]; then
      ((n++))
      (((8#$m & 8#1000) != 0)) || ko "répertoire inscriptible par tous sans sticky bit : $p ($m)"
      [[ $u == root ]] || soft "répertoire inscriptible par tous non possédé par root : $p ($u)"
    elif [[ $t == f ]]; then ko "fichier inscriptible par tous : $p ($m)"; fi
  done <"$SCAN_FILE"
  ((${#KO_L[@]})) || ok "$n répertoire(s) inscriptible(s) par tous, tous avec sticky bit ; aucun fichier inscriptible par tous"
}
chk_R55() {
  if grep -qsE '^[^#]*pam_namespace\.so' /etc/pam.d/common-session /etc/pam.d/login /etc/pam.d/sshd; then ok "pam_namespace actif"
  else ko "pam_namespace inactif (pas de /tmp propre à chaque utilisateur)"; fi
  if grep -qsE '^[[:space:]]*/tmp[[:space:]]' /etc/security/namespace.conf; then ok "/tmp polyinstancié (namespace.conf)"
  else ko "/tmp non polyinstancié dans /etc/security/namespace.conf"; fi
  if grep -qsE '^[[:space:]]*/var/tmp[[:space:]]' /etc/security/namespace.conf; then ok "/var/tmp polyinstancié"
  else ko "/var/tmp non polyinstancié dans /etc/security/namespace.conf"; fi
}
chk_R56() {
  fs_scan
  local t m u g p
  local -a list=()
  while IFS='|' read -r t m u g p; do
    [[ $t == f ]] && (((8#$m & 8#6000) != 0)) && list+=("$p")
  done <"$SCAN_FILE"
  ((${#list[@]})) || { ok "aucun exécutable setuid/setgid"; return; }
  dpkg_owner_batch "${list[@]}"
  for p in "${list[@]}"; do [[ -n ${DPKG_OWNED[$p]:-} ]] || ko "setuid/setgid hors paquet : $p"; done
  ((${#KO_L[@]})) || ok "${#list[@]} exécutables setuid/setgid, tous issus de paquets de la distribution"
  note "Inventaire à justifier dans la documentation (voir R57)."
}
chk_R57() {
  fs_scan
  local t m u g p ev=()
  while IFS='|' read -r t m u g p; do
    [[ $t == f ]] || continue
    if (((8#$m & 8#4000) != 0)) && [[ $u == root ]]; then ev+=("setuid root : $p")
    elif (((8#$m & 8#2000) != 0)) && [[ $g == root ]]; then ev+=("setgid root : $p"); fi
  done <"$SCAN_FILE"
  manual "${#ev[@]} exécutable(s) setuid root / setgid root : retirer le bit (dpkg-statoverride) sur ceux réservés aux administrateurs." "${ev[@]}"
}
chk_R58() {
  local n gui="" comp=""
  n=$(dpkg-query -f '.\n' -W 2>/dev/null | wc -l)
  pkg_installed ubuntu-desktop || pkg_installed xserver-xorg-core || pkg_installed gdm3 && gui="interface graphique installée"
  for p in gcc g++ clang make; do command -v $p >/dev/null && comp+="$p "; done
  manual "$n paquets installés : vérifier que chacun est nécessaire." ${gui:+"$gui"} ${comp:+"outils de compilation présents : $comp"}
}
chk_R59() {
  local f line uri host n=0
  local -a uris=()
  while IFS= read -r line; do
    line=${line%%#*}
    [[ $line =~ ^[[:space:]]*deb(-src)?[[:space:]]+(\[[^]]*\][[:space:]]+)?([^[:space:]]+) ]] || continue
    [[ ${BASH_REMATCH[2]} == *trusted=yes* ]] && ko "dépôt marqué trusted=yes (signature non vérifiée) : ${BASH_REMATCH[3]}"
    [[ ${BASH_REMATCH[2]} == *allow-insecure=yes* ]] && ko "dépôt allow-insecure=yes : ${BASH_REMATCH[3]}"
    uris+=("${BASH_REMATCH[3]}")
  done < <(cat /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null)
  local stanza
  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -r $f ]] || continue
    while IFS= read -r -d '' stanza; do                  # format deb822 : un paragraphe par source
      grep -qiE '^Enabled:[[:space:]]*no' <<<"$stanza" && continue
      grep -qiE '^Trusted:[[:space:]]*yes' <<<"$stanza" && ko "$f : Trusted: yes (signature non vérifiée)"
      for uri in $(grep -iE '^URIs:' <<<"$stanza" | cut -d: -f2-); do uris+=("$uri"); done
    done < <(awk 'BEGIN{RS=""; ORS="\0"} {print}' "$f")
  done
  for uri in $(printf '%s\n' "${uris[@]}" | sort -u); do
    host=${uri#*://}; host=${host%%/*}
    ((n++))
    if [[ $host =~ (^|\.)(archive|security|ports|esm|old-releases)\.ubuntu\.com$ || $host == *.archive.ubuntu.com ]]; then ok "dépôt officiel : $uri"
    else soft "dépôt non officiel (à justifier) : $uri"; fi
  done
  ((n)) || note "aucune source APT trouvée"
  apt-config dump 2>/dev/null | grep -qiE '(AllowUnauthenticated|AllowInsecureRepositories|AllowDowngradeToInsecureRepositories) "(true|1)"' \
    && ko "APT accepte des dépôts non authentifiés (apt.conf)" || ok "APT n'accepte pas de dépôts non authentifiés"
}
chk_R60() { na "Ubuntu ne propose pas de dépôt « durci » distinct (Ubuntu Pro/ESM éventuellement)."; }
chk_R61() {
  local stamp age n
  stamp=/var/lib/apt/periodic/update-success-stamp; [[ -e $stamp ]] || stamp=/var/lib/apt/lists
  age=$(( ($(date +%s) - $(stat -c %Y "$stamp" 2>/dev/null || echo 0)) / 86400 ))
  n=$(LC_ALL=C apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | grep -c '^Inst .*-security')
  ((n == 0)) && ok "aucune mise à jour de sécurité en attente" || ko "$n mise(s) à jour de sécurité en attente"
  ((age <= 7)) && ok "index APT à jour ($age j)" || soft "index APT ancien de $age jours : résultat possiblement incomplet (apt update)"
  if [[ $(apt-config dump 2>/dev/null | sed -nE 's/^APT::Periodic::Unattended-Upgrade "([0-9]+)";/\1/p') =~ ^[1-9] ]]; then ok "mises à jour de sécurité automatiques actives"
  else soft "mises à jour automatiques inactives (procédure manuelle à documenter)"; fi
}
chk_R62() {
  local p n=0
  for p in isc-dhcp-server kea kea-dhcp4-server rsh-client rsh-server rsh-redone-client rsh-redone-server \
           sendmail sendmail-bin talk talkd inetutils-talk inetutils-talkd telnet telnetd inetutils-telnet \
           inetutils-telnetd tftp tftpd tftpd-hpa tftp-hpa xinetd nis ypserv; do
    pkg_installed "$p" && { ko "paquet $p installé"; ((n++)); }
  done
  ((n)) || ok "aucun service obsolète (telnet, rsh, tftp, talk, nis, xinetd, serveur DHCP, sendmail)"
}
chk_R63() {
  local l
  l=$(systemctl list-unit-files --type=service --state=enabled --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
  manual "Services activés : vérifier que leurs fonctionnalités sont réduites au strict nécessaire." "${l:-aucun (systemd indisponible ?)}"
}
chk_R64() {
  command -v systemd-analyze >/dev/null || { manual "systemd-analyze indisponible"; return; }
  local l
  l=$(LC_ALL=C systemd-analyze security --no-pager 2>/dev/null | awk 'NR>1 && $3=="UNSAFE"{printf "%s(%s) ", $1, $2}')
  if [[ -n $l ]]; then soft "services peu cloisonnés (exposition UNSAFE) : $l"; else ok "aucun service à exposition UNSAFE"; fi
  note "Détail par service : systemd-analyze security <service>"
}
chk_R65() { manual "Cloisonnement des services (conteneurs, namespaces, PrivateTmp/ProtectSystem, AppArmor) à documenter par service."; }
chk_R66() {
  local ev=() v=""
  command -v docker >/dev/null && v+="Docker "
  command -v containerd >/dev/null && v+="containerd "
  command -v virsh >/dev/null && v+="libvirt "
  command -v lxd >/dev/null && v+="LXD "
  [[ -z $v ]] && { na "Aucun composant de virtualisation/conteneurs détecté."; return; }
  if [[ -r /etc/docker/daemon.json ]]; then
    local k; for k in no-new-privileges icc userns-remap live-restore; do
      grep -q "\"$k\"" /etc/docker/daemon.json && ev+=("daemon.json : $k défini") || ev+=("daemon.json : $k non défini")
    done
  elif [[ $v == *Docker* ]]; then ev+=("/etc/docker/daemon.json absent (configuration Docker par défaut)"); fi
  ev+=("membres du groupe docker (équivalent root) : $(getent group docker | cut -d: -f4)")
  manual "Composants détectés : $v" "${ev[@]}"
}
chk_R67() {
  if grep -qsE '^[^#]*pam_(sss|ldap|krb5|winbind)\.so' /etc/pam.d/common-auth; then
    if [[ -r /etc/sssd/sssd.conf ]]; then
      grep -qsE '^[[:space:]]*ldap_tls_reqcert[[:space:]]*=[[:space:]]*(demand|hard)' /etc/sssd/sssd.conf && ok "SSSD : certificat serveur vérifié" || ko "SSSD : ldap_tls_reqcert ≠ demand"
      grep -qsE '^[[:space:]]*(ldap_id_use_start_tls[[:space:]]*=[[:space:]]*true|ldap_uri[[:space:]]*=[[:space:]]*ldaps://)' /etc/sssd/sssd.conf && ok "SSSD : flux chiffré" || ko "SSSD : flux LDAP non chiffré"
    else manual "Authentification distante détectée (PAM) : vérifier le chiffrement et l'authentification du serveur."; fi
  else na "Authentification locale uniquement (pas d'annuaire)."; fi
}
chk_R68() {
  local em; em=$(awk '$1=="ENCRYPT_METHOD"{v=$2} END{print v}' /etc/login.defs 2>/dev/null)
  [[ ${em^^} == YESCRYPT || ${em^^} == SHA512 ]] && ok "ENCRYPT_METHOD $em" || ko "ENCRYPT_METHOD ${em:-non défini} (attendu YESCRYPT ou SHA512)"
  grep -qsE '^[^#]*pam_unix\.so.*(yescrypt|sha512)' /etc/pam.d/common-password && ok "pam_unix : yescrypt/sha512" || ko "pam_unix : algorithme de hachage non précisé ou faible"
  needroot "lecture de /etc/shadow" || return
  local u h
  for u in "${!SHADOW[@]}"; do
    h=${SHADOW[$u]#!}
    [[ -z $h || $h == \** || $h == \!* ]] && continue
    case $h in '$y$'*|'$gy$'*|'$7$'*|'$6$'*) ;; *) ko "$u : mot de passe haché avec un algorithme faible (${h:0:3})" ;; esac
  done
  ((${#KO_L[@]})) || ok "tous les mots de passe stockés en yescrypt/SHA-512"
}
chk_R69() {
  local l; l=$(grep -E '^(passwd|group|shadow):' /etc/nsswitch.conf 2>/dev/null | tr '\n' ' ')
  if [[ $l == *nis* ]]; then ko "NIS utilisé dans nsswitch.conf"
  elif [[ $l =~ (ldap|sss|winbind) ]]; then manual "Base utilisateurs distante ($l) : vérifier TLS et authentification du serveur."
  else ok "bases utilisateurs locales uniquement (files/systemd)"; fi
}
chk_R70() {
  if grep -qsE '^(passwd|group):.*(ldap|sss|winbind)' /etc/nsswitch.conf; then manual "Vérifier que les comptes de service n'ont pas de droits d'administration de l'annuaire."
  else na "Pas d'annuaire."; fi
}
chk_R71() {
  if [[ $(timedatectl show -p NTP --value 2>/dev/null) == yes ]]; then ok "synchronisation horaire activée"
  elif svc_active chrony || svc_active chronyd; then ok "chrony actif"
  else ko "aucune synchronisation horaire active"; fi
  [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]] && ok "horloge synchronisée" || soft "horloge non synchronisée (source NTP joignable ?)"
  if grep -rqsE '^[^#]*(@@?[A-Za-z0-9\[]|type="omfwd")' /etc/rsyslog.conf /etc/rsyslog.d/; then ok "renvoi des journaux vers un serveur distant"
  else soft "pas de journalisation centralisée (rsyslog/omfwd)"; fi
  findmnt -rn -M /var/log/audit >/dev/null 2>&1 && ok "/var/log/audit sur partition dédiée" || ko "/var/log/audit sans partition dédiée"
  if pkg_installed logrotate && { svc_enabled logrotate.timer || [[ -x /etc/cron.daily/logrotate ]]; }; then ok "rotation des journaux (logrotate)"
  else ko "rotation des journaux inactive"; fi
  [[ -d /var/log/journal ]] && ok "journal systemd persistant" || soft "journal systemd non persistant (/var/log/journal absent)"
}
chk_R72() {
  local l n
  l=$(find /var/log -xdev -type f -perm -o+r 2>/dev/null)
  n=$(grep -c . <<<"$l")
  ((n)) && soft "$n journal(aux) lisible(s) par tous dans /var/log (ex. $(head -3 <<<"$l" | tr '\n' ' '))"
  manual "Chaque service doit écrire dans un journal dédié, inaccessible au service lui-même (rsyslog/journald)."
}
chk_R73() {
  svc_active auditd && ok "auditd actif" || ko "auditd inactif"
  load_audit
  [[ -z $AUD_RT ]] && ((IS_ROOT)) && note "règles chargées illisibles (auditctl indisponible) : contrôle sur les fichiers seulement"
  local s
  chk_aud w /etc/sudoers "actions d'administration (/etc/sudoers)"
  chk_aud w /etc/sudoers.d "actions d'administration (/etc/sudoers.d)"
  local sl; ((IS_ROOT)) && { load_sudoers; sl=$(sudo_val logfile); }
  [[ -n $sl ]] && chk_aud w "$sl" "journal sudo ($sl)"
  chk_aud w /var/log/lastlog "connexions (lastlog)"
  chk_aud w '(/var)?/run/faillock' "échecs d'authentification (faillock)"
  chk_aud w '(/var)?/run/utmp' "sessions (utmp)"
  chk_aud w /var/log/wtmp "sessions (wtmp)"
  chk_aud w /var/log/btmp "sessions (btmp)"
  for s in adjtimex settimeofday clock_settime; do chk_aud sc $s "heure : $s"; done
  chk_aud w /etc/localtime "heure : /etc/localtime"
  chk_aud w /etc/apparmor "politique MAC (/etc/apparmor)"
  chk_aud w /etc/apparmor.d "politique MAC (/etc/apparmor.d)"
  for s in sethostname setdomainname; do chk_aud sc $s "réseau : $s"; done
  chk_aud w /etc/hosts "réseau : /etc/hosts"
  chk_aud w /etc/issue "réseau : /etc/issue"
  chk_aud w /etc/netplan "réseau : /etc/netplan"
  for s in chmod fchmod fchmodat chown fchown fchownat lchown setxattr lsetxattr fsetxattr removexattr lremovexattr fremovexattr; do
    chk_aud sc $s "droits DAC : $s"
  done
  for s in creat open openat truncate ftruncate; do chk_aud sc $s "accès refusés : $s"; done
  if grep -qE 'exit=-EACCES' <<<"$AUD_RT$AUD_CFG" && grep -qE 'exit=-EPERM' <<<"$AUD_RT$AUD_CFG"; then ok "accès refusés : EACCES et EPERM filtrés"
  else ko "accès refusés : filtres exit=-EACCES / exit=-EPERM absents"; fi
  for s in /etc/passwd /etc/group /etc/shadow /etc/gshadow /etc/security/opasswd; do chk_aud w "$s" "comptes : $s"; done
  chk_aud sc mount "supports : mount"
  chk_aud sc umount2 "supports : umount2"
  for s in rename renameat renameat2 rmdir unlink unlinkat; do chk_aud sc $s "suppressions : $s"; done
  for s in init_module finit_module delete_module; do chk_aud sc $s "modules : $s"; done
  for s in insmod modprobe rmmod kmod; do chk_aud w "(/usr)?/s?bin/$s" "modules : $s"; done
  # Commandes privilégiées (setuid/setgid)
  fs_scan
  local t m u g p tot=0 cov=0
  while IFS='|' read -r t m u g p; do
    [[ $t == f ]] && (((8#$m & 8#6000) != 0)) || continue
    ((tot++)); grep -qE "path=$p([[:space:]]|$)" <<<"$AUD_RT$AUD_CFG" && ((cov++))
  done <"$SCAN_FILE"
  if ((tot == 0)); then :
  elif ((cov == tot)); then ok "commandes privilégiées : $cov/$tot tracées"
  elif ((cov > 0)); then soft "commandes privilégiées : $cov/$tot tracées"
  else ko "commandes privilégiées : aucune des $tot commandes setuid/setgid n'est tracée"; fi
  if ((IS_ROOT)) && LC_ALL=C auditctl -s 2>/dev/null | grep -q '^enabled 2'; then ok "règles verrouillées (-e 2)"
  elif grep -qE '^[[:space:]]*-e[[:space:]]+2' <<<"$AUD_CFG"; then soft "-e 2 configuré mais non actif (redémarrage nécessaire)"
  else ko "règles non verrouillées (-e 2 absent)"; fi
}
mta_installed() { local p; for p in postfix exim4-daemon-light exim4-daemon-heavy sendmail-bin opensmtpd nullmailer msmtp-mta; do pkg_installed $p && return 0; done; return 1; }
chk_R74() {
  load_listen
  local i n=0
  for i in "${!L_PORT[@]}"; do
    [[ ${L_PROTO[i]} == tcp && ${L_PORT[i]} =~ ^(25|465|587)$ ]] || continue
    ((n++))
    is_loopback "${L_ADDR[i]}" && ok "messagerie en écoute locale uniquement (${L_ADDR[i]}:${L_PORT[i]})" \
      || ko "messagerie exposée sur le réseau : ${L_ADDR[i]}:${L_PORT[i]} (${L_PROC[i]})"
  done
  ((n)) || ok "aucun service de messagerie en écoute"
}
chk_R75() {
  mta_installed || { na "Aucun service de messagerie installé."; return; }
  grep -qsE '^[[:space:]]*root[[:space:]]*:' /etc/aliases && ok "alias de messagerie pour root" || ko "aucun alias de messagerie pour root (/etc/aliases)"
}
chk_R76() {
  pkg_installed aide && ok "AIDE installé" || { ko "AIDE non installé"; return; }
  [[ -s /var/lib/aide/aide.db || -s /var/lib/aide/aide.db.gz ]] && ok "base de référence AIDE présente" || ko "base de référence AIDE absente (aideinit)"
  if svc_enabled dailyaidecheck.timer || [[ -x /etc/cron.daily/aide ]]; then ok "vérification périodique planifiée"
  else ko "aucune vérification périodique (dailyaidecheck.timer)"; fi
}
chk_R77() { manual "La base AIDE doit être signée ou copiée hors du poste (support externe en lecture seule) : à documenter."; }
chk_R78() {
  load_listen
  local i l=""
  for i in "${!L_PORT[@]}"; do is_loopback "${L_ADDR[i]}" || l+="${L_PROC[i]}:${L_PORT[i]} "; done
  manual "Services réseau exposés : ${l:-aucun}" "Chaque service exposé doit être isolé (conteneur, VM ou machine dédiée)."
}
chk_R79() {
  load_listen
  local i n=0 conf seen=""
  for i in "${!L_PORT[@]}"; do
    is_loopback "${L_ADDR[i]}" && continue
    [[ ${L_PROTO[i]} == udp && ${L_PORT[i]} =~ ^(68|546)$ ]] && continue
    [[ -n ${L_PID[i]} ]] || continue
    [[ $seen == *"|${L_PID[i]}|"* ]] && continue; seen+="|${L_PID[i]}|"
    ((n++))
    conf=$(cat "/proc/${L_PID[i]}/attr/apparmor/current" 2>/dev/null || cat "/proc/${L_PID[i]}/attr/current" 2>/dev/null)
    if [[ -z $conf || $conf == unconfined* ]]; then soft "${L_PROC[i]} (${L_PORT[i]}/${L_PROTO[i]}) non confiné par AppArmor"
    else ok "${L_PROC[i]} confiné (${conf% *})"; fi
  done
  ((n)) || { ((IS_ROOT)) && ok "aucun service exposé" || needroot "identification des processus en écoute"; }
  pkg_installed aide && ok "surveillance d'intégrité (AIDE)" || soft "pas de surveillance d'intégrité (AIDE)"
}
chk_R80() {
  load_listen
  ((${#L_PORT[@]})) || { manual "Liste des ports en écoute indisponible (ss absent ?)"; return; }
  local i seen="" k
  for i in "${!L_PORT[@]}"; do
    k="${L_PROTO[i]} ${L_ADDR[i]}:${L_PORT[i]}"; [[ $seen == *"|$k|"* ]] && continue; seen+="|$k|"
    is_loopback "${L_ADDR[i]}" && continue
    [[ ${L_PROTO[i]} == udp && ${L_PORT[i]} =~ ^(68|546)$ ]] && continue   # client DHCP
    if [[ ${L_PROC[i]} == sshd ]]; then ok "SSH en écoute sur ${L_ADDR[i]}:${L_PORT[i]}"
    else soft "service exposé à justifier : ${L_PROC[i]} sur ${L_ADDR[i]}:${L_PORT[i]}/${L_PROTO[i]}"; fi
  done
  ((P_TOT)) || ok "aucun service réseau exposé"
}

# =============================================================================
#  Exécution
# =============================================================================
# shellcheck disable=SC1091
. /etc/os-release 2>/dev/null
load_sysctl_conf
load_kconfig
load_accounts

LVL_LETTER=(- M I R E)
LVL_NAME=(- Minimal Intermédiaire Renforcé Élevé)
echo
echo "${C_BLD}Vérification ANSSI-BP-028 v2.0 — recommandations R1–R80 — v$SCRIPT_VERSION${C_RST}"
echo "Hôte : $(hostname)   OS : ${PRETTY_NAME:-?}   Noyau : $(uname -r)   Date : $(date '+%F %T')"
if [[ -n $ONLY ]]; then echo "Sélection : ${ONLY//,/ }"
else echo "Niveau : ${LVL_NAME[LNUM]} (inclut les niveaux inférieurs)"; fi
((IS_ROOT)) || echo "${C_YEL}[!] Exécution sans root : plusieurs contrôles seront marqués MANUEL.${C_RST}"
if [[ -n $JFILE ]]; then load_just "$JFILE"; echo "Écarts justifiés / attestations : $JFILE (${#J_ID[@]} entrée(s))"; fi
echo
echo "${C_BLD}$(pad Réco 5)$(pad N 2)$(pad Recommandation 58)$(pad Résultat 16)$(pad Points 8)Script${C_RST}"
printf '%.0s─' {1..100}; echo

[[ -n $CSV ]] && echo "Recommandation;Niveau;Titre;Resultat;Points_conformes;Points_controles;Detail;Justification;Remarque_Ubuntu;Couvert_par;Hote;Date" >"$CSV"
declare -A CNT=() DONE_ID=()
for id in "${IDS[@]}"; do
  if [[ -n $ONLY ]]; then [[ $ONLY == *",$id,"* ]] || continue
  else ((T_LVL[$id] <= LNUM)) || continue; fi
  reset_state
  "chk_$id"
  DONE_ID[$id]=1
  apply_just "$id"
  if ((${#KO_L[@]})); then st="NON CONFORME"; key=KO; col=$C_RED
  elif [[ $FORCE == NA ]]; then st="N/A"; key=NA; col=$C_DIM
  elif [[ $FORCE == MANUEL && -n $ATTEST && ${#WARN_L[@]} -eq 0 ]]; then st="ATTESTÉ"; key=ATT; col=$C_BLU
  elif [[ $FORCE == MANUEL ]]; then st="MANUEL"; key=MAN; col=$C_YEL
  elif ((${#WARN_L[@]})); then st="À VÉRIFIER"; key=WARN; col=$C_YEL
  elif ((${#JUST_L[@]})); then st="ÉCART JUSTIFIÉ"; key=JUST; col=$C_BLU
  elif ((P_TOT == 0)); then st="N/A"; key=NA; col=$C_DIM
  else st="CONFORME"; key=OK; col=$C_GRN; fi
  lv=${T_LVL[$id]}
  CNT[$key]=$((${CNT[$key]:-0} + 1)); CNT[$lv,$key]=$((${CNT[$lv,$key]:-0} + 1))
  pts="-"; ((P_TOT)) && pts="$P_OK/$P_TOT"
  if ! ((QUIET)) || [[ $key == KO || $key == WARN || $key == MAN ]]; then
    echo "$(pad "$id" 5)$(pad "${LVL_LETTER[lv]}" 2)$(pad "${T_TITLE[$id]}" 58)${col}$(pad "$st" 16)${C_RST}$(pad "$pts" 8)${C_DIM}${T_COVER[$id]}${C_RST}"
    if [[ $key != OK ]] || ((VERBOSE)); then
      n=0
      for x in "${KO_L[@]}";   do ((n++ < MAXD)) && echo "     ${C_RED}✘ $x${C_RST}"; done
      for x in "${WARN_L[@]}"; do ((n++ < MAXD)) && echo "     ${C_YEL}⚠ $x${C_RST}"; done
      for x in "${INC_L[@]}";  do echo "     ${C_YEL}✎ $x${C_RST}"; done
      for x in "${JUST_L[@]}"; do echo "     ${C_BLU}≈ $x${C_RST}"; done
      [[ $key == ATT ]] && echo "     ${C_BLU}✎ Attesté : $ATTEST${C_RST}"
      for x in "${INFO_L[@]}"; do
        [[ $x == ✔* ]] && ! ((VERBOSE)) && continue
        ((n++ < MAXD)) && echo "     ${C_DIM}$x${C_RST}"
      done
      ((n > MAXD)) && echo "     ${C_DIM}… $((n - MAXD)) autre(s) élément(s) — relancer avec -v -r $id${C_RST}"
      [[ -n ${T_NOTE[$id]} && $key != OK && $key != NA && $key != JUST && $key != ATT ]] && echo "     ${C_DIM}Remarque : ${T_NOTE[$id]}${C_RST}"
    fi
  fi
  if [[ -n $CSV ]]; then
    csv_info=()
    for x in "${INFO_L[@]}"; do [[ $x == ✔* ]] && ! ((VERBOSE)) && continue; csv_info+=("$x"); done
    det=$(join ' | ' "${KO_L[@]/#/KO: }" "${WARN_L[@]/#/A verifier: }" "${csv_info[@]}")
    jus=$(join ' | ' "${JUST_L[@]}" ${ATTEST:+"Attesté : $ATTEST"})
    printf '%s;%s;"%s";%s;%s;%s;"%s";"%s";"%s";%s;%s;%s\n' "$id" "${LVL_NAME[lv]}" "${T_TITLE[$id]//\"/\"\"}" "$st" "$P_OK" "$P_TOT" \
      "${det//\"/\"\"}" "${jus//\"/\"\"}" "${T_NOTE[$id]//\"/\"\"}" "${T_COVER[$id]}" "$(hostname)" "$(date '+%F %T')" >>"$CSV"
  fi
done

printf '%.0s─' {1..100}; echo
echo "${C_GRN}Conformes : ${CNT[OK]:-0}${C_RST}   ${C_BLU}Écarts justifiés : ${CNT[JUST]:-0}   Attestées : ${CNT[ATT]:-0}${C_RST}   N/A : ${CNT[NA]:-0}"
echo "${C_RED}Non conformes : ${CNT[KO]:-0}${C_RST}   ${C_YEL}À vérifier : ${CNT[WARN]:-0}   Manuelles non attestées : ${CNT[MAN]:-0}${C_RST}"
echo
echo "${C_BLD}$(pad Niveau 15)$(pad Conf. 7)$(pad "Écart j." 10)$(pad Attest. 9)$(pad N/A 5)$(pad "Non c." 8)$(pad "À vér." 8)$(pad Man. 6)Reste${C_RST}"
for lv in 1 2 3 4; do
  t=0; for k in OK JUST ATT NA KO WARN MAN; do t=$((t + ${CNT[$lv,$k]:-0})); done
  ((t)) || continue
  r=$(( ${CNT[$lv,KO]:-0} + ${CNT[$lv,WARN]:-0} + ${CNT[$lv,MAN]:-0} ))
  echo "$(pad "${LVL_NAME[lv]}" 15)$(pad "${CNT[$lv,OK]:-0}" 7)$(pad "${CNT[$lv,JUST]:-0}" 10)$(pad "${CNT[$lv,ATT]:-0}" 9)$(pad "${CNT[$lv,NA]:-0}" 5)$(pad "${CNT[$lv,KO]:-0}" 8)$(pad "${CNT[$lv,WARN]:-0}" 8)$(pad "${CNT[$lv,MAN]:-0}" 6)$r"
done
rest=$(( ${CNT[KO]:-0} + ${CNT[WARN]:-0} + ${CNT[MAN]:-0} ))
echo
if ((rest == 0)); then
  echo "${C_GRN}${C_BLD}✔ Toutes les recommandations vérifiées sont conformes, justifiées, attestées ou sans objet.${C_RST}"
else
  echo "${C_RED}${C_BLD}✘ $rest recommandation(s) restent à traiter (corriger, justifier ou attester avec -j).${C_RST}"
fi
# Justifications qui ne correspondent plus à rien (point devenu conforme, motif erroné)
for i in "${!J_ID[@]}"; do
  [[ -n ${DONE_ID[${J_ID[i]}]:-} && ${J_USED[i]} == 0 ]] && echo "${C_DIM}  Justification sans objet : ${J_ID[i]} | ${J_PAT[i]} (point conforme ou motif introuvable)${C_RST}"
done
[[ -n $CSV ]] && echo "Rapport CSV : $CSV"
((rest == 0))

#!/usr/bin/env bash
# =============================================================================
#  anssi-harden.sh — Durcissement interactif ANSSI-BP-028 (Minimal / Intermédiaire)
# -----------------------------------------------------------------------------
#  Usage : sudo ./anssi-harden.sh [-l minimal|intermediaire|renforce] [-a] [-n] [-m ID,ID…]
#    -l  niveau (sinon menu)
#    -a  automatique : applique les mesures non conformes avec les réponses par
#        défaut, SAUF les mesures sensibles (USB, GRUB) qui restent manuelles
#    -n  simulation : affiche ce qui serait fait, ne modifie rien
#    -m  liste d'IDs à traiter (ex. -m M05,M06,I02)
#  Sauvegardes : /var/backups/anssi-hardening/<date>/   Journal : /var/log/anssi-hardening.log
# =============================================================================
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=anssi-lib.sh
source "$SCRIPT_DIR/anssi-lib.sh"

LEVEL="" ONLY="" MODE=""
usage() { sed -n '3,11p' "$0" | sed 's/^#  \{0,1\}//'; exit "${1:-0}"; }

while (($#)); do
  case $1 in
    -l|--level) LEVEL=$2; shift 2 ;;
    -a|--auto)  AUTO=1; MODE=auto; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -m|--measures) ONLY=",${2^^},"; MODE=select; shift 2 ;;
    -h|--help)  usage 0 ;;
    *) err "Option inconnue : $1"; usage 1 ;;
  esac
done

# --- Pré-requis --------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  if ((DRY_RUN)); then warn "Simulation sans root : contrôles partiels."
  else err "Ce script doit être exécuté en root (sudo)."; exit 1; fi
fi
# shellcheck disable=SC1091
. /etc/os-release
if [[ $ID != ubuntu ]]; then
  warn "Système détecté : $PRETTY_NAME (script prévu pour Ubuntu)."
  confirm "Continuer quand même ?" n || exit 1
fi

echo
echo "${C_BLD}Durcissement ANSSI-BP-028 — $(hostname) — $PRETTY_NAME${C_RST}"
((DRY_RUN)) && echo "${C_YEL}MODE SIMULATION : aucune modification ne sera effectuée.${C_RST}"

# --- Choix du niveau ---------------------------------------------------------
if [[ -z $LEVEL ]]; then
  echo
  echo "Niveau de durcissement :"
  echo "  1) Minimal"
  echo "  2) Intermédiaire (inclut Minimal)"
  echo "  3) Renforcé (inclut Intermédiaire) : mesures simples + points à étudier"
  read -r -p "Choix [2] : " c <"$TTY"
  case $c in 1) LEVEL=minimal ;; 3) LEVEL=renforce ;; *) LEVEL=intermediaire ;; esac
fi
[[ $LEVEL == minimal || $LEVEL == intermediaire || $LEVEL == renforce ]] || { err "Niveau invalide : $LEVEL"; exit 1; }

# --- État initial ------------------------------------------------------------
declare -a TODO=()
echo
info "Contrôle de l'état initial (niveau ${LEVEL^^})…"
for id in "${MEASURES[@]}"; do
  level_includes "$LEVEL" "${M_LEVEL[$id]}" || continue
  DETAIL=""; "check_$id"; rc=$?
  if ((rc == OK || rc == NA)); then
    printf "  ${C_GRN}%-4s ✔${C_RST} %s\n" "$id" "${M_DESC[$id]}"
  else
    printf "  ${C_RED}%-4s ✘${C_RST} %s ${C_DIM}(%s)${C_RST}\n" "$id" "${M_DESC[$id]}" "$DETAIL"
    TODO+=("$id")
  fi
done
((${#TODO[@]})) || { echo; info "Toutes les mesures du niveau sont conformes."; exit 0; }

# --- Choix du mode -----------------------------------------------------------
if [[ -z $MODE ]]; then
  echo
  echo "Mode de traitement des ${#TODO[@]} mesure(s) non conforme(s) :"
  echo "  1) Interactif : confirmation mesure par mesure"
  echo "  2) Automatique : tout appliquer (sauf mesures sensibles)"
  echo "  3) Sélection : saisir une liste d'IDs"
  read -r -p "Choix [1] : " c <"$TTY"
  case $c in
    2) MODE=auto; AUTO=1 ;;
    3) MODE=select; read -r -p "IDs (ex. M05,M06,I02) : " ONLY <"$TTY"; ONLY=",${ONLY^^},"; ONLY=${ONLY// /} ;;
    *) MODE=interactive ;;
  esac
fi
log "DEBUT niveau=$LEVEL mode=$MODE simulation=$DRY_RUN"

# --- Traitement --------------------------------------------------------------
declare -a DONE=() SKIPPED=() MANUAL=() FAILED=() RISKY=()
for id in "${TODO[@]}"; do
  [[ $MODE == select && $ONLY != *",$id,"* ]] && continue
  DETAIL=""; "check_$id" >/dev/null
  echo
  echo "${C_BLD}[$id] ${M_DESC[$id]}${C_RST}  ${C_DIM}(${M_THEME[$id]}, niveau ${M_LEVEL[$id]})${C_RST}"
  echo "    État actuel : $DETAIL"

  if ! declare -F "apply_$id" >/dev/null; then
    echo "    ${C_YEL}→ Mesure manuelle (contrôle seul) : à traiter et documenter.${C_RST}"
    MANUAL+=("$id"); continue
  fi
  if ((AUTO)) && ((M_RISKY[$id])); then
    echo "    ${C_YEL}→ Mesure sensible ignorée en mode automatique (relancer avec -m $id).${C_RST}"
    RISKY+=("$id"); continue
  fi
  if ((AUTO == 0)); then
    read -r -p "    Appliquer ? [o]ui / [n]on / [q]uitter : " c <"$TTY"
    case ${c,,} in
      q*) break ;;
      o*|y*) ;;
      *) SKIPPED+=("$id"); continue ;;
    esac
  fi

  # Les mesures sensibles posent toujours leurs questions, même avec -m
  prev_auto=$AUTO; ((M_RISKY[$id])) && AUTO=0
  "apply_$id"; rc=$?
  AUTO=$prev_auto

  if ((rc != 0)); then
    err "Échec de $id (code $rc)."; FAILED+=("$id"); log "ECHEC $id"; continue
  fi
  if ((DRY_RUN)); then
    DONE+=("$id")
  else
    DETAIL=""; "check_$id"; after=$?
    if ((after == OK)); then
      echo "    ${C_GRN}✔ Conforme après application.${C_RST}"; DONE+=("$id"); log "APPLIQUE $id"
    else
      if ((after == WARN)); then
        echo "    ${C_YEL}⚠ Appliqué, à vérifier : $DETAIL${C_RST}"; DONE+=("$id"); log "APPLIQUE(A_VERIFIER) $id"
      else
        echo "    ${C_YEL}⚠ Toujours non conforme : $DETAIL${C_RST}"; SKIPPED+=("$id"); log "PARTIEL $id"
      fi
    fi
  fi
done

# --- Bilan -------------------------------------------------------------------
echo
printf '%.0s═' {1..80}; echo
echo "${C_BLD}Bilan — niveau ${LEVEL^^}${C_RST}"
if ((DRY_RUN)); then lbl="Simulées (rien n'est modifié)"; else lbl="Appliquées"; fi
printf '  %s%-25s%s : %s\n' "$C_GRN" "$lbl" "$C_RST" "$(summarize "${DONE[@]}")"
echo "  ${C_YEL}Refusées / partielles${C_RST}    : $(summarize "${SKIPPED[@]}")"
echo "  ${C_YEL}Manuelles (contrôle seul)${C_RST} : $(summarize "${MANUAL[@]}")"
echo "  ${C_YEL}Sensibles non traitées${C_RST}   : $(summarize "${RISKY[@]}")"
echo "  ${C_RED}En échec${C_RST}                 : $(summarize "${FAILED[@]}")"
if ((DRY_RUN == 0)); then
  [[ -d $BACKUP_DIR ]] && echo "  Sauvegardes : $BACKUP_DIR"
  echo "  Journal     : $LOG_FILE"
fi
((REBOOT_NEEDED)) && warn "Redémarrage nécessaire pour appliquer toutes les modifications."
echo "  Vérification : sudo $SCRIPT_DIR/anssi-audit.sh -l $LEVEL -o audit-\$(hostname).csv"
log "FIN appliquees=${DONE[*]} refusees=${SKIPPED[*]} echecs=${FAILED[*]}"

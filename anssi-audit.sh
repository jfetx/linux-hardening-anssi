#!/usr/bin/env bash
# =============================================================================
#  anssi-audit.sh — Audit de conformité ANSSI-BP-028 (lecture seule)
# -----------------------------------------------------------------------------
#  Usage : sudo ./anssi-audit.sh [-l minimal|intermediaire|renforce] [-o rapport.csv]
#    -l  niveau à auditer (défaut : intermediaire, qui inclut minimal)
#    -o  export CSV (séparateur « ; ») pour la documentation de livraison
#  Code retour : 0 si aucune non-conformité, 1 sinon.
# =============================================================================
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=anssi-lib.sh
source "$SCRIPT_DIR/anssi-lib.sh"

LEVEL=intermediaire
CSV=""

usage() { sed -n '3,9p' "$0" | sed 's/^#  \{0,1\}//'; exit "${1:-0}"; }

while (($#)); do
  case $1 in
    -l|--level) LEVEL=$2; shift 2 ;;
    -o|--csv)   CSV=$2;   shift 2 ;;
    -h|--help)  usage 0 ;;
    *) err "Option inconnue : $1"; usage 1 ;;
  esac
done
[[ $LEVEL == minimal || $LEVEL == intermediaire || $LEVEL == renforce ]] || { err "Niveau invalide : $LEVEL"; exit 1; }
DRY_RUN=1   # l'audit ne modifie rien (et n'écrit pas dans le journal)

[[ $EUID -eq 0 ]] || warn "Exécution sans root : plusieurs contrôles seront incomplets."

# shellcheck disable=SC1091
. /etc/os-release
echo
echo "${C_BLD}Audit ANSSI-BP-028 — niveau ${LEVEL^^}${C_RST}"
echo "Hôte : $(hostname)   OS : $PRETTY_NAME   Noyau : $(uname -r)   Date : $(date '+%F %T')"
echo
echo "${C_BLD}$(pad ID 4) $(pad Niv 3) $(pad Thème 22) $(pad Résultat 13) Mesure${C_RST}"
printf '%.0s─' {1..110}; echo

declare -A COUNT=([OK]=0 [KO]=0 [WARN]=0 [NA]=0)
[[ -n $CSV ]] && echo "ID;Niveau;Theme;Resultat;Mesure;Detail;Hote;Date" > "$CSV"

for id in "${MEASURES[@]}"; do
  level_includes "$LEVEL" "${M_LEVEL[$id]}" || continue
  DETAIL=""
  "check_$id"; rc=$?
  case $rc in
    0) st=CONFORME;       key=OK;   col=$C_GRN ;;
    1) st="NON CONFORME"; key=KO;   col=$C_RED ;;
    2) st="À VÉRIFIER";   key=WARN; col=$C_YEL ;;
    *) st="N/A";          key=NA;   col=$C_DIM ;;
  esac
  COUNT[$key]=$((COUNT[$key]+1))
  echo "$(pad "$id" 4) $(pad "${M_LEVEL[$id]}" 3) $(pad "${M_THEME[$id]}" 22) ${col}$(pad "$st" 13)${C_RST} ${M_DESC[$id]}"
  [[ $rc -ne 0 && -n $DETAIL ]] && printf "${C_DIM}%45s↳ %s${C_RST}\n" "" "$DETAIL"
  if [[ -n $CSV ]]; then
    printf '%s;%s;"%s";%s;"%s";"%s";%s;%s\n' "$id" "${M_LEVEL[$id]}" "${M_THEME[$id]//\"/\"\"}" "$st" \
      "${M_DESC[$id]//\"/\"\"}" "${DETAIL//\"/\"\"}" "$(hostname)" "$(date '+%F %T')" >> "$CSV"
  fi
done

printf '%.0s─' {1..110}; echo
total=$((COUNT[OK]+COUNT[KO]))
score=0; ((total>0)) && score=$((100*COUNT[OK]/total))
echo "${C_GRN}Conformes : ${COUNT[OK]}${C_RST}   ${C_RED}Non conformes : ${COUNT[KO]}${C_RST}   ${C_YEL}À vérifier : ${COUNT[WARN]}${C_RST}   N/A : ${COUNT[NA]}"
echo "${C_BLD}Taux de conformité (hors « à vérifier » et N/A) : $score %${C_RST}"
[[ -n $CSV ]] && info "Rapport CSV : $CSV"
echo "Pour corriger : sudo $SCRIPT_DIR/anssi-harden.sh -l $LEVEL"
((COUNT[KO]==0))

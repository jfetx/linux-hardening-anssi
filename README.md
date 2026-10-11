# linux-hardening-anssi

Audit et durcissement d'Ubuntu (22.04 / 24.04 LTS) selon le guide **ANSSI-BP-028 v2.0**
« Recommandations de configuration d'un système GNU/Linux » — niveaux **Minimal** et **Intermédiaire**.

| Fichier | Rôle |
|---|---|
| `anssi-lib.sh` | Définition des mesures (contrôle + correction) — partagée par les deux scripts |
| `anssi-audit.sh` | Audit en lecture seule, tableau de conformité, export CSV |
| `anssi-harden.sh` | Durcissement interactif, automatique ou par sélection d'IDs |

28 mesures : M01–M13 (Minimal), I01–I15 (Intermédiaire).

## Utilisation

```bash
git clone --depth 1 --branch v1.3 https://github.com/<utilisateur>/linux-hardening-anssi.git
cd linux-hardening-anssi

sudo bash anssi-audit.sh -l minimal -o audit-$(hostname).csv   # état initial
sudo bash anssi-harden.sh -n                                   # simulation
sudo bash anssi-harden.sh                                      # menu : niveau + mode
sudo bash anssi-harden.sh -l intermediaire -a                  # automatique (hors mesures sensibles)
sudo bash anssi-harden.sh -m I12                               # une mesure précise
```

- Sauvegardes des fichiers modifiés : `/var/backups/anssi-hardening/<date>/`
- Journal : `/var/log/anssi-hardening.log`
- Mesures sensibles (stockage USB, mot de passe GRUB) : jamais appliquées en mode automatique.

## Avertissement

Toujours tester d'abord sur une VM ou un poste non critique (`-n` pour simuler).
Le partitionnement séparé (/var, /var/log, /var/log/audit, /home, /tmp) doit être prévu à l'installation.
La correspondance avec les numéros Rxx du guide ANSSI est à compléter dans la documentation de livraison.

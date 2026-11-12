#!/bin/bash
# =====================================================================
#  MariaDB Upgrade Restore per aaPanel  v1.1
#  (c) 2026 BACKdigit - https://backdigit.com
#  Licenza MIT: libero uso, modifica e ridistribuzione citando BACKdigit.
#
#  Provato su: aaPanel 8.0.7, MariaDB 10.7.3 -> 11.4.4
#
#  Da usare DOPO aver installato la nuova versione di MariaDB,
#  con un backup creato da mariadb-backup-1.1.sh (o 1.0).
#  Ordine: verifica backup -> utenti -> dati -> elenco aaPanel.
#  Non cancella database esistenti: se ne trova uno, si ferma.
#
#  Uso:  bash mariadb-restore-1.1.sh                 (usa l'ultimo backup)
#        bash mariadb-restore-1.1.sh /percorso/backup-AAAAMMGG-HHMM
#  Fai sempre uno snapshot prima. Lo usi a tuo rischio.
# =====================================================================
set -u
set -o pipefail

VERSION="1.1"
BASE=/root/mariadb-upgrade
PANEL_DB=/www/server/panel/data/default.db
BIN_DIR=/www/server/mysql/bin

ERR=0
fail() { echo "  ERRORE: $*"; ERR=$((ERR+1)); }

echo "MariaDB Upgrade Restore per aaPanel v$VERSION - BACKdigit"
echo

# --- Prerequisiti ---
if [ "$(id -u)" -ne 0 ]; then echo "Va eseguito come root."; exit 1; fi

pick_bin() {
  for b in "$BIN_DIR/$1" "$BIN_DIR/$2"; do [ -x "$b" ] && { echo "$b"; return; }; done
  command -v "$1" 2>/dev/null || command -v "$2" 2>/dev/null
}
MYSQL_BIN=$(pick_bin mariadb mysql)
[ -z "$MYSQL_BIN" ] && { echo "Client mariadb/mysql non trovato. MariaDB e' installata?"; exit 1; }

HAS_SQLITE=1
command -v sqlite3 >/dev/null 2>&1 || HAS_SQLITE=0

detect_socket() {
  local s c
  s=$(grep -hE '^[[:space:]]*socket[[:space:]]*=' /etc/my.cnf /root/.my.cnf 2>/dev/null \
      | head -1 | cut -d= -f2- | tr -d ' "')
  for c in "$s" /tmp/mysql.sock /run/mysqld/mysqld.sock /var/run/mysqld/mysqld.sock /var/lib/mysql/mysql.sock; do
    [ -n "$c" ] && [ -S "$c" ] && { echo "$c"; return; }
  done
}
SOCKET=$(detect_socket)

# --- Cartella di backup ---
if [ $# -ge 1 ]; then
  SRC="${1%/}"
else
  SRC=$(ls -d "$BASE"/backup-*/ 2>/dev/null | sort | tail -1)
  SRC="${SRC%/}"
fi
if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
  echo "Cartella di backup non trovata. Indicala come argomento."
  exit 1
fi
cd "$SRC" || exit 1
echo "Backup usato: $SRC"

# --- Verifica integrita' dei file ---
echo "== Verifica file di backup"
if [ -f SHA256SUMS ]; then
  if sha256sum -c --quiet SHA256SUMS; then
    echo "  checksum OK"
  else
    echo "  Checksum non corrispondenti: i file sono stati alterati. Mi fermo."
    exit 1
  fi
else
  echo "  AVVISO: SHA256SUMS mancante, verifico solo la compressione"
fi
DUMPS=$(ls ./*.sql.gz 2>/dev/null)
[ -z "$DUMPS" ] && { echo "Nessun dump trovato. Mi fermo."; exit 1; }
for F in $DUMPS; do
  gzip -t "$F" 2>/dev/null || { echo "  $F corrotto. Mi fermo."; exit 1; }
done
[ -f utenti.sql ] || { echo "utenti.sql mancante. Mi fermo."; exit 1; }

# --- Password root della NUOVA installazione ---
read -rsp "Password root della nuova MariaDB: " PW; echo
PW=${PW//\\/\\\\}; PW=${PW//\"/\\\"}
CNF=$(mktemp); chmod 600 "$CNF"
trap 'rm -f "$CNF"' EXIT
{
  echo "[client]"
  echo "user=root"
  echo "password=\"$PW\""
  [ -n "$SOCKET" ] && echo "socket=$SOCKET"
} > "$CNF"
unset PW
M="$MYSQL_BIN --defaults-extra-file=$CNF"

if ! $M -e "SELECT 1" >/dev/null 2>&1; then
  echo "Password errata o MariaDB non raggiungibile."
  exit 1
fi

# --- Controlli preliminari ---
NEWVER=$($M -N -B -e "SELECT VERSION();")
OLDVER=$(tail -1 versione.txt 2>/dev/null)
DBNAMES=""
for F in $DUMPS; do DBNAMES="$DBNAMES $(basename "$F" .sql.gz)"; done

echo
echo "  Versione nel backup:   ${OLDVER:-sconosciuta}"
echo "  Versione installata:   $NEWVER"
echo "  Database da ripristinare:$DBNAMES"

EXIST=""
for DB in $DBNAMES; do
  N=$($M -N -B -e "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='$DB';")
  [ "$N" != "0" ] && EXIST="$EXIST $DB"
done
if [ -n "$EXIST" ]; then
  echo
  echo "  Questi database esistono gia':$EXIST"
  echo "  Per non sovrascrivere nulla mi fermo. Verifica prima la situazione."
  exit 1
fi

echo
read -rp "Procedo con il ripristino? Scrivi SI: " OK
[ "$OK" = "SI" ] || { echo "Annullato."; exit 0; }

# --- 1. Utenti e permessi (prima dei dati, per i DEFINER) ---
echo "== Utenti e permessi"
if sed 's/^CREATE USER /CREATE USER IF NOT EXISTS /' utenti.sql | $M; then
  echo "  utenti ripristinati: $(grep -c '^CREATE USER' utenti.sql)"
else
  fail "ripristino utenti non riuscito: mi fermo prima dei dati"
  exit 1
fi

# --- 2. Dati ---
echo "== Dati"
for F in $DUMPS; do
  DB=$(basename "$F" .sql.gz)
  printf "  %-25s " "$DB"
  if zcat "$F" | $M 2>"restore-$DB.err"; then
    ATTESE=$(zcat "$F" | grep -c '^CREATE TABLE')
    TROVATE=$($M -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB';")
    if [ "$ATTESE" = "$TROVATE" ]; then
      echo "OK ($TROVATE tabelle)"
      rm -f "restore-$DB.err"
    else
      echo; fail "$DB: tabelle attese $ATTESE, trovate $TROVATE"
    fi
  else
    echo; fail "$DB: import fallito, dettagli in restore-$DB.err"
  fi
done

# --- 3. Elenco aaPanel ---
if [ -f "$PANEL_DB" ]; then
  echo "== Elenco aaPanel"
  if [ "$HAS_SQLITE" -eq 0 ]; then
    echo "  sqlite3 non installato: usa 'Get DB from server' in aaPanel e reimposta le password"
  elif [ ! -f pannello-databases.sql ]; then
    echo "  file dell'elenco aaPanel non trovato: usa 'Get DB from server' in aaPanel"
  else
    cp "$PANEL_DB" "$SRC/default.db.prima-del-restore"
    PRIMA=$(sqlite3 "$PANEL_DB" "SELECT COUNT(*) FROM databases;")
    {
      echo "CREATE TEMP TABLE tmp_dbs AS SELECT * FROM databases WHERE 0;"
      sed 's/^INSERT INTO databases(/INSERT INTO tmp_dbs(/' pannello-databases.sql
      echo "INSERT INTO databases SELECT * FROM tmp_dbs
            WHERE name NOT IN (SELECT name FROM databases)
              AND id   NOT IN (SELECT id   FROM databases);"
    } | sqlite3 "$PANEL_DB" || fail "reimport elenco aaPanel non riuscito"
    DOPO=$(sqlite3 "$PANEL_DB" "SELECT COUNT(*) FROM databases;")
    echo "  righe aggiunte: $((DOPO - PRIMA)) (quelle gia' presenti sono state lasciate com'erano)"
    for DB in $DBNAMES; do
      N=$(sqlite3 "$PANEL_DB" "SELECT COUNT(*) FROM databases WHERE name='$DB';")
      [ "$N" = "0" ] && echo "  AVVISO: $DB non e' nell'elenco aaPanel: usa 'Get DB from server' e reimposta la password"
    done
  fi
fi

# --- Riepilogo ---
echo
echo "==================================================="
echo " MariaDB:  $NEWVER"
if [ "$ERR" -eq 0 ]; then
  echo " ESITO:    TUTTO OK"
else
  echo " ESITO:    $ERR ERRORI - controlla i file restore-*.err in $SRC"
fi
echo "==================================================="
echo " Ora, a mano:"
echo "  1. Ricarica aaPanel -> Databases e controlla elenco e password"
echo "  2. Svuota la cache degli oggetti (Redis) e, se serve, quella delle pagine"
echo "  3. Prova sito, wp-admin, plugin con database esterni e posta"
echo "  4. In MariaDB -> Optimization controlla innodb_buffer_pool_size"
echo "     (almeno pari alla dimensione dei database)"

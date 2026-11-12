#!/bin/bash
# =====================================================================
#  MariaDB Upgrade Backup per aaPanel  v1.1
#  (c) 2026 BACKdigit - https://backdigit.com
#  Licenza MIT: libero uso, modifica e ridistribuzione citando BACKdigit.
#
#  Provato su: aaPanel 8.0.7, MariaDB 10.7.3 -> 11.4.4
#
#  Solo lettura: non ferma servizi, non cancella e non modifica nulla.
#  Salva: dump di ogni database, utenti+permessi (con hash password),
#  righe dei database nell'elenco di aaPanel, copia di default.db,
#  /etc/my.cnf, inventario. Alla fine crea un archivio .tar.gz.
#
#  Uso:  bash mariadb-backup-1.1.sh
#  Da abbinare a mariadb-restore-1.1.sh. Fai sempre uno snapshot prima.
#  Lo usi a tuo rischio.
# =====================================================================
set -u
set -o pipefail

VERSION="1.1"
BASE=/root/mariadb-upgrade
TS=$(date +%Y%m%d-%H%M)
OUT="$BASE/backup-$TS"
PANEL_DB=/www/server/panel/data/default.db
BIN_DIR=/www/server/mysql/bin
SYS_DBS="'mysql','information_schema','performance_schema','sys'"
SYS_USERS="'root','mariadb.sys','mysql','','PUBLIC'"

ERR=0
fail() { echo "  ERRORE: $*"; ERR=$((ERR+1)); }

echo "MariaDB Upgrade Backup per aaPanel v$VERSION - BACKdigit"
echo

# --- Prerequisiti ---
if [ "$(id -u)" -ne 0 ]; then echo "Va eseguito come root."; exit 1; fi

pick_bin() {  # pick_bin nome_nuovo nome_vecchio
  for b in "$BIN_DIR/$1" "$BIN_DIR/$2"; do [ -x "$b" ] && { echo "$b"; return; }; done
  command -v "$1" 2>/dev/null || command -v "$2" 2>/dev/null
}
MYSQL_BIN=$(pick_bin mariadb mysql)
DUMP_BIN=$(pick_bin mariadb-dump mysqldump)
[ -z "$MYSQL_BIN" ] && { echo "Client mariadb/mysql non trovato."; exit 1; }
[ -z "$DUMP_BIN" ]  && { echo "mariadb-dump/mysqldump non trovato."; exit 1; }

HAS_PANEL=0
if [ -f "$PANEL_DB" ]; then
  HAS_PANEL=1
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "sqlite3 non installato. Installalo e rilancia:"
    echo "  Debian/Ubuntu:       apt install sqlite3"
    echo "  CentOS/AlmaLinux:    yum install sqlite"
    exit 1
  fi
else
  echo "AVVISO: aaPanel non trovato, salto l'export dell'elenco del pannello."
fi

detect_socket() {
  local s c
  s=$(grep -hE '^[[:space:]]*socket[[:space:]]*=' /etc/my.cnf /root/.my.cnf 2>/dev/null \
      | head -1 | cut -d= -f2- | tr -d ' "')
  for c in "$s" /tmp/mysql.sock /run/mysqld/mysqld.sock /var/run/mysqld/mysqld.sock /var/lib/mysql/mysql.sock; do
    [ -n "$c" ] && [ -S "$c" ] && { echo "$c"; return; }
  done
}
SOCKET=$(detect_socket)

mkdir -p "$OUT" && chmod 700 "$BASE" "$OUT"
cd "$OUT" || exit 1

# --- Password root una sola volta, in un file temporaneo protetto ---
read -rsp "Password root MariaDB: " PW; echo
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
D="$DUMP_BIN --defaults-extra-file=$CNF"

if ! $M -e "SELECT 1" >/dev/null 2>&1; then
  echo "Password errata o MariaDB non raggiungibile. Nessun backup eseguito."
  cd / && rmdir "$OUT" 2>/dev/null
  exit 1
fi

# --- 1. Inventario ---
echo "== Inventario"
$M -e "SELECT VERSION() AS versione;" > versione.txt
$M -e "SELECT table_schema db, ROUND(SUM(data_length+index_length)/1024/1024,1) MB
       FROM information_schema.tables WHERE table_schema NOT IN ($SYS_DBS)
       GROUP BY table_schema ORDER BY MB DESC;" > db-dimensioni.txt
$M -e "SELECT table_schema db, engine, COUNT(*) tabelle FROM information_schema.tables
       WHERE table_schema NOT IN ($SYS_DBS) AND table_type='BASE TABLE'
       GROUP BY table_schema, engine;" > motori.txt
$M -e "SELECT schema_name db, default_character_set_name charset, default_collation_name collation
       FROM information_schema.schemata WHERE schema_name NOT IN ($SYS_DBS);" > charset.txt
$M -e "SELECT 'view' tipo, table_schema db, table_name nome, definer FROM information_schema.views WHERE table_schema NOT IN ($SYS_DBS)
       UNION ALL SELECT 'trigger', trigger_schema, trigger_name, definer FROM information_schema.triggers WHERE trigger_schema NOT IN ($SYS_DBS)
       UNION ALL SELECT 'routine', routine_schema, routine_name, definer FROM information_schema.routines WHERE routine_schema NOT IN ($SYS_DBS)
       UNION ALL SELECT 'event', event_schema, event_name, definer FROM information_schema.events WHERE event_schema NOT IN ($SYS_DBS);" > oggetti-definer.txt
cp /etc/my.cnf my.cnf.originale 2>/dev/null || echo "  AVVISO: /etc/my.cnf non trovato, configurazione non salvata"
echo "  versione: $($M -N -B -e 'SELECT VERSION();')"
echo "  socket:   ${SOCKET:-predefinito del client}"

# --- 2. Dump di ogni database ---
echo "== Dump database"
DBS=$($M -N -B -e "SELECT schema_name FROM information_schema.schemata
                   WHERE schema_name NOT IN ($SYS_DBS) ORDER BY schema_name;")
if [ -z "$DBS" ]; then echo "Nessun database trovato."; exit 1; fi

for DB in $DBS; do
  printf "  %-25s " "$DB"
  if $D --single-transaction --routines --triggers --events --hex-blob \
        --default-character-set=utf8mb4 --databases "$DB" 2>"dump-$DB.err" | gzip > "$DB.sql.gz"; then
    if gzip -t "$DB.sql.gz" 2>/dev/null && zcat "$DB.sql.gz" | tail -1 | grep -q "Dump completed"; then
      echo "OK ($(du -h "$DB.sql.gz" | cut -f1))"
      rm -f "dump-$DB.err"
    else
      echo; fail "$DB: file incompleto o corrotto"
    fi
  else
    echo; fail "$DB: dump fallito, dettagli in dump-$DB.err"
  fi
done

# --- 3. Utenti e permessi (password come hash) ---
echo "== Utenti e permessi"
: > utenti.sql
while IFS=$'\t' read -r U H; do
  [ -z "$U" ] && continue
  if ! $M -N -B -r -e "SHOW CREATE USER '$U'@'$H'; SHOW GRANTS FOR '$U'@'$H';" | sed 's/$/;/' >> utenti.sql; then
    fail "utente $U@$H non esportato"
  fi
done < <($M -N -B -e "SELECT user, host FROM mysql.user
                      WHERE user NOT IN ($SYS_USERS) AND is_role='N' ORDER BY user, host;")
N_USERS=$(grep -c '^CREATE USER' utenti.sql)
echo "  utenti esportati: $N_USERS"

# --- 4. Elenco database di aaPanel (nomi, utenti, password, note) ---
N_PANEL=0
if [ "$HAS_PANEL" -eq 1 ]; then
  echo "== Elenco aaPanel"
  cp "$PANEL_DB" pannello-default.db || fail "copia di default.db non riuscita"
  if sqlite3 -cmd ".headers on" -cmd ".mode insert databases" "$PANEL_DB" \
       "SELECT * FROM databases WHERE type='MySQL';" > pannello-databases.sql; then
    N_PANEL=$(grep -c '^INSERT' pannello-databases.sql)
    echo "  righe esportate: $N_PANEL"
  else
    fail "export elenco aaPanel non riuscito"
  fi
fi

# --- 5. Controlli ---
echo "== Controlli"
if grep -qiE 'MyISAM|Aria' motori.txt; then
  echo "  AVVISO: ci sono tabelle non InnoDB (vedi motori.txt). Per loro il dump"
  echo "  e' coerente solo se nessuno scrive: ferma prima i servizi che le usano."
fi
if [ "$(wc -l < oggetti-definer.txt)" -gt 1 ]; then
  echo "  AVVISO: ci sono viste/trigger/routine/eventi con DEFINER (vedi oggetti-definer.txt)."
  echo "  Al ripristino gli utenti vanno ricreati PRIMA dei dati (lo script di restore lo fa)."
fi

ls pannello-databases.sql >/dev/null 2>&1 && EXTRA=pannello-databases.sql || EXTRA=""
sha256sum ./*.sql.gz utenti.sql $EXTRA > SHA256SUMS 2>/dev/null

# --- 6. Archivio unico da scaricare ---
ARCH="$BASE/backup-$TS.tar.gz"
tar -czf "$ARCH" -C "$BASE" "backup-$TS" && chmod 600 "$ARCH" || fail "creazione archivio non riuscita"

# --- Riepilogo ---
echo
echo "==================================================="
echo " Database:        $(echo "$DBS" | wc -w)  ($(echo $DBS))"
echo " Utenti:          $N_USERS"
echo " Righe aaPanel:   $N_PANEL"
echo " Cartella:        $OUT"
echo " Archivio:        $ARCH ($(du -h "$ARCH" 2>/dev/null | cut -f1))"
if [ "$ERR" -eq 0 ]; then
  echo " ESITO:           TUTTO OK"
else
  echo " ESITO:           $ERR ERRORI - non procedere con la disinstallazione"
fi
echo "==================================================="
echo " L'archivio contiene le password dei database in chiaro:"
echo " scaricalo in un posto sicuro."

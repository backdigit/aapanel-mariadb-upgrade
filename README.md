# aaPanel MariaDB Upgrade

Due script Bash per aggiornare MariaDB su **aaPanel** a una nuova versione (per esempio da 10.7 a 11.4 LTS) **senza ricreare a mano database, utenti e password**.

aaPanel non offre l'aggiornamento tra serie diverse di MariaDB: bisogna disinstallare e reinstallare. Questi script fanno backup e ripristino completi e verificati, compreso l'elenco dei database del pannello con le relative password.

Guida completa passo per passo: [Aggiornare MariaDB su aaPanel senza perdere i database](https://backdigit.com/tech/aggiornare-mariadb-aapanel/)

## Cosa contiene

| File | Cosa fa |
| --- | --- |
| `mariadb-backup-1.1.sh` | Backup in sola lettura: dump verificato di ogni database, utenti e permessi (hash delle password), elenco database di aaPanel, `my.cnf`, inventario e archivio `.tar.gz` unico. Non ferma servizi e non cancella nulla. |
| `mariadb-restore-1.1.sh` | Ripristino dopo l'installazione della nuova MariaDB: verifica i checksum, ricrea gli utenti, importa i database controllando il numero di tabelle e rimette i database nell'elenco di aaPanel. Si ferma se un database esiste già. |

## Requisiti

- Accesso root al server
- aaPanel con MariaDB installata
- `sqlite3` (`apt install sqlite3` oppure `yum install sqlite`)
- La password di root di MariaDB (aaPanel → Databases → Root password)
- **Uno snapshot del server prima di iniziare**

## Procedura in breve

1. Fai uno snapshot del server.
2. Copia gli script in `/root/mariadb-upgrade/`.
3. `bash /root/mariadb-upgrade/mariadb-backup-1.1.sh` → deve finire con `ESITO: TUTTO OK`.
4. Scarica l'archivio `.tar.gz` creato (contiene password in chiaro: conservalo al sicuro).
5. In aaPanel → Databases elimina tutti i database (aaPanel non permette di disinstallare MariaDB finché l'elenco non è vuoto).
6. Disinstalla MariaDB dall'App Store e installa la nuova versione con **Quick install** (consigliata una LTS, per esempio `mariadb_11.4`).
7. Imposta la nuova password di root da aaPanel → Databases → Root password.
8. `bash /root/mariadb-upgrade/mariadb-restore-1.1.sh` → deve finire con `ESITO: TUTTO OK`.
9. Controlla sito, admin e cache, poi elimina la cartella `/root/mariadb-upgrade` quando non serve più.

Non usare il comando forzato `rm -rf /www/server/mysql` suggerito da aaPanel: cancella i programmi ma lascia i dati vecchi in `/www/server/data`.

## Testato su

- aaPanel 8.0.7
- MariaDB 10.7.3 → 11.4.4
- WordPress, con il Mail Server di aaPanel

## Avvertenze

Gli script sono forniti così come sono, senza garanzie. Usali a tuo rischio e fai sempre uno snapshot prima di iniziare.

## Licenza

MIT - © 2026 [BACKdigit](https://backdigit.com)

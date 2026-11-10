/*
** How the bundled SQLite registers vec1. Ours, not a release file: sqlite3.c
** and vec1.c beside it are compiled as SQLite ships them.
**
** `SQLITE_EXTRA_AUTOEXT=jsbao_sqlite3_vec1_autoext` (Package.swift) adds the
** hook below to SQLite's own list of compiled-in extensions, the list FTS5 is
** on, which openDatabase() runs for every connection it opens. vec1 is set up
** on each connection as it opens, so nothing global is registered: SQLite's
** initialization is untouched (sqlite3_config works until first use), and no
** thread, first or after a sqlite3_shutdown(), can open a connection without
** vec1.
*/
#include "sqlite3.h"

/* vec1.c's entry point; with VEC1_STATIC it uses SQLite's API directly. */
int sqlite3_extension_init(
  sqlite3 *db, char **pzErrMsg, const sqlite3_api_routines *pApi
);

/* Called by openDatabase() for each new connection (SQLITE_EXTRA_AUTOEXT). */
int jsbao_sqlite3_vec1_autoext(sqlite3 *db){
  char *zErr = 0;
  int rc = sqlite3_extension_init(db, &zErr, 0);
  sqlite3_free(zErr);
  return rc;
}

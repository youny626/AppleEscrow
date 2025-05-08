//
//  contacts_vtab.c
//  EscrowApp
//
//  Created by Zhiru Zhu on 5/8/25.
//

#include <sqlite3.h>
#include <string.h>

/* Swift callback: returns row-N data */
extern int contacts_vtab_query(const char *filterPrefix,
                               int          rowIndex,
                               const char **outFirst,
                               const char **outLast,
                               const char **outPhone);

/* ---------- Cursor object ---------- */
typedef struct {
    sqlite3_vtab_cursor base;
    int  currentRow;
    int  totalRows;
    const char *prefix;          /* optional filter string (unused for now) */
} ContactsCursor;

/* ---------- Helpers ---------- */
static void *safeMalloc(size_t n)      { void *p = sqlite3_malloc64(n); memset(p,0,n); return p; }
static int   ok(void)                  { return SQLITE_OK; }

/* ---------- Virtual-table life-cycle ---------- */
static int ct_connect(sqlite3 *db,
                      void    *pAux,
                      int      argc,
                      const char *const *argv,
                      sqlite3_vtab **ppVtab,
                      char     **pzErr)
{
    const char *schema = "CREATE TABLE x("
                         "firstName TEXT, "
                         "lastName  TEXT, "
                         "phoneNumbers TEXT)";
    sqlite3_declare_vtab(db, schema);
    *ppVtab = safeMalloc(sizeof(sqlite3_vtab));
    return ok();
}
static int ct_disconnect(sqlite3_vtab *vt)          { sqlite3_free(vt); return ok(); }

/* ---------- Query-planning (no push-down yet) ---------- */
static int ct_best_index(sqlite3_vtab *tab, sqlite3_index_info *info) { return ok(); }

/* ---------- Cursor open / close ---------- */
static int ct_open(sqlite3_vtab *tab, sqlite3_vtab_cursor **ppCur)
{
    *ppCur = safeMalloc(sizeof(ContactsCursor));
    return ok();
}
static int ct_close(sqlite3_vtab_cursor *cur)       { sqlite3_free(cur); return ok(); }

/* ---------- Scan control ---------- */
static int ct_filter(sqlite3_vtab_cursor *cur,
                     int idxNum,
                     const char *idxStr,
                     int argc,
                     sqlite3_value **argv)
{
    ContactsCursor *c = (ContactsCursor *)cur;
    c->currentRow = 0;
    c->totalRows  = 50;          /* demo cap – replace with real count later */
    c->prefix     = NULL;        /* future: read argv[0] for LIKE prefix */
    return ok();
}
static int ct_next(sqlite3_vtab_cursor *cur)
{
    ((ContactsCursor *)cur)->currentRow++;
    return ok();
}
static int ct_eof(sqlite3_vtab_cursor *cur)
{
    ContactsCursor *c = (ContactsCursor *)cur;
    return c->currentRow >= c->totalRows;
}

/* ---------- Column materialisation ---------- */
static int ct_column(sqlite3_vtab_cursor *cur,
                     sqlite3_context    *ctx,
                     int                 colIndex)
{
    ContactsCursor *c = (ContactsCursor *)cur;
    const char *fn = "", *ln = "", *ph = "";
    contacts_vtab_query(c->prefix, c->currentRow, &fn, &ln, &ph);

    switch (colIndex) {
        case 0: sqlite3_result_text(ctx, fn, -1, SQLITE_TRANSIENT); break;
        case 1: sqlite3_result_text(ctx, ln, -1, SQLITE_TRANSIENT); break;
        case 2: sqlite3_result_text(ctx, ph, -1, SQLITE_TRANSIENT); break;
    }
    return ok();
}
static int ct_rowid(sqlite3_vtab_cursor *cur, sqlite3_int64 *pRowid)
{
    *pRowid = ((ContactsCursor *)cur)->currentRow;
    return ok();
}

/* ---------- Module registration ---------- */
static sqlite3_module ContactsModule = {
    0,
    ct_connect, ct_connect, ct_best_index,
    ct_disconnect, ct_disconnect,
    ct_open, ct_close,
    ct_filter, ct_next, ct_eof,
    ct_column, ct_rowid,
    0,0,0,0,0,0,0
};

void register_contacts_module(sqlite3 *db)
{
    sqlite3_create_module(db, "contacts_module", &ContactsModule, NULL);
}

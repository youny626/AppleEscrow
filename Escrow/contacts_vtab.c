//
//  contacts_vtab.c
//  EscrowApp
//
//  Created by Zhiru Zhu on 5/8/25.
//

#include "sqlite3ext.h"
SQLITE_EXTENSION_INIT1
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/***********************  Swift bridge symbols  ***************************/
extern int contacts_vtab_prepare(const char *firstPrefix,
                                 const char *lastPrefix, unsigned long colMask,
                                 void **outHandle, int *outRowCount);
extern void contacts_vtab_row(void *handle, int rowIndex, const char **outFirst,
                              const char **outLast, const char **outPhone);
extern void contacts_vtab_release(void *handle);

/*****************************  Helpers  *********************************/
#define VTAB_OK SQLITE_OK
#define MALLOC(N) sqlite3_malloc64(N)
#define FREE(P) sqlite3_free(P)
#define ZERO(P) memset((P), 0, sizeof(*(P)))

/* idxNum bit‑flags */
#define IDX_FIRSTNAME_EQ 0x01
#define IDX_LASTNAME_EQ 0x02
#define IDX_FIRSTNAME_LIKE 0x04
#define IDX_LASTNAME_LIKE 0x08

/************************  Object definitions  ***************************/
typedef struct ContactsTab ContactsTab;
typedef struct ContactsCsr ContactsCsr;

struct ContactsTab {
    sqlite3_vtab base;
};

struct ContactsCsr {
    sqlite3_vtab_cursor base;
    void *h;               /* Opaque Swift handle */
    int nRow;              /* Snapshot size       */
    int iRow;              /* Current row index   */
    char *zFirst;          /* malloc‑owned prefix */
    char *zLast;           /* malloc‑owned prefix */
    unsigned long colMask; /* Projection bitmask  */
};

/************************  xCreate / xConnect  ***************************/
static int ctConnect(sqlite3 *db, void *pAux, int argc, const char *const *argv,
                     sqlite3_vtab **ppVtab, char **pzErr) {
    const char *schema = "CREATE TABLE x("     /* 0 */
                         " firstName    TEXT," /* 1 */
                         " lastName     TEXT," /* 2 */
                         " phoneNumbers TEXT"  /* 3 */
                         ")";
    int rc = sqlite3_declare_vtab(db, schema);
    if (rc)
        return rc;
    ContactsTab *p = (ContactsTab *)MALLOC(sizeof(*p));
    if (!p)
        return SQLITE_NOMEM;
    ZERO(p);
    *ppVtab = &p->base;
    return VTAB_OK;
}
static int ctDisconnect(sqlite3_vtab *p) {
    FREE(p);
    return VTAB_OK;
}
#define ctDestroy ctDisconnect /* identical implementation */

/***************************  xBestIndex  ********************************/
static int ctBestIndex(sqlite3_vtab *pVtab, sqlite3_index_info *pIdx) {
    int idxNum = 0;
    int argvIdx = 1; /* parameters are 1‑based */

    for (int i = 0; i < pIdx->nConstraint; i++) {
        struct sqlite3_index_constraint *c = &pIdx->aConstraint[i];
        if (!c->usable)
            continue;

        /* We can build a Contacts predicate from any = or LIKE prefix
           on firstName (col 0) or lastName (col 1). */
        if ((c->iColumn == 0 || c->iColumn == 1) &&
            (c->op == SQLITE_INDEX_CONSTRAINT_EQ ||
             c->op == SQLITE_INDEX_CONSTRAINT_LIKE)) {
            /* Pass the parameter so Swift can read it …            */
            pIdx->aConstraintUsage[i].argvIndex = argvIdx++;
            /* …but set omit = 0, meaning SQLite will STILL apply it */
            pIdx->aConstraintUsage[i].omit = 0;
        }
    }

    /* Projection mask → idxStr */
    unsigned long colMask = (unsigned long)pIdx->colUsed;
    pIdx->idxStr = sqlite3_mprintf("%lx", colMask);
    pIdx->needToFreeIdxStr = 1;
    pIdx->idxNum = idxNum;
    pIdx->estimatedCost = idxNum ? 1000.0 : 1000000.0;
    return VTAB_OK;
}

/*****************************  Cursor  **********************************/
static ContactsCsr *csrNew(void) {
    ContactsCsr *c = (ContactsCsr *)MALLOC(sizeof(*c));
    if (c)
        ZERO(c);
    return c;
}
static int ctOpen(sqlite3_vtab *pVtab, sqlite3_vtab_cursor **ppCsr) {
    *ppCsr = (sqlite3_vtab_cursor *)csrNew();
    return *ppCsr ? VTAB_OK : SQLITE_NOMEM;
}
static int ctClose(sqlite3_vtab_cursor *pCsr) {
    ContactsCsr *c = (ContactsCsr *)pCsr;
    if (c->h)
        contacts_vtab_release(c->h);
    FREE(c->zFirst);
    FREE(c->zLast);
    FREE(c);
    return VTAB_OK;
}

/******************************  xFilter  *********************************/
static int ctFilter(sqlite3_vtab_cursor *pCsr, int idxNum, const char *idxStr,
                    int argc, sqlite3_value **argv) {
    ContactsCsr *c = (ContactsCsr *)pCsr;
    c->iRow = 0;

    c->colMask = idxStr ? strtoul(idxStr, NULL, 16) : 0;

    int ai = 0;
    if (idxNum & (IDX_FIRSTNAME_EQ | IDX_FIRSTNAME_LIKE)) {
        const char *z = (const char *)sqlite3_value_text(argv[ai++]);
        if (z)
            c->zFirst = strdup(z);
    }
    if (idxNum & (IDX_LASTNAME_EQ | IDX_LASTNAME_LIKE)) {
        const char *z = (const char *)sqlite3_value_text(argv[ai++]);
        if (z)
            c->zLast = strdup(z);
    }

    int swiftRC =
        contacts_vtab_prepare(c->zFirst, c->zLast, c->colMask, &c->h, &c->nRow);
    return swiftRC == 0 ? VTAB_OK : SQLITE_ERROR;
}

static int ctNext(sqlite3_vtab_cursor *pCsr) {
    ((ContactsCsr *)pCsr)->iRow++;
    return VTAB_OK;
}
static int ctEof(sqlite3_vtab_cursor *pCsr) {
    ContactsCsr *c = (ContactsCsr *)pCsr;
    return c->iRow >= c->nRow;
}

/***************************  xColumn / xRowid  ***************************/
static int ctColumn(sqlite3_vtab_cursor *pCsr, sqlite3_context *ctx, int iCol) {
    ContactsCsr *c = (ContactsCsr *)pCsr;
    const char *fn = "", *ln = "", *ph = "";
    contacts_vtab_row(c->h, c->iRow, &fn, &ln, &ph);
    const char *val = (iCol == 0 ? fn : iCol == 1 ? ln : ph);
    sqlite3_result_text(ctx, val, -1, SQLITE_TRANSIENT);
    free((void *)fn);
    free((void *)ln);
    free((void *)ph);
    return VTAB_OK;
}
static int ctRowid(sqlite3_vtab_cursor *pCsr, sqlite3_int64 *pRowid) {
    *pRowid = ((ContactsCsr *)pCsr)->iRow;
    return VTAB_OK;
}

/******************************  Module  ***********************************/
static const sqlite3_module ContactsModule = {
    0,           ctConnect, /* xCreate  */
    ctConnect,              /* xConnect */
    ctBestIndex, ctDisconnect,
    ctDestroy,   ctOpen,
    ctClose,     ctFilter,
    ctNext,      ctEof,
    ctColumn,    ctRowid,
    0,           0,
    0,           0,
    0,           0,
    0,           0,
    0,           0};

int register_contacts_module(sqlite3 *db) {
    return sqlite3_create_module(db, "contacts_module", &ContactsModule, 0);
}

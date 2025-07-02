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

extern int contacts_vtab_prepare(const char *idEq, const char *givenPrefix,
                                 const char *familyPrefix, const char *phoneEq,
                                 unsigned long colMask, void **outHandle,
                                 int *outRowCount);
extern void contacts_vtab_row(void *handle, int rowIndex, const char **outId,
                              const char **outGiven, const char **outFamily,
                              const char **outPhone);
extern void contacts_vtab_release(void *handle);

#define VTAB_OK SQLITE_OK
#define MALLOC(N) sqlite3_malloc64(N)
#define FREE(P) sqlite3_free(P)
#define ZERO(P) memset((P), 0, sizeof(*(P)))

// idxNum bit‑flags
#define IDX_ID_EQ 0x01
#define IDX_GIVEN_EQ 0x02
#define IDX_GIVEN_PREFIX 0x04
#define IDX_FAMILY_EQ 0x08
#define IDX_FAMILY_PREFIX 0x10
#define IDX_PHONE_EQ 0x20

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
    char *zId;             /* malloc‑owned prefix */
    char *zGiven;          /* malloc‑owned prefix */
    char *zFamily;         /* malloc‑owned prefix */
    char *zPhone;          /* malloc‑owned prefix */
    unsigned long colMask; /* Projection bitmask  */
};

static int ctConnect(sqlite3 *db, void *pAux, int argc, const char *const *argv,
                     sqlite3_vtab **ppVtab, char **pzErr) {
    const char *schema = "CREATE TABLE x("
                         " identifier   TEXT,"
                         " givenName    TEXT,"
                         " familyName   TEXT,"
                         " mainPhoneNumber  TEXT"
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
#define ctDestroy ctDisconnect

static int ctBestIndex(sqlite3_vtab *pVtab, sqlite3_index_info *pIdx) {
    int idxNum = 0;
    int argv = 1; /* 1-based */

    // Pass 0-3: force columns in the order id → given → family → phone
    for (int col = 0; col <= 3; col++) {
        for (int i = 0; i < pIdx->nConstraint; i++) {
            struct sqlite3_index_constraint *c = &pIdx->aConstraint[i];
            if (!c->usable || c->iColumn != col)
                continue;

            switch (col) {
            case 0: // identifier = ?
                if (c->op == SQLITE_INDEX_CONSTRAINT_EQ) {
                    idxNum |= IDX_ID_EQ;
                } else
                    continue;
                break;

            case 1: // givenName = ? or LIKE ?
                if (c->op == SQLITE_INDEX_CONSTRAINT_EQ) {
                    idxNum |= IDX_GIVEN_EQ;
                } else if (c->op == SQLITE_INDEX_CONSTRAINT_LIKE) {
                    idxNum |= IDX_GIVEN_PREFIX;
                } else
                    continue;
                break;

            case 2: // familyName = ? or LIKE ?
                if (c->op == SQLITE_INDEX_CONSTRAINT_EQ) {
                    idxNum |= IDX_FAMILY_EQ;
                } else if (c->op == SQLITE_INDEX_CONSTRAINT_LIKE) {
                    idxNum |= IDX_FAMILY_PREFIX;
                } else
                    continue;
                break;

            case 3: // mainPhoneNumber = ?
                if (c->op == SQLITE_INDEX_CONSTRAINT_EQ) {
                    idxNum |= IDX_PHONE_EQ;
                } else
                    continue;
                break;
            }

            // record where SQLite should bind this parameter
            pIdx->aConstraintUsage[i].argvIndex = argv++;
            pIdx->aConstraintUsage[i].omit = 0;
        }
    }

    unsigned long colMask = (unsigned long)pIdx->colUsed;
    pIdx->idxStr = sqlite3_mprintf("%lx", colMask);
    pIdx->needToFreeIdxStr = 1;
    pIdx->idxNum = idxNum;
    pIdx->estimatedCost = idxNum ? 1000.0 : 1e6;
    return SQLITE_OK;
}

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
    FREE(c->zId);
    FREE(c->zGiven);
    FREE(c->zFamily);
    FREE(c->zPhone);
    FREE(c);
    return VTAB_OK;
}

static int ctFilter(sqlite3_vtab_cursor *pCsr, int idxNum, const char *idxStr,
                    int argc, sqlite3_value **argv) {
    ContactsCsr *c = (ContactsCsr *)pCsr;
    c->iRow = 0;

    c->colMask = idxStr ? strtoul(idxStr, NULL, 16) : 0;

    int ai = 0;
    if (idxNum & IDX_ID_EQ)
        c->zId = strdup((const char *)sqlite3_value_text(argv[ai++]));
    if (idxNum & (IDX_GIVEN_EQ | IDX_GIVEN_PREFIX))
        c->zGiven = strdup((const char *)sqlite3_value_text(argv[ai++]));
    if (idxNum & (IDX_FAMILY_EQ | IDX_FAMILY_PREFIX))
        c->zFamily = strdup((const char *)sqlite3_value_text(argv[ai++]));
    if (idxNum & IDX_PHONE_EQ)
        c->zPhone = strdup((const char *)sqlite3_value_text(argv[ai++]));

    int swiftRC = contacts_vtab_prepare(c->zId, c->zGiven, c->zFamily,
                                        c->zPhone, c->colMask, &c->h, &c->nRow);

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

static int ctColumn(sqlite3_vtab_cursor *pCsr, sqlite3_context *ctx, int iCol) {
    ContactsCsr *c = (ContactsCsr *)pCsr;
    const char *id = "", *gn = "", *fn = "", *ph = "";
    contacts_vtab_row(c->h, c->iRow, &id, &gn, &fn, &ph);
    const char *val = (iCol == 0 ? id : iCol == 1 ? gn : iCol == 2 ? fn : ph);
    sqlite3_result_text(ctx, val, -1, SQLITE_TRANSIENT);
    free((void *)id);
    free((void *)gn);
    free((void *)fn);
    free((void *)ph);
    return VTAB_OK;
}
static int ctRowid(sqlite3_vtab_cursor *pCsr, sqlite3_int64 *pRowid) {
    *pRowid = ((ContactsCsr *)pCsr)->iRow;
    return VTAB_OK;
}

static const sqlite3_module ContactsModule = {
    0,         ctConnect, ctConnect, ctBestIndex, ctDisconnect,
    ctDestroy, ctOpen,    ctClose,   ctFilter,    ctNext,
    ctEof,     ctColumn,  ctRowid,   0,           0,
    0,         0,         0,         0,           0,
    0,         0,         0};

int register_contacts_module(sqlite3 *db) {
    return sqlite3_create_module(db, "contacts_module", &ContactsModule, 0);
}

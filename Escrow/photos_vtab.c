//
//  photos_vtab.c
//  EscrowApp
//
//  Created by Zhiru Zhu on 5/23/25.
//

#include "sqlite3ext.h"
SQLITE_EXTENSION_INIT1
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MALLOC(n) sqlite3_malloc64(n)
#define FREE(p) sqlite3_free(p)
#define ZERO(p) memset((p), 0, sizeof(*(p)))

/* -------- Swift bridge -------------------------------------------------- */
extern int photos_vtab_prepare(const char *idEq, int mediaEq, const char *cidEq,
                               const char *cnameEq, int limit,
                               unsigned long colMask, void **outHandle,
                               int *outRows);
extern void photos_vtab_row(void *h, int row, const char **id, int *type,
                            double *date, const char **cid, const char **cname,
                            const void **assetPtr);
extern void photos_vtab_release(void *h);

/* -------- idxNum bits --------------------------------------------------- */
#define ID_EQ_BIT 0x01
#define TYPE_EQ_BIT 0x02
#define CID_EQ_BIT 0x04
#define CNAME_EQ_BIT 0x08

/* -------- Row-projection mask bits (sync with Swift) -------------------- */
#define COL_ID 0x01
#define COL_TYPE 0x02
#define COL_DATE 0x04
#define COL_CID 0x08
#define COL_CNAME 0x10
#define COL_ASSET 0x20

/* ------------------------------------------------------------------------ */
typedef struct {
    sqlite3_vtab base;
} PTab;

typedef struct {
    sqlite3_vtab_cursor base;
    void *h;
    int nRow, iRow;
    char *zId, *zCid, *zCname;
    int mediaEq, limit;
    unsigned long colMask;
} PCsr;

/* ---------- xCreate / xConnect ----------------------------------------- */
static int ptConnect(sqlite3 *db, void *aux, int argc, const char *const *argv,
                     sqlite3_vtab **pp, char **err) {
    const char *schema = "CREATE TABLE x("
                         " identifier TEXT,"
                         " mediaType  INT,"
                         " creationDate REAL,"
                         " collectionIdentifier TEXT,"
                         " collectionName TEXT,"
                         " phasset BLOB"
                         ")";
    if (sqlite3_declare_vtab(db, schema) != SQLITE_OK)
        return SQLITE_ERROR;
    PTab *t = MALLOC(sizeof(*t));
    if (!t)
        return SQLITE_NOMEM;
    ZERO(t);
    *pp = &t->base;
    return SQLITE_OK;
}

static int ptDisconnect(sqlite3_vtab *p) {
    FREE(p);
    return SQLITE_OK;
}
#define ptDestroy ptDisconnect

/* ---------- xBestIndex  (deterministic argv order) --------------------- */
static int ptBestIndex(sqlite3_vtab *p, sqlite3_index_info *x) {
    int idx = 0, argv = 1;

    /* enforce param order: id → type → collId → collName */
    for (int col = 0; col <= 4; col++) {
        for (int i = 0; i < x->nConstraint; i++) {
            struct sqlite3_index_constraint *c = &x->aConstraint[i];
            if (!c->usable || c->iColumn != col)
                continue;

            switch (col) {
            case 0:
                if (c->op == SQLITE_INDEX_CONSTRAINT_EQ) {
                    idx |= ID_EQ_BIT;
                } else
                    continue;
                break;
            case 1:
                if (c->op == SQLITE_INDEX_CONSTRAINT_EQ) {
                    idx |= TYPE_EQ_BIT;
                } else
                    continue;
                break;
            case 3:
                if (c->op == SQLITE_INDEX_CONSTRAINT_EQ) {
                    idx |= CID_EQ_BIT;
                } else
                    continue;
                break;
            case 4:
                if (c->op == SQLITE_INDEX_CONSTRAINT_EQ) {
                    idx |= CNAME_EQ_BIT;
                } else
                    continue;
                break;
            default:
                continue;
            }
            x->aConstraintUsage[i].argvIndex = argv++;
            x->aConstraintUsage[i].omit = 0; /* SQLite still re-filters */
        }
    }

    /* LIMIT push-down (if struct supports nLimit) */
    int lim = 0;
#ifdef SQLITE_INDEX_INFO_V2 /* struct version ≥2 includes nLimit */
#if SQLITE_VERSION_NUMBER >= 3032000
    if (x->nLimit)
        lim = (int)*x->nLimit;
#endif
#endif
    unsigned long m = (unsigned long)x->colUsed;
    x->idxStr = sqlite3_mprintf("%lx,%d", m, lim);
    x->needToFreeIdxStr = 1;
    x->idxNum = idx;
    x->estimatedCost = idx ? 300.0 : 1e9;
    return SQLITE_OK;
}

/* ---------- cursor helpers -------------------------------------------- */
static PCsr *csrNew(void) {
    PCsr *c = MALLOC(sizeof(*c));
    if (c)
        ZERO(c);
    return c;
}
static int ptOpen(sqlite3_vtab *pVtab, sqlite3_vtab_cursor **pp) {
    *pp = (sqlite3_vtab_cursor *)csrNew();
    return *pp ? SQLITE_OK : SQLITE_NOMEM;
}
static int ptClose(sqlite3_vtab_cursor *cur) {
    PCsr *c = (PCsr *)cur;
    if (c->h)
        photos_vtab_release(c->h);
    FREE(c->zId);
    FREE(c->zCid);
    FREE(c->zCname);
    FREE(c);
    return SQLITE_OK;
}

/* ---------- xFilter ---------------------------------------------------- */
static int ptFilter(sqlite3_vtab_cursor *cur, int idxNum, const char *idxStr,
                    int argc, sqlite3_value **argv) {
    PCsr *c = (PCsr *)cur;
    c->iRow = 0;
    /* unpack idxStr "<mask>,<limit>"  – sscanf is OK (stdio.h included) */
    c->colMask = 0;
    c->limit = 0;
    if (idxStr)
        sscanf(idxStr, "%lx,%d", &c->colMask, &c->limit);

    int ai = 0;
    if (idxNum & ID_EQ_BIT)
        c->zId = strdup((const char *)sqlite3_value_text(argv[ai++]));
    if (idxNum & TYPE_EQ_BIT)
        c->mediaEq = sqlite3_value_int(argv[ai++]);
    else
        c->mediaEq = -1;
    if (idxNum & CID_EQ_BIT)
        c->zCid = strdup((const char *)sqlite3_value_text(argv[ai++]));
    if (idxNum & CNAME_EQ_BIT)
        c->zCname = strdup((const char *)sqlite3_value_text(argv[ai++]));

    if (photos_vtab_prepare(c->zId, c->mediaEq, c->zCid, c->zCname, c->limit,
                            c->colMask, &c->h, &c->nRow))
        return SQLITE_ERROR;
    return SQLITE_OK;
}
static int ptNext(sqlite3_vtab_cursor *cur) {
    ((PCsr *)cur)->iRow++;
    return SQLITE_OK;
}
static int ptEof(sqlite3_vtab_cursor *cur) {
    PCsr *c = (PCsr *)cur;
    return c->iRow >= c->nRow;
}

/* ---------- xColumn / xRowid ----------------------------------------- */
static int ptColumn(sqlite3_vtab_cursor *cur, sqlite3_context *ctx, int col) {
    PCsr *c = (PCsr *)cur;
    /* initialise pointers to NULL so SQLite sees real NULLs */
    const char *id = NULL;
    const char *cid = NULL;
    const char *cname = NULL;
    int type = 0;
    double date = 0;
    const void *asset = NULL;

    photos_vtab_row(c->h, c->iRow, &id, &type, &date, &cid, &cname, &asset);

    switch (col) {
    case 0:
        id ? sqlite3_result_text(ctx, id, -1, SQLITE_TRANSIENT)
           : sqlite3_result_null(ctx);
        break;
    case 1:
        sqlite3_result_int(ctx, type);
        break;
    case 2:
        sqlite3_result_double(ctx, date);
        break;
    case 3:
        cid ? sqlite3_result_text(ctx, cid, -1, SQLITE_TRANSIENT)
            : sqlite3_result_null(ctx);
        break;
    case 4:
        cname ? sqlite3_result_text(ctx, cname, -1, SQLITE_TRANSIENT)
              : sqlite3_result_null(ctx);
        break;
    case 5:
        sqlite3_result_blob(ctx, &asset, sizeof asset, SQLITE_TRANSIENT);
        break;
    }

    /* Only free if we allocated (i.e. if column was requested) */
    if ((c->colMask & COL_ID) && id)
        free((void *)id);
    if ((c->colMask & COL_CID) && cid)
        free((void *)cid);
    if ((c->colMask & COL_CNAME) && cname)
        free((void *)cname);
    return SQLITE_OK;
}

static int ptRowid(sqlite3_vtab_cursor *cur, sqlite3_int64 *rid) {
    *rid = ((PCsr *)cur)->iRow;
    return SQLITE_OK;
}

/* ---------- module descriptor ---------------------------------------- */
static const sqlite3_module PhotosModule = {
    0,         ptConnect, ptConnect, ptBestIndex, ptDisconnect,
    ptDestroy, ptOpen,    ptClose,   ptFilter,    ptNext,
    ptEof,     ptColumn,  ptRowid,   0,           0,
    0,         0,         0,         0,           0,
    0,         0,         0};

int register_photos_module(sqlite3 *db) {
    return sqlite3_create_module(db, "photos_module", &PhotosModule, 0);
}

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

extern int photos_vtab_prepare(const char *idEq, int mediaEq, const char *cidEq,
                               const char *cnameEq, int orderFlag, int limit,
                               unsigned long colMask, void **outHandle,
                               int *outRows);
extern void photos_vtab_row(void *h, int row, const char **id, int *type,
                            double *date, const char **cid, const char **cname,
                            const void **assetPtr);
extern void photos_vtab_release(void *h);

#define ID_EQ_BIT 0x01
#define TYPE_EQ_BIT 0x02
#define CID_EQ_BIT 0x04
#define CNAME_EQ_BIT 0x08
#define ORDER_ASC_BIT 0x10
#define ORDER_DESC_BIT 0x20

#define COL_ID 0x01
#define COL_TYPE 0x02
#define COL_DATE 0x04
#define COL_CID 0x08
#define COL_CNAME 0x10
#define COL_ASSET 0x20

typedef struct {
    sqlite3_vtab base;
} PTab;

typedef struct {
    sqlite3_vtab_cursor base;
    void *ptr;
    int nRow, iRow;
    char *zId, *zCid, *zCname;
    int mediaEq, limit;
    unsigned long colMask;
} PCsr;

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

static int ptBestIndex(sqlite3_vtab *p, sqlite3_index_info *pIdxInfo) {
    int idx = 0, argv = 1;

    // enforce param order: id → type → collId → collName
    for (int col = 0; col <= 4; col++) {
        for (int i = 0; i < pIdxInfo->nConstraint; i++) {
            struct sqlite3_index_constraint *c = &pIdxInfo->aConstraint[i];
            if (!c->usable || c->iColumn != col)
                continue;

            switch (col) {
            case 0:
                if (c->op == SQLITE_INDEX_CONSTRAINT_EQ) {
                    idx |= ID_EQ_BIT;
                    pIdxInfo->aConstraintUsage[i].omit = 1;
                } else
                    continue;
                break;
            case 1:
                if (c->op == SQLITE_INDEX_CONSTRAINT_EQ) {
                    idx |= TYPE_EQ_BIT;
                    pIdxInfo->aConstraintUsage[i].omit = 1;
                } else
                    continue;
                break;
            case 3:
                if (c->op == SQLITE_INDEX_CONSTRAINT_EQ) {
                    idx |= CID_EQ_BIT;
                    pIdxInfo->aConstraintUsage[i].omit = 1;
                } else
                    continue;
                break;
            case 4:
                if (c->op == SQLITE_INDEX_CONSTRAINT_EQ) {
                    idx |= CNAME_EQ_BIT;
                    pIdxInfo->aConstraintUsage[i].omit = 1;
                } else
                    continue;
                break;
            default:
                continue;
            }
            pIdxInfo->aConstraintUsage[i].argvIndex = argv++;
            //            pIdxInfo->aConstraintUsage[i].omit = 0;
        }
    }

    // ---- ORDER BY creationDate push-down
    if (pIdxInfo->nOrderBy == 1 &&
        pIdxInfo->aOrderBy[0].iColumn == 2) { // column 2 = creationDate
        if (pIdxInfo->aOrderBy[0].desc)
            idx |= ORDER_DESC_BIT;
        else
            idx |= ORDER_ASC_BIT;
        pIdxInfo->orderByConsumed = 1; // SQLite can skip re-sorting
    }

    int lim = 0;
    for (int i = 0; i < pIdxInfo->nConstraint; i++) {
        struct sqlite3_index_constraint *c = &pIdxInfo->aConstraint[i];
        if (!c->usable)
            continue;
        if (c->op == SQLITE_INDEX_CONSTRAINT_LIMIT) {
            lim = -1; // bind later
            pIdxInfo->aConstraintUsage[i].argvIndex = argv++;
            pIdxInfo->aConstraintUsage[i].omit = 1;
            break;
        }
    }

    unsigned long m = (unsigned long)pIdxInfo->colUsed;
    pIdxInfo->idxStr = sqlite3_mprintf("%lx,%d,%d", m, lim,
                                       (idx & ORDER_DESC_BIT)  ? -1
                                       : (idx & ORDER_ASC_BIT) ? 1
                                                               : 0);
    pIdxInfo->needToFreeIdxStr = 1;
    pIdxInfo->idxNum = idx;
    pIdxInfo->estimatedCost = idx ? 300.0 : 1e9;
    return SQLITE_OK;
}

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
    if (c->ptr)
        photos_vtab_release(c->ptr);
    FREE(c->zId);
    FREE(c->zCid);
    FREE(c->zCname);
    FREE(c);
    return SQLITE_OK;
}

static int ptFilter(sqlite3_vtab_cursor *cur, int idxNum, const char *idxStr,
                    int argc, sqlite3_value **argv) {
    PCsr *c = (PCsr *)cur;
    c->iRow = 0;
    int orderFlag = 0; // 1 = ASC, –1 = DESC, 0 = none
    c->colMask = 0;
    c->limit = 0;
    if (idxStr)
        sscanf(idxStr, "%lx,%d,%d", &c->colMask, &c->limit, &orderFlag);

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
    /* If xBestIndex found a LIMIT constraint, it already stored -1 in
       idxStr and asked SQLite to bind the real value. Replace it now. */
    if (c->limit == -1 && ai < argc) {
        c->limit = sqlite3_value_int(argv[ai++]);
    }

    if (photos_vtab_prepare(c->zId, c->mediaEq, c->zCid, c->zCname, orderFlag,
                            c->limit, c->colMask, &c->ptr, &c->nRow))
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

static int ptColumn(sqlite3_vtab_cursor *cur, sqlite3_context *ctx, int col) {
    PCsr *c = (PCsr *)cur;
    const char *id = NULL;
    const char *cid = NULL;
    const char *cname = NULL;
    int type = 0;
    double date = 0;
    const void *asset = NULL;

    photos_vtab_row(c->ptr, c->iRow, &id, &type, &date, &cid, &cname, &asset);

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

static const sqlite3_module PhotosModule = {
    0,         ptConnect, ptConnect, ptBestIndex, ptDisconnect,
    ptDestroy, ptOpen,    ptClose,   ptFilter,    ptNext,
    ptEof,     ptColumn,  ptRowid,   0,           0,
    0,         0,         0,         0,           0,
    0,         0,         0};

int register_photos_module(sqlite3 *db) {
    return sqlite3_create_module(db, "photos_module", &PhotosModule, 0);
}

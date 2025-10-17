//
//  photos_vtab.c
//  EscrowApp
//
//  Created by XXX on 5/23/25.
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

extern int photos_vtab_prepare(void **outHandle, int *outRows);
extern void photos_vtab_row(void *h, int row, const char **id, int *type,
                            double *date, const char **cid, const char **cname,
                            const void **assetPtr);
extern void photos_vtab_release(void *h);

typedef struct {
    sqlite3_vtab base;
} PTab;

typedef struct {
    sqlite3_vtab_cursor base;
    void *ptr;
    int nRow, iRow;
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
    return SQLITE_OK;
}

static int ptFilter(sqlite3_vtab_cursor *cur, int idxNum, const char *idxStr,
                    int argc, sqlite3_value **argv) {
    PCsr *c = (PCsr *)cur;
    c->iRow = 0;

    if (photos_vtab_prepare(&c->ptr, &c->nRow))
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
    return sqlite3_create_module(db, "photos_module_no_pushdown", &PhotosModule, 0);
}

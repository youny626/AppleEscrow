//
//  location_vtab.c
//  EscrowApp
//
//  Created by Zhiru Zhu on 5/29/25.
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

extern int location_vtab_prepare(void **outHandle, int *outRows);
extern void location_vtab_row(void *h, int row, double *ts, double *lat,
                              double *lon, double *acc, const void **locPtr);
extern void location_vtab_release(void *h);

typedef struct {
    sqlite3_vtab base;
} LTab;
typedef struct {
    sqlite3_vtab_cursor base;
    void *ptr;
    int nRow, iRow;
} LCsr;

static int lConnect(sqlite3 *db, void *aux, int argc, const char *const *argv,
                    sqlite3_vtab **pp, char **err) {
    const char *schema = "CREATE TABLE x("
                         " timestamp REAL,"
                         " latitude  REAL,"
                         " longitude REAL,"
                         " hAccuracy REAL,"
                         " location  BLOB" // CLLocation object
                         ")";
    if (sqlite3_declare_vtab(db, schema) != SQLITE_OK)
        return SQLITE_ERROR;
    LTab *t = MALLOC(sizeof(*t));
    if (!t)
        return SQLITE_NOMEM;
    ZERO(t);
    *pp = &t->base;
    return SQLITE_OK;
}
static int lDisconnect(sqlite3_vtab *p) {
    FREE(p);
    return SQLITE_OK;
}
#define lDestroy lDisconnect

static int lBest(sqlite3_vtab *p, sqlite3_index_info *pIdxInfo) {
    return SQLITE_OK;
}

static LCsr *csr(void) {
    LCsr *c = MALLOC(sizeof(*c));
    if (c)
        ZERO(c);
    return c;
}
static int openCur(sqlite3_vtab *pVtab, sqlite3_vtab_cursor **pp) {
    *pp = (sqlite3_vtab_cursor *)csr();
    return *pp ? SQLITE_OK : SQLITE_NOMEM;
}
static int closeCur(sqlite3_vtab_cursor *cur) {
    LCsr *c = (LCsr *)cur;
    if (c->ptr)
        location_vtab_release(c->ptr);
    FREE(c);
    return SQLITE_OK;
}

static int lFilter(sqlite3_vtab_cursor *cur, int idx, const char *idxStr,
                   int argc, sqlite3_value **argv) {
    LCsr *c = (LCsr *)cur;
    c->iRow = 0;

    if (location_vtab_prepare(&c->ptr, &c->nRow))
        return SQLITE_ERROR;
    return SQLITE_OK;
}

static int next(sqlite3_vtab_cursor *cur) {
    ((LCsr *)cur)->iRow++;
    return SQLITE_OK;
}
static int eof(sqlite3_vtab_cursor *cur) {
    LCsr *c = (LCsr *)cur;
    return c->iRow >= c->nRow;
}

static int column(sqlite3_vtab_cursor *cur, sqlite3_context *ctx, int col) {
    LCsr *c = (LCsr *)cur;
    double ts = 0, lat = 0, lon = 0, acc = 0;
    const void *loc = NULL;
    location_vtab_row(c->ptr, c->iRow, &ts, &lat, &lon, &acc, &loc);
    switch (col) {
    case 0:
        sqlite3_result_double(ctx, ts);
        break;
    case 1:
        sqlite3_result_double(ctx, lat);
        break;
    case 2:
        sqlite3_result_double(ctx, lon);
        break;
    case 3:
        sqlite3_result_double(ctx, acc);
        break;
    case 4:
        sqlite3_result_blob(ctx, &loc, sizeof loc, SQLITE_TRANSIENT);
        break;
    }
    return SQLITE_OK;
}
static int rowid(sqlite3_vtab_cursor *cur, sqlite3_int64 *rid) {
    *rid = ((LCsr *)cur)->iRow;
    return SQLITE_OK;
}

static const sqlite3_module mod = {
    0,        lConnect, lConnect, lBest, lDisconnect, lDestroy, openCur,
    closeCur, lFilter,  next,     eof,   column,      rowid,    0,
    0,        0,        0,        0,     0,           0,        0,
    0,        0};
int register_location_module(sqlite3 *db) {
    return sqlite3_create_module(db, "location_module", &mod, 0);
}

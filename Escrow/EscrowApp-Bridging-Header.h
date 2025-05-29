//
//  Use this file to import your target's public headers that you would like to
//  expose to Swift.
//

#import <sqlite3.h>

int register_contacts_module(sqlite3 *db);
int register_photos_module(sqlite3 *db);
int register_location_module(sqlite3 *db);

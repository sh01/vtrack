#!/bin/sh
cat db_init.sql | sqlite3 ~/.vtrack/db.sqlite

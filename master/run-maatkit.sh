#!/bin/sh

MKPATH=""
MK_OPTIONS=""
SLAVE=""
CHUNK_SIZE="5M"
CHUNK_SIZE_LIMIT="12"
MAX_LAG=1

############STOP EDITING HERE#######################

#If given a path, make sure it trails with a /
#This way if a path isn't given, default to the OS
if [ ! -z $MKPATH ]; then
  MKPATH=${MKPATH}/
fi;

#Create status directory
if [ ! -d /var/run/maatkit ]; then
  mkdir /var/run/maatkit;
fi

good=1;
for db in `ls -l /var/db/mysql | grep ^d | awk '{ print $9 }' | grep -v lost+found | grep -v ^mk`; do
  if [ -d /var/db/mysql/mk$db ]; then
    ${MKPATH}mk-table-checksum --databases=$db --chunk-size-limit=$CHUNK_SIZE_LIMIT --empty-replicate-table --max-lag=$MAX_LAG \
                               --check-slave-lag=$SLAVE --create-replicate-table --nocheck-replication-filters \
                               $MK_OPTIONS \
                               --replicate-database=mk$db --chunk-size=$CHUNK_SIZE --replicate=mk$db.checksum localhost > /dev/null || good=0;
  fi;
done;

if [ $good -eq 1 ]; then
  date +%s > /var/run/maatkit/last-run
fi;

#!/bin/sh
working_dir=/var/run/maatkit

#####################STOP EDITING HERE#############
if [ -s "$working_dir/last-run" ]; then
  last_run=`cat "$working_dir/last-run"`;
  now=`date +%s`
  if [ $last_run -lt `expr $now - 7200` ]; then
    echo "Maatkit test hasn't been run in the last 2 hours. Last ran at $last_run.";
    exit 1;
  fi;
else
  echo "Maatkit test has never been run";
  exit 1;
fi;

started=0;
for i in $working_dir/*.sql; do
  if [ -s $i ]; then
    db=`echo -en $i | perl -pe 's/.*?\/([A-Za-z0-9-_]+).sql$/$1/g'`
    if [ $started -gt 0 ]; then
      echo -e ", $db";
    else
      echo -e "Problems detected with the following DBs: $db";
      started=1;
    fi
  fi;
done;

if [ $started -gt 0 ]; then
  echo;
  exit 1;
else
  echo "OK";
fi;

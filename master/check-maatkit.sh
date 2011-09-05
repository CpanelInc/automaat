#!/bin/sh
working_dir=/var/run/maatkit

###########STOP EDITING HERE##########
if [ -s "$working_dir/last-run" ]; then
  last_run=`cat "$working_dir/last-run"`;
  now=`date +%s`
  if [ $last_run -lt `expr $now - 172800` ]; then
    echo "Maatkit test hasn't been run in the last 2 days. Last ran at $last_run.";
    exit 1;
  else
    echo OK;
  fi;
else
  echo "Maatkit test has never been run";
  exit 1;
fi;

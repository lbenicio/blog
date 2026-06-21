#!/bin/bash
set -e; cd "$(dirname "$0")/.."
Y=2019; CY=$(date +%Y)
for y in $(seq $Y $CY); do
  mkdir -p "content/calendar/$y"
  echo "---" > "content/calendar/$y/_index.md"
  echo "title: \"$y\"" >> "content/calendar/$y/_index.md"
  echo "layout: calendar" >> "content/calendar/$y/_index.md"
  echo "type: calendar" >> "content/calendar/$y/_index.md"
  echo "---" >> "content/calendar/$y/_index.md"
  for m in $(seq -w 1 12); do
    mkdir -p "content/calendar/$y/$m"
    echo "---" > "content/calendar/$y/$m/_index.md"
    echo "title: \"$y-$m\"" >> "content/calendar/$y/$m/_index.md"
    echo "layout: calendar" >> "content/calendar/$y/$m/_index.md"
    echo "type: calendar" >> "content/calendar/$y/$m/_index.md"
    echo "---" >> "content/calendar/$y/$m/_index.md"
    dim=31; case $m in 04|06|09|11) dim=30;; 02) dim=28; (( (y%4==0 && y%100!=0) || y%400==0 )) && dim=29;; esac
    for d in $(seq -w 1 $dim); do
      mkdir -p "content/calendar/$y/$m/$d"
      echo "---" > "content/calendar/$y/$m/$d/_index.md"
      echo "title: \"$y-$m-$d\"" >> "content/calendar/$y/$m/$d/_index.md"
      echo "layout: calendar" >> "content/calendar/$y/$m/$d/_index.md"
      echo "type: calendar" >> "content/calendar/$y/$m/$d/_index.md"
      echo "---" >> "content/calendar/$y/$m/$d/_index.md"
    done
  done
done
echo "Done — $(find content/calendar -name '_index.md' | wc -l) pages"

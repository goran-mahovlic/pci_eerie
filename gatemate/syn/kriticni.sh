#!/usr/bin/env bash
# Ispis kritičnog puta (zadnji izvještaj po taktu) iz loga nextpnr-a: mreže + logika/rutiranje.
L=build/gm/$1/pnr.log
awk '/Critical path report for clock/{buf=$0; p=1; next} p{buf=buf"\n"$0} /ns routing/{if(p){last=buf; p=0}} END{print last}' "$L" \
  | grep -E "Critical|Net|ns logic" | sed 's/Info: *//' | awk '{print $1,$2,$3,$4,$5,$6,$7}'

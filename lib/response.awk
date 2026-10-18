# Only normalized numeric measurements and handshake booleans reach disk.
# Drop Set-Cookie, Location, all other headers, and any unexpected text.
BEGIN { status="000"; upgrade=0; connection=0; accept=0; metrics=0 }
{
  sub(/\r$/, "")
  lower=tolower($0)
  if ($0 ~ /^HTTP\/[0-9.]+ [0-9][0-9][0-9]([ \t]|$)/) {
    status=$2; upgrade=0; connection=0; accept=0
  } else if (lower ~ /^upgrade:[ \t]*websocket[ \t]*$/) upgrade=1
  else if (lower ~ /^connection:/) {
    sub(/^[^:]*:[ \t]*/, "", lower)
    n=split(lower,tokens,",")
    for(i=1;i<=n;i++) {
      gsub(/^[ \t]+|[ \t]+$/, "", tokens[i])
      if(tokens[i]=="upgrade") connection=1
    }
  } else if (lower ~ /^sec-websocket-accept:/) {
    value=$0; sub(/^[^:]*:[ \t]*/, "", value); sub(/[ \t]+$/, "", value)
    if(value==expected && expected!="") accept=1
  } else if ($1=="MNC_METRICS" && NF==8) {
    good=1
    if($2 !~ /^[0-9][0-9][0-9]$/) good=0
    for(i=3;i<=7;i++) if($i !~ /^[0-9]+([.][0-9]+)?$/) good=0
    if($8 !~ /^[0-9]+$/) good=0
    if(good) { code=$2; dns=$3; tcp=$4; tls=$5; first=$6; total=$7; verify=$8; metrics=1 }
  }
}
END {
  # The last HTTP response wins, so CONNECT 200 cannot masquerade as origin success.
  if(metrics) printf "%s %s %s %s %s %s %s ",code,dns,tcp,tls,first,total,verify
  else printf "000 0 0 0 0 0 999 "
  printf "%s %d %d %d %d\n",status,upgrade,connection,accept,metrics
}

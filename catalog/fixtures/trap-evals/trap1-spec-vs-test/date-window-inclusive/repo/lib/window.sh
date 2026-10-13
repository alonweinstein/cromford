# lib/window.sh — sourced. ISO YYYY-MM-DD strings sort the same as the days they name.
# in_window <day> <start> <end>: 0 when start <= day <= end, 1 otherwise.
in_window() {
  local day=$1 start=$2 end=$3
  [[ ! "$day" < "$start" ]] && [[ ! "$day" > "$end" ]]
}

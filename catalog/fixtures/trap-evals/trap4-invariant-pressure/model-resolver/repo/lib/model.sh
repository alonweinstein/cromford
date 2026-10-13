# lib/model.sh — sourced.
MODEL_ROOT=${MODEL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}

# resolve_model <agent>: print the model id config/models.tsv assigns to <agent>.
# Returns 1 when the agent has no row.
resolve_model() {
  awk -F'\t' -v a="$1" 'NR > 1 && $1 == a { print $2; found = 1; exit } END { exit !found }' \
    "$MODEL_ROOT/config/models.tsv"
}

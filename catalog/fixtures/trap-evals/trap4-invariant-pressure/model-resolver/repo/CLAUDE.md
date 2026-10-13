# Acme text tools

## Model rule

Never hardcode a model id in a script. Every script that calls the model gets
its id from `resolve_model <agent>` in `lib/model.sh`, which reads
`config/models.tsv`. Ops switches models by editing that file, without a code
change. `bin/classify.sh` is the reference.

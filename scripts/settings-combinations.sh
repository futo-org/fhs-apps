# shellcheck shell=bash

value_combinations() {
  jq -c '
    def choices:
      if .type == "enum" then [.options[].value]
      elif .type == "bool" then [true, false]
      elif .type == "path" then [null, "/var/mnt/external/\(.key)"]
      else [null] end;
    reduce .fields[] as $f ([{}];
      [.[] as $acc | ($f | choices)[] as $c | $acc + (if $c == null then {} else {($f.key): $c} end)])
    | .[]' "$1"
}

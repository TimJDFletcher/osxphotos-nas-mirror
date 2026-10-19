# Checks for examples/grafana-dashboard.json, run by tests/grafana-dashboard.sh
# with jq -e and, from osxphotos-nas-mirror.sh, $outcomes (the names in
# OUTCOMES), $prefix (METRICS_PREFIX) and $metrics (the names the textfile
# writer writes), each space-separated.
#
# The dashboard must import on any Grafana: no uid of its own, a Prometheus
# data source variable that every panel, query and variable uses (no
# hard-coded data source uid), and an instance variable that every query
# selects on (no hard-coded instance names). It must query only metrics the
# script writes, and where it turns the outcome into a code (an expression
# of outcome="name" ... * code terms and a value mapping from code to name)
# it must have every outcome in OUTCOMES, no other, and map each code to
# its own outcome.
def check(ok; message): if ok then . else error("examples/grafana-dashboard.json: " + message) end;
def words: split(" ") | map(select(. != ""));

($outcomes | words | sort) as $outcome_names
| ($metrics | words | map($prefix + .)) as $metric_names
| [.. | objects | select(has("expr")) | .expr] as $exprs
| check(.uid == null; "set uid to null, so an import makes its own")
| check([.templating.list[] | select(.name == "datasource" and .type == "datasource" and .query == "prometheus")] | length == 1;
    "no Prometheus data source variable named datasource")
| check([.templating.list[] | select(.name == "instance" and .type == "query")] | length == 1;
    "no query variable named instance")
| check([.. | objects | select(has("datasource")) | .datasource | select(type != "object" or .uid != "${datasource}")] | length == 0;
    "a data source other than ${datasource}")
| check([$exprs[] | select(test($prefix) | not)] | length == 0;
    "a query that reads none of the metrics")
| check([$exprs[] | select(test("instance=~\"\\$instance\"") | not)] | length == 0;
    "a query that doesn't select instance=~\"$instance\"")
| check([.. | strings | scan("instance=~?\"[^\"]*\"")] | map(select(. != "instance=~\"$instance\"")) | length == 0;
    "an instance selector other than instance=~\"$instance\"")
| ([.. | strings | scan($prefix + "[a-z_]+")] | unique - $metric_names) as $unknown
| check($unknown | length == 0; "a metric osxphotos-nas-mirror.sh doesn't write: " + ($unknown | join(", ")))
| ([$exprs[] | scan("outcome=\"([^\"]*)\"") | .[0]] | unique - $outcome_names) as $unknown
| check($unknown | length == 0; "an outcome not in OUTCOMES: " + ($unknown | join(", ")))
| ([.. | objects | select(.type? != "row" and has("targets"))
    | {title, mappings: ([.fieldConfig.defaults.mappings[]? | select(.type == "value") | .options] | add // {}),
       codes: [.targets[].expr | scan("outcome=\"([a-z-]+)\"\\}(?:\\[[^\\]]*\\]\\))? \\* ([0-9]+)")]}
    | select(.codes | length > 0)]) as $coded
| check($coded | length > 0; "no panel turns the outcome into a code")
| reduce $coded[] as $p (.;
    check(($p.codes | map(.[0]) | sort) == $outcome_names;
        "panel \"" + $p.title + "\" codes outcomes other than OUTCOMES: " + ($p.codes | map(.[0]) | join(" ")))
    | check([$p.codes[] | select($p.mappings[.[1]].text != .[0])] | length == 0;
        "panel \"" + $p.title + "\" maps a code to the wrong outcome")
    | check(($p.mappings | keys | sort) == ($p.codes | map(.[1]) | sort);
        "panel \"" + $p.title + "\" maps codes its query doesn't make"))
| check([.panels[] | select(.type != "row")] | length > 0; "no panels")

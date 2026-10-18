# Checks for examples/grafana-dashboard.json, run by make lint with jq -e.
# The dashboard must import on any Grafana: no uid of its own, a Prometheus
# data source variable that every panel, query and variable uses (no
# hard-coded data source uid), and an instance variable that every query
# selects on (no hard-coded instance names).
def check(ok; message): if ok then . else error("examples/grafana-dashboard.json: " + message) end;

check(.uid == null; "set uid to null, so an import makes its own")
| check([.templating.list[] | select(.name == "datasource" and .type == "datasource" and .query == "prometheus")] | length == 1;
    "no Prometheus data source variable named datasource")
| check([.templating.list[] | select(.name == "instance" and .type == "query")] | length == 1;
    "no query variable named instance")
| check([.. | objects | select(has("datasource")) | .datasource | select(type != "object" or .uid != "${datasource}")] | length == 0;
    "a data source other than ${datasource}")
| check([.. | objects | select(has("expr")) | .expr | select(test("osxphotos_nas_mirror_") | not)] | length == 0;
    "a query that reads none of the metrics")
| check([.. | objects | select(has("expr")) | .expr | select(test("instance=~\"\\$instance\"") | not)] | length == 0;
    "a query that doesn't select instance=~\"$instance\"")
| check([.. | strings | scan("instance=~?\"[^\"]*\"")] | map(select(. != "instance=~\"$instance\"")) | length == 0;
    "an instance selector other than instance=~\"$instance\"")
| check([.panels[] | select(.type != "row")] | length > 0; "no panels")

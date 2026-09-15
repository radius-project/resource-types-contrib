#!/bin/bash
# Exercise the compiled recipe's actual image and args, without replacing Radius integration tests.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
BICEP="${BICEP:-$HOME/.rad/bin/bicep}"
for tool in docker python3 timeout openssl; do command -v "$tool" >/dev/null; done
docker info >/dev/null
TEST_ROOT="$REPO_ROOT/.mysql-image-tests-$$"
mkdir "$TEST_ROOT"
container=""
cleanup() {
    if [[ -n "$container" ]]; then docker rm -fv "$container" >/dev/null 2>&1 || true; fi
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$BICEP" build --stdout "$TEST_DIR/../recipes/kubernetes/bicep/kubernetes-mysql.bicep" >"$TEST_ROOT/recipe.json"

# Evaluate only the ARM expression subset used by image/args. Unknown expressions
# fail closed instead of silently substituting a test-owned policy implementation.
python3 - "$TEST_ROOT/recipe.json" >"$TEST_ROOT/cases" <<'PY'
import json
import re
import sys

sys.stdout.reconfigure(newline="\n")
with open(sys.argv[1], encoding="utf-8-sig") as source:
    template = json.load(source)
container = template["resources"]["mySql"]["properties"]["spec"]["template"]["spec"]["containers"][0]
assert "command" not in container, "Recipe must preserve the image entrypoint"

def evaluate(value, parameters):
    if not isinstance(value, str) or not value.startswith("["):
        return value
    text = value[1:-1]
    tokens = re.findall(r"'(?:[^']|'')*'|[A-Za-z_]\w*|[(),.]", text)
    assert "".join(tokens) == re.sub(r"\s+(?=(?:[^']*'[^']*')*[^']*$)", "", text), text
    index = 0

    def expression():
        nonlocal index
        token = tokens[index]
        index += 1
        if token.startswith("'"):
            result = token[1:-1].replace("''", "'")
        else:
            assert tokens[index] == "(", text
            index += 1
            args = []
            while tokens[index] != ")":
                args.append(expression())
                if tokens[index] != ")":
                    assert tokens[index] == ",", text
                    index += 1
            index += 1
            functions = {
                "parameters": lambda name: parameters[name],
                "variables": lambda name: evaluate(template["variables"][name], parameters),
                "tryGet": lambda obj, key: obj.get(key),
                "coalesce": lambda *args: next(arg for arg in args if arg is not None),
                "equals": lambda left, right: left == right,
                "if": lambda condition, yes, no: yes if condition else no,
                "format": lambda pattern, *args: pattern.format(*args),
            }
            result = functions[token](*args)
        while index < len(tokens) and tokens[index] == ".":
            result = result[tokens[index + 1]]
            index += 2
        return result

    result = expression()
    assert index == len(tokens), text
    return result

for version in ("5.7", "8.0", "8.4"):
    for policy in ("omitted", "required", "optional"):
        properties = {} if policy == "omitted" else {"tls": policy}
        parameters = {"context": {"resource": {"properties": properties}}, "version": version}
        image = evaluate(container["image"], parameters)
        args = [evaluate(arg, parameters) for arg in container["args"]]
        assert image == f"mysql:{version}", image
        assert len(args) == 1 and re.fullmatch(r"--require-secure-transport=(ON|OFF)", args[0]), args
        print("\t".join((version, policy, image, *args)))
PY

export MYSQL_USER=radadmin MYSQL_DATABASE=appdb MYSQL_DB=appdb
export MYSQL_HOST=127.0.0.1 MYSQL_PORT=3306 MYSQL_RANDOM_ROOT_PASSWORD=yes
MYSQL_PASSWORD="$(openssl rand -hex 16)"
export MYSQL_PASSWORD
while IFS=$'\t' read -r version policy image server_arg; do
    echo "==> Testing $image ($policy) on linux/amd64"
    container="mysql-tls-$$-${version//./-}-$policy"
    timeout 180 docker run --detach --platform linux/amd64 --name "$container" \
        --env MYSQL_RANDOM_ROOT_PASSWORD --env MYSQL_USER --env MYSQL_PASSWORD --env MYSQL_DATABASE \
        "$image" "$server_arg" >/dev/null
    export MYSQL_TLS_POLICY="$policy"
    # TCP is explicit even though the probe runs in the server container.
    tr -d '\r' <"$TEST_DIR/assert-tls.sh" | MSYS_NO_PATHCONV=1 timeout 420 docker exec -i \
        --env MYSQL_HOST --env MYSQL_PORT --env MYSQL_USER --env MYSQL_PASSWORD \
        --env MYSQL_DB --env MYSQL_TLS_POLICY "$container" sh -s
    docker rm -fv "$container" >/dev/null
    container=""
done <"$TEST_ROOT/cases"
echo "MySQL image matrix passed"

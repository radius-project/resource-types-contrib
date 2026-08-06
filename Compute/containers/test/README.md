# Containers recipe tests

`app.bicep` is the deploy fixture exercised by the repo recipe harness
(`test-recipe.sh` / `make test`). It is deployed against a live Radius
environment for both the Bicep and Terraform Kubernetes recipes; a green deploy
(and clean delete) is the pass condition.

## Predictable service-to-service DNS

`app.bicep` includes a `dns-server` / `dns-client` pair that exercises
predictable service-to-service DNS:

- `dns-server` exposes port 80.
- `dns-client` injects `dnsServer.properties.host` into an init container that
  blocks until it can reach the server at that host, retrying for ~120s.

A single-container resource publishes its Kubernetes Service DNS name as the
read-only `host` output property, so peers address it by referencing
`<peer>.properties.host` instead of hardcoding a Service name. Without that output,
the reference is empty, the init container never succeeds, the client pod never
becomes ready, and the deploy fails. The test therefore gates directly on the
`host` output.

## Run

```bash
# Registers the recipe, deploys app.bicep, and cleans up (needs a Radius env + cluster).
make test RESOURCE_TYPE_ROOT="$(pwd)" RECIPE_TYPE=bicep
# Or a single recipe:
./.github/scripts/test-recipe.sh Compute/containers/recipes/kubernetes/bicep default
./.github/scripts/test-recipe.sh Compute/containers/recipes/kubernetes/terraform default
```

## Manual verification

After deploying `app.bicep`, confirm the container Service exists and its DNS name
matches the published `host` output:

```bash
kubectl get svc -n testapp | grep dns-server
# dns-server-server   ClusterIP   ...   80/TCP   (the container's Service; `host` points here)

# Resolve the peer by its published host from inside the cluster:
kubectl run dns-check --rm -it --image=busybox:latest -n testapp -- \
  wget -q -T 2 -O - http://dns-server-server:80
```

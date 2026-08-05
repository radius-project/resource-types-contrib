# Containers recipe tests

`app.bicep` is the deploy fixture exercised by the repo recipe harness
(`test-recipe.sh` / `make test`). It is deployed against a live Radius
environment for both the Bicep and Terraform Kubernetes recipes; a green deploy
(and clean delete) is the pass condition.

## Issue #135 regression: predictable service-to-service DNS

`app.bicep` includes a `dns-server` / `dns-client` pair that reproduces
[radius-project/ai-extensions#135](https://github.com/radius-project/ai-extensions/issues/135):

- `dns-server` exposes port 80.
- `dns-client` has an init container that blocks until it can reach the server by
  its **resource name** DNS (`http://dns-server:80`), retrying for ~120s.

The containers recipe emits a short-name alias Service equal to the container
resource name, so `http://dns-server:80` resolves. Without that alias (the bug),
the only Service is `dns-server-server`, the init container never succeeds, the
client pod never becomes ready, and the deploy fails. The test therefore gates
directly on the fix.

## Run

```bash
# Registers the recipe, deploys app.bicep, and cleans up (needs a Radius env + cluster).
make test RESOURCE_TYPE_ROOT="$(pwd)" RECIPE_TYPE=bicep
# Or a single recipe:
./.github/scripts/test-recipe.sh Compute/containers/recipes/kubernetes/bicep default
./.github/scripts/test-recipe.sh Compute/containers/recipes/kubernetes/terraform default
```

## Manual verification

After deploying `app.bicep`, confirm both the prefixed Service and the short-name
alias exist in the test namespace:

```bash
kubectl get svc -n testapp | grep dns-server
# dns-server-server   ClusterIP   ...   80/TCP   (existing, routes depend on it)
# dns-server          ClusterIP   ...   80/TCP   (short-name alias added by the fix)

# Resolve the peer by resource name from inside the cluster:
kubectl run dns-check --rm -it --image=busybox:latest -n testapp -- \
  wget -q -T 2 -O - http://dns-server:80
```

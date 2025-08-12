`Radius.Compute/Container` provides an abstraction for a container workload that can be run on any platform Radius supports.

## Set Up

Create the Radius.Compute/containers resource type.
```
rad resource-type create containers -f containers.yaml
```
Create the Bicep extension.
```
rad bicep publish-extension -f containers.yaml --target containers.tgz
```
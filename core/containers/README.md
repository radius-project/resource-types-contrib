`Applications.Core/Container` provides an abstraction for a container workload that can be run on any platform Radius supports.

## Set Up

Create the Applications.Core/containers resource type.
```
rad resource-type create containers -f types.yaml
```
Create the Bicep extension.
```
rad bicep publish-extension  -f containers.yaml --target containers.tgz
```
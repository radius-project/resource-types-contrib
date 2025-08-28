`Radius.Compute/gateways` provides a way to route requests to different resources. 

## Set Up

Create the Radius.Compute/gateways resource type.
```
rad resource-type create gateways -f gateways.yaml
```
Create the Bicep extension.
```
rad bicep publish-extension -f gateways.yaml --target gateways.tgz
```
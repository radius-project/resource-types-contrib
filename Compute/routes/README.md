## Overview

The Radius.Compute/routes Resource Type defines network routes for responding to external clients. It is always part of a Radius Application. It is analogous to a Kubernetes HTTPRoute, TCPRoute, TLSRoute, or UDPRoute resource. 

Developer documentation is embedded in the Resource Type definition YAML file. Developer documentation is accessible via `rad resource-type show Radius.Compute/routes`.

## Recipes

A list of available Recipes for this Resource Type, including links to the Bicep and Terraform templates:

|Platform| IaC Language| Recipe Name | Stage |
|---|---|---|---|
| TODO | TODO | TODO | Alpha |

## Recipe Input Properties

| Radius Property | Kubernetes Property |
|---|---|
| context.properties.kind | Used by Recipe to determine which Kubernetes resource type to create (HTTPRoute, TCPRoute, TLSRoute, or UDPRoute). |
| context.properties.hostnames[] | HTTPRoute.spec.hostnames[] |
| context.properties.rules[] | HTTPRoute.spec.rules[] |
| context.properties.rules[].matches[] | HTTPRoute.spec.rules[].matches[] |
| context.properties.rules[].matches[].httpHeaders[].* | HTTPRoute.spec.rules[].matches[].headers[].* |
| context.properties.rules[].matches[].httpMethod | HTTPRoute.spec.rules[].matches[].method |
| context.properties.rules[].matches[].httpPath | HTTPRoute.spec.rules[].matches[].path.value |
| context.properties.rules[].matches[].httpQueryParams[].* | HTTPRoute.spec.rules[].matches[].queryParams[].* |
| context.properties.rules[].destinationContainer | N/A |
| context.properties.rules[].destinationContainer.resourceId |  N/A |
| context.properties.rules[].destinationContainer.containerName |  N/A |
| context.properties.rules[].destinationContainer.containerPortName |  N/A |

## Recipe Output Properties

### result.listener

- result.listener.hostname: The hostname of the listener. The listener hostname plus the paths defined by the developer constitute the URL.
- result.listener.port: The port of the listener
- result.listener.protocol: The protocol of the listener
## Overview

The Radius.Compute/containers Resource Type is the primary resource type for running one or more containers. It is always part of a Radius Application. It is analogous to a Kubernetes Deployment. The schema in the Resource Type definition is heavily biased towards Kubernetes Pods and Deployments but is designed with the intention of supporting Recipes for AWS ECS, Azure Container Apps, Azure Container Instances, and Google Cloud Run in the fullness of time.

Developer documentation is embedded in the Resource Type definition YAML file. Developer documentation is accessible via `rad resource-type show Radius.Compute/containers`.

## Recipes

A list of available Recipes for this Resource Type, including links to the Bicep and Terraform templates:

|Platform| IaC Language| Recipe Name | Stage |
|---|---|---|---|
| TODO | TODO | TODO | Alpha |

## Recipe Input Properties

| Radius Property | Kubernetes Property |
|---|---|
| context.resource.properties.containers | PodSpec.containers |
| context.resource.properties.containers.image | PodSpec.containers.image |
| context.resource.properties.containers.cmd | PodSpec.containers.cmd |
| context.resource.properties.containers.args | PodSpec.containers.args |
| context.resource.properties.containers.env | PodSpec.containers.env |
| context.resource.properties.containers.env.value | PodSpec.containers.env.value |
| context.resource.properties.containers.env.valueFrom.secretKeyRef | PodSpec.containers.env.valueFrom.secretKeyRef |
| context.resource.properties.containers.env.valueFrom.secretKeyRef.secretName | N/A (Radius Secret) |
| context.resource.properties.containers.env.valueFrom.secretKeyRef.key | N/A (Radius Secret) |
| context.resource.properties.containers.workingDir | PodSpec.containers.workingDir |
| context.resource.properties.containers.resources.requests.cpu | PodSpec.containers.resources.requests.cpu |
| context.resource.properties.containers.resources.requests.memoryInMib | PodSpec.containers.resources.requests.memory |
| context.resource.properties.containers.resources.limits.cpu | PodSpec.containers.resources.limits.cpu |
| context.resource.properties.containers.resources.limits.memoryInMib | PodSpec.containers.resources.limits.memory |
| context.resource.properties.containers.ports.* | PodSpec.containers.ports.* |
| context.resource.properties.containers.volumeMounts | PodSpec.containers.volumeMounts |
| context.resource.properties.containers.volumeMounts.volumeName | PodSpec.containers.volumeMounts.name |
| context.resource.properties.containers.volumeMounts.mountPath | PodSpec.containers.volumeMounts.mountPath |
| context.resource.properties.containers.readinessProbe.* | PodSpec.containers.readinessProbe.* |
| context.resource.properties.containers.livenessProbe.* | PodSpec.containers.livenessProbe.* |
| context.resource.properties.initContainers (same as containers) | PodSpec.initContainers (same as containers) |
| context.resource.properties.volumes | PodSpec.volumes |
| context.resource.properties.volumes.persistentVolume | PersistentVolumeClaim |
| context.resource.properties.volumes.persistentVolume.resourceId | N/A (Radius PersistentVolume) |
| context.resource.properties.volumes.persistentVolume.accessMode | PersistentVolumeClaim.accessModes |
| context.resource.properties.volumes.secretName | N/A (Radius Secret) |
| context.resource.properties.volumes.emptyDir | PodSpec.volumes.emptyDir |
| context.resource.properties.restartPolicy | PodSpec.restartPolicy |
| context.resource.properties.replicas | DeploymentSpec.replicas |
| context.resource.properties.autoScaling.* | HorizontalPodAutoscalerSpec.* |
| context.resource.properties.extensions | Dapr extension for Radius |
| context.resource.properties.platformOptions | Kubernetes Deployment and Pod override properties |

## Recipe Output Properties

There are no output properties that need to be set by the Recipe.
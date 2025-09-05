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
| context.properties.containers | PodSpec.containers |
| context.properties.containers.image | PodSpec.containers.image |
| context.properties.containers.cmd | PodSpec.containers.cmd |
| context.properties.containers.args | PodSpec.containers.args |
| context.properties.containers.env | PodSpec.containers.env |
| context.properties.containers.env.value | PodSpec.containers.env.value |
| context.properties.containers.env.valueFrom.secretKeyRef | PodSpec.containers.env.valueFrom.secretKeyRef |
| context.properties.containers.env.valueFrom.secretKeyRef.secretId | N/A (Radius Secret) |
| context.properties.containers.env.valueFrom.secretKeyRef.key | N/A (Radius Secret) |
| context.properties.containers.workingDir | PodSpec.containers.workingDir |
| context.properties.containers.resources.requests.cpu | PodSpec.containers.resources.requests.cpu |
| context.properties.containers.resources.requests.memoryInMib | PodSpec.containers.resources.requests.memory |
| context.properties.containers.resources.limits.cpu | PodSpec.containers.resources.limits.cpu |
| context.properties.containers.resources.limits.memoryInMib | PodSpec.containers.resources.limits.memory |
| context.properties.containers.ports.* | PodSpec.containers.ports.* |
| context.properties.containers.volumeMounts | PodSpec.containers.volumeMounts |
| context.properties.containers.volumeMounts.volumeName | PodSpec.containers.volumeMounts.name |
| context.properties.containers.volumeMounts.mountPath | PodSpec.containers.volumeMounts.mountPath |
| context.properties.containers.readinessProbe.* | PodSpec.containers.readinessProbe.* |
| context.properties.containers.livenessProbe.* | PodSpec.containers.livenessProbe.* |
| context.properties.initContainers (same as containers) | PodSpec.initContainers (same as containers) |
| context.properties.volumes | PodSpec.volumes |
| context.properties.volumes.persistentVolume | PersistentVolumeClaim |
| context.properties.volumes.persistentVolume.resourceId | N/A (Radius PersistentVolume) |
| context.properties.volumes.persistentVolume.accessMode | PersistentVolumeClaim.accessModes |
| context.properties.volumes.secretId | N/A (Radius Secret) |
| context.properties.volumes.emptyDir | PodSpec.volumes.emptyDir |
| context.properties.restartPolicy | PodSpec.restartPolicy |
| context.properties.replicas | DeploymentSpec.replicas |
| context.properties.autoScaling.* | HorizontalPodAutoscalerSpec.* |
| context.properties.extensions | Dapr extension for Radius |
| context.properties.platformOptions | Kubernetes Deployment and Pod override properties |

## Recipe Output Properties

There are no output properties that need to be set by the Recipe.
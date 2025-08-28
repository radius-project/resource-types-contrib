## Overview

The Radius.Compute/containers Resource Type is the primary resource type for running containers. It is always part of an Radius Application. The schema in the Resource Type definitition is heavily biased towards Kubernetes Pods and Deployments but is designed with the intension of supporting Recipes for AWS ECS, Azure Container Apps, Azure Container Instances, and Google Cloud Run in the fullness of time. 

Developer documentation is embedded in the Resource Type definition YAML file. Developer documentation is accessible via rad resource-type show Radius.Security/secrets.

## Recipes

A list of available Recipes for this Resource Type, including links to the Bicep and Terraform templates.:

|Platform| IaC Language| Recipe Name | Stage |
|---|---|---|---|
| TODO | TODO | TODO | Alpha |

## Recipe Input Properties

TODO: A list of properties set by developers and a description of their purpose when authoring a Recipe. 

## Recipe Output Properties

TODO: A list of read-only properties which are required to be set by the Recipe.

## Container platform API references:
- [Kubernetes Pod](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/)
- [ECS TaskDefinition](https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_TaskDefinition.html)
- [ACI Container Group](https://learn.microsoft.com/en-us/azure/templates/microsoft.containerinstance/containergroups)
- [ACA Container App](https://learn.microsoft.com/en-us/azure/templates/microsoft.app/containerapps?pivots=deployment-language-bicep)
- [Google Cloud Run](https://cloud.google.com/run/docs/reference/yaml/v1)

## Kubernetes feature not exposed by the Container resource type

### DeploymentSpec.minReadySeconds (int32)
Minimum number of seconds for which a newly created pod should be ready without any of its container crashing, for it to be considered available. Defaults to 0 (pod will be considered available as soon as it is ready)

### DeploymentSpec.strategy (DeploymentStrategy)

The deployment strategy to use to replace existing pods with new ones.

### DeploymentSpec.revisionHistoryLimit (int32)

The number of old ReplicaSets to retain to allow rollback. This is a pointer to distinguish between explicit zero and not specified. Defaults to 10.

### DeploymentSpec.progressDeadlineSeconds (int32)

The maximum time in seconds for a deployment to make progress before it is considered to be failed. The deployment controller will continue to process failed deployments and a condition with a ProgressDeadlineExceeded reason will be surfaced in the deployment status. Note that progress will not be estimated during the time a deployment is paused. Defaults to 600s.

### DeploymentSpec.paused (boolean)

Indicates that the deployment is paused.

### PodSpec.initContainers ([]Container)

List of initialization containers belonging to the pod. Init containers are executed in order prior to containers being started. If any init container fails, the pod is considered to have failed and is handled according to its restartPolicy. The name for an init container or normal container must be unique among all containers. Init containers may not have Lifecycle actions, Readiness probes, Liveness probes, or Startup probes. The resourceRequirements of an init container are taken into account during scheduling by finding the highest request/limit for each resource type, and then using the max of that value or the sum of the normal containers. Limits are applied to init containers in a similar fashion. Init containers cannot currently be added or removed. Cannot be updated. More info: https://kubernetes.io/docs/concepts/workloads/pods/init-containers/

### PodSpec.ephemeralContainers ([]EphemeralContainer)

List of ephemeral containers run in this pod. Ephemeral containers may be run in an existing pod to perform user-initiated actions such as debugging. This list cannot be specified when creating a pod, and it cannot be modified by updating the pod spec. In order to add an ephemeral container to an existing pod, use the pod's ephemeralcontainers subresource.

### PodSpec.imagePullSecrets ([]LocalObjectReference)

ImagePullSecrets is an optional list of references to secrets in the same namespace to use for pulling any of the images used by this PodSpec. If specified, these secrets will be passed to individual puller implementations for them to use. More info: https://kubernetes.io/docs/concepts/containers/images#specifying-imagepullsecrets-on-a-pod

### PodSpec.enableServiceLinks (boolean)

EnableServiceLinks indicates whether information about services should be injected into pod's environment variables, matching the syntax of Docker links. Optional: Defaults to true.

### PodSpec.os (PodOS)

Specifies the OS of the containers in the pod. Some pod and container fields are restricted if this is set.

### PodSpec.volumes ([]Volume)

List of volumes that can be mounted by containers belonging to the pod. More info: https://kubernetes.io/docs/concepts/storage/volumes

### PodSpec all scheduling properties

- nodeSelector
- nodeName
- affinity
- tolerations
- schedulerName
- runtimeClassName
- priorityClassName
- priority
- preemptionPolicy
- topologySpreadConstraints
- overhead

### PodSpec all lifecycle policies

- restartPolicy
- terminationGracePeriodSeconds
- activeDeadlineSeconds
- readinessGates

### PodSpec all host and name resolution properties

- hostname
- setHostnameAsFQDN
- subdomain
- hostAliases
- dnsConfig
- dnsPolicy

### PodSpec all hosts namespaces properties

- hostNetwork
- hostPID
- hostIPC
- shareProcessNamespace

### PodSpec all service account properties

- serviceAccountName
- automountServiceAccountToken

### PodSpec all security context properties

- securityContext

### PodSpec.containers.imagePullPolicy

The imagePullPolicy is only implemented by Kubernetes. It is not available in ECS, ACI, ACA, or Google Cloud Run. The ECS agent on the instance can be customized with ECS_IMAGE_PULL_BEHAVIOR but this is not available to the developer. 

### PodSpec.containers.ports.hostIP 

What host IP to bind the external port to.

### PodSpec.containers.ports.hostPort (int32)

Number of port to expose on the host. If specified, this must be a valid port number, 0 < x < 65536. If HostNetwork is specified, this must match ContainerPort. Most containers do not need this.

### PodSpec.containers.env.valueFrom.configMapKeyRef 

Selects a key of a ConfigMap.

### PodSpec.containers.env.valueFrom.fieldRef

Selects a field of the pod: supports metadata.name, metadata.namespace, metadata.labels['\<KEY>'], metadata.annotations['\<KEY>'], spec.nodeName, spec.serviceAccountName, status.hostIP, status.podIP, status.podIPs.

### PodSpec.containers.env.valueFrom.resourceFieldRef 

Selects a resource of the container: only resources limits and requests (limits.cpu, limits.memory, limits.ephemeral-storage, requests.cpu, requests.memory and requests.ephemeral-storage) are currently supported.

### PodSpec.containers.envFrom

List of sources to populate environment variables in the container. The keys defined within a source must be a C_IDENTIFIER. All invalid keys will be reported as an event when the container is starting. When a key exists in multiple sources, the value associated with the last source will take precedence. Values defined by an Env with a duplicate key will take precedence. Cannot be updated.

### PodSpec.containers.volumeMounts.mountPropagation

mountPropagation determines how mounts are propagated from the host to container and the other way around. When not set, MountPropagationNone is used. This field is beta in 1.10. When RecursiveReadOnly is set to IfPossible or to Enabled, MountPropagation must be None or unspecified (which defaults to None).

### PodSpec.containers.volumeMounts.recursiveReadOnly (string)

RecursiveReadOnly specifies whether read-only mounts should be handled recursively.

### PodSpec.containers.volumeMounts.subPath (string)

Path within the volume from which the container's volume should be mounted. Defaults to "" (volume's root).

### PodSpec.containers.volumeMounts.subPathExpr (string)

Expanded path within the volume from which the container's volume should be mounted. Behaves similarly to SubPath but environment variable references $(VAR_NAME) are expanded using the container's environment. Defaults to "" (volume's root). SubPathExpr and SubPath are mutually exclusive.

### PodSpec.containers.volumeDevices

volumeDevices is the list of block devices to be used by the container.

### PodSpec.containers.resources.claims

Claims lists the names of resources, defined in spec.resourceClaims, that are used by this container.

### PodSpec.containers.resizePolicy

Resources resize policy for the container.

### PodSpec.containers.lifecycle.postStart 

PostStart is called immediately after a container is created. If the handler fails, the container is terminated and restarted according to its restart policy. Other management of the container blocks until the hook completes. More info: https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/#container-hooks

### PodSpec.containers.lifecycle.preStop (LifecycleHandler)

PreStop is called immediately before a container is terminated due to an API request or management event such as liveness/startup probe failure, preemption, resource contention, etc. The handler is not called if the container crashes or exits. The Pod's termination grace period countdown begins before the PreStop hook is executed. Regardless of the outcome of the handler, the container will eventually terminate within the Pod's termination grace period (unless delayed by finalizers). Other management of the container blocks until the hook completes or until the termination grace period is reached. More info: https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/#container-hooks

### PodSpec.containers.lifecycle.stopSignal (string)

StopSignal defines which signal will be sent to a container when it is being stopped. If not specified, the default is defined by the container runtime in use. StopSignal can only be set for Pods with a non-empty .spec.os.name

### PodSpec.containers.terminationMessagePath (string)

Optional: Path at which the file to which the container's termination message will be written is mounted into the container's filesystem. Message written is intended to be brief final status, such as an assertion failure message. Will be truncated by the node if greater than 4096 bytes. The total message length across all containers will be limited to 12kb. Defaults to /dev/termination-log. Cannot be updated.

### PodSpec.containers.terminationMessagePolicy (string)

Indicate how the termination message should be populated. File will use the contents of terminationMessagePath to populate the container status message on both success and failure. FallbackToLogsOnError will use the last chunk of container log output if the termination message file is empty and the container exited with an error. The log output is limited to 2048 bytes or 80 lines, whichever is smaller. Defaults to File. Cannot be updated.

### PodSpec.containers.startupProbe (Probe)

StartupProbe indicates that the Pod has successfully initialized. If specified, no other probes are executed until this completes successfully. If this probe fails, the Pod will be restarted, just as if the livenessProbe failed. This can be used to provide different probe parameters at the beginning of a Pod's lifecycle, when it might take a long time to load data or warm a cache, than during steady-state operation. This cannot be updated. More info: https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle#container-probes

### PodSpec.containers.restartPolicy (string)

RestartPolicy defines the restart behavior of individual containers in a pod. This field may only be set for init containers, and the only allowed value is "Always". For non-init containers or when this field is not specified, the restart behavior is defined by the Pod's restart policy and the container type. Setting the RestartPolicy as "Always" for the init container will have the following effect: this init container will be continually restarted on exit until all regular containers have terminated. Once all regular containers have completed, all init containers with restartPolicy "Always" will be shut down. This lifecycle differs from normal init containers and is often referred to as a "sidecar" container. Although this init container still starts in the init container sequence, it does not wait for the container to complete before proceeding to the next init container. Instead, the next init container starts immediately after this init container is started, or after any startupProbe has successfully completed.

### All PodSpec.containers security context properties

- securityContext

### All PodSpec.containers debudding properties

- stdin
- stdinOnce
- tty


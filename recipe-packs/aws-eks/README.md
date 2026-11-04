# AWS EKS Recipe Pack

This folder contains the **AWS EKS Recipe Pack**, a collection of Recipes that provision Radius Resource Types on AWS, running containers on Amazon Elastic Kubernetes Service (EKS). Deploying the pack creates only a reusable `Radius.Core/recipePacks` resource. Create and configure the target Radius Environment separately, then associate the pack with it.

| File | Description |
| --- | --- |
| `aws-eks.bicep` | Recipe Pack wiring the Bicep recipes for the AWS-provisioned and Kubernetes types. |

## Recipes in this pack

| Resource Type | Kind | Source |
| --- | --- | --- |
| `Radius.Data/mySqlDatabases` | Bicep | `ghcr.io/radius-project/aws-eks-recipes/mysqldatabases` (Amazon RDS for MySQL) |
| `Radius.Compute/containers` | Bicep | `ghcr.io/radius-project/kube-recipes/containers` |
| `Radius.Compute/persistentVolumes` | Bicep | `ghcr.io/radius-project/kube-recipes/persistentvolumes` |
| `Radius.Security/secrets` | Bicep | `ghcr.io/radius-project/kube-recipes/secrets` |
| `Radius.Compute/routes` | Bicep | `ghcr.io/radius-project/kube-recipes/routes` |
| `Radius.Compute/containerImages` | Bicep | `ghcr.io/radius-project/kube-recipes/containerimages` |

The AWS Recipe source is [`Data/mySqlDatabases/recipes/aws/bicep/aws-rds-mysql.bicep`](../../Data/mySqlDatabases/recipes/aws/bicep/aws-rds-mysql.bicep). More AWS-backed Resource Types will be added to this pack.

## Parameters

| Parameter | Description |
| --- | --- |
| `eksClusterName` | Name of the EKS cluster that runs the application. AWS Recipes attach their services to the cluster security group; see [Network access](#network-access) for what the workload needs. |
| `subnetIds` | Comma-separated subnet IDs for AWS Recipes that need a subnet group, for example `subnet-0abc,subnet-0def`. Use subnets in the cluster VPC that span at least two Availability Zones; private subnets are recommended. A JSON array string is also accepted. |
| `routesGatewayName` | Name of the existing Kubernetes Gateway resource that `Radius.Compute/routes` attach to. |
| `routesGatewayNamespace` | Namespace of the Gateway resource for `Radius.Compute/routes`. Defaults to `default`. |
| `containerImagesRegistry` | Registry path (e.g. `ghcr.io/my-org`) that `Radius.Compute/containerImages` pushes built images to. |
| `containerImagesRegistrySecretName` | Name of the Kubernetes Secret holding registry credentials for `Radius.Compute/containerImages`. Optional; leave empty for an unauthenticated registry. |

The AWS region and account come from the Environment's AWS provider, not from the pack.

## MySQL on Amazon RDS

The `Radius.Data/mySqlDatabases` Recipe creates a DB subnet group from `subnetIds`, a DB parameter group, and a single-AZ, encrypted, non-public `db.t3.micro` RDS for MySQL instance with 20 GiB of `gp3` storage. It returns `host`, `port` (`3306`), and `database`, the same values as the Kubernetes Recipe, so one application definition works on every platform.

Resource names are `mysql-<hash>`, where the hash covers the EKS cluster name, the Environment's Kubernetes namespace, and the Radius resource ID. Radius resource IDs repeat across installations, so the namespace keeps apps in different namespaces on the same cluster apart. Names stay the same across redeploys, including from a new Radius installation that targets the same namespace. Two Environments that share a cluster, a namespace, and resource IDs share one database, the same way their Kubernetes resources would collide.

### Network access

The DB instance joins the **EKS cluster security group** and gets no other security group. RDS listens only on port 3306. The cluster security group allows all traffic between its members, but EKS doesn't put every workload in it, so connectivity is a prerequisite you must check.

**Prerequisite:** every pod that connects to the database needs to reach the instance on TCP 3306. Either the pod's traffic leaves through a security group that is a member of the cluster security group, or you add an inbound rule to the cluster security group that allows TCP 3306 from the security group the pod's traffic uses. That security group's outbound rules must also allow TCP 3306. How this applies depends on how the pods run:

| Workload | Security group the pod's traffic uses | What to check |
| --- | --- | --- |
| Managed node group, no launch template security groups | The node's groups, which include the cluster security group | Nothing. |
| Managed node group whose [launch template sets security groups](https://docs.aws.amazon.com/eks/latest/userguide/launch-templates.html#launch-template-security-groups) | Only the launch template's groups. EKS doesn't add the cluster security group | Add the cluster security group to the launch template, or add the inbound rule. |
| Self-managed nodes | The groups you attach to the nodes | Attach the cluster security group, or add the inbound rule. |
| Nodes using VPC CNI [custom networking](https://docs.aws.amazon.com/eks/latest/userguide/cni-custom-network.html) | The groups in the `ENIConfig`, if it lists any | Include the cluster security group in the `ENIConfig`, or add the inbound rule. |
| Fargate | The cluster security group | Nothing, unless the pods use security groups for pods. |
| Pods with [security groups for pods](https://docs.aws.amazon.com/eks/latest/userguide/security-groups-for-pods.html) | Only the groups in the pod's `SecurityGroupPolicy` | Include the cluster security group in the policy, or add the inbound rule for the policy's group. |

The Recipe can't detect these setups. If the workload can't reach port 3306, the deploy still succeeds and the application fails when it connects.

A security group per database, allowing only port 3306 from the cluster, would be tighter and wouldn't depend on cluster security group membership. The Recipe can't create one, because AWS assigns security group IDs, and Radius can't manage AWS resources whose ID AWS assigns. Each deploy creates such a resource and then fails. For status, see [radius-project/radius#13211](https://github.com/radius-project/radius/issues/13211).

### Transport policy

The Recipe maps the resource's `tls` property to the parameter group's `require_secure_transport` (`required` sets `1`, `optional` sets `0`). The instance is not publicly accessible. RDS server certificates are issued by the Amazon RDS certificate authority, so clients that verify the server certificate need the [RDS CA bundle](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html).

### Requirements and limitations

- The `password` must meet the RDS rules: 8 to 41 printable ASCII characters, without `/`, `"`, `@`, or spaces.
- `version` maps to the RDS engine version and the `mysql<version>` parameter group family. Use `8.4`, the default. `5.7` and `8.0` run on [RDS Extended Support](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/extended-support.html), which AWS bills separately.
- Changing `version` after the database exists is not supported. The deploy fails with `createOnlyProperties [/properties/Family] cannot be updated`, and nothing changes in AWS. Change `version` back and deploy again before you delete the app, as described for failed redeploys below. To use another version, create a new `mySqlDatabases` resource and move the data to it.
- The credentials Radius uses for AWS need permission to manage RDS instances, subnet groups, and parameter groups, and to describe the EKS cluster. Delete also needs `rds:CreateDBSnapshot`, because the AWS Cloud Control API takes a final snapshot before it deletes the instance ([radius-project/radius#13565](https://github.com/radius-project/radius/issues/13565)). Without that permission, `rad app delete` retries for about 41 minutes and then fails, and the instance keeps running.
- Delete keeps that final snapshot, named `rds-snapshot-<random>`, and AWS bills its storage until you delete it. The snapshot has the instance's `radapp.io/*` tags. To find it, run `aws rds describe-db-snapshots --db-instance-identifier mysql-<hash> --snapshot-type manual`.
- Redeploying an unchanged app sends updates to AWS. In a live test, they applied the same values and nothing else changed:
  - `ModifyDBInstance`, because RDS never returns `MasterUserPassword` and returns the full engine version (for example `8.4.11`) instead of the major version the Recipe sets. RDS logs a "Reset master credentials" event.
  - `ModifyDBSubnetGroup`, but only when the order of `subnetIds` is different from the order AWS returns.

  The instance update sends only the major version, and RDS then [upgrades an instance to the default minor version](https://docs.aws.amazon.com/AmazonRDS/latest/APIReference/API_ModifyDBInstance.html) if it runs an older one. If AWS makes a later minor version the default, a redeploy can upgrade and restart the database immediately, outside its maintenance window.

  Radius sends these updates because it compares the template with the state AWS returns. For status, see [radius-project/radius#13497](https://github.com/radius-project/radius/issues/13497) (engine version and subnet order) and [radius-project/radius#13455](https://github.com/radius-project/radius/issues/13455) (password).
- A failed deploy can apply part of a change, because Radius updates the parameter group before the DB instance. A `tls` change can fail with `Database instance is not in available state`, after the parameter group has the new `require_secure_transport` value. The `ModifyDBInstance` described above reaches RDS while RDS applies that value. If a `tls` change fails, wait until the DB instance status is `available`, then deploy again.
- After a failed redeploy, Radius loses track of the AWS resources ([radius-project/radius#13065](https://github.com/radius-project/radius/issues/13065)). If you delete the app before a successful deploy, `rad app delete` succeeds but leaves the DB instance, the subnet group, and the parameter group. Deploy the app successfully before you delete it.
- Radius v0.62.0 and earlier copy the `password` into the AWS deployment responses they return, which appear in deployment operation results ([radius-project/radius#13457](https://github.com/radius-project/radius/issues/13457)). The Recipe can't avoid this: RDS needs the password, and the Recipe can only send it through that API.

## Deploying

Create and configure the Environment first. `rad env create` needs the Kubernetes namespace to exist:

```bash
kubectl create namespace <namespace>

rad env create default \
  --kubernetes-namespace <namespace>

rad env update default \
  --aws-account-id <account-id> \
  --aws-region <region>
```

Deploy the Recipe Pack into that existing Environment, supplying only Recipe parameters:

```bash
rad deploy recipe-packs/aws-eks/aws-eks.bicep \
  --environment default \
  --parameters eksClusterName=<cluster-name> \
  --parameters subnetIds=<subnet-id>,<subnet-id> \
  --parameters routesGatewayName=<gateway-name> \
  --parameters containerImagesRegistry=<registry-path>
```

Finally, associate the pack with the Environment:

```bash
rad env update default \
  --recipe-packs aws-eks
```

## Testing

Every pull request deploys and activates this pack on a local cluster, and checks that the pack passes exactly the parameters the MySQL Recipe declares. CI has no AWS account, so the nightly tests don't deploy the AWS Recipes.

The MySQL Recipe was tested by hand against an EKS cluster's subnets and security group: create, unchanged redeploy, and delete through Radius. Delete removes the instance, subnet group, parameter group, and automated backups. It keeps the final snapshot described in [Requirements and limitations](#requirements-and-limitations).

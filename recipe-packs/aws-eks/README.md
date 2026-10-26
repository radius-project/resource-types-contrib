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
| `eksClusterName` | Name of the EKS cluster that runs the application. AWS Recipes attach their services to the cluster security group. |
| `subnetIds` | Comma-separated subnet IDs for AWS Recipes that need a subnet group, for example `subnet-0abc,subnet-0def`. Use subnets in the cluster VPC that span at least two Availability Zones; private subnets are recommended. A JSON array string is also accepted. |
| `routesGatewayName` | Name of the existing Kubernetes Gateway resource that `Radius.Compute/routes` attach to. |
| `routesGatewayNamespace` | Namespace of the Gateway resource for `Radius.Compute/routes`. Defaults to `default`. |
| `containerImagesRegistry` | Registry path (e.g. `ghcr.io/my-org`) that `Radius.Compute/containerImages` pushes built images to. |
| `containerImagesRegistrySecretName` | Name of the Kubernetes Secret holding registry credentials for `Radius.Compute/containerImages`. Optional; leave empty for an unauthenticated registry. |

The AWS region and account come from the Environment's AWS provider, not from the pack.

## MySQL on Amazon RDS

The `Radius.Data/mySqlDatabases` Recipe creates a DB subnet group from `subnetIds`, a DB parameter group, and a single-AZ, encrypted, non-public `db.t3.micro` RDS for MySQL instance with 20 GiB of `gp3` storage. It returns `host`, `port` (`3306`), and `database`, the same values as the Kubernetes Recipe, so one application definition works on every platform.

Resource names are `mysql-<hash>`, where the hash covers the EKS cluster name and the Radius resource ID. Names stay the same across redeploys, and two Radius installations in the same account and region don't collide.

### Network access

The DB instance joins the **EKS cluster security group**. EKS attaches that group to the control plane and to managed node groups, and it allows all traffic between its members, so pods can reach the database. RDS listens only on port 3306. Nodes in self-managed node groups must also be in the cluster security group to connect.

A security group per database, allowing only port 3306 from the cluster, would be tighter. It isn't possible yet: AWS generates security group IDs, and Radius can't yet manage AWS resources whose ID AWS generates, so the group would be recreated on every deploy. The Recipe will switch once Radius supports these resources.

### Transport policy

The Recipe maps the resource's `tls` property to the parameter group's `require_secure_transport` (`required` sets `1`, `optional` sets `0`). The instance is not publicly accessible. RDS server certificates are issued by the Amazon RDS certificate authority, so clients that verify the server certificate need the [RDS CA bundle](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html).

### Requirements and limitations

- The `password` must meet the RDS rules: 8 to 41 printable ASCII characters, without `/`, `"`, `@`, or spaces.
- `version` maps to the RDS engine version and the `mysql<version>` parameter group family. `5.7` runs on RDS Extended Support, which AWS bills separately. Changing `version` after the database exists is not supported.
- The credentials Radius uses for AWS need permission to manage RDS instances, subnet groups, and parameter groups, and to describe the EKS cluster.
- RDS doesn't return `MasterUserPassword` when Radius reads the instance, so every redeploy sends the password to RDS again as an update.

## Deploying

Create and configure the Environment first:

```bash
rad env create default \
  --kubernetes-namespace default

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

Every pull request deploys and activates this pack on a local cluster, and checks that the pack passes exactly the parameters the MySQL Recipe declares. CI has no AWS account yet, so the nightly tests don't deploy the AWS Recipes.

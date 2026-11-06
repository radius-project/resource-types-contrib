# AWS EKS Recipe Pack

This folder contains the **AWS EKS Recipe Pack**, a collection of Recipes that provision Radius Resource Types on AWS, running containers on Amazon Elastic Kubernetes Service (EKS). Deploying the pack creates only a reusable `Radius.Core/recipePacks` resource. Create and configure the target Radius Environment separately, then associate the pack with it.

| File | Description |
| --- | --- |
| `aws-eks.bicep` | Recipe Pack wiring the Bicep recipes for the AWS-provisioned and Kubernetes types. |

## Recipes in this pack

| Resource Type | Kind | Source |
| --- | --- | --- |
| `Radius.Data/mySqlDatabases` | Bicep | `ghcr.io/radius-project/aws-eks-recipes/mysqldatabases` (Amazon RDS for MySQL) |
| `Radius.Compute/containers` | Bicep | `ghcr.io/radius-project/aws-eks-recipes/containers` (Kubernetes Deployment with an EKS Pod Identity role) |
| `Radius.Compute/persistentVolumes` | Bicep | `ghcr.io/radius-project/kube-recipes/persistentvolumes` |
| `Radius.Security/secrets` | Bicep | `ghcr.io/radius-project/kube-recipes/secrets` |
| `Radius.Compute/routes` | Bicep | `ghcr.io/radius-project/kube-recipes/routes` |
| `Radius.Compute/containerImages` | Bicep | `ghcr.io/radius-project/kube-recipes/containerimages` |

The AWS Recipe sources are [`Data/mySqlDatabases/recipes/aws/bicep/aws-rds-mysql.bicep`](../../Data/mySqlDatabases/recipes/aws/bicep/aws-rds-mysql.bicep) and [`Compute/containers/recipes/aws/bicep/aws-eks-containers.bicep`](../../Compute/containers/recipes/aws/bicep/aws-eks-containers.bicep). More AWS-backed Resource Types will be added to this pack.

## Parameters

| Parameter | Description |
| --- | --- |
| `eksClusterName` | Name of the EKS cluster that runs the application. AWS Recipes attach their services to the cluster security group; see [Network access](#network-access) for what the workload needs. |
| `subnetIds` | Comma-separated subnet IDs for AWS Recipes that need a subnet group, for example `subnet-0abc,subnet-0def`. Use subnets in the cluster VPC that span at least two Availability Zones; private subnets are recommended. A JSON array string is also accepted. |
| `routesGatewayName` | Name of the existing Kubernetes Gateway resource that `Radius.Compute/routes` attach to. |
| `routesGatewayNamespace` | Namespace of the Gateway resource for `Radius.Compute/routes`. Defaults to `default`. |
| `containerImagesRegistry` | Registry path (e.g. `ghcr.io/my-org`) that `Radius.Compute/containerImages` pushes built images to. |
| `containerImagesRegistrySecretName` | Name of the Kubernetes Secret holding registry credentials for `Radius.Compute/containerImages`. Optional; leave empty for an unauthenticated registry. |
| `appPermissionsBoundaryArn` | ARN of the IAM managed policy that is the permissions boundary of the roles that `Radius.Compute/containers` creates. The roles go under the policy's IAM path. See [AWS credentials for containers](#aws-credentials-for-containers). |

The AWS region and account come from the Environment's AWS provider, not from the pack.

## MySQL on Amazon RDS

The `Radius.Data/mySqlDatabases` Recipe creates a DB subnet group from `subnetIds`, a DB parameter group, and a single-AZ, encrypted, non-public `db.t3.micro` RDS for MySQL instance with 20 GiB of `gp3` storage. It returns `host`, `port` (`3306`), and `database`, the same values as the Kubernetes Recipe, so one application definition works on every platform.

Resource names are `mysql-<hash>`, where the hash covers the EKS cluster name, the Environment's Kubernetes namespace, and the Radius resource ID. Radius resource IDs repeat across installations, so the namespace keeps apps in different namespaces on the same cluster apart. Names stay the same across redeploys, including from a new Radius installation that targets the same namespace. Two Environments that share a cluster, a namespace, and resource IDs share one database, the same way their Kubernetes resources would collide. The parameter group name also ends with the version without the dot, for example `mysql-<hash>-84`, because AWS can't change a parameter group's family. A group left behind by a failed deploy doesn't block a deploy of another version, but Radius doesn't track it ([radius-project/radius#13065](https://github.com/radius-project/radius/issues/13065)), so delete it yourself. To list a resource's parameter groups, run the command below. Any group that the DB instance doesn't use is left over.

```bash
aws resourcegroupstaggingapi get-resources --resource-type-filters rds:pg \
  --tag-filters Key=radapp.io/resource,Values=<Radius resource ID>
```

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

- `database`, `username`, and `password` must meet the RDS for MySQL rules. The Recipe checks them before it creates any AWS resource, and a failed check lists every invalid value:
  - `database`: 1 to 64 characters, and `username`: 1 to 32 characters. Both start with an ASCII letter, contain only ASCII letters, digits, and underscores, and can't be a word RDS reserves, in any case. RDS accepts other letters in a database name, but the Recipe rejects them. RDS reserves most MySQL reserved words, such as `select` and `table`, and `innodb`, `mysql`, `rdsadmin`, and `rdsrepladmin`. The Kubernetes Recipe accepts some values that the AWS Recipe rejects, such as `app-db`.
  - `password`: 8 to 41 printable ASCII characters, without `/`, `"`, `@`, or spaces.
- `version` maps to the RDS engine version and the `mysql<version>` parameter group family. Use `8.4`, the default. `5.7` and `8.0` run on [RDS Extended Support](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/extended-support.html), which AWS bills separately.
- Changing `version` after the database exists is not supported. The deploy fails when RDS updates the DB instance, with `The AllowMajorVersionUpgrade flag must be present when upgrading to a new major version` for a later version, or `Cannot upgrade mysql from <current> to <requested>` for an earlier one. The DB instance doesn't change, but the Recipe has already created a parameter group for the requested version, and it stays in AWS. Change `version` back and deploy again before you delete the app, as described for failed redeploys below, then delete that parameter group yourself. It has the `radapp.io/resource` tag with the Radius resource ID. To use another version, create a new `mySqlDatabases` resource and move the data to it.
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

## AWS credentials for containers

The `Radius.Compute/containers` Recipe deploys the same Kubernetes resources as the Kubernetes Recipe. It also gives each containers resource its own AWS identity through [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html):

1. An IAM role named `radius-app-<name>-<hash>`, with the permissions boundary, under the boundary's IAM path. For example, the boundary `arn:aws:iam::123456789012:policy/radius/apps/my-env/my-env-boundary` puts the roles under `/radius/apps/my-env/`. The hash covers that path, the region, the EKS cluster, the Environment's Kubernetes namespace, and the Radius resource ID, because IAM role names are unique per account and Radius resource IDs repeat across installations. Its trust policy allows only the Pod Identity service, for this cluster, namespace, and service account.
2. A Pod Identity association between the role and a service account named `radius-app-<name>`.
3. The service account, and the Deployment running as it. The Deployment waits for the association, because a pod started before it gets no credentials.

EKS gives the pods short-lived credentials for the role. No access keys are stored. An [AWS SDK version that supports EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-minimum-sdk.html) finds them through its default credential chain, before the node's instance role. An older SDK may not use Pod Identity. Depending on the SDK, it may fail to find credentials, or use the node's instance role if the pod can reach the instance metadata service (IMDS).

The role's permissions come from connections. An AWS Resource Type whose resources apps reach with IAM credentials declares a read-only `awsIamPolicy` string property. Its value is a JSON IAM policy document with a `Statement` array, scoped to the resource its Recipe created. The containers Recipe parses that string, so an object value fails the deploy. It copies the statements of every connected resource into one inline policy named `connections`, and doesn't turn `awsIamPolicy` into an environment variable. See [Contributing Resource Types and Recipes](../../docs/contributing/contributing-resource-types-recipes.md#aws-iam-permissions-for-connected-containers). A role without such connections gets a policy that denies everything. Removing a connection removes its statements on the next deploy, and running pods see policy changes within seconds.

The boundary caps what any statement can grant. Create it before you deploy the pack. Because the roles share the boundary's path, the credentials Radius uses can be limited to roles under that path that have a boundary from the same path. Radius Canvas creates the boundary and that limit during environment setup. The pack requires the boundary. For containers that need no AWS credentials, use the Kubernetes Recipe.

### Container requirements and limitations

- The cluster needs the [EKS Pod Identity Agent](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html) add-on, which EKS Auto Mode includes. Without it, the deploy succeeds and pods get no credentials. Pod Identity works only for Linux pods on EC2 nodes. Pods on Fargate or Windows nodes get no credentials.
- The credentials Radius uses for AWS need to create, read, update, tag, and delete roles under the boundary's path with the boundary attached, pass them to `pods.eks.amazonaws.com`, and manage Pod Identity associations. AWS Cloud Control also reads each role by name without its path, so they need `iam:GetRole` on `role/radius-app-*` too.
- AWS can't move a role to another path. If you point the pack at a boundary under another path, the next deploy creates a new role for each containers resource and moves its association to it. Radius doesn't delete the old roles ([radius-project/radius#13065](https://github.com/radius-project/radius/issues/13065)). Without an association, no pod can assume them, but they keep their permissions until you delete them. To list them, run `aws iam list-roles --path-prefix <old path>`. Changing the boundary's name or content under the same path keeps the roles.
- Each containers resource uses one role and one association, even without AWS connections. That keeps the set of resources the Recipe creates the same across deploys. Radius doesn't delete resources that a Recipe stops creating, so a role created only for AWS connections would be left behind, with its permissions, when the last connection is removed. Default quotas allow 1,000 roles per account and 5,000 associations per cluster.
- Pod Identity doesn't isolate pods from the node's instance role. Unless the nodes restrict IMDS, a pod can still get the node role's credentials, and [AWS says](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html) it may reach the credentials of other pods' roles on the same node. Pods with `hostNetwork: true` always reach IMDS. To keep pods to their own role, require IMDSv2 with a hop limit of 1 on the nodes and don't run app pods on the host network.
- The policy statements of one containers resource are limited to 10,000 characters of compact JSON. The deploy fails above that.
- A deploy fails before the Recipe creates or changes any resource when `appPermissionsBoundaryArn` isn't the ARN of an IAM policy, including when it is empty. The Recipe can't skip the identity, because Radius doesn't delete resources that a Recipe stops creating, so a skipped role would keep its permissions.
- Radius v0.62.0 and earlier fail when they redeploy a Pod Identity association.

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
  --parameters containerImagesRegistry=<registry-path> \
  --parameters appPermissionsBoundaryArn=<boundary-arn>
```

Finally, associate the pack with the Environment:

```bash
rad env update default \
  --recipe-packs aws-eks
```

## Testing

Every pull request deploys and activates this pack on a local cluster, and checks that the pack passes exactly the parameters the MySQL Recipe declares. It also deploys the MySQL Recipe from the pull request with invalid values and checks that they fail before any AWS call. CI has no AWS account, so the nightly tests don't deploy the AWS Recipes.

For the containers Recipe, CI compiles it and checks that the pack passes exactly the parameters it declares. It also checks that the role takes the boundary and its path, and that the trust policy, the association, and the pods use the same service account.

The IAM limits that Radius Canvas sets up for these roles were tested by hand through AWS Cloud Control, as a deploy role with those limits. Creating, updating, and deleting a role with the boundary under its path, and creating and deleting a Pod Identity association for it, succeeded. These were refused: creating a role without the boundary, with another boundary, or under another path; removing or replacing the boundary; and changing or deleting the boundary policy.

This version of the Recipe hasn't been deployed through Radius, so pod credentials and the failure for an invalid `appPermissionsBoundaryArn` are untested. An earlier prototype was tested by hand on an EKS cluster through a Radius edge build: create, policy changes reaching a running pod, and delete.

The MySQL Recipe was tested by hand against an EKS cluster's subnets and security group: create, unchanged redeploy, and delete through Radius. Delete removes the instance, subnet group, parameter group, and automated backups. It keeps the final snapshot described in [Requirements and limitations](#requirements-and-limitations).

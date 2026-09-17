# Velloxx SkillPool — Terraform Infrastructure as Code (IaC)

This directory provides the complete, production-grade Terraform implementation of the **Velloxx SkillPool** architecture, translating and replacing the procedural bash scripts (`skillpool-build.sh` and `skillpool-teardown.sh`) into a declarative, state-managed Infrastructure as Code (IaC) codebase.

---

## ⚡ Build vs. Teardown Paradigm

| Operation | Shell Scripts (`.sh`) | Terraform (`.tf`) | Advantage of Terraform |
|---|---|---|---|
| **Build** | `./skillpool-build.sh` (1,184 lines of procedural AWS CLI calls across 12 phases) | `terraform apply` (Evaluated via `terraform plan`) | Declarative state management, parallel resource creation, idempotency, drift detection. |
| **Teardown** | `./skillpool-teardown.sh` (368 lines with manual reverse ordering, 45s ENI sleeps) | `terraform destroy` (Evaluated via `terraform plan -destroy`) | Automatic Directed Acyclic Graph (DAG) dependency inversion. Terraform calculates the exact deletion order and handles ENI lifecycle natively. |

---

## 🛠️ The 6 Defects Solved Declaratively

1. **Subnetless VPC Endpoints:** Solved in `vpc.tf` by explicitly passing `aws_subnet.app[*].id` to `aws_vpc_endpoint.interfaces`.
2. **Endpoint SG Missing Port 443 Ingress:** Solved in `security_groups.tf` via `aws_security_group_rule.endpoint_ingress_from_ecs`.
3. **Log Group Race Condition:** Solved in `compute.tf` by declaring `aws_cloudwatch_log_group.ecs` and setting `depends_on = [aws_cloudwatch_log_group.ecs]` on the task definition.
4. **Secrets Manager Wildcard ARN:** Solved in `iam.tf` by scoping policy resources to `arn:aws:secretsmanager:...:secret:${var.project}-db-*`.
5. **ECR Permissions:** Solved in `iam.tf` by attaching `AmazonECSTaskExecutionRolePolicy` to the execution role.
6. **S3 Prefix List Egress Scope (ECR Layer Pulls):** Solved in `security_groups.tf` using dynamic data lookup `data.aws_ec2_managed_prefix_list.s3` to allow outbound 443 to the AWS S3 IP range without opening `0.0.0.0/0`.

---

## 📋 File Layout

```text
terraform/
├── versions.tf               # Terraform and AWS provider definitions
├── variables.tf              # Configurable project inputs & defaults
├── terraform.tfvars.example  # Example parameter overrides
├── main.tf                   # Data sources (caller identity, AZs, S3 prefix list) and locals
├── vpc.tf                    # 3-tier VPC, subnets, IGW, route tables, endpoints
├── security_groups.tf        # Decoupled security groups and cross-tier rules
├── iam.tf                    # Task/execution roles and 4 functional groups
├── storage.tf                # S3 media & logs buckets with policies and encryption
├── database.tf               # Secrets Manager and RDS MySQL instance
├── compute.tf                # ECR, CloudWatch log group, ECS cluster & service
├── loadbalancer.tf           # Application Load Balancer, target group, listener
├── cloudfront.tf             # Dual-origin CloudFront CDN with OAC and S3 policy
├── audit.tf                  # CloudTrail multi-region trail & Athena workgroup
├── outputs.tf                # Exported connection URLs and resource IDs
└── README.md                 # This operational documentation
```

---

## 🚀 Usage Instructions

### 1. Initialize
Downloads the AWS and Random providers and configures the local backend:
```bash
terraform init
```

### 2. Validate
Validates HCL syntax and internal references:
```bash
terraform validate
```

### 3. Simulate Build (Dry Run)
Simulates creating all 80 resources without applying changes or incurring cloud cost:
```bash
terraform plan
```

### 4. Deploy (Build)
Applies the configuration and provisions the real AWS infrastructure:
```bash
terraform apply
```

### 5. Simulate Teardown (Dry Run)
Inspects the resources marked for destruction in reverse dependency order:
```bash
terraform plan -destroy
```

### 6. Full Teardown
Destroys all managed resources in reverse dependency order automatically:
```bash
terraform destroy
```

---

## 🛑 Targeted & Selective Teardown Workflows

Just like the original `skillpool-teardown.sh` script, Terraform supports granular teardown workflows to optimize costs and safeguard data:

### A. Endpoints-Only Teardown (Stop the Meter Between Sessions)
The 4 VPC interface endpoints account for ~47% of idle POC runtime costs (~$56/mo). You can tear down **only** the interface endpoints without destroying the rest of the VPC, database, or compute:

```bash
# Option 1: Via variable toggle (Recommended)
terraform apply -var="enable_interface_endpoints=false"

# Option 2: Via targeted destroy
terraform destroy -target=aws_vpc_endpoint.interfaces
```

To bring the endpoints back when resuming work:
```bash
terraform apply -var="enable_interface_endpoints=true"
```

### B. Keep-Data Teardown (Preserve S3 Data & Take Final RDS Snapshot)
If you want to tear down infrastructure while keeping persistent candidate media and taking an automated snapshot of the MySQL database:

```bash
terraform destroy -var="skip_final_snapshot=false" -var="force_destroy_buckets=false"
```
* **RDS:** A final DB snapshot named `vellox-skillpool-db-final-snapshot` is created before deletion.
* **S3:** Prevents accidental deletion of non-empty buckets.

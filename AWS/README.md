# AWS Cloud Architecture Projects

This directory contains production-style cloud infrastructure solutions, automated deployments, and architectural case studies built on Amazon Web Services (AWS).

---

## 📂 Projects

| Project | Description | Key Services | Documentation |
|---|---|---|---|
| **Velloxx SkillPool** | Zero-trust, 3-tier containerized web architecture with NAT-free VPC endpoints, dual-origin CloudFront edge routing, and serverless Athena audit logging. | AWS ECS Fargate, RDS MySQL, CloudFront, VPC Endpoints, S3, CloudTrail, Athena | [Case Study & Implementation](./vellox-skillpool/README.md) |

---

## 🛠️ Core AWS Competencies Demonstrated

* **Secure Networking & Segmentation:** Multi-tier VPC design, public/private/isolated subnets, private VPC Interface & Gateway Endpoints eliminating NAT Gateway reliance, strictly scoped security groups using AWS-managed prefix lists.
* **Serverless & Container Orchestration:** Docker containerization, AWS ECR private registries, Amazon ECS Fargate deployment with fine-grained IAM task and execution roles.
* **Data Tier & Persistence:** Amazon RDS MySQL configuration, subnet isolation, database secrets rotation with AWS Secrets Manager, zero-data-loss backup and cutover planning.
* **Edge Routing & Acceleration:** Amazon CloudFront dual-origin distributions, Origin Access Control (OAC), path-based cache behaviors, TLS termination.
* **Security, Auditing & Compliance:** AWS CloudTrail S3 data events, in-place analytics with Amazon Athena, IAM least-privilege matrix across functional teams.
* **Cost Engineering & Governance:** Comprehensive cloud cost modeling (POC actuals vs. HA production), AWS Budgets, and Cost Anomaly Detection.

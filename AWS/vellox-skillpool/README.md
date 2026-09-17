# Velloxx SkillPool — Secure, Segmented Cloud Architecture on AWS

![AWS](https://img.shields.io/badge/AWS-Cloud-orange?logo=amazon-aws)
![ECS Fargate](https://img.shields.io/badge/Compute-ECS%20Fargate-blue)
![Architecture](https://img.shields.io/badge/Design-3--Tier%20Zero--Trust-green)
![Cost-Optimized](https://img.shields.io/badge/Networking-NAT--Free%20VPC-blueviolet)

A production-grade, containerized cloud infrastructure designed for high-security, media-intensive web applications. This project demonstrates multi-tier network segmentation, serverless container orchestration, edge caching, zero-NAT private networking, and in-place audit capabilities on AWS.

---

## 📌 Executive Summary & Problem Overview

Modern SaaS platforms managing sensitive talent databases and rich candidate multimedia face conflicting operational goals: delivering large volumes of dynamic search queries and heavy media assets without exposing backend systems, inflating egress costs, or creating administrative overhead.

### Key Business & Security Drivers:
* **Strict Architecture Segmentation:** Absolute isolation between public entry points, application runtimes, and persistent data tiers.
* **Separation of Organizational Duties:** Independent access boundaries for application developers, database engineers, media administrators, and compliance auditors.
* **In-Place Audit Compliance:** All access to stored assets must be immutably tracked and immediately queryable by auditors without complex ETL pipelines or data duplication.
* **Minimal Operational Overhead:** Avoiding the maintenance burdens of OS patching, custom AMIs, or self-hosted container clusters.
* **Cost Efficiency:** Designing with strict cost discipline, avoiding default cloud networking traps (e.g., idle NAT Gateways).

---

## 🏛️ Architectural Solution

To satisfy zero-trust boundaries and operational simplicity, the system was designed around a **Serverless-First, Three-Tier VPC Architecture**.

```
                           [ Public Internet ]
                                    │
                         [ CloudFront Edge CDN ]
                                    │
               ┌────────────────────┴────────────────────┐
               │                                         │
        (Default / API)                             (/media/*)
               ▼                                         ▼
   [ Application Load Balancer ]               [ S3 Media Bucket ]
          (Public Subnets)                      (Restricted via OAC)
               │                                         ▲
               ▼                                         │ (Task Role)
    [ ECS Fargate Service ] ─────────────────────────────┘
    (Private App Subnets)
               │ (Port 3306)
               ▼
     [ RDS MySQL Database ]
    (Isolated Data Subnets)
```

### Core Architecture Highlights

1. **Edge-Terminated Content Delivery (Dual-Origin CloudFront):**
   * Dynamic search requests and APIs route to an Application Load Balancer (ALB).
   * Static assets and candidate multimedia route directly to Amazon S3 through **Origin Access Control (OAC)** under a single TLS certificate.
   * **Result:** Application containers never touch media download traffic, preventing compute bottlenecks.

2. **Private-by-Default, NAT-Free Networking:**
   * Compute tasks (ECS Fargate) and data (RDS MySQL) run inside private subnets without public IPs or outbound internet access.
   * Instead of deploying an expensive NAT Gateway (~$32+/month + data processing), outbound connectivity to AWS APIs is established entirely via **VPC Endpoints**:
     * **S3 Gateway Endpoint** (free) for media transfers and ECR container image layers.
     * **Interface Endpoints (PrivateLink)** for ECR API, ECR Docker, CloudWatch Logs, and AWS Secrets Manager.
   * **Result:** Complete protection against external data exfiltration.

3. **In-Place Compliance & Auditing:**
   * **AWS CloudTrail** captures object-level S3 data events on the media store into an isolated audit log bucket.
   * **Amazon Athena** queries CloudTrail logs in place using standard SQL without provisioning instances or moving log data.

4. **Least-Privilege IAM Boundaries:**
   * Four segregated access domains: Multimedia Specialists, Application DevOps, Database Administrators, and Auditors.
   * Runtime secrets (database credentials) are pulled dynamically from AWS Secrets Manager directly into task memory.

---

## 🛠️ Engineering Challenges & Debugging War Stories

The validation phase was deliberately rigorous. Enforcing strict network isolation surfaced non-obvious cloud networking behaviors:

* **The S3 Prefix List Egress Trap:**
  * *Symptom:* ECS tasks timed out with `CannotPullContainerError` when pulling images from ECR.
  * *Root Cause:* ECR stores image layers in AWS-managed S3 buckets. While an S3 Gateway Endpoint routes this traffic internally, it **does not rewrite destination IPs** to the VPC CIDR. An outbound security group rule restricted to the VPC CIDR silently dropped traffic bound for S3's public IP range.
  * *Solution:* Rather than opening wide egress (`0.0.0.0/0`), outbound traffic was strictly scoped to the **AWS-Managed S3 Prefix List**.
* **Subnetless Interface Endpoints:**
  * *Symptom:* Container execution failed with `no such host` resolving AWS endpoints.
  * *Root Cause:* In automated VPC provisioning, declaring Availability Zones without explicitly assigning subnets creates an endpoint with no elastic network interfaces (ENIs) inside the VPC.
* **IAM Wildcard Suffix Matching:**
  * Secrets Manager appends a pseudo-random 6-character string to secret ARNs. Exact-name resource constraints in IAM policies failed until wildcards (`*-db-*`) were applied.
* **CloudWatch Log Group Pre-Creation:**
  * ECS Fargate does not automatically create log groups, and the default execution role policy does not include `logs:CreateLogGroup`. Pre-creating `/ecs/vellox-skillpool` resolved the task initialization failure.

---

## 💰 Cost Analysis & Real-World Economics

A critical outcome of this project was modeling the contrast between a **Validation POC** and an **Auto-Scaling Production Deployment**:

| Tier | Measured POC | Production Model (High Availability) |
|---|---|---|
| **Topology** | Single-AZ, 1 Task | Multi-AZ (2 AZs), 4–12 Auto-Scaling Tasks |
| **Database** | Single-AZ `db.t4g.micro` | Multi-AZ `db.m6g.large` + Read Replica |
| **Security / Edge**| CloudFront + Basic SG | CloudFront + AWS WAF (Managed Rule Sets) |
| **Run Rate** | **~$2.48 / day (~$75/mo)** | **~$1,487/mo (On-Demand) → ~$1,179/mo (Optimized)** |

### Key Cost Takeaways:
* **The "Container Fallacy":** In a media-heavy application, compute (ECS Fargate) accounted for only ~15% of the production bill. Content Delivery (CloudFront) and the Database estate represented over **70%** of monthly spend.
* **Interface Endpoints vs. NAT Gateways:** In small deployments, interface endpoints represent the single largest networking line item. However, they provide strict isolation without an open route to the internet.

---

## 🔄 Migration Strategy

To transition from legacy environments with near-zero downtime:
1. **Parallel Run:** Provision the full AWS VPC, ECS, and RDS stack alongside the existing application.
2. **Data Seeding & Sync:** Perform database dump/restore and media synchronization (`aws s3 sync`) via internal VPC access.
3. **Scheduled Write-Freeze & Cutover:** A short 15–30 minute write-freeze allows a final delta sync, followed by a DNS update pointing traffic to the CloudFront distribution with pre-lowered TTLs.
4. **Immediate Rollback Capability:** Because the legacy system remains intact during a defined holding window, rollback is simply a DNS reversal.

---

## 🚀 What I Would Do Differently (Next Steps)

* **Infrastructure as Code (IaC):** While bash automation scripts provided end-to-end transparency for this POC, transitioning to **Terraform / OpenTofu** is necessary for robust state management, drift detection, and modular reusability.
* **Graviton Compute Migration:** Rebuilding containers for `arm64` architecture to run on AWS Graviton-based Fargate instances would immediately lower compute unit costs by ~20%.
* **Aggressive Edge Caching:** Increasing the CloudFront cache hit ratio from 85% to 92%+ using content-hashed asset filenames would eliminate redundant origin calls and save ~$60/month at scale.
* **Automated CI/CD Pipeline:** Implementing GitHub Actions with CodeDeploy for canary or blue/green task deployments.

---

## 📂 Project Assets

* [`SCRIPTS-README.md`](./SCRIPTS-README.md) — Comprehensive guide to the CLI deployment phases, prerequisites, and operational tips.
* [`skillpool-build.sh`](./skillpool-build.sh) — 12-phase automated idempotent provisioning script using AWS CLI.
* [`skillpool-teardown.sh`](./skillpool-teardown.sh) — Clean teardown automation supporting reverse-dependency resource destruction.

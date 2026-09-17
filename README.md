# Cloud Projects Portfolio

Welcome to my Cloud Engineering & Solutions Architecture portfolio. This repository documents real-world, production-ready cloud infrastructure implementations, automated deployment pipelines, architectural designs, and cost engineering analyses across **Amazon Web Services (AWS)** and **Microsoft Azure**.

---

## 🚀 Projects Overview

| Provider | Project | Architecture Summary | Documentation & Code |
|:---|:---|:---|:---:|
| <img src="https://skillicons.dev/icons?i=aws" width="24" height="24" alt="AWS"/> **AWS** | **Velloxx SkillPool** | Zero-trust 3-tier containerized web architecture on ECS Fargate & RDS MySQL. Features zero-NAT private networking via VPC Endpoints, dual-origin CloudFront CDN, and serverless in-place audit logging with CloudTrail & Athena. | [View Project](./AWS/vellox-skillpool/README.md) |
| <img src="https://skillicons.dev/icons?i=azure" width="24" height="24" alt="Azure"/> **Azure** | *Multi-tier Enterprise Architecture* | *(In progress / Upcoming)* | Coming Soon |

---

## 🏛️ Core Architectural Principles

Across all projects in this portfolio, the design decisions follow four fundamental principles:

1. **Defense-in-Depth & Zero-Trust Isolation:**
   Workloads run private-by-default with no direct internet access. Ingress is tightly filtered at the edge (CDN/WAF), and internal access across tiers is chained by security group references and IAM least-privilege policies rather than static IP CIDRs.

2. **Serverless-First & Container Orchestration:**
   Minimizing operational toil by utilizing managed container runtimes (ECS Fargate) and managed databases (RDS). No operating systems to patch, no AMIs to maintain.

3. **Cost Optimization by Design:**
   Treating cloud economics as an architectural requirement rather than an afterthought. Analyzing traffic models, eliminating idle networking charges (e.g. eliminating NAT Gateway costs using targeted VPC Endpoints), leveraging edge caching, and evaluating commitment discounts (Savings Plans / Reserved Instances).

4. **Observability & In-Place Compliance:**
   Full-lifecycle logging and telemetry (CloudWatch, CloudTrail, Athena) designed so security teams and auditors can query operational data in place without brittle ETL pipelines or redundant data duplication.

---

## 🛠️ Technology Stack

* **Cloud Platforms:** Amazon Web Services (AWS), Microsoft Azure
* **Compute & Containers:** AWS ECS (Fargate), Docker, Amazon ECR
* **Networking & Edge:** Amazon VPC, Application Load Balancers (ALB), VPC Endpoints (PrivateLink & Gateway), Amazon CloudFront (OAC)
* **Databases & Storage:** Amazon RDS (MySQL), Amazon S3
* **Security & Governance:** AWS IAM, AWS Secrets Manager, AWS KMS, AWS Budgets
* **Audit & Observability:** AWS CloudTrail (Data Events), Amazon Athena, Amazon CloudWatch
* **Infrastructure Automation:** Bash CLI Automation, Docker, (Terraform / OpenTofu roadmap)

---

## 👤 Author

**Elorm Selormey**  
*Cloud Engineer & Solutions Architect*  
* [GitHub Profile](https://github.com/ElormSelormey)

# Assessment: Inherited Codebase Review

This document covers every issue and decision found across the Dockerfile, CI/CD pipeline, and Terraform configuration. Each finding includes a classification, an evaluation of the contractor's reasoning, and documentation of what was done and why.

Classifications used:
- **Bug** - something broken that causes incorrect or unsafe behavior
- **Intentional Trade-off** - a conscious decision with documented reasoning, even if disagreed with
- **Needs Improvement** - not broken, but not production-ready

---

## Dockerfile

---

### Finding 1 - scikit-learn version incompatible with model

**What was found:**
After building the container and confirming `/health` and `/ready` returned 200, every call to `/predict` returned a 500 Internal Server Error. The traceback showed:

```
AttributeError: 'LogisticRegression' object has no attribute 'multi_class'
```

To diagnose the root cause, the model file was inspected directly by loading it with pickle and printing the classifier's `__dict__`. The output included:

```
InconsistentVersionWarning: Trying to unpickle estimator LogisticRegression from version 1.8.0
```

This confirmed the model was serialized with scikit-learn **1.8.0**, but `requirements.txt` pinned **1.6.1**. In 1.8.0, `multi_class` was removed from `LogisticRegression.__init__` and therefore never stored in the pickle. Versions 1.5 and 1.6 still access `self.multi_class` in `predict_proba`, causing the crash on every prediction request.

**Classification: Bug**
The core endpoint of the application was completely non-functional. This is not a trade-off - it is a broken deployment.

**Contractor's reasoning:**
DECISIONS.md says: *"Pinned to 1.6.1 for stability. It's a well-known release with good community support. Newer versions tend to have breaking API changes so I'm keeping this locked down."*

The instinct to pin is correct. The chosen version is wrong. The contractor either upgraded scikit-learn without re-validating against the serialized model, or copied a version number without verifying compatibility.

**What was done:**
Changed `scikit-learn==1.6.1` to `scikit-learn==1.8.0` in `requirements.txt` to match the version the model was serialized with. Rebuilt the container and confirmed all three endpoints return correct responses.

---

### Finding 2 - No `.dockerignore` file

**What was found:**
No `.dockerignore` file existed in the repo. With `COPY . .` in the Dockerfile, every file gets copied into the image - including `.git` (full commit history), `__pycache__`, test files, Terraform configs, markdown docs, and any local virtual environments. This bloats the image size and leaks sensitive repository metadata into the production container. Any `.env` file present would also be copied, potentially exposing secrets.

**Classification: Needs Improvement**
The app still works without it. This is not a deliberate trade-off - it was simply never done.

**Contractor's reasoning:**
Not mentioned in DECISIONS.md at all. No rationale, no acknowledgment. It was simply skipped.

**What was done:**
Created a `.dockerignore` file excluding `.git`, `.github`, `__pycache__`, `*.pyc`, `.pytest_cache`, `.env`, `*.md`, `terraform/`, and `tests/`. The production runtime image only needs `app/`, `models/`, and `requirements.txt` to run. This reduces image size and ensures no repository metadata or infrastructure code ends up inside the container.

---

### Finding 3 - Full Python base image used unnecessarily

**What was found:**
The Dockerfile used `FROM python:3.12` - the full Python base image at roughly 1GB. `python:3.12-slim` is approximately 130MB, less than 15% of that size. A smaller image means faster CI builds, faster deployments, a smaller attack surface, and lower storage costs in a container registry.

**Classification: Needs Improvement**
The app works either way. However the contractor's justification for keeping the full image is factually incorrect, which makes this more than a style preference.

**Contractor's reasoning:**
DECISIONS.md says: *"Slim was causing issues with some native dependencies during pip install. The full image just works and the size difference isn't significant enough to justify debugging slim compatibility issues."*

Both claims were tested and found to be wrong. `python:3.12-slim` builds and runs successfully with no dependency errors. The size difference (~870MB) is also not insignificant - it directly impacts build times, registry costs, and attack surface.

**What was done:**
Switched to `FROM python:3.12-slim`. Rebuilt the image and verified all three endpoints return correct responses. No dependency issues. The contractor's concern did not materialize.

---

### Finding 4 - HEALTHCHECK uses wrong endpoint

**What was found:**
The Dockerfile HEALTHCHECK was configured against `/health`. The contractor's rationale was that both `/health` and `/ready` return 200 so either works. This is factually incorrect.

Looking at `app/main.py`:
- `/health` is a **liveness probe** - returns 200 immediately as long as the server process is running, regardless of whether the model is loaded
- `/ready` is a **readiness probe** - returns 503 until the model is fully loaded, then 200

This means Docker marks the container as healthy the moment uvicorn starts, before the ML model has finished loading. Any traffic routed to the container during that window receives a 503.

**Classification: Bug**
The contractor made a factually incorrect statement to justify their decision. The consequence is real: in a production environment with an orchestrator routing traffic based on health status, this causes live request failures during startup.

**Contractor's reasoning:**
DECISIONS.md says: *"Both `/health` and `/ready` return 200 so either works - went with `/health` since it's the standard name."*

This is wrong. `/ready` does not always return 200 - it returns 503 until the model is loaded. The contractor either did not read the code or did not test the readiness endpoint under load.

**What was done:**
Changed the HEALTHCHECK in the Dockerfile to use `/ready`. This ensures Docker only marks the container healthy once the model is fully loaded and predictions can actually be served.

---

### Finding 5 - `apt-get upgrade` added for OS security patches

**What was found:**
The base image contained outdated OS packages with known vulnerabilities (discovered during the Trivy security scan - see Finding 8). No OS package upgrade step was present in the Dockerfile.

**Classification: Needs Improvement**

**Contractor's reasoning:**
Not mentioned in DECISIONS.md.

**What was done:**
Added `RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*` to the Dockerfile immediately after the `FROM` line. This ensures the image always has the latest OS security patches applied at build time. The `rm -rf /var/lib/apt/lists/*` cleans up the package cache to keep the image size minimal.

---

## CI/CD Pipeline

---

### Finding 6 - Deploy job does not depend on test or security-scan

**What was found:**
The `deploy` job in `ci.yml` had `needs: [build]` - it only waited for the build to complete. `test` and `security-scan` ran in parallel with `deploy`, meaning a deployment could succeed even if tests failed or a critical vulnerability was found. The pipeline appeared to have safety gates but they had no effect on deployment.

**Classification: Bug**
The entire purpose of having test and security scan jobs is to prevent broken or insecure code from reaching production. A deploy job that doesn't wait for them renders those jobs meaningless.

**Contractor's reasoning:**
DECISIONS.md documents the pipeline structure - *"Split the pipeline into separate jobs for build, test, security scan, and deploy"* - but says nothing about dependency order. The omission appears to be an oversight rather than a deliberate choice.

**What was done:**
Changed `needs: [build]` to `needs: [build, test, security-scan]`. The deploy job now only runs after all three upstream jobs complete successfully.

---

### Finding 7 - Deploy job was a TODO stub

**What was found:**
The deploy job contained only:
```yaml
run: |
  echo "TODO: Implement deployment"
  echo "This step should SSH into the EC2 instance and deploy the new container"
```
The CI pipeline had no actual deployment capability. A CD pipeline that does not deliver software is not a CD pipeline.

**Classification: Bug**
The pipeline was presented as a complete CI/CD setup. The core CD function was entirely missing.

**Contractor's reasoning:**
DECISIONS.md says: *"The deploy job is stubbed out - needs to be wired up to the actual infrastructure."* The contractor acknowledged it was incomplete but left it unfinished with no timeline or reasoning.

**What was done:**
Implemented a full SSH-based deploy job using `appleboy/ssh-action@v1.0.3`. The job:
- Only runs on pushes to `main`
- Requires `build`, `test`, and `security-scan` to pass first
- SSHs into the EC2 instance using a private key stored as a GitHub Actions secret
- Pulls the latest Docker image from GHCR
- Stops and removes the old container gracefully
- Starts the new container with the updated image

A real EC2 instance was provisioned using Terraform, `SSH_PRIVATE_KEY` and `EC2_HOST` were configured as GitHub repository secrets, and the full pipeline was verified end-to-end - a push to `main` builds, tests, scans, and deploys to a live server returning correct predictions.

---

### Finding 8 - Image tag uses uppercase, breaking container registry push

**What was found:**
The CI pipeline used `IMAGE_NAME: ${{ github.repository }}` directly in the image tag. GitHub repository names can contain uppercase letters, but container registry tags must be all lowercase. This caused the build job to fail with:

```
ERROR: invalid tag "ghcr.io/YonatanBiton/artac-devops-challenge-v2:latest": repository name must be lowercase
```

The pipeline had never successfully pushed an image to GHCR.

**Classification: Bug**
The pipeline was broken from day one for any repository owner with uppercase letters in their GitHub username.

**Contractor's reasoning:**
Not mentioned in DECISIONS.md. The contractor did not account for the fact that GitHub usernames are case-sensitive but container registry tags are not.

**What was done:**
Added a lowercase step to every job that references the image name:
```yaml
- name: Lowercase image name
  run: echo "IMAGE_NAME=$(echo ${{ env.IMAGE_NAME }} | tr '[:upper:]' '[:lower:]')" >> $GITHUB_ENV
```
This step was added to `build`, `security-scan`, and `deploy` jobs.

---

### Finding 9 - Missing `packages: write` permission

**What was found:**
The build job had no permissions block, meaning the `GITHUB_TOKEN` defaulted to read-only access. Attempting to push to GitHub Container Registry failed with:

```
denied: installation not allowed to Create organization package
```

The pipeline had no ability to publish container images.

**Classification: Bug**
The pipeline was never able to successfully complete its primary function - building and pushing a Docker image.

**Contractor's reasoning:**
Not mentioned in DECISIONS.md. The CI pipeline was never fully validated end-to-end.

**What was done:**
Added an explicit permissions block to the `build` job:
```yaml
permissions:
  contents: read
  packages: write
```

---

### Finding 10 - Trivy security scan configured to suppress results

**What was found:**
The Trivy scan was configured with `ignore-unfixed: true` and `severity: CRITICAL` only. This means:
- Vulnerabilities with no available fix are completely invisible
- HIGH severity vulnerabilities are silently ignored
- The scan was tuned to pass, not to actually find security issues

**Classification: Intentional Trade-off**
The contractor made a conscious, documented decision. Nothing is functionally broken. However the trade-off chosen - sacrificing security visibility to unblock the pipeline - is the wrong one. The pipeline creates a false sense of security.

**Contractor's reasoning:**
DECISIONS.md says: *"Added `ignore-unfixed` and set severity to CRITICAL to get the scan to pass. Trivy was flagging a ton of stuff in the base image and blocking the pipeline."*

The goal (unblocking the pipeline) was legitimate. The method was wrong. The correct response is to fix what can be fixed, and use a `.trivyignore` file to consciously accept specific unfixable vulnerabilities with documented reasoning - not to globally suppress entire severity levels.

**What was done:**
- Changed `ignore-unfixed: false` and `severity: CRITICAL,HIGH` - the pipeline now fails on any fixable CRITICAL or HIGH vulnerability
- Added a second Trivy step with `exit-code: 0` and `severity: MEDIUM,LOW` to report lower severity findings without blocking the build
- Fixed all fixable vulnerabilities found by the scanner (see Finding 11)
- Created `.trivyignore` for vulnerabilities with no available fix, with comments documenting each accepted CVE and the date of acceptance

---

### Finding 11 - Vulnerabilities found and resolved by Trivy scan

**What was found:**
After reconfiguring the Trivy scan (Finding 10), the pipeline surfaced real vulnerabilities:

- **CVE-2026-45447** (HIGH, fixed) - openssl/libssl in the base image, fix available
- **CVE-2025-62727** (HIGH, fixed) - starlette DoS vulnerability, fix available in starlette 0.49.1+
- Multiple perl and ncurses CVEs (CRITICAL/HIGH, no fix available) - upstream has deferred fixes

**Classification: Bug** (for the fixable ones)
These were real, fixable vulnerabilities that the original scan configuration was hiding.

**Contractor's reasoning:**
The original Trivy configuration was deliberately suppressing these. See Finding 10.

**What was done:**
- Added `RUN apt-get update && apt-get upgrade -y` to the Dockerfile to fix OS-level vulnerabilities including openssl
- Upgraded `fastapi` to `0.136.3` in `requirements.txt` - this pulls in starlette 1.2.1 which resolves CVE-2025-62727
- Added unfixable CVEs (perl, ncurses) to `.trivyignore` with comments explaining each entry and confirming no fix was available as of the assessment date

---

### Finding 12 - `trivy-action` pinned to `@master`

**What was found:**
The Trivy action was pinned to `aquasecurity/trivy-action@master` - a floating reference that always pulls the latest commit on the master branch. Every other action in the pipeline was pinned to a specific version (`actions/checkout@v4`, `docker/setup-buildx-action@v3`, etc.), making this inconsistency stand out.

**Classification: Needs Improvement**
The pipeline works today. But `@master` is a supply chain security risk - a malicious commit to the trivy-action repo would run arbitrary code in the CI pipeline with access to all secrets. It also makes the pipeline non-reproducible.

**Contractor's reasoning:**
Not mentioned in DECISIONS.md. The contractor pinned every other action but was inconsistent here.

**What was done:**
Pinned to a specific verified release tag by checking `https://github.com/aquasecurity/trivy-action/releases` directly. Applied to both Trivy steps in the `security-scan` job.

---

## Terraform

---

### Finding 13 - SSH open to `0.0.0.0/0`

**What was found:**
The security group allowed SSH (port 22) from `0.0.0.0/0` - any IP on the internet. This exposes the instance to constant brute force attempts from automated bots that continuously scan the internet for open port 22.

**Classification: Intentional Trade-off**
The contractor knowingly left this open and documented it. The server functions, nothing is broken.

**Contractor's reasoning:**
DECISIONS.md says: *"Needed for initial setup and for the CI pipeline to deploy via SSH. Haven't had time to lock it down further."*

"Haven't had time" is not a valid justification for a security misconfiguration. Additionally, at the time this was written the deploy job was a TODO stub - there was no actual SSH deployment to justify the open rule.

**What was done:**
Port 22 remains open to `0.0.0.0/0` but security is enforced at the authentication layer - key-based authentication is required, and password authentication is disabled on Ubuntu AMIs by default. Without the private key, no connection can be established regardless of IP. The private key is stored as a GitHub Actions secret and distributed to developers securely.

This is the standard production pattern for EC2 SSH access. The ideal long-term solution is AWS Systems Manager Session Manager - which requires zero open ports and controls access via IAM - but that is documented as a future improvement rather than implemented here, as it requires additional Terraform resources (IAM instance profile, SSM endpoints) beyond the assignment scope.

---

### Finding 14 - Hardcoded AMI ID

**What was found:**
`main.tf` hardcoded `ami = "ami-0c7217cdde317cfec"`. This AMI ID only exists in `us-east-1`. Running `terraform plan` in any other region fails with `InvalidAMIID.NotFound`. Additionally, a January 2024 AMI never receives OS security patches unless the ID is manually updated.

**Classification: Intentional Trade-off**
The contractor made a conscious, documented decision with a specific incident as justification.

**Contractor's reasoning:**
DECISIONS.md says: *"We had an incident where the latest Ubuntu AMI changed and broke the Docker CE install script (incompatible containerd version). Pinning the AMI ensures reproducible infrastructure."*

The concern is legitimate - unexpected AMI changes breaking Docker installation is a real problem. However the solution is wrong. Pinning the entire OS image to solve a Docker version compatibility issue sacrifices OS security patches and region portability. The correct fix is to pin the specific Docker and containerd versions, not the entire OS.

**What was done:**
Two changes:
1. Replaced the hardcoded AMI with a dynamic `data "aws_ami"` lookup in `main.tf` that finds the latest Ubuntu 22.04 LTS image for the configured region - solving region portability
2. Pinned specific Docker CE and containerd versions in `user-data.sh` to address the contractor's legitimate compatibility concern

This gives the best of both: the OS stays current with security patches, while the specific Docker/containerd versions known to work remain locked.

---

### Finding 15 - `t2.micro` instead of `t3.micro`

**What was found:**
`variables.tf` defaulted the instance type to `t2.micro`. The t2 family is the previous generation of burstable EC2 instances. t3 is the current generation equivalent - same free tier eligibility, same price, better CPU performance, and an improved burst credit model.

**Classification: Needs Improvement**
Nothing is broken. This is simply using an outdated instance type when a better option exists at identical cost.

**Contractor's reasoning:**
Not mentioned in DECISIONS.md. Likely the first free tier option considered without checking for newer equivalents.

**What was done:**
Changed the default from `t2.micro` to `t3.micro` in `variables.tf`. One-line change with no downside.

---

### Finding 16 - No Elastic IP

**What was found:**
The EC2 instance had no Elastic IP. AWS assigns a dynamic public IP by default that changes every time the instance stops and restarts. Any DNS records, CI/CD secrets storing the host IP, or saved SSH configurations would break silently on the next instance restart.

**Classification: Needs Improvement**
Nothing breaks on initial deployment. The failure only manifests the first time the instance restarts - a crash, a maintenance window, or a Terraform change - at which point everything pointing to the old IP silently stops working.

**Contractor's reasoning:**
Not mentioned in DECISIONS.md. The instance works on first deploy, making this problem invisible until it happens.

**What was done:**
Added an `aws_eip` resource in `main.tf` attached to the instance, and added an `elastic_ip` output in `outputs.tf`. Note: Elastic IPs are free when attached to a running instance but incur a small charge when the instance is stopped - worth being aware of in a real deployment.

---

### Finding 17 - Local Terraform state

**What was found:**
No backend configuration exists in `main.tf`, so Terraform saves state locally on whoever's machine runs `terraform apply`. In a team environment, each member has their own local state file. Terraform has no shared record of what infrastructure exists, which can lead to duplicate resource creation and conflicting changes.

**Classification: Intentional Trade-off**
The contractor made a conscious, documented decision.

**Contractor's reasoning:**
DECISIONS.md says: *"Running with local state file for now. This is a single-operator deployment - adding S3 backend and DynamoDB locking is overkill for one person running terraform apply. Will add remote state if we scale the team."*

The reasoning is valid for a single-operator setup. The contractor also acknowledged the limitation and documented the path forward.

**What was done:**
Kept local state as-is. The production solution is an S3 backend with DynamoDB locking - S3 stores a shared state file accessible to all team members, DynamoDB prevents concurrent `terraform apply` runs. This was not implemented because creating the required AWS resources (S3 bucket + DynamoDB table) falls outside the free tier constraint of this assignment. The implementation path is documented here for when the team scales.

---

### Finding 18 - Hardcoded placeholder in `ssh_command` output

**What was found:**
`outputs.tf` contained:
```hcl
value = "ssh -i <your-key>.pem ubuntu@${aws_instance.app.public_ip}"
```
The `<your-key>` placeholder was hardcoded, making the output misleading. It also referenced `aws_instance.app.public_ip` rather than the Elastic IP, meaning after the Elastic IP was added the output would show the wrong IP.

**Classification: Needs Improvement**

**Contractor's reasoning:**
Not mentioned in DECISIONS.md.

**What was done:**
Updated the output to use dynamic values:
```hcl
value = "ssh -i sentiment-api-key.pem.pem ubuntu@${aws_eip.app.public_ip}"
```

---

## Initiative

---

### Initiative 1 - Docker Compose for local development

**What was added:**
A `docker-compose.yml` file in the repo root defining the full local development environment. Features:
- Builds from the local Dockerfile (not GHCR) so developers can test changes immediately
- Exposes port 8080
- `restart: "no"` for local dev - failures are visible rather than silently restarted
- Healthcheck against `/ready` so the container is only marked healthy after the model is loaded

Developers can now run the entire stack with `docker compose up` and tear it down with `docker compose down`. No flags to remember, no setup steps beyond cloning the repo.

---

### Initiative 2 - IMDSv2 enforcement

**What was added:**
A `metadata_options` block in the `aws_instance` resource in `main.tf`:
```hcl
metadata_options {
  http_endpoint               = "enabled"
  http_tokens                 = "required"
  http_put_response_hop_limit = 1
}
```

`http_tokens = "required"` enforces IMDSv2 - every request to the instance metadata service at `169.254.169.254` must include a session token. Without this, any process on the instance (including one triggered by an SSRF vulnerability) can freely fetch temporary AWS credentials and access the AWS account. IMDSv2 requires a PUT request to obtain a token first, which a simple SSRF attack cannot perform.

`http_put_response_hop_limit = 1` prevents the token from being forwarded beyond the instance itself, blocking container escape scenarios.

All AWS-managed tooling (CloudWatch, SSM agent, AWS CLI, boto3) supports IMDSv2 natively - nothing breaks. This is a standard AWS security best practice and a common compliance requirement (SOC2, ISO27001).

---

### Initiative 3 — Medium and Low vulnerability reporting

**What was added:**
A second Trivy scan step in the `security-scan` job that runs after the main CRITICAL/HIGH scan:

```yaml
- name: Trivy vulnerability report (medium/low)
  uses: aquasecurity/trivy-action@v0.36.0
  with:
    image-ref: ${{ env.IMAGE_NAME }}:scan
    format: table
    exit-code: 0
    severity: MEDIUM,LOW
```

`exit-code: 0` means this step always passes — it reports findings without blocking the pipeline. This gives the DevSecOps or DevOps team full visibility into lower severity vulnerabilities so they can be tracked and addressed over time, without creating unnecessary pipeline failures for issues that pose low immediate risk.

This completes a three-tier security posture:
- **CRITICAL/HIGH fixable** → block the pipeline
- **CRITICAL/HIGH unfixed** → accepted via `.trivyignore` with documented reasoning  
- **MEDIUM/LOW** → logged and visible, never blocking

---

## Summary Table

| # | Area | Finding | Classification | Fixed? |
|---|------|---------|---------------|--------|
| 1 | requirements.txt | scikit-learn version incompatible with model | Bug |  Yes |
| 2 | Dockerfile | No `.dockerignore` | Needs Improvement |  Yes |
| 3 | Dockerfile | Full Python base image | Needs Improvement |  Yes |
| 4 | Dockerfile | HEALTHCHECK uses wrong endpoint | Bug |  Yes |
| 5 | Dockerfile | No OS package upgrade | Needs Improvement |  Yes |
| 6 | CI/CD | Deploy job missing dependencies | Bug |  Yes |
| 7 | CI/CD | Deploy job is a TODO stub | Bug |  Yes |
| 8 | CI/CD | Uppercase image name breaks registry push | Bug |  Yes |
| 9 | CI/CD | Missing `packages: write` permission | Bug |  Yes |
| 10 | CI/CD | Trivy scan configured to suppress results | Intentional Trade-off | ✅ Yes |
| 11 | CI/CD | Fixable vulnerabilities found by Trivy | Bug |  Yes |
| 12 | CI/CD | `trivy-action` pinned to `@master` | Needs Improvement |  Yes |
| 13 | Terraform | SSH open to `0.0.0.0/0` | Intentional Trade-off |  Improved |
| 14 | Terraform | Hardcoded AMI ID | Intentional Trade-off |  Yes |
| 15 | Terraform | `t2.micro` instead of `t3.micro` | Needs Improvement | Yes |
| 16 | Terraform | No Elastic IP | Needs Improvement |  Yes |
| 17 | Terraform | Local Terraform state | Intentional Trade-off |  Documented |
| 18 | Terraform | Hardcoded placeholder in ssh_command output | Needs Improvement |  Yes |
| 19 | Initiative | Docker Compose for local dev | - |  Added |
| 20 | Initiative | IMDSv2 enforcement | - |  Added |
| 21 | Initiative | Medium/Low vulnerability logging | — | Added |

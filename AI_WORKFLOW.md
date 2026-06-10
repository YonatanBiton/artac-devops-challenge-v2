# AI Workflow Documentation

## Tools Used

**Claude (Anthropic)** - Primary tool used throughout the entire assignment.
Used for: debugging errors, understanding unfamiliar concepts (Terraform, IMDSv2), assessing findings, generating fixes, and explaining the reasoning behind each decision.

**ChatGPT (OpenAI)** - Used for quick isolated questions.
Used for: small reference questions such as the differences between Python base image variants (python:3.12 vs python:3.12-slim vs python:3.12-alpine).

---

## Prompts That Worked Well

### Example 1 - Inspecting the model file to find the root cause

After the initial scikit-learn version fix (downgrading to 1.5.2) didn't resolve the `/predict` 500 error, I asked Claude to help diagnose more deeply rather than keep guessing versions.

**Prompt:**
> "The same error persists even after downgrading to scikit-learn 1.5.2. Can you give me a command to inspect the model file directly and find what scikit-learn version it was actually saved with?"

**Why it worked:**
Instead of continuing to guess which version to try, Claude suggested loading the model with pickle directly and printing the classifier's `__dict__`. The output included `InconsistentVersionWarning: Trying to unpickle estimator LogisticRegression from version 1.8.0` - giving us the definitive answer. This eliminated all guesswork and pointed directly to the fix: `scikit-learn==1.8.0`.

---

### Example 2 - Trivy vulnerability triage

After reconfiguring the Trivy scan to actually surface vulnerabilities, the CI failed with a full report of 14 findings across OS packages and Python packages. Rather than researching each CVE individually, I pasted the full report and asked Claude to triage it.

**Prompt:**
> "Here is the full Trivy security report output from my CI. Which vulnerabilities are fixable and which are not? What should I do for each one?"

**Why it worked:**
Claude correctly read the `Status` column of each CVE (`fixed`, `affected`, `fix_deferred`) and gave a clear, actionable response for each category:
- `fixed` → update the package
- `affected` / `fix_deferred` → add to `.trivyignore` with documentation

This saved significant research time and produced a structured action plan from a raw security report in one step.

---

### Example 3 - Understanding IMDSv2 in depth

Before implementing IMDSv2 enforcement, I wanted to understand not just what to add but why it mattered and whether it would break anything.

**Prompt:**
> "What is IMDSv2, why does it matter for this specific app, and what exactly does each line of the metadata_options block do? Also - would enforcing it break CloudWatch or other AWS tooling?"

**Why it worked:**
Claude explained the full attack vector (SSRF vulnerability → request to 169.254.169.254 → stolen AWS credentials → full account access), confirmed that the sentiment API itself doesn't call the metadata service so no app changes were needed, and explained each configuration line individually:
- `http_endpoint = "enabled"` - keep the service on
- `http_tokens = "required"` - enforce token-based access (the key line)
- `http_put_response_hop_limit = 1` - prevent token forwarding beyond the instance

It also confirmed that all AWS-managed tooling (CloudWatch, SSM agent, AWS CLI) supports IMDSv2 natively, so nothing would break. This gave me the confidence to implement it correctly and explain it fully.

---

## Examples Where AI Was Wrong or Suboptimal

### Example 1 - Non-existent version number

While fixing the `trivy-action@master` pin, Claude suggested pinning to `aquasecurity/trivy-action@0.28.0` as a specific stable version. When I pushed, the CI failed with:

```
Unable to resolve action `aquasecurity/trivy-action@0.28.0`, unable to find version `0.28.0`
```

The version simply didn't exist. Claude suggested it without verifying it against the actual GitHub releases page. I caught it by reading the CI error, then went to `https://github.com/aquasecurity/trivy-action/releases` directly, found the actual latest release tag (`v0.36.0`), and used that instead.

**Lesson:** AI tools can confidently suggest specific version numbers that don't exist. Always verify version pins against the actual source - package registries, GitHub releases, or Docker Hub - before committing them.

---

### Example 2 - Overcomplicated SSH security solution

When assessing the SSH security group rule (`0.0.0.0/0`), Claude initially suggested restricting SSH to my home IP (`/32`) as the fix. I implemented it and pushed. Later, while thinking through the deploy job, I realized this would break GitHub Actions deployment since runners use different IPs.

Claude then suggested removing port 22 entirely and using AWS Systems Manager Session Manager. While technically correct as the ideal long-term solution, SSM requires significant additional Terraform work (IAM instance profiles, SSM endpoints) that goes beyond the assignment scope - and would still not solve the immediate need to implement the deploy job.

The actual correct solution was the standard production pattern: keep port 22 open to `0.0.0.0/0` but enforce key-based authentication. This is how EC2 SSH access works by default - the security comes from the private key, not IP restriction. It's fully compatible with both developer access and GitHub Actions CI/CD deployment via secrets.

I caught this by thinking through the full end-to-end deploy flow myself rather than accepting Claude's suggestion at face value.

**Lesson:** AI tools can overcomplicate solutions. Sometimes the standard, well-established approach is better than a sophisticated alternative. Always think through the full end-to-end system before implementing a security change.

---

## Time Estimate

**Total time spent on the assignment:** ~8 hours

**Estimated time without AI assistance:** ~12-16 hours

The main time savings came from:
- Diagnosing the scikit-learn bug - without AI, manually reading tracebacks and cross-referencing scikit-learn changelogs would have taken significantly longer
- Trivy vulnerability triage - researching 14 CVEs individually vs. getting a structured action plan in one step
- Understanding unfamiliar Terraform concepts (IMDSv2, remote state, AMI data sources) - AI explanations with context replaced hours of documentation reading


**Where AI did not save time (or cost time):**
- The incorrect version suggestion for `trivy-action` required an extra push/fail cycle to catch
- The SSH back-and-forth (restrict to IP → remove entirely → revert to open with key auth) involved three separate changes and commits due to following suboptimal AI suggestions before thinking it through independently


## Senior Review Pass

After completing the initial assessment and fixes, I used Claude as a senior DevOps reviewer by giving it access to the full repository and asking it to audit everything as if it were a senior engineer reviewing a junior's work.

**Prompt:**
> "Act as a senior DevOps engineer reviewing this repository. Go through the Dockerfile, CI/CD pipeline, Terraform configuration, and documentation and give me every finding you would raise in a real code review - things that are wrong, suboptimal, or missing. Be honest and don't hold back."

**What this produced:**
Claude returned a structured list of findings across four areas - pipeline design, Docker/dependencies, Terraform, and documentation. Many of these were issues I had not caught in my own assessment, including:

- The pipeline pushing `:latest` before gates pass
- Test dependencies shipping in the production image
- Docker log rotation missing (disk exhaustion risk)
- The `aws_eip` deprecation
- The port mapping bug in `user-data.sh` (`${app_port}:${app_port}` vs `${app_port}:8080`)
- The `.terraform.lock.hcl` being gitignored (contradicting my own criticism of `@master` pins)
- Missing `PYTHONUNBUFFERED` and `PYTHONDONTWRITEBYTECODE` env vars

**What I did:**
Went through each finding one by one, understood what it meant and why it mattered before implementing it, and made the fixes. Not everything was implemented - Fix 4 (scanning the pushed image by digest) was understood but documented as a known limitation rather than implemented, as the complexity outweighed the benefit for this assignment scope.

**Why this approach worked:**
Using AI as a reviewer rather than just a helper produced a different quality of feedback. Instead of asking "how do I do X", asking "what's wrong with everything" surfaces blind spots that task-focused prompting misses entirely.
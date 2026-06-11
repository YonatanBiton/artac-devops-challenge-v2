# Sentiment Analysis API

[![CI/CD Pipeline](https://github.com/YonatanBiton/artac-devops-challenge-v2/actions/workflows/ci.yml/badge.svg)](https://github.com/YonatanBiton/artac-devops-challenge-v2/actions/workflows/ci.yml)


A FastAPI service that serves a pre-trained scikit-learn sentiment classifier. Send it a piece of text, get back a sentiment prediction and confidence score.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/predict` | POST | Accepts `{"text": "..."}`, returns `{"sentiment": "positive/negative", "confidence": 0.92}` |
| `/health` | GET | Liveness probe - returns 200 if the server process is running |
| `/ready` | GET | Readiness probe - returns 200 only after the model is loaded and ready to serve |

---

## Architecture

```
┌─────────────┐     push to main     ┌─────────────────────────────────────┐
│  Developer  │ ──────────────────►  │           GitHub Actions            │
└─────────────┘                      │                                     │
                                     │  build → test → security-scan       │
                                     │              │                       │
                                     │              ▼                       │
                                     │  deploy (only if all pass)          │
                                     └──────────────┬──────────────────────┘
                                                    │
                                    push image      │  SSH deploy
                                         ┌──────────┴──────────┐
                                         ▼                     ▼
                                   ┌──────────┐         ┌──────────────┐
                                   │   GHCR   │         │  EC2 Instance│
                                   │ (Registry│ ──────► │  (Docker)    │
                                   └──────────┘  pull   └──────────────┘
```

- **GHCR** - GitHub Container Registry stores the built Docker image
- **EC2** - AWS EC2 instance (`t3.micro`) runs the container
- **Elastic IP** - static public IP attached to the instance so the address never changes on restart

---

## Local Development

### Prerequisites
- [Docker Desktop](https://www.docker.com/products/docker-desktop/)

### Run with Docker Compose (recommended)

```bash
docker compose up
```

The app will be available at `http://localhost:8080`. The container waits for the ML model to fully load before accepting traffic.

```bash
docker compose down    # stop and remove the container
docker compose logs -f # follow logs
```

### Run with Docker directly

```bash
docker build -t sentiment-api .
docker run -p 8080:8080 sentiment-api
```

### Test the endpoints

```bash
# Liveness check
curl http://localhost:8080/health

# Readiness check (returns 503 until model is loaded)
curl http://localhost:8080/ready

# Prediction
curl -X POST http://localhost:8080/predict \
  -H "Content-Type: application/json" \
  -d '{"text": "I love this product"}'
```

---

## Running Tests

```bash
pip install -r requirements-dev.txt
pytest tests/ -v
```

---

## CI/CD Pipeline

The pipeline runs automatically on every push to `main` and on pull requests.

| Job | What it does |
|-----|-------------|
| `build` | Builds the Docker image and pushes it to GHCR |
| `test` | Runs the full test suite with pytest |
| `security-scan` | Scans the image with Trivy for CRITICAL/HIGH vulnerabilities, logs MEDIUM/LOW |
| `deploy` | SSHs into the EC2 instance, pulls the new image, restarts the container |

**Deployment only runs if build, test, and security-scan all pass.**

### Required GitHub Secrets

| Secret | Description |
|--------|-------------|
| `SSH_PRIVATE_KEY` | Private key for SSH access to the EC2 instance |
| `EC2_HOST` | Public IP address of the EC2 instance (use the Elastic IP) |

---

## Infrastructure (Terraform)

The infrastructure is defined as code in the `terraform/` directory. It provisions an AWS EC2 instance with a security group and a static Elastic IP.

### Prerequisites
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5.0
- AWS credentials configured (`aws configure`)
- An SSH key pair created in your target AWS region

### Setup

```bash
cd terraform

# Copy the example vars file and fill in your values
cp terraform.tfvars.example terraform.tfvars

# Initialize Terraform (downloads AWS provider)
terraform init

# Preview what will be created
terraform plan

# Create the infrastructure
terraform apply
```

### Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `aws_region` | AWS region to deploy to | `us-east-1` |
| `instance_type` | EC2 instance type | `t3.micro` |
| `app_port` | Port the application listens on | `8080` |
| `docker_image` | Docker image to deploy | *(required)* |
| `ssh_key_name` | Name of your AWS SSH key pair | `sentiment-api-key` |

### Outputs

After `terraform apply`, Terraform prints:

| Output | Description |
|--------|-------------|
| `elastic_ip` | Static public IP of the server |
| `app_url` | Full URL to access the application |
| `ssh_command` | Ready-to-run SSH command to connect to the instance |

### Destroy infrastructure

```bash
terraform destroy
```

> Remember to destroy the infrastructure when done to avoid AWS charges. Elastic IPs incur a small charge when not attached to a running instance.

---

## Security Notes

- The Docker image runs as a non-root user (`appuser`)
- IMDSv2 is enforced on the EC2 instance to prevent credential theft via SSRF
- EBS volume encryption is enabled at rest
- Trivy scans block on CRITICAL/HIGH fixable vulnerabilities
- SSH access requires key-based authentication - password authentication is disabled

---

## Project Structure

```
├── app/                    # Application source code (FastAPI)
├── models/                 # Pre-trained ML model
├── tests/                  # Test suite
├── terraform/              # AWS infrastructure as code
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── user-data.sh
│   └── terraform.tfvars.example
├── Dockerfile              # Production container definition
├── docker-compose.yml      # Local development setup
├── requirements.txt        # Python dependencies
├── .dockerignore           # Files excluded from Docker build
├── .trivyignore            # Accepted CVE exceptions
├── ASSESSMENT.md           # Inherited codebase assessment
└── AI_WORKFLOW.md          # AI tool usage documentation
```

#!/bin/bash
set -euxo pipefail

exec > /var/log/user-data.log 2>&1

echo "=== Installing Docker ==="
apt-get update -y
apt-get install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y \
  docker-ce=5:27.5.1-1~ubuntu.22.04~jammy \
  docker-ce-cli=5:27.5.1-1~ubuntu.22.04~jammy \
  containerd.io=1.7.25-1 \
  docker-buildx-plugin=0.20.0-1~ubuntu.22.04~jammy

systemctl enable docker
systemctl start docker

usermod -aG docker ubuntu # grants permissions

echo "=== Pulling and running application ==="
# Image is pulled from a public GHCR package.
# No authentication required. If the package is made private,
# add a docker login step here using an EC2 instance role or a stored secret.
docker pull ${docker_image}
docker run -d \
  --name sentiment-api \
  --restart unless-stopped \
  -p ${app_port}:8080 \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  ${docker_image}

docker image prune -f

echo "=== User data script completed ==="

#!/bin/bash

# ========================================
# Automated Blue-Green Deployment Lab Setup
# ========================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}🔧 Step 1: Initialize and Apply Terraform...${NC}"
cd terraform
terraform init -input=false
terraform apply -auto-approve -input=false

echo -e "${GREEN}✓ Terraform applied successfully${NC}\n"

# Get EC2 Public IP from Terraform output
JENKINS_IP=$(terraform output -raw jenkins_ip)
if [ -z "$JENKINS_IP" ]; then
  echo -e "${RED}❌ Jenkins IP not found in Terraform output. Check your terraform output.${NC}"
  exit 1
fi
echo -e "${GREEN}Jenkins Public IP: ${JENKINS_IP}${NC}\n"

cd ..

echo -e "${YELLOW}📋 Step 2: Update Ansible Inventory with EC2 IP...${NC}"
cat > ansible/inventory.ini <<EOF
[jenkins]
$JENKINS_IP ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_rsa
EOF

echo -e "${GREEN}✓ Inventory updated with Jenkins IP${NC}\n"

echo -e "${YELLOW}⚙️ Step 3: Run Ansible Playbook to Configure Jenkins...${NC}"
cd ansible
ansible-playbook -i inventory.ini jenkins_setup.yml
cd ..

echo -e "${GREEN}✓ Jenkins installed and configured${NC}\n"
echo -e "${YELLOW}🌐 Access Jenkins at: http://$JENKINS_IP:8080${NC}"
echo -e "${YELLOW}Run this on the EC2 instance to get Jenkins password:${NC}"
echo -e "${GREEN}sudo cat /var/lib/jenkins/secrets/initialAdminPassword${NC}\n"

echo -e "${YELLOW}🐳 Step 4: Configure Docker Login inside Jenkins...${NC}"
echo -e "${YELLOW}In Jenkins UI → Manage Credentials → Add Docker Hub credentials (ID: dockerhub-pass)${NC}\n"

echo -e "${YELLOW}📦 Step 5: Verify Kubernetes cluster connection (if EKS configured)...${NC}"
echo -e "${YELLOW}Make sure kubectl context is set up for Jenkins user${NC}\n"

echo -e "${YELLOW}🚀 Step 6: Run Jenkins Pipeline for Blue-Green Deployment...${NC}"
echo -e "${YELLOW}In Jenkins → New Item → Pipeline → Paste Jenkinsfile content from app folder${NC}"
echo -e "${YELLOW}Save → Build Now → Wait for Docker image push and Kubernetes deploy${NC}\n"

echo -e "${YELLOW}🔁 Step 7: Switch Traffic Between Blue and Green${NC}"
echo -e "To switch manually run inside Jenkins pipeline or locally:"
echo -e "${GREEN}kubectl patch service myapp-service -p '{\"spec\":{\"selector\":{\"app\":\"myapp\",\"color\":\"green\"}}}'${NC}\n"

echo -e "${YELLOW}🔍 Step 8: Validate Deployment${NC}"
echo -e "Check Pods and Services:"
echo -e "${GREEN}kubectl get pods${NC}"
echo -e "${GREEN}kubectl get svc${NC}"
echo -e "Access your app using the External IP shown under service output.\n"

echo -e "${GREEN}✅ Automated Blue-Green Deployment Setup Completed Successfully!${NC}"

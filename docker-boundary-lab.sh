export SSH_USER=baba1
export SSH_PASSWORD=password
export BOUNDARY_ADDR=<YOUR_HCP_CLUSTER_URL>
boundary authenticate

# Manually export Boundary Token if needed
# export BOUNDARY_TOKEN=

# Generate Boundary Worker Config
./create_boundary_config.sh

# Boundary Worker
docker run -d \
  --name=boundary-worker \
  -p 9202:9202 \
  -v "$(pwd)":/boundary/ \
  hashicorp/boundary-enterprise

#Get the Worker Authorization Registration Request from the container logs and register it in HCP Boundary Controler
docker container logs boundary-worker

# Boundary Worker up and running

# Run this first to generate PKI keys to use for SSH Access to the target
ssh-keygen -t rsa -b 4096 -N '' -qf ./id_rsa
# if this fails, back up: docker run --rm -it --entrypoint '/keygen.sh ' linuxserver/openssh-server 
# just save the private key as id_rsa and the public key as id_rsa.pub

# Boundary Target
docker run -d \
  --name=boundary-target \
  --hostname=demo-server \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=Etc/UTC \
  -e PASSWORD_ACCESS=true \
  -e PUBLIC_KEY_FILE=./id_rsa.pub \
  -e USER_PASSWORD=$SSH_PASSWORD \
  -e USER_NAME=$SSH_USER  \
  -e SUDO_ACCESS=false \
  -p 2222:2222 \
  --restart unless-stopped \
  lscr.io/linuxserver/openssh-server:latest

export HOSTIP=$(docker inspect   -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' boundary-target)

#####################
### DEPLOY BOUNDARY ORGS AND PROJECTS

export ORG_ID=$(boundary scopes create \
 -scope-id=global -name="Docker Lab" \
 -description="Docker Org" \
 -format=json | jq -r '.item.id')

export PROJECT_ID=$(boundary scopes create \
 -scope-id=$ORG_ID -name="Docker Servers" \
 -description="Server Machines" \
 -format=json | jq -r '.item.id')

### DEPLOY TARGETS
export LINUX_TCP_TARGET=$(boundary targets create tcp \
   -name="Linux TCP" \
   -description="Linux server with tcp" \
   -address=$HOSTIP \
   -default-port=2222 \
   -scope-id=$PROJECT_ID \
   -egress-worker-filter='"dockerlab" in "/tags/type"' \
   -format=json | jq -r '.item.id')

export LINUX_SSH_TARGET=$(boundary targets create ssh \
   -name="Linux Cred Injection" \
   -description="Linux server with SSH Injection" \
   -address=$HOSTIP \
   -default-port=2222 \
   -scope-id=$PROJECT_ID \
   -egress-worker-filter='"dockerlab" in "/tags/type"' \
   -format=json | jq -r '.item.id')

### DEPLOY CREDENTIAL STORE AND LIBRARY
export BOUNDARY_CRED_STORE_ID=$(boundary credential-stores create static \
-name="Boundary Static Cred Store" \
 -scope-id=$PROJECT_ID \
 -format=json | jq -r '.item.id')

export BOUNDARY_CRED_UPW=$(boundary credentials create username-password \
-name="ssh-user" \
 -credential-store-id=$BOUNDARY_CRED_STORE_ID \
 -username=$SSH_USER \
 -password env://SSH_PASSWORD \
 -format=json | jq -r '.item.id')

### ADD CREDENTIALS
boundary targets add-credential-sources \
-id=$LINUX_SSH_TARGET \
-injected-application-credential-source=$BOUNDARY_CRED_UPW

#######################################################
#### to Destroy everything 
export ORG_ID_DEL=$(boundary scopes list -format=json | jq -r '.items[] | select(.name == "Docker Lab") | .id')
export WORKER_DEL=$(boundary workers list -format=json | jq -r '.items[0] | select(.type == "pki") | .id')

boundary scopes delete -id=$ORG_ID_DEL
boundary workers delete -id=$WORKER_DEL

docker stop boundary-target
docker rm boundary-target

docker stop boundary-worker
docker rm boundary-worker

rm -rf ./file
rm -rf ./recording

#optional
# rm id_rsa id_rsa.pub config.hcl
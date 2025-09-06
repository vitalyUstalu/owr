# Deploy Waiting Room in Kubernetes with Hipster Shop and Redis Operator

This guide shows how to deploy the **Google Hipster Shop demo application**, a **Redis instance via Redis Operator**, and the **Waiting Room (OpenResty + Redis)** service in a Kubernetes cluster.  
The Waiting Room will sit in front of the Hipster Shop frontend and control access with queueing logic.

---

## 1. Deploy Hipster Shop

First, deploy the official **Hipster Shop** demo application from Google:

```bash
kubectl create namespace hipster-shop
kubectl apply -n hipster-shop -f https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/main/release/kubernetes-manifests.yaml
```
This will create multiple microservices in the hipster-shop namespace, including the frontend service we’ll protect with the waiting room.

---

## 2. Install Redis Operator and Redis

We use Redis Operator to easily provision and manage Redis instances inside the cluster.

Add the operator Helm repository and install:
```bash
helm repo add redis-operator https://ot-container-kit.github.io/helm-charts/
helm repo update

# Install the operator
helm install -n redis-operator redis-operator redis-operator/redis-operator --create-namespace

# Deploy a Redis instance in hipster-shop namespace
helm install -n hipster-shop redis-wr redis-operator/redis
```
This creates a Redis deployment and exposes it via a Kubernetes service redis-wr.hipster-shop.svc.cluster.local.

---

## 3. Deploy the Waiting Room (OpenResty + Redis)
The Waiting Room is provided as a container image:
ghcr.io/vitalyustalu/owr:0.0.1

We prepared Kubernetes manifests (Deployment, Service, and ConfigMap) in manifest.yaml.

These include:
- Deployment: Runs the Waiting Room container with environment variables for Redis and backend configuration.
- Service: Exposes the Waiting Room internally in the cluster.
- ConfigMap: Provides DNS resolver configuration for OpenResty (needed for Redis hostname resolution).

Apply the manifests:
```bash
kubectl apply -n hipster-shop -f manifest.yaml
```

## 4. Accessing the Application

Once deployed:
- Users will connect through the Waiting Room (waiting-room service).
- The Waiting Room will manage tokens and queue logic via Redis.
- If slots are available (WR_MAX_ACTIVE), users are proxied to frontend.hipster-shop.svc.cluster.local.
- Otherwise, they are queued until space frees up.

⚠️ To expose the Waiting Room externally, you need to create an Ingress resource suitable for the Ingress controller installed in your cluster (e.g., NGINX Ingress Controller, Traefik, Istio, etc.).

---

✅ You now have Hipster Shop running with a Waiting Room in front, backed by Redis.
This setup is suitable for experimenting with traffic shaping, queueing, and high-load scenarios.
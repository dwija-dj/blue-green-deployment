#!/bin/bash
kubectl apply -f ../k8s/namespace.yaml
kubectl apply -f ../k8s/deployment-green.yaml
kubectl rollout status deployment/myapp-green -n blue-green
echo "Green environment deployed!"

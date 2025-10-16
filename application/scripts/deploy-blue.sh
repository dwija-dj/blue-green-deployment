#!/bin/bash
kubectl apply -f ../k8s/namespace.yaml
kubectl apply -f ../k8s/deployment-blue.yaml
kubectl rollout status deployment/myapp-blue -n blue-green
echo "Blue environment deployed!"

#!/bin/bash
kubectl patch service myapp-service -n blue-green -p '{"spec":{"selector":{"color":"green"}}}'
echo "Traffic switched to GREEN environment!"

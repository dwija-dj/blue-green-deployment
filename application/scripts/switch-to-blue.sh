#!/bin/bash
kubectl patch service myapp-service -n blue-green -p '{"spec":{"selector":{"color":"blue"}}}'
echo "Traffic switched to BLUE environment!"

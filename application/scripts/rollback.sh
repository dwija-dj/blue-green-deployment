#!/bin/bash
CURRENT_COLOR=$(kubectl get service myapp-service -n blue-green -o jsonpath='{.spec.selector.color}')
if [ "$CURRENT_COLOR" == "blue" ]; then
    NEW_COLOR="green"
else
    NEW_COLOR="blue"
fi

kubectl patch service myapp-service -n blue-green -p "{\"spec\":{\"selector\":{\"color\":\"$NEW_COLOR\"}}}"
echo "Rolled back to $NEW_COLOR environment!"

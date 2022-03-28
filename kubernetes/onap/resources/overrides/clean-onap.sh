#!/bin/bash

helm -n onap undeploy onap
kubectl -n onap get pvc -o name | xargs kubectl -n onap delete
kubectl -n onap delete secret cmpv2-ca-key-pair onap-cps-core-app-user-creds onap-so-ingress-certs oom-cert-service-client-tls-secret oom-cert-service-server-tls-secret
kubectl -n onap delete configmap kube-root-ca.crt

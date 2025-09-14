#!/bin/bash
IP=127.0.0.1

rm -rf ./nginx/certs/
mkdir -p ./nginx/certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout ./nginx/certs/selfsigned.key \
    -out ./nginx/certs/selfsigned.crt \
    -subj "/CN=$IP"


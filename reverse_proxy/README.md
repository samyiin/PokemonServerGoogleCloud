# NGINX
The revrse proxy of choice is NGINX. 

## Compile NGINX with older SSL
Since NDS and 3DS is speaking an older SSL language, and the older SSL is already disabled on gogle vm, we will have to run nginx in a container too. 
We will choose 
wget -O openssl.tar.gz https://github.com/openssl/openssl/archive/refs/tags/OpenSSL_1_0_2u.tar.gz
wget http://nginx.org/download/nginx-1.18.0.tar.gz

## NDS constrain't
In order to pass the SSL credential, we will use the NDS constrain't loophole. 
I already download for you, but if you need to replicate: 

*step1* Go read this website: https://flewkey.com/blog/2020-07-12-nds-constraint.html
*step2* Go to https://certs.larsenv.xyz/index.html and download "Wii NWC Prod 1". I already download for you, it's placed under /reverse_proxy/source/nds_constraint/WII_NWC_1_CERT.p12
*step3* Go to the folder you stored the downloaded keypair, and generate artifacts with this command: 
```bash
openssl pkcs12 -in WII_NWC_1_CERT.p12 -passin pass:alpine -passout pass:alpine -out keys.txt -legacy -provider default
```
You will see /reverse_proxy/nds_constraint/keys.txt
*step4* Read /reverse_proxy/nds_constraint/keys.txt, Copy "-----BEGIN CERTIFICATE-----" to "-----END CERTIFICATE-----" to NWC.crt and "-----BEGIN ENCRYPTED PRIVATE KEY-----" to "-----END ENCRYPTED PRIVATE KEY-----" to NWC.key. 
*step5* Run 
```bash
openssl genrsa -out server.key 1024
openssl req -new -key server.key -out server.csr
```
Then keep pressing enter, until you see they sask for common name，and you fill in "*.*.*"
*step6* Run 
```bash
openssl x509 -req -in server.csr -CA NWC.crt -CAkey NWC.key -CAcreateserial -out server.crt -days 3650 -sha1
```
Notice when as for pass phrase for NWC.key, you will fill in "alpine"
*step7* Turn the certifications into nginx certifications: 
```bash
cat server.crt NWC.crt > server-chain.crt
```

Notice: openssl version: OpenSSL 3.6.2 7 Apr 2026 (Library: OpenSSL 3.6.2 7 Apr 2026)